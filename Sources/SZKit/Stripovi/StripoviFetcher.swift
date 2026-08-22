import Foundation

/// What one comic's fetch produced.
public struct StripoviFetchResult: Equatable, Sendable {
    public let bytes: Int64
    /// The file the download is recorded against — the first page.
    public let file: URL
    public let pages: Int
    /// Whether the shipped page-address rule stopped working part-way and the
    /// addresses had to be read off the site instead.
    ///
    /// Reported rather than swallowed: it is the signal that the catalogue
    /// needs rebuilding, and the only place it can be noticed is a download
    /// that had to work around it.
    public let resolvedFromSite: Bool

    /// Pages the site counts but does not actually have.
    ///
    /// Said out loud rather than passed over, because the comic really is
    /// short a page and a reader who counts will notice. Nothing can be done
    /// about it from here — the file is not on the server.
    public let missingFromSource: [Int]
}

/// Fetches one Stripovi comic, a page at a time.
///
/// No web view and no session: this site is behind nothing at all, so the
/// pages are ordinary requests. That makes this the simplest of the app's
/// fetchers and the only one that is testable without a network.
///
/// **The shipped rule is a shortcut, not a source of truth.**
/// `StripoviCatalog.Comic` builds each page's address from a pattern inferred
/// from the site. It is verified, but it is still an inference about a site
/// that never promised it, and one day a directory will be renamed or a comic
/// re-scanned at a different padding.
///
/// So the rule is used until it fails, and the first failure demotes the whole
/// download: from that page on, every address is read off the comic's own page
/// exactly as if no rule had ever shipped. That costs one extra request per
/// page and nothing else — where a stale rule with no fallback would fail
/// silently and permanently, for every reader, until the app was rebuilt.
public struct StripoviFetcher: Sendable {

    /// How long to leave between requests.
    ///
    /// The same courtesy every other host in this app is extended. This is a
    /// small site rather than an archive, so the interval is doing real work
    /// here even though nothing has ever refused us.
    public static let betweenPages: Duration = .milliseconds(500)

    private let transport: Transport
    private let interval: Duration

    public init(transport: Transport, interval: Duration = StripoviFetcher.betweenPages) {
        self.transport = transport
        self.interval = interval
    }

    public func fetch(comic: StripoviCatalog.Comic,
                      in catalogue: StripoviCatalog,
                      into directory: URL,
                      progress: (@Sendable (Int, Int) -> Void)? = nil)
        async throws -> StripoviFetchResult {

        let download = try PageDownload(directory: directory,
                                        images: comic.pageImages.map(catalogue.url))
        let total = download.pageCount
        guard total > 0 else { throw PageFetchError.noPages }

        // Pages already on disk from an interrupted attempt cost nothing the
        // second time — neither a request nor a pause.
        var fetched = (1...total).filter { download.has(page: $0) }.count
        progress?(fetched, total)

        var resolving = false
        var asked = false
        /// Pages the site itself does not have. Skipped rather than retried:
        /// they will never arrive, and refusing to finish would mean a comic
        /// with one hole in it could never be read at all.
        var absent: Set<Int> = []
        for page in 1...total {
            try Task.checkCancellation()
            guard !download.has(page: page) else { continue }

            // Before the request, so pages already present are never charged
            // for a pause they did not cause.
            if asked { try await Task.sleep(for: interval) }
            asked = true

            var bytes: Data?
            /// Why the rule's address was rejected, kept so that a fallback
            /// which also fails does not replace the real reason with its own.
            var ruleRefusal = ""

            if !resolving {
                do {
                    bytes = try await image(at: download.address(page: page),
                                            referer: Stripovi.comicURL(id: comic.id),
                                            page: page)
                } catch let refusal as DownloadError where refusal.isRateLimited {
                    // Never demote on a refusal. The rule is not what is
                    // wrong, and resolving would answer a server asking us to
                    // stop with *two* requests per page instead of one.
                    throw refusal
                } catch let stop as NotWorthResolving {
                    // The server misbehaved rather than the address being
                    // wrong — a redirect loop, or one leading off the site.
                    // Asking the same server where the page lives runs into
                    // whatever it is already doing, so this goes straight out
                    // with its own reason intact.
                    throw stop.reason
                } catch {
                    // The address did not work. Whether that is the rule going
                    // stale or the page being gone is not decided here — it is
                    // decided by asking the site, below.
                    ruleRefusal = Self.why(error)
                }
            }

            if bytes == nil {
                let address: String
                do {
                    address = try await resolve(comic: comic.id, page: page, in: catalogue)
                } catch let refusal as DownloadError where refusal.isRateLimited {
                    throw refusal
                } catch {
                    // Both reasons, because either alone misleads. The rule
                    // failing is why the fallback ran at all, and reporting
                    // only the fallback's complaint hides what started it.
                    throw PageFetchError.pageFailed(
                        page: page,
                        reason: ruleRefusal.isEmpty ? Self.why(error)
                            : "\(ruleRefusal); and reading the address off the site: "
                            + Self.why(error))
                }

                // The site naming the very address the rule built is the site
                // agreeing with us: the address was right and the file is
                // simply not there. That is a hole in the source, not a stale
                // rule, so the page is skipped and the rule is left alone —
                // demoting here would spend a second request on every
                // remaining page to be told the same thing.
                //
                // Stripovi.com really is like this: its page menu counts
                // twenty pages, its markup links the eighteenth, and that file
                // 404s while nineteen and twenty are served normally.
                if !resolving, address == download.address(page: page) {
                    absent.insert(page)
                    progress?(fetched, total)
                    continue
                }

                // Somewhere else, so the shipped rule is out of date. From
                // here the whole download behaves as though none had shipped.
                resolving = true

                do {
                    // One pause for the second request too: resolving is two
                    // requests, and the courtesy applies to both.
                    try await Task.sleep(for: interval)
                    bytes = try await image(
                        at: address,
                        referer: Stripovi.readerURL(comic: comic.id, page: page),
                        page: page)
                } catch let refusal as DownloadError where refusal.isRateLimited {
                    throw refusal
                } catch is PageMissing {
                    // The site's own answer is a page that is not there.
                    absent.insert(page)
                    progress?(fetched, total)
                    continue
                } catch {
                    let fallback = Self.why((error as? NotWorthResolving)?.reason ?? error)
                    throw PageFetchError.pageFailed(
                        page: page,
                        reason: ruleRefusal.isEmpty ? fallback
                            : "\(ruleRefusal); and reading the address off the site: \(fallback)")
                }
            }

            try download.write(bytes ?? Data(), page: page)
            fetched += 1
            progress?(fetched, total)
        }

        return StripoviFetchResult(bytes: try download.finish(absentFromSource: absent),
                                   file: download.recordedFile,
                                   pages: total - absent.count,
                                   resolvedFromSite: resolving,
                                   missingFromSource: absent.sorted())
    }

    // MARK: - One request

    /// A failure that reading the address off the site cannot fix.
    ///
    /// The fallback exists for an address that has gone wrong, and it works by
    /// asking the site where the page lives now. When the server is the thing
    /// misbehaving — redirecting in a circle, or off the site altogether —
    /// that second question runs into the same behaviour and answers with its
    /// own complaint, which then replaces the real one. This carries the
    /// original reason past the fallback untouched.
    private struct NotWorthResolving: Error {
        let reason: PageFetchError
    }

    /// The server says there is no such file.
    ///
    /// Its own case because it is the one failure that can mean the *source*
    /// is incomplete rather than this app being wrong about an address — and
    /// those need opposite responses. See the loop in `fetch`.
    private struct PageMissing: Error {}

    /// One failure's reason, without the sentence that names the page.
    ///
    /// These get composed into a message that already says which page failed,
    /// and `PageFetchError.pageFailed` says it too — so used whole they read
    /// "Page 1 could not be fetched: Page 1 could not be fetched: HTTP 301".
    static func why(_ error: Error) -> String {
        if case .pageFailed(_, let reason) = error as? PageFetchError { return reason }
        return Library.reason(error)
    }

    /// How many redirects one page may be sent through.
    ///
    /// Three is generous for a site that uses exactly one. The limit is here
    /// so a server that redirects to itself cannot spin a download for ever.
    private static let maxRedirects = 3

    /// The page image at an address, checked before it is accepted.
    ///
    /// **Redirects are followed here**, which the shared transport pointedly
    /// does not do. That rule belongs to file-host probes, where the answer is
    /// the `Location` header itself and following it would download the file.
    /// For a picture it is simply wrong: this site stores some files under a
    /// lowercased path and answers the mixed-case one with a 301, per *file*
    /// rather than per comic — `mm0117.jpg` is served directly and `mm0118.jpg`
    /// redirects. Refusing to follow turned an ordinary redirect into a comic
    /// that could not be downloaded.
    ///
    /// A redirect is not treated as the shipped rule being stale: the rule
    /// named a real page and the server is pointing at where it keeps it, so
    /// demoting would spend an extra request per page on something one hop
    /// settles.
    private func image(at address: String, referer: String, page: Int) async throws -> Data {
        guard var url = URL(string: address) else {
            throw PageFetchError.pageFailed(page: page, reason: "not an address: \(address)")
        }

        for _ in 0...Self.maxRedirects {
            var request = HTTPRequest(url: url)
            request.headers["Referer"] = referer
            request.headers["Accept"] = "image/jpeg,image/png,image/*,*/*;q=0.8"
            // The default is zero, which means "do not read the body at all" —
            // right for a probe reading a header, and here it would write a
            // comic of empty pages.
            request.maxBodyBytes = 32 << 20

            let response = try await transport.send(request)
            if let refusal = RetryAfter.refusal(status: response.status,
                                                header: response.headers["retry-after"],
                                                host: url.host ?? Stripovi.host) {
                throw refusal
            }

            if (300..<400).contains(response.status) {
                // Resolved against the address it came from, because a
                // `Location` is allowed to be relative and this one need not
                // stay absolute for ever.
                guard let location = response.location,
                      let next = URL(string: location, relativeTo: url)?.absoluteURL else {
                    throw PageFetchError.pageFailed(
                        page: page, reason: "HTTP \(response.status) with nowhere to go")
                }
                // Fenced, exactly like every other part of this app that
                // follows a link: a redirect off the site is a page fetched
                // from somewhere nobody chose.
                guard let host = next.host?.lowercased(),
                      host == Stripovi.host || host.hasSuffix("." + Stripovi.host) else {
                    throw NotWorthResolving(reason: .pageFailed(
                        page: page,
                        reason: "redirected off the site, to \(next.host ?? "somewhere else")"))
                }
                url = next
                continue
            }

            // Told apart from every other failure, because it is the only
            // one that can mean "there is no such page" rather than "this
            // address is wrong".
            if response.status == 404 { throw PageMissing() }
            guard (200..<300).contains(response.status) else {
                throw PageFetchError.pageFailed(page: page, reason: "HTTP \(response.status)")
            }
            // Checked here rather than only in `PageDownload`, so that a page
            // of HTML — which is what a site serves when an address stops
            // existing — demotes to resolving instead of failing outright.
            guard ImageBytes.looksLikeImage(response.body) else {
                throw PageFetchError.pageFailed(
                    page: page, reason: "the server sent something that is not an image")
            }
            return response.body
        }
        throw NotWorthResolving(
            reason: .pageFailed(page: page, reason: "too many redirects"))
    }

    /// The address of one page, read off the comic's own page.
    private func resolve(comic id: Int, page: Int,
                         in catalogue: StripoviCatalog) async throws -> String {
        guard let url = URL(string: Stripovi.readerURL(comic: id, page: page)) else {
            throw PageFetchError.pageFailed(page: page, reason: "not an address")
        }
        var request = HTTPRequest(url: url)
        request.maxBodyBytes = 2 << 20
        let response = try await transport.send(request)
        if let refusal = RetryAfter.refusal(status: response.status,
                                            header: response.headers["retry-after"],
                                            host: url.host ?? Stripovi.host) {
            throw refusal
        }
        guard (200..<300).contains(response.status),
              let html = StripoviPage.decode(response.body),
              let relative = StripoviPage.pageImage(html) else {
            throw PageFetchError.pageFailed(
                page: page, reason: "the site no longer says where this page is")
        }
        return catalogue.url(relative)
    }
}

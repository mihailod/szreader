import Foundation

/// What one book's own page says about its file.
public struct ComicBookPlusFile: Equatable, Sendable {
    /// "Jesse_James_024__Avon_1955.09_10__c2c___Willie_Williams.cbz"
    public let filename: String?
    public let bytes: Int64?
    /// Where the file is actually fetched from, when the page offers it.
    ///
    /// Present only for a signed-in reader: logged out, the site replaces the
    /// link with an invitation to register.
    public let downloadURL: String?

    public init(filename: String?, bytes: Int64?, downloadURL: String?) {
        self.filename = filename; self.bytes = bytes; self.downloadURL = downloadURL
    }
}

/// Reads a `?dlid=` book page.
public enum ComicBookPlusBookPage {

    /// "File name" and the value beside it. The class on the value cell is
    /// matched loosely because it carries a second class only sometimes.
    private static let filename = Rx(
        #">File name</td>\s*<td[^>]*>([^<]+)</td>"#, [.caseInsensitive])

    /// "21.61mb consisting of 36 pages". Megabytes to two decimals, which is
    /// all the site states — so the byte count is rounded from it and is a
    /// display figure, not an exact length.
    private static let size = Rx(#"([0-9]+(?:\.[0-9]+)?)\s*mb\s+consisting"#, [.caseInsensitive])

    /// The download itself.
    ///
    /// Matched on the `/dload/` path rather than on the link's text, which is
    /// an image on some skins, and rather than on the host, which has changed
    /// once already.
    private static let download = Rx(
        #"href=["'](https?://[^"']*/dload/\?[^"']+)["']"#, [.caseInsensitive])

    public static func read(_ html: String) -> ComicBookPlusFile {
        let name = filename.firstGroups(html)?[1]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let megabytes = size.firstGroups(html).flatMap { Double($0[1]) }
        // The page writes `&amp;` between query parameters, and a URL with a
        // literal "&amp;" in it fetches nothing.
        let link = download.firstGroups(html).map { HTMLText.decodeEntities($0[1]) }

        return ComicBookPlusFile(
            filename: (name?.isEmpty == false) ? name : nil,
            bytes: megabytes.map { Int64($0 * 1_048_576) },
            downloadURL: link)
    }
}

/// Comic Book Plus as a file host.
///
/// An issue's mirror is its book page, not a download address — see
/// `Store.importComicBookPlus` for why — so this host's job is to turn the one
/// into the other, and it does that by reading the page rather than by
/// building a URL.
///
/// That is deliberate. The address the site serves carries four parameters,
/// two of which (the format and the stored filename) are not on the listing
/// page at all, and one of which is a session token that rolls over on its
/// own. Constructing it would mean guessing at all four and getting a silent
/// 403 whenever any guess went stale; reading it means the site states its own
/// answer and this host copies it down.
public struct ComicBookPlusHost: FileHost {

    public let name = "comicbookplus"

    /// The site's cookies as a `Cookie` header, or nil when the reader has
    /// never signed in.
    ///
    /// Injected rather than read here because the cookies live in the app's
    /// web view, which SZKit cannot see and should not learn about. The
    /// closure is what keeps the session out of this layer and out of the
    /// database: it is asked immediately before each request and the answer is
    /// never stored.
    private let cookies: @Sendable () async -> String?

    public init(cookies: @escaping @Sendable () async -> String? = { nil }) {
        self.cookies = cookies
    }

    /// Book pages, and nothing else.
    ///
    /// Narrow on purpose. The resolved `/dload/` address is on the same domain
    /// and must *not* be claimed: it is handed back from `directLink` for the
    /// downloader to fetch directly, and a host that claimed it too would be
    /// asked to resolve it a second time and would read a file as a page.
    public func canHandle(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased(),
              host == ComicBookPlus.host || host.hasSuffix("." + ComicBookPlus.host)
        else { return false }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.contains { $0.name == "dlid" } == true
    }

    /// The filename and size the page states.
    ///
    /// No session needed: the description of a book is public, and only the
    /// link to its file is not. So a shelf can show what a download will cost
    /// before the reader has signed in to anything.
    public func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        guard canHandle(url) else { throw HostError.unrecognisedURL(url.absoluteString) }
        let page = try await fetch(url, via: transport, authenticated: false)
        let file = ComicBookPlusBookPage.read(page)
        return FileMeta(filename: file.filename, size: file.bytes.map(Int.init))
    }

    /// The address the file actually comes from.
    ///
    /// Resolved immediately before use and never stored: the session token in
    /// it is replaced whenever the site's session rolls over, so a copy kept
    /// anywhere is a stale credential.
    public func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        guard canHandle(url) else { throw HostError.unrecognisedURL(url.absoluteString) }
        let page = try await fetch(url, via: transport, authenticated: true)
        let file = ComicBookPlusBookPage.read(page)

        guard let link = file.downloadURL, let resolved = URL(string: link) else {
            // The one failure a reader can do something about, so it says the
            // thing to do rather than naming a status code. Logged out, the
            // site puts "To download files please Log in or Register" exactly
            // where this link would be.
            throw HostError.apiError(
                "Sign in to \(IssueSite.comicbookplus.display) in the browser, "
                + "then try again — the site only offers downloads to members.")
        }
        // The Referer is what the site's own pages send, and its image paths
        // refuse a request without one. Cheap to send and it costs nothing if
        // the file server does not care.
        //
        // The size goes with it because the download itself will not state
        // one: `/dload/` is a PHP script that streams the file, and answers
        // with no `Content-Length` at all — measured, not assumed. Without
        // this the reader watches a bar sit at zero until the comic simply
        // appears, and the free-space check has nothing to weigh.
        return DirectLink(url: resolved,
                          headers: ["Referer": url.absoluteString,
                                    "User-Agent": UserAgent.browser],
                          expectedBytes: file.bytes)
    }

    /// One page fetch, with the reader's session when it is wanted.
    private func fetch(_ url: URL, via transport: Transport,
                       authenticated: Bool) async throws -> String {
        var headers = ["User-Agent": UserAgent.browser]
        if authenticated, let jar = await cookies(), !jar.isEmpty {
            headers["Cookie"] = jar
        }
        // A book page is around 130 KB; the cap is generous enough for one to
        // grow and small enough that a redirect to something enormous cannot
        // be read into memory.
        let response = try await transport.send(
            HTTPRequest(url: url, headers: headers, maxBodyBytes: 1_000_000))
        guard response.status == 200 else {
            if response.status == 404 { throw HostError.notFound }
            throw TransportError.badStatus(response.status)
        }
        return response.text
    }
}

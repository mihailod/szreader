import Foundation

/// Where downloaded comics live.
///
/// Application Support, not Caches: the OS can purge Caches at any moment,
/// including mid-read. Excluded from backup so a library of 90 MB archives
/// never lands in iCloud.
public struct LibraryPaths: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public static func standard() throws -> LibraryPaths {
        let base = try FileManager.default.url(for: .applicationSupportDirectory,
                                               in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        var root = base.appendingPathComponent("SZReader/comics", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? root.setResourceValues(values)
        return LibraryPaths(root: root)
    }

    public func directory(forIssue id: Int) -> URL {
        root.appendingPathComponent("\(id)", isDirectory: true)
    }
}

public struct DownloadOutcome: Equatable, Sendable {
    public let issueID: Int
    public let path: URL
    public let kind: ArchiveKind
    public let bytes: Int64
    public let mirrorURL: String
}

/// Turns "I want to read this" into a file on disk.
public final class Library {

    private let store: Store
    private let paths: LibraryPaths
    private let registry: HostRegistry
    private let transport: Transport
    private let downloader: FileDownloader

    /// Space a download needs relative to the archive size.
    ///
    /// The archive lands first, then unpacks alongside itself before the
    /// archive is deleted, so peak usage is already roughly double. 3x leaves
    /// room for unpacked pages exceeding the compressed archive and for the
    /// system needing air — running out mid-unpack leaves a half-written comic
    /// and a full disk, which is far worse than refusing up front.
    public static let spaceHeadroom = 3.0

    private let availableSpace: @Sendable () -> Int64

    public init(store: Store, paths: LibraryPaths,
                transport: Transport, downloader: FileDownloader,
                registry: HostRegistry = HostRegistry(),
                availableSpace: @escaping @Sendable () -> Int64 = Library.systemFreeSpace) {
        self.availableSpace = availableSpace
        self.store = store; self.paths = paths; self.registry = registry
        self.transport = transport; self.downloader = downloader
        // Downloads record paths relative to this root, so a relocated app
        // container does not orphan every file.
        store.libraryRoot = paths.root
    }

    /// A reason short enough to show a person.
    ///
    /// Interpolating an `NSError` dumps its whole userInfo — the failing URL,
    /// the session task, the underlying error — which fills an alert and
    /// buries the one sentence that says what went wrong.
    public static func reason(_ error: Error) -> String {
        // Matched explicitly: every Swift Error bridges to NSError, so an
        // `is NSError` test is always true and would swallow our own messages.
        switch error {
        case let e as DownloadError:  return e.description
        case let e as HostError:      return e.description
        case let e as ArchiveError:   return e.description
        case let e as TransportError: return e.description
        // Without this a database failure renders as "SZKit.SQLiteError error
        // 1" — the code with the message thrown away, which says nothing about
        // what actually went wrong.
        case let e as SQLiteError:    return "database: " + e.description
        default: break
        }
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        // The few URL errors worth distinguishing, in words that say what to
        // do about it. The rest fall back to the system wording.
        switch ns.code {
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "blocked: the mirror offered an insecure connection"
        case NSURLErrorNotConnectedToInternet:  return "no internet connection"
        case NSURLErrorTimedOut:                return "timed out"
        case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost:
            return "mirror unreachable"
        case NSURLErrorNetworkConnectionLost:   return "connection lost"
        default:                                return ns.localizedDescription
        }
    }

    /// Aborts a transfer whose declared size will not fit.
    ///
    /// Runs on the response headers, before a byte is written, so nothing has
    /// to be cleaned up and the host is asked nothing extra.
    private func spaceCheck() -> @Sendable (Int64) throws -> Void {
        let free = availableSpace()
        let headroom = Self.spaceHeadroom
        return { expected in
            guard free > 0, expected > 0 else { return }
            let required = Int64(Double(expected) * headroom)
            if free < required {
                throw DownloadError.insufficientSpace(required: required, available: free)
            }
        }
    }

    /// Free space iOS will actually hand this app.
    public static func systemFreeSpace() -> Int64 {
        guard let url = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                     in: .userDomainMask,
                                                     appropriateFor: nil, create: false),
              let values = try? url.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let capacity = values.volumeAvailableCapacityForImportantUsage
        else { return 0 }
        return Int64(capacity)
    }

    /// Refuses a download that cannot fit, before a byte is fetched.
    ///
    /// Checked once for the issue rather than per mirror: running out of disk
    /// is not a bad mirror, and trying the next one would waste the user's
    /// bandwidth to fail the same way. Unknown size means no check — a missing
    /// figure must not block a download that would have fitted.
    func checkSpace(forIssue issueID: Int) throws {
        // Only what is already known. Asking the host costs a request, and a
        // second request moments after resolving a link looks like scraping —
        // the transfer's own Content-Length covers the rest, in `spaceCheck`.
        guard let size = try store.knownSize(forIssue: issueID), size > 0 else { return }
        let required = Int64(Double(size) * Self.spaceHeadroom)
        let free = availableSpace()
        guard free > 0 else { return }        // could not read the volume
        if free < required {
            throw DownloadError.insufficientSpace(required: required, available: free)
        }
    }

    /// Unpacks a freshly downloaded comic so the first open is instant.
    ///
    /// Opening a comic means unwrapping any outer archive and extracting the
    /// pages, and for a RAR that is most of a minute of work on a large scan.
    /// Doing it at download time hides it inside a wait the reader has already
    /// accepted, instead of charging it to the first tap on the cover — where
    /// the same seconds are the difference between "opening" and "broken".
    ///
    /// The document is discarded: what matters is the unpacked directory it
    /// leaves behind, which every later open reuses.
    public func prepareForReading(issueID: Int) throws {
        _ = try document(forIssue: issueID)
    }

    /// Opens a downloaded comic for reading.
    ///
    /// Unpacking a solid RAR is slow enough to notice, so callers should do
    /// this off the main thread.
    public func document(forIssue issueID: Int) throws -> ComicDocument {
        guard let file = try store.downloadedFile(issueID: issueID),
              FileManager.default.fileExists(atPath: file.path.path) else {
            throw DownloadError.notAnArchive("not downloaded yet")
        }
        return try ComicDocument(fileURL: file.path,
                                 workDirectory: paths.directory(forIssue: issueID))
    }

    /// Bytes currently held by downloaded comics.
    public var diskUsage: Int64 { store.totalDownloadedBytes }


    /// Downloads an issue, trying mirrors in order until one yields a valid
    /// archive.
    ///
    /// Mirror fallback is the whole point of the `drugi sken` convention: links
    /// rot, and a dead primary should cost the user nothing.
    @discardableResult
    public func fetch(issueID: Int,
                           progress: (@Sendable (DownloadProgress) -> Void)? = nil)
        async throws -> DownloadOutcome {

        if let existing = try store.downloadedFile(issueID: issueID),
           FileManager.default.fileExists(atPath: existing.path.path) {
            return existing
        }

        let directory = paths.directory(forIssue: issueID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Before the network, and outside the mirror loop: a full disk is not a
        // dead mirror, so this must abort rather than be collected as one.
        try checkSpace(forIssue: issueID)

        let mirrors = try store.liveMirrors(forIssue: issueID)

        // Two links under one issue are usually alternatives, but sometimes
        // they are halves of a split archive. Deciding needs their names, so
        // this asks the hosts before downloading anything — one small request
        // per mirror, and only when there is more than one to compare.
        if mirrors.count > 1,
           let parts = MultiPartArchive.parts(try await namedMirrors(mirrors)) {
            return try await fetchParts(parts, issueID: issueID, into: directory,
                                        progress: progress)
        }

        var failures: [String] = []
        for mirror in mirrors {
            guard let url = URL(string: mirror.url) else { continue }
            do {
                let outcome = try await attempt(mirror: mirror, url: url,
                                                issueID: issueID, into: directory,
                                                progress: progress)
                try store.recordDownload(issueID: issueID, mirrorURL: mirror.url,
                                         path: outcome.path, bytes: outcome.bytes)
                return outcome
            } catch let error as DownloadError where error.isInsufficientSpace {
                throw error
            } catch HostError.notFound {
                failures.append("\(mirror.host): dead")
                try store.markMirrorDead(url: mirror.url)
            } catch {
                failures.append("\(mirror.host): \(Self.reason(error))")
            }
        }
        throw DownloadError.allMirrorsFailed(failures)
    }

    /// Each mirror paired with the filename its host reports.
    ///
    /// Uses what a previous probe recorded and asks only for the rest, so a
    /// library whose titles have already been resolved pays nothing here.
    private func namedMirrors(_ mirrors: [MirrorLink])
        async throws -> [(source: MirrorLink, filename: String)] {

        var named: [(MirrorLink, String)] = []
        for mirror in mirrors {
            if let known = try? store.filename(forMirrorAt: mirror.url) {
                named.append((mirror, known))
                continue
            }
            guard let url = URL(string: mirror.url),
                  let meta = try? await registry.probe(url, via: transport),
                  let filename = meta.filename else { continue }
            try? store.recordFilename(filename, forMirrorAt: mirror.url)
            named.append((mirror, filename))
        }
        return named.map { (source: $0.0, filename: $0.1) }
    }

    /// Downloads every volume of a split archive, then hands back the first.
    ///
    /// All of them land in one directory under the names their host gave them,
    /// because that is the only way unrar will join them. The download is
    /// recorded against volume one, which is the file the reader opens.
    private func fetchParts(_ parts: [(source: MirrorLink, filename: String, part: Int)],
                            issueID: Int, into directory: URL,
                            progress: (@Sendable (DownloadProgress) -> Void)?)
        async throws -> DownloadOutcome {

        var failures: [String] = []
        var total: Int64 = 0
        var first: URL?

        for (index, piece) in parts.enumerated() {
            guard let url = URL(string: piece.source.url) else { continue }
            do {
                // One bar across the whole set: reported as a fraction of all
                // the volumes, so it climbs once instead of restarting per
                // piece.
                let slice: @Sendable (DownloadProgress) -> Void = { p in
                    guard p.expected > 0 else { return }
                    let done = (Double(index) + Double(p.received) / Double(p.expected))
                        / Double(parts.count)
                    progress?(DownloadProgress(received: Int64(done * 1_000_000),
                                               expected: 1_000_000))
                }
                let outcome = try await attempt(mirror: piece.source, url: url,
                                                issueID: issueID, into: directory,
                                                filename: piece.filename,
                                                sniff: piece.part == 1,
                                                progress: slice)
                total += outcome.bytes
                if piece.part == 1 { first = outcome.path }
            } catch {
                failures.append("\(piece.source.host) part \(piece.part): "
                                + "\(Self.reason(error))")
            }
        }

        // A split archive is all or nothing: a missing volume is not a comic
        // you can read some of.
        guard failures.isEmpty, let firstVolume = first else {
            throw DownloadError.allMirrorsFailed(
                failures.isEmpty ? ["split archive has no first volume"] : failures)
        }
        let kind = ArchiveKind.sniff(firstVolume)
        guard kind != .unknown else {
            throw DownloadError.notAnArchive("first volume is neither zip nor rar")
        }
        let outcome = DownloadOutcome(issueID: issueID, path: firstVolume, kind: kind,
                                      bytes: total, mirrorURL: parts[0].source.url)
        try store.recordDownload(issueID: issueID, mirrorURL: parts[0].source.url,
                                 path: firstVolume, bytes: total)
        return outcome
    }

    private func attempt(mirror: MirrorLink, url: URL, issueID: Int,
                         into directory: URL,
                         filename explicitName: String? = nil,
                         sniff: Bool = true,
                         progress: (@Sendable (DownloadProgress) -> Void)?)
        async throws -> DownloadOutcome {

        // Resolved immediately before use: these tokens expire in minutes, so
        // caching them would trade a cheap request for a confusing failure.
        let link = try await registry.directLink(url, via: transport)

        let name = explicitName ?? ((try? store.filename(forMirrorAt: mirror.url)) ?? nil)
        let filename = name ?? "\(issueID).bin"
        let finalURL = directory.appendingPathComponent(filename)
        let rawURL = directory.appendingPathComponent(filename + ".part")

        try? FileManager.default.removeItem(at: rawURL)
        try await downloader.download(link, to: rawURL, progress: progress,
                                      check: spaceCheck())

        switch link.postProcess {
        case .aesCTR(let key, let nonce)?:
            let plainURL = directory.appendingPathComponent(filename + ".dec")
            try? FileManager.default.removeItem(at: plainURL)
            try AES.decryptCTR(source: rawURL, destination: plainURL, key: key, nonce: nonce)
            try? FileManager.default.removeItem(at: rawURL)
            try FileManager.default.moveItem(at: plainURL, to: finalURL)
        case nil:
            try? FileManager.default.removeItem(at: finalURL)
            try FileManager.default.moveItem(at: rawURL, to: finalURL)
        }

        // Sniffing is both the extension check (a .cbr is often a zip) and the
        // proof that a Mega decrypt produced real data rather than noise.
        //
        // Skipped for volumes after the first: a later piece of a split
        // archive is a fragment, not something that has to stand on its own.
        let kind = ArchiveKind.sniff(finalURL)
        guard !sniff || kind != .unknown else {
            try? FileManager.default.removeItem(at: finalURL)
            throw DownloadError.notAnArchive(
                "magic bytes match neither zip nor rar (bad mirror, or wrong decryption)")
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: finalURL.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        return DownloadOutcome(issueID: issueID, path: finalURL, kind: kind,
                               bytes: bytes, mirrorURL: mirror.url)
    }

}

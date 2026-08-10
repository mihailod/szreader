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

    public init(store: Store, paths: LibraryPaths,
                transport: Transport, downloader: FileDownloader,
                registry: HostRegistry = HostRegistry()) {
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

        var failures: [String] = []
        for mirror in try store.liveMirrors(forIssue: issueID) {
            guard let url = URL(string: mirror.url) else { continue }
            do {
                let outcome = try await attempt(mirror: mirror, url: url,
                                                issueID: issueID, into: directory,
                                                progress: progress)
                try store.recordDownload(issueID: issueID, mirrorURL: mirror.url,
                                         path: outcome.path, bytes: outcome.bytes)
                return outcome
            } catch HostError.notFound {
                failures.append("\(mirror.host): dead")
                try store.markMirrorDead(url: mirror.url)
            } catch {
                failures.append("\(mirror.host): \(Self.reason(error))")
            }
        }
        throw DownloadError.allMirrorsFailed(failures)
    }

    private func attempt(mirror: MirrorLink, url: URL, issueID: Int,
                         into directory: URL,
                         progress: (@Sendable (DownloadProgress) -> Void)?)
        async throws -> DownloadOutcome {

        // Resolved immediately before use: these tokens expire in minutes, so
        // caching them would trade a cheap request for a confusing failure.
        let link = try await registry.directLink(url, via: transport)

        let name = (try? store.filename(forMirrorAt: mirror.url)) ?? nil
        let filename = name ?? "\(issueID).bin"
        let finalURL = directory.appendingPathComponent(filename)
        let rawURL = directory.appendingPathComponent(filename + ".part")

        try? FileManager.default.removeItem(at: rawURL)
        try await downloader.download(link, to: rawURL, progress: progress)

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
        let kind = ArchiveKind.sniff(finalURL)
        guard kind != .unknown else {
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

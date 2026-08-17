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

    /// Where a set downloaded once for many issues lives.
    public func directory(forSegment id: Int) -> URL {
        root.appendingPathComponent("set-\(id)", isDirectory: true)
    }

    /// Artwork taken from a comic's own first page.
    ///
    /// Beside the downloads rather than inside the issue's folder: removing a
    /// download deletes that folder, and a cover the reader has been looking
    /// at should not disappear with it.
    public func coverFile(forIssue id: Int) -> URL {
        let covers = root.appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: covers, withIntermediateDirectories: true)
        return covers.appendingPathComponent("\(id).jpg")
    }

    /// Small renderings of an issue's pages, for the grid a page is picked
    /// from.
    ///
    /// Emphatically *not* inside the issue's own folder. Once a download is
    /// unpacked that folder is the comic — `ComicDocument(unpackedAt:)` reads
    /// every image in it as a page — so a thumbnail written there would turn
    /// up in the middle of the magazine, at a fifth of the size of everything
    /// around it. `discardUnwrapped` would delete it too.
    ///
    /// Zero-padded so the directory lists in reading order, which is worth a
    /// great deal the first time you go looking in it.
    public func pageThumbnails(forIssue id: Int) -> URL {
        root.appendingPathComponent("thumbs/\(id)", isDirectory: true)
    }

    public func pageThumbnail(forIssue id: Int, page: Int) -> URL {
        pageThumbnails(forIssue: id)
            .appendingPathComponent(String(format: "%04d.jpg", page))
    }

    /// Every issue's thumbnails at once.
    public var allPageThumbnails: URL {
        root.appendingPathComponent("thumbs", isDirectory: true)
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
        // Without this a missing catalogue reads as "The operation couldn't be
        // completed. (SZKit.SeedError error 0.)" in the status line — which is
        // exactly the sentence that hid a catalogue left out of the app bundle.
        case let e as SeedError:      return e.description
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
    /// Removes a set: its files, and the record of every issue it served.
    ///
    /// One directory holds them all, so there is no removing a single issue
    /// from it — which is why the reader is told before agreeing to either.
    @discardableResult
    public func removeSegmentDownload(issueID: Int) throws -> Bool {
        guard let segment = try store.segment(forIssue: issueID) else { return false }
        let context = try store.context(forIssue: issueID) ?? ""
        for id in try store.issues(inSegment: segment, context: context) {
            _ = try store.deleteDownload(issueID: id)
        }
        try? FileManager.default.removeItem(at: paths.directory(forSegment: segment.id))
        return true
    }

    /// The set an issue belongs to, for the warning shown before either.
    public func segment(forIssue issueID: Int) throws -> IssueSegment? {
        try store.segment(forIssue: issueID)
    }

    /// Downloads a whole set and gives every issue in it its own file.
    ///
    /// The archives hold one PDF per issue, so after a single transfer each
    /// issue points at its own member. They share the unpacked directory,
    /// which is why removing one removes the set.
    private func fetchSegment(_ segment: IssueSegment, wanting issueID: Int,
                              progress: (@Sendable (DownloadProgress) -> Void)?)
        async throws -> DownloadOutcome {

        let directory = paths.directory(forSegment: segment.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let unpacked = directory.appendingPathComponent("contents", isDirectory: true)
        var entries = (try? UnpackedReader(root: unpacked).entries()) ?? []

        if entries.isEmpty {
            guard let url = URL(string: segment.url) else {
                throw DownloadError.notAnArchive("the set has no usable link")
            }
            try checkSpace(forIssue: issueID)
            let name = ((try? await registry.probe(url, via: transport).filename) ?? nil)
                ?? "set-\(segment.id)"
            let outcome = try await attempt(
                mirror: MirrorLink(url: segment.url, host: "", ordinal: 0),
                url: url, issueID: issueID, into: directory,
                filename: name, progress: progress)

            let reader = try ArchiveOpener.open(outcome.path, workDirectory: unpacked)
            entries = try reader.entries()
            // The archive has served its purpose; what is read from now on is
            // the members it left behind.
            try? FileManager.default.removeItem(at: outcome.path)
        }

        guard !entries.isEmpty else {
            throw DownloadError.notAnArchive("the set unpacked to nothing")
        }

        // Every issue the set covers now has a file of its own.
        let context = try store.context(forIssue: issueID) ?? ""
        var mine: DownloadOutcome?
        for id in try store.issues(inSegment: segment, context: context) {
            guard let issue = try store.issueIdentity(id: id),
                  let member = IssueSegment.member(entries, number: issue.number,
                                                   numberTo: issue.numberTo,
                                                   title: issue.title) else { continue }
            let file = unpacked.appendingPathComponent(member)
            let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size])
                as? Int64) ?? 0
            try store.recordDownload(issueID: id, mirrorURL: segment.url,
                                     path: file, bytes: size)
            if id == issueID {
                mine = DownloadOutcome(issueID: id, path: file, kind: .pdf,
                                       bytes: size, mirrorURL: segment.url)
            }
        }
        guard let mine else {
            throw DownloadError.notAnArchive("this issue is not in the set")
        }
        return mine
    }

    /// The document is discarded: what matters is the unpacked directory it
    /// leaves behind, which every later open reuses.
    public func prepareForReading(issueID: Int) throws {
        _ = try document(forIssue: issueID)
    }

    /// Saves the comic's first page as its artwork, and returns the reference
    /// to record against the issue.
    ///
    /// For issues the forum gave no cover image — the shelf shows them as a
    /// grey rectangle with an issue number, which is no help at all in
    /// finding one. Once the comic is on the device its own first page is
    /// almost always the cover, and is certainly better than a number.
    ///
    /// The reference is a scheme rather than a path. An absolute path is what
    /// broke downloads when the container was renamed, and this file is found
    /// from the library root the same way the archives are.
    public func captureCover(issueID: Int, maxPixelSize: Int = 600) throws -> String {
        let document = try document(forIssue: issueID)
        guard let page = try document.page(0, maxPixelSize: maxPixelSize) else {
            throw DownloadError.notAnArchive("first page could not be decoded")
        }
        let file = paths.coverFile(forIssue: issueID)
        guard PageRenderer.writeJPEG(page, to: file) else {
            throw DownloadError.notAnArchive("cover could not be written")
        }
        return Self.coverReference(issueID: issueID)
    }

    /// How wide a page thumbnail is rendered.
    ///
    /// Twice the widest a tile is ever drawn — about 190pt on an iPad — and no
    /// more: a 300-page magazine is 300 of these, and the point of the grid is
    /// to recognise a page at a glance rather than to read it.
    ///
    /// Changing this invalidates what is already on disk, which is why the app
    /// discards the cache when the number moves.
    public static let thumbnailPixels = 400

    /// A small rendering of one page, made once and kept.
    ///
    /// Nil rather than throwing: a page that will not decode is one blank
    /// square in a grid of hundreds, and there is nothing the reader could do
    /// about it. Every other tile still draws.
    ///
    /// Pass the open document to have a missing thumbnail rendered; without
    /// one this answers only from what is already on disk, which is what makes
    /// re-opening the grid a handful of file reads rather than a second pass
    /// over the whole magazine.
    public func pageThumbnail(_ page: Int, ofIssue issueID: Int,
                              renderingFrom document: ComicDocument? = nil) -> URL? {
        let file = paths.pageThumbnail(forIssue: issueID, page: page)
        if FileManager.default.fileExists(atPath: file.path) { return file }
        guard let document, page >= 0, page < document.pageCount,
              let image = (try? document.page(page, maxPixelSize: Self.thumbnailPixels)) ?? nil
        else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        return PageRenderer.writeJPEG(image, to: file) ? file : nil
    }

    /// Throws away one issue's thumbnails.
    ///
    /// Called when its download goes: the pages they were made from are gone,
    /// so the grid has nothing to show and the files are only taking up room.
    /// They cost a re-render if the issue is downloaded again, which is the
    /// same price as the first time.
    public func discardPageThumbnails(forIssue issueID: Int) {
        try? FileManager.default.removeItem(at: paths.pageThumbnails(forIssue: issueID))
    }

    public func discardAllPageThumbnails() {
        try? FileManager.default.removeItem(at: paths.allPageThumbnails)
    }

    /// Drops what is left over from unwrapping an inner archive.
    ///
    /// A RAR volume set whose volumes join into a single .cbr leaves three
    /// copies of the comic on the device: the .cbr the volumes extracted to,
    /// the copy written out to be opened, and the pages themselves. Only the
    /// pages are worth keeping, and they are the only one anything reads.
    ///
    /// Guarded by re-reading the comic from the pages alone first, because
    /// this deletes the last thing that could produce them again.
    private func discardUnwrapped(forIssue issueID: Int) {
        let directory = paths.directory(forIssue: issueID)
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(at: directory,
                                                    includingPropertiesForKeys: nil)) ?? []
        guard contents.contains(where: {
            $0.lastPathComponent.hasPrefix("nested-") && $0.lastPathComponent.hasSuffix("-work")
        }), let pages = try? ComicDocument(unpackedAt: directory),
              Self.readsBackWhole(pages) else { return }

        // Everything but the pages. Once they are unwrapped, nothing else in
        // the directory is read: not the archives, not the inner archive they
        // yielded, not the copy of it made to be opened, and not the marker
        // left by the extraction that produced them.
        for url in contents where !(url.lastPathComponent.hasPrefix("nested-")
                                    && url.lastPathComponent.hasSuffix("-work")) {
            try? fm.removeItem(at: url)
        }
    }

    /// Whether a comic really reads back: both ends decode.
    ///
    /// The cheapest check that would have caught a truncated or half-written
    /// extraction. Pages are decoded tiny, so this costs a few milliseconds
    /// against a download worth hundreds of megabytes.
    private static func readsBackWhole(_ document: ComicDocument) -> Bool {
        guard document.pageCount > 0 else { return false }
        let ends = Set([0, document.pageCount - 1])
        return ends.allSatisfy { (try? document.page($0, maxPixelSize: 32)) ?? nil != nil }
    }

    /// How a page-derived cover is written down. Resolved back to a file by
    /// whoever loads covers.
    public static func coverReference(issueID: Int) -> String { "szpage:\(issueID)" }

    /// The issue id in a reference, if that is what this is.
    public static func coverIssueID(reference: String) -> Int? {
        guard reference.hasPrefix("szpage:") else { return nil }
        return Int(reference.dropFirst("szpage:".count))
    }

    /// Opens a downloaded comic for reading.
    ///
    /// Unpacking a solid RAR is slow enough to notice, so callers should do
    /// this off the main thread.
    public func document(forIssue issueID: Int) throws -> ComicDocument {
        let directory = paths.directory(forIssue: issueID)

        // Already unpacked: the pages are all there is, because the archive
        // they came from is deleted as soon as they exist. Comics unpacked by
        // an earlier build still have theirs, so this is also where those get
        // their space back.
        if let unpacked = try? ComicDocument(unpackedAt: directory) {
            discardArchives(forIssue: issueID, keeping: unpacked)
            return unpacked
        }

        guard let file = try store.downloadedFile(issueID: issueID),
              FileManager.default.fileExists(atPath: file.path.path) else {
            throw DownloadError.notAnArchive("not downloaded yet")
        }
        let document = try ComicDocument(fileURL: file.path, workDirectory: directory)
        // The pages are out, so the archive is a second copy of the comic.
        // Dropped here rather than only after a download, so a comic unpacked
        // by an earlier build gets its space back the first time it is opened.
        discardArchives(forIssue: issueID, keeping: document)
        return document
    }

    /// Deletes the archives an issue was unpacked from.
    ///
    /// Only the archives: the recorded file and any sibling belonging to the
    /// same split set. Everything else in the directory is pages — for a
    /// single-archive comic they sit right beside it — and a rule any looser
    /// than "same stem as the archive" would take them too.
    ///
    /// Deleting an archive is the one irreversible thing this app does to a
    /// download, so it is done only against a comic that has been shown to
    /// read back — the marker alone says an extraction finished, not that
    /// what it produced can be decoded.
    private func discardArchives(forIssue issueID: Int, keeping document: ComicDocument) {
        // The test is whether the comic survives *without* them — opened from
        // the directory alone, as every later read will. Checking the document
        // in hand proves nothing: it was built from the archives, and a zip is
        // served straight out of the file, so it reads back perfectly right up
        // until the file is deleted and the comic becomes unopenable.
        guard let standalone = try? ComicDocument(unpackedAt: paths.directory(forIssue: issueID)),
              Self.readsBackWhole(standalone),
              let recorded = try? store.downloadedFile(issueID: issueID)?.path
        else { return }

        let fm = FileManager.default
        discardUnwrapped(forIssue: issueID)
        let stem = MultiPartArchive.stem(of: recorded.lastPathComponent)
        let siblings = (try? fm.contentsOfDirectory(
            at: recorded.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey])) ?? []
        for url in siblings {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                    .isRegularFile == true,
                  url.lastPathComponent == recorded.lastPathComponent
                    || MultiPartArchive.stem(of: url.lastPathComponent) == stem
            else { continue }
            try? fm.removeItem(at: url)
        }
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

        // Already here? The archive is deleted once its pages are out, so the
        // question is whether the comic can be read, not whether the file it
        // arrived in still exists. Asking about the file re-downloads every
        // comic that has been unpacked.
        if let existing = try store.downloadedFile(issueID: issueID),
           FileManager.default.fileExists(atPath: existing.path.path)
            || (try? ComicDocument(unpackedAt: paths.directory(forIssue: issueID))) != nil {
            return existing
        }

        // Some topics outlive their individual links and survive only as a
        // set: one archive holding every issue. Downloading any of them means
        // downloading all of them, so it is fetched once and shared.
        if let segment = try store.segment(forIssue: issueID) {
            return try await fetchSegment(segment, wanting: issueID, progress: progress)
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

    /// How many times one mirror is asked, when what it answers is a 5xx.
    ///
    /// Three tries two seconds apart, which turns archive.org's roughly
    /// one-in-three 500 into about one download in thirty needing the reader
    /// to tap again. Only 5xx: a 404 is an answer, and asking again is how a
    /// dead link becomes six seconds of waiting before the same message.
    private static let serverErrorAttempts = 3
    private static let serverErrorPause: UInt64 = 2_000_000_000

    private func attempt(mirror: MirrorLink, url: URL, issueID: Int,
                         into directory: URL,
                         filename explicitName: String? = nil,
                         sniff: Bool = true,
                         progress: (@Sendable (DownloadProgress) -> Void)?)
        async throws -> DownloadOutcome {

        var last: Error?
        for round in 1...Self.serverErrorAttempts {
            if round > 1 { try await Task.sleep(nanoseconds: Self.serverErrorPause) }
            do {
                return try await transfer(mirror: mirror, url: url, issueID: issueID,
                                          into: directory, filename: explicitName,
                                          sniff: sniff, progress: progress)
            } catch let error as DownloadError where error.isServerError {
                last = error
            }
        }
        throw last ?? DownloadError.badStatus(500)
    }

    /// One pass at one mirror: resolve, fetch, and check what arrived.
    private func transfer(mirror: MirrorLink, url: URL, issueID: Int,
                          into directory: URL,
                          filename explicitName: String?,
                          sniff: Bool,
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

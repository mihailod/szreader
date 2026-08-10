import XCTest
@testable import SZKit

/// Refusing a download that cannot fit.
final class FreeSpaceTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func makeStore(size: Int64?) throws -> (Store, Int) {
        let store = try Store()
        try store.ingest(html:
            "<div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>")
        let issue = try XCTUnwrap(try store.recent().first)
        if let size {
            try store.recordSize(size, forMirrorAt: "http://www.mediafire.com/?FAKEKEY013")
        }
        return (store, issue.id)
    }

    private func library(_ store: Store, free: Int64) -> Library {
        Library(store: store, paths: LibraryPaths(root: root),
                transport: StubTransport { _ in HTTPResponse(status: 200) },
                downloader: StubDownloader(bodies: [:]),
                availableSpace: { free })
    }

    /// A 100 MB archive needs 250 MB: it lands, then unpacks alongside itself
    /// before the archive is deleted.
    func testDownloadIsRefusedWhenSpaceIsShort() async throws {
        let (store, issueID) = try makeStore(size: 100_000_000)
        let library = library(store, free: 250_000_000)   // more than the file, less than 3x

        do {
            _ = try await library.fetch(issueID: issueID)
            XCTFail("download proceeded with too little space")
        } catch let error as DownloadError {
            guard case .insufficientSpace = error else {
                return XCTFail("wrong error: \(error)")
            }
            XCTAssertEqual("\(error)",
                           "No free space on device — make room or remove some downloads")
        }
    }

    /// Comfortably enough room: the check must not stand in the way.
    func testDownloadProceedsWhenThereIsRoom() throws {
        let (store, issueID) = try makeStore(size: 100_000_000)
        XCTAssertNoThrow(try library(store, free: 400_000_000).checkSpace(forIssue: issueID))
    }

    /// Exactly at the boundary counts as enough. 3x, so 100 MB needs 300 MB.
    func testBoundaryIsNotRefused() throws {
        let (store, issueID) = try makeStore(size: 100_000_000)
        XCTAssertNoThrow(try library(store, free: 300_000_000).checkSpace(forIssue: issueID))
        XCTAssertThrowsError(try library(store, free: 299_999_999).checkSpace(forIssue: issueID))
    }

    /// An unprobed mirror has no recorded size. That must not block a download
    /// which would have fitted perfectly well.
    /// Nothing recorded means nothing to check up front — the transfer's own
    /// Content-Length catches it instead, before any bytes are written.
    func testUnknownSizeDoesNotBlockUpFront() throws {
        let (store, issueID) = try makeStore(size: nil)
        XCTAssertNoThrow(try library(store, free: 1).checkSpace(forIssue: issueID))
    }

    /// Nor must a volume we cannot read.
    func testUnreadableVolumeDoesNotBlock() throws {
        let (store, issueID) = try makeStore(size: 100_000_000)
        XCTAssertNoThrow(try library(store, free: 0).checkSpace(forIssue: issueID))
    }


    /// The check happens before any network work, not per mirror: a full disk
    /// is not a dead mirror, and retrying wastes bandwidth to fail identically.
    func testRefusalDoesNotMarkMirrorsDead() async throws {
        let (store, issueID) = try makeStore(size: 100_000_000)
        _ = try? await library(store, free: 10_000_000).fetch(issueID: issueID)
        XCTAssertEqual(try store.liveMirrors(forIssue: issueID).count, 1,
                       "a full disk should not retire a working mirror")
    }
}

/// Aborting a transfer on its own declared size.
///
/// Most mirrors are MediaFire, whose probe reports a filename and no size, so
/// nothing is recorded up front. The size still arrives — in the response
/// headers of the transfer itself — which is where this catches it, without
/// asking the host a second question.
final class DeclaredSizeTests: XCTestCase {

    /// A downloader that announces a size, as a real server does.
    private struct SizedDownloader: FileDownloader {
        let declared: Int64
        func download(_ link: DirectLink, to destination: URL,
                      progress: (@Sendable (DownloadProgress) -> Void)?,
                      check: (@Sendable (Int64) throws -> Void)?) async throws {
            try check?(declared)                     // before writing, as the real one does
            FileManager.default.createFile(atPath: destination.path,
                                           contents: Data(repeating: 0x50, count: 8))
        }
    }

    /// Resolves without touching the network, so the test exercises the space
    /// guard rather than a host's page-scraping.
    private struct DirectHost: FileHost {
        let name = "test"
        func canHandle(_ url: URL) -> Bool { true }
        func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
            FileMeta(filename: "comic.cbz")          // no size, like MediaFire
        }
        func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
            DirectLink(url: URL(string: "https://download.example/comic.cbz")!)
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture(free: Int64, declared: Int64) throws -> (Library, Store, Int) {
        let store = try Store()
        try store.ingest(html:
            "<div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>")
        let issue = try XCTUnwrap(try store.recent().first)
        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in HTTPResponse(status: 200) },
                              downloader: SizedDownloader(declared: declared),
                              registry: HostRegistry(hosts: [DirectHost()]),
                              availableSpace: { free })
        return (library, store, issue.id)
    }

    func testTransferIsRefusedOnItsDeclaredSize() async throws {
        let (library, _, issueID) = try fixture(free: 250_000_000, declared: 100_000_000)
        do {
            _ = try await library.fetch(issueID: issueID)
            XCTFail("a transfer that cannot fit was allowed to run")
        } catch let error as DownloadError {
            XCTAssertTrue(error.isInsufficientSpace, "wrong error: \(error)")
            XCTAssertEqual("\(error)",
                           "No free space on device — make room or remove some downloads")
        }
    }

    /// Nothing may be left on disk, since the refusal happens before writing.
    func testRefusedTransferLeavesNoPartialFile() async throws {
        let (library, _, issueID) = try fixture(free: 250_000_000, declared: 100_000_000)
        _ = try? await library.fetch(issueID: issueID)
        let leftovers = (try? FileManager.default.subpathsOfDirectory(atPath: root.path)) ?? []
        XCTAssertTrue(leftovers.filter { $0.hasSuffix(".part") }.isEmpty,
                      "partial file left behind: \(leftovers)")
    }

    /// A full disk is not a dead mirror.
    func testRefusalDoesNotRetireTheMirror() async throws {
        let (library, store, issueID) = try fixture(free: 250_000_000, declared: 100_000_000)
        _ = try? await library.fetch(issueID: issueID)
        XCTAssertEqual(try store.liveMirrors(forIssue: issueID).count, 1)
    }

    func testTransferProceedsWhenItFits() async throws {
        let (library, _, issueID) = try fixture(free: 400_000_000, declared: 100_000_000)
        // Gets past the space guard; the stub's 8 bytes are not a real archive,
        // so it fails later for an entirely different reason.
        do {
            _ = try await library.fetch(issueID: issueID)
        } catch let error as DownloadError {
            XCTAssertFalse(error.isInsufficientSpace, "refused a transfer that fitted")
        } catch {}
    }
}

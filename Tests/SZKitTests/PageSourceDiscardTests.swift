import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SZKit

/// Opening an issue must not delete part of it.
///
/// `document(forIssue:)` drops the archive an issue was unpacked from as soon
/// as its pages exist, which is right for every source that arrives as a file
/// and wrong for the three that do not. Stripovi, PopBoks and BatCave fetch
/// pages one at a time into the issue's own folder; there is no archive, and
/// the download is recorded against the first page for want of anything else
/// to name — see `PageDownload.recordedFile`. Nothing else in the folder is
/// distinguishable from that page, so "delete the file the download names"
/// read as "delete page one".
final class PageSourceDiscardTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Real pictures, not magic bytes. `discardArchives` only runs once it has
    /// re-opened the folder and rendered the first and last pages, so bytes
    /// that do not decode would make these tests pass without ever reaching
    /// the code they are about.
    private static func imageData(width: Int = 40, height: Int = 60) throws -> Data {
        let space = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage() else { throw XCTSkip("cannot synthesise an image") }
        let data = NSMutableData()
        guard let out = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw XCTSkip("cannot write a JPEG here")
        }
        CGImageDestinationAddImage(out, image, nil)
        guard CGImageDestinationFinalize(out) else { throw XCTSkip("JPEG write failed") }
        return data as Data
    }

    private func library(_ store: Store) -> Library {
        Library(store: store, paths: LibraryPaths(root: root),
                transport: StubTransport { _ in HTTPResponse(status: 200) },
                downloader: StubDownloader(bodies: [:]))
    }

    /// One issue, downloaded exactly the way the page-image sources do it:
    /// pages written into the issue's own folder, the marker written last,
    /// and the download recorded against `PageDownload.recordedFile`.
    private func fetchedAPageAtATime(pages: Int = 8) throws -> (Store, Library, Int) {
        let store = try Store()
        try store.ingest(html: """
            <title>Winter song - Stripovi</title>
            <div>013-Winter song</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let library = self.library(store)
        let id = try XCTUnwrap(try store.recent().first).id

        let download = try PageDownload(
            directory: LibraryPaths(root: root).directory(forIssue: id),
            images: (1...pages).map { "https://www.stripovi.com/img/\($0).jpg" })
        let bytes = try Self.imageData()
        for page in 1...pages { try download.write(bytes, page: page) }
        let total = try download.finish()
        try store.recordDownload(issueID: id, mirrorURL: "winter",
                                 path: download.recordedFile, bytes: total)
        return (store, library, id)
    }

    private func pagesOnDisk(_ issueID: Int) -> [String] {
        let dir = LibraryPaths(root: root).directory(forIssue: issueID)
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".jpg") }
            .sorted()
    }

    /// The bug, at the size a reader meets it: open the issue, lose page one.
    func testOpeningAPageFetchedIssueKeepsItsFirstPage() throws {
        let (_, library, id) = try fetchedAPageAtATime()
        XCTAssertEqual(pagesOnDisk(id).first, "0001.jpg", "the premise: page one starts here")

        let document = try library.document(forIssue: id)

        XCTAssertEqual(pagesOnDisk(id).first, "0001.jpg",
                       "opening the issue deleted its first page")
        XCTAssertEqual(document.pageCount, 8)
    }

    /// The whole comic, not just its first file. A rule that spared page one
    /// by name would still take a sibling sharing its stem.
    func testOpeningAPageFetchedIssueKeepsEveryPage() throws {
        let (_, library, id) = try fetchedAPageAtATime()
        let before = pagesOnDisk(id)
        _ = try library.document(forIssue: id)
        XCTAssertEqual(pagesOnDisk(id), before, "opening the issue changed what is on disk")
    }

    /// Reopening is the case that actually bit: the first open unpacks, and
    /// every open after it runs the discard again over a folder that now holds
    /// nothing but pages.
    func testReopeningAPageFetchedIssueKeepsEveryPage() throws {
        let (_, library, id) = try fetchedAPageAtATime()
        _ = try library.document(forIssue: id)
        let after = pagesOnDisk(id)
        let document = try library.document(forIssue: id)
        XCTAssertEqual(pagesOnDisk(id), after, "reopening the issue changed what is on disk")
        XCTAssertEqual(document.pageCount, 8)
    }

    /// The download stays a download. Deleting the recorded file used to be
    /// invisible to the shelf because the row survives it, and the row is what
    /// "downloaded" means — but `reconcileDownloads` now asks the disk too,
    /// and a recorded file that is gone leans entirely on the folder still
    /// being there.
    func testThePageFetchedIssueIsStillDownloadedAfterOpening() throws {
        let (store, library, id) = try fetchedAPageAtATime()
        _ = try library.document(forIssue: id)

        XCTAssertTrue(library.isOnDevice(issueID: id))
        XCTAssertEqual(try library.reconcileDownloads(), [])
        let file = try XCTUnwrap(try store.downloadedFile(issueID: id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path.path),
                      "the recorded file should still be the page it names")
    }

    /// Every device that has already opened one of these issues is carrying
    /// the damage: page one gone, and a download recorded against it. The fix
    /// cannot give the page back, but opening the issue again must not cost a
    /// second one — and here the recorded file is *not* among the pages, so it
    /// takes a different route through the discard than the case above.
    func testOpeningAnAlreadyDamagedPageFetchedIssueLosesNothingFurther() throws {
        let (_, library, id) = try fetchedAPageAtATime()
        let directory = LibraryPaths(root: root).directory(forIssue: id)
        try FileManager.default.removeItem(at: directory.appendingPathComponent("0001.jpg"))
        let damaged = pagesOnDisk(id)
        XCTAssertEqual(damaged.first, "0002.jpg", "the premise: this library is already hurt")

        let document = try library.document(forIssue: id)

        XCTAssertEqual(pagesOnDisk(id), damaged, "opening it again cost another page")
        XCTAssertEqual(document.pageCount, 7)
    }

    // MARK: - The behaviour that must survive the fix

    /// An archive really is a second copy once its pages are out, and dropping
    /// it is what keeps a 90 MB download from costing 180 MB for good. This is
    /// the case the discard exists for.
    func testOpeningAnArchiveStillDeletesIt() throws {
        let store = try Store()
        try store.ingest(html:
            "<div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>")
        let library = self.library(store)
        let id = try XCTUnwrap(try store.recent().first).id

        // An archive beside the pages it unpacked to, which is the state
        // `document(forIssue:)` finds after an unpack.
        let directory = LibraryPaths(root: root).directory(forIssue: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bytes = try Self.imageData()
        for page in 1...3 {
            try bytes.write(to: directory.appendingPathComponent(String(format: "%04d.jpg", page)))
        }
        try Data().write(to: directory.appendingPathComponent(".szunpacked"))
        let archive = directory.appendingPathComponent("Nasilje.cbz")
        try Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: UInt8(0x41), count: 200))
            .write(to: archive)
        try store.recordDownload(issueID: id, mirrorURL: "http://x/y",
                                 path: archive, bytes: 204)

        _ = try library.document(forIssue: id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path),
                       "the archive outlived the pages it unpacked to")
        XCTAssertEqual(pagesOnDisk(id).count, 3, "the pages went with the archive")
    }
}

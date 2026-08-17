import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SZKit

/// Small renderings of an issue's pages, for the grid a page is picked from.
final class PageThumbnailTests: XCTestCase {

    private var root: URL!
    private var paths: LibraryPaths!
    private var library: Library!
    private var document: ComicDocument!
    private let issueID = 7

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        paths = LibraryPaths(root: root)
        library = Library(store: try Store(), paths: paths,
                          transport: StubTransport { _ in HTTPResponse(status: 404) },
                          downloader: URLSessionDownloader())

        // A real six-page comic, unpacked where a downloaded one would be.
        let archive = try SevenZipFixture.make(named: "c.7z", pages: 1...6, in: root, at: root)
        document = try ComicDocument(
            fileURL: archive,
            workDirectory: paths.directory(forIssue: issueID).appendingPathComponent("volume-1"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Rendered once, then answered from disk. This is what makes re-opening
    /// the grid a handful of file reads instead of a second pass over a
    /// three-hundred-page magazine.
    func testAPageIsRenderedOnceAndThenReadFromDisk() throws {
        let made = try XCTUnwrap(library.pageThumbnail(2, ofIssue: issueID,
                                                       renderingFrom: document))
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path))

        // No document this time: only something already on disk can answer.
        XCTAssertEqual(library.pageThumbnail(2, ofIssue: issueID), made)
    }

    /// And a page nothing has rendered yet has no answer without one, rather
    /// than a blank file that would be cached as though it were the page.
    func testWithoutADocumentAnUnrenderedPageHasNothing() {
        XCTAssertNil(library.pageThumbnail(5, ofIssue: issueID))
    }

    /// The reason they are kept outside the issue's own folder.
    ///
    /// A comic unpacked in place *is* that folder, and it is read with a
    /// recursive enumerator — so a subdirectory of thumbnails inside it is
    /// not ignored, it is more pages. This is the shape that would break:
    /// eleven pages in a five-page comic, each of the extra ones a fifth of
    /// the size of the real thing.
    func testAThumbnailInsideTheIssueFolderWouldBeReadAsAPage() throws {
        let unpacked = root.appendingPathComponent("in-place", isDirectory: true)
        let thumbs = unpacked.appendingPathComponent("thumbs", isDirectory: true)
        try FileManager.default.createDirectory(at: thumbs, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: unpacked.appendingPathComponent(UnpackMarker.name).path, contents: Data())
        for page in 1...5 {
            try Self.imageData(width: 40, height: 60).write(
                to: unpacked.appendingPathComponent(String(format: "p%03d.jpg", page)))
        }
        XCTAssertEqual(try ComicDocument(unpackedAt: unpacked).pageCount, 5)

        try Self.imageData(width: 12, height: 18)
            .write(to: thumbs.appendingPathComponent("0000.jpg"))
        XCTAssertEqual(try ComicDocument(unpackedAt: unpacked).pageCount, 6,
                       "the hazard this layout avoids is no longer real — "
                       + "thumbnails could live beside the pages after all")
    }

    /// And so they are written somewhere else entirely.
    func testThumbnailsAreNotWrittenIntoTheIssueFolder() throws {
        for page in 0..<6 {
            XCTAssertNotNil(library.pageThumbnail(page, ofIssue: issueID,
                                                  renderingFrom: document))
        }
        let issueFolder = paths.directory(forIssue: issueID).path
        XCTAssertFalse(paths.pageThumbnails(forIssue: issueID).path.hasPrefix(issueFolder),
                       "thumbnails are inside the comic")
        XCTAssertEqual(try ComicDocument(unpackedAt: paths.directory(forIssue: issueID)).pageCount,
                       6, "a thumbnail was read back as a page")
    }

    /// They go when the download does: the pages they were made from have
    /// gone, so there is nothing left for the grid to show.
    func testTheyGoWhenTheDownloadDoes() throws {
        _ = library.pageThumbnail(0, ofIssue: issueID, renderingFrom: document)
        let directory = paths.pageThumbnails(forIssue: issueID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        library.discardPageThumbnails(forIssue: issueID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(library.pageThumbnail(0, ofIssue: issueID))
    }

    /// A grid of three hundred of these is only affordable because each one is
    /// tiny. A scan is a couple of thousand pixels down its long edge; what
    /// gets stored must not be.
    func testAThumbnailIsSmallEnoughToHaveThreeHundredOf() throws {
        let page = try Self.imageData(width: 1400, height: 2000)
        let thumbnail = try XCTUnwrap(
            PageRenderer.downsample(data: page, maxPixelSize: Library.thumbnailPixels))
        XCTAssertEqual(max(thumbnail.width, thumbnail.height), Library.thumbnailPixels)
    }

    private static func imageData(width: Int, height: Int) throws -> Data {
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
}

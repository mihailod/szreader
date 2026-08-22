import XCTest
@testable import SZKit

/// Writing a BatCave issue to disk.
///
/// This source has no archive, so the pages go straight into the layout
/// `ComicDocument(unpackedAt:)` reads. The two tests that matter are at the
/// bottom: an interrupted fetch must not be readable, and a finished one must.
final class PageDownloadTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("batcave-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Bytes that pass the sniff. Only the magic number is real — nothing here
    /// decodes them.
    private func jpeg() -> Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x20, count: 64) }
    private func png() -> Data { Data([0x89, 0x50, 0x4E, 0x47]) + Data(repeating: 0x20, count: 64) }

    private func addresses(_ count: Int, ext: String = "jpg") -> [String] {
        (1...count).map { "https://img.batcave.biz/img/5/11/22/\($0)-hash.\(ext)" }
    }

    private func download(_ count: Int, ext: String = "jpg") throws -> PageDownload {
        try PageDownload(directory: directory, images: addresses(count, ext: ext))
    }

    // MARK: - Names

    /// Zero-padded so the folder lists in reading order.
    func testPagesAreNamedInReadingOrder() throws {
        let d = try download(12)
        XCTAssertEqual(d.name(page: 1), "0001.jpg")
        XCTAssertEqual(d.name(page: 12), "0012.jpg")
    }

    func testTheExtensionComesFromTheAddress() throws {
        XCTAssertEqual(try download(1, ext: "png").name(page: 1), "0001.png")
        XCTAssertEqual(try download(1, ext: "webp").name(page: 1), "0001.webp")
    }

    /// `UnpackedReader` finds pages by extension, so an address ending in
    /// something else must not produce a file the reader cannot see.
    func testAnUnreadableExtensionBecomesJPEG() {
        XCTAssertEqual(PageDownload.extension(of: "https://x/1-hash.php"), "jpg")
        XCTAssertEqual(PageDownload.extension(of: "https://x/1-hash"), "jpg")
    }

    // MARK: - What is refused

    /// The guard that earns its place: the site answers a request it dislikes
    /// with HTML and a 200, and written blind that becomes a blank page.
    func testHTMLIsNotWrittenAsAPage() throws {
        let d = try download(1)
        let html = Data("<!DOCTYPE html><html><head><title>Just a moment".utf8)
        XCTAssertThrowsError(try d.write(html, page: 1))
        XCTAssertFalse(d.has(page: 1))
    }

    func testEmptyBytesAreRefused() throws {
        let d = try download(1)
        XCTAssertThrowsError(try d.write(Data(), page: 1))
    }

    func testRealImageMagicIsAccepted() {
        XCTAssertTrue(ImageBytes.looksLikeImage(jpeg()))
        XCTAssertTrue(ImageBytes.looksLikeImage(png()))
        XCTAssertTrue(ImageBytes.looksLikeImage(
            Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])))
        XCTAssertFalse(ImageBytes.looksLikeImage(Data("<html>".utf8)))
        XCTAssertFalse(ImageBytes.looksLikeImage(Data()))
    }

    // MARK: - Resume

    /// A download stopped at page 2 of 4 should cost two requests the second
    /// time, not four.
    func testPagesAlreadyOnDiskAreKnown() throws {
        let d = try download(4)
        try d.write(jpeg(), page: 1)
        try d.write(jpeg(), page: 2)
        XCTAssertEqual((1...4).map(d.has), [true, true, false, false])
    }

    // MARK: - Finishing

    func testItWillNotFinishWithAPageMissing() throws {
        let d = try download(3)
        try d.write(jpeg(), page: 1)
        try d.write(jpeg(), page: 3)
        XCTAssertThrowsError(try d.finish())
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(UnpackMarker.name).path))
    }

    func testFinishingReportsWhatIsOnDisk() throws {
        let d = try download(3)
        for page in 1...3 { try d.write(jpeg(), page: page) }
        let bytes = try d.finish()
        XCTAssertEqual(bytes, Int64(jpeg().count * 3))
    }

    // MARK: - The safety property

    /// An interrupted fetch must not read as a short comic. This is the whole
    /// reason the marker is written last.
    func testAnInterruptedDownloadIsNotAComic() throws {
        let d = try download(4)
        try d.write(jpeg(), page: 1)
        try d.write(jpeg(), page: 2)
        XCTAssertThrowsError(try ComicDocument(unpackedAt: directory),
                             "half a comic must not open as a whole one")
    }

    /// And a finished one is a comic, with every page in it — which is what
    /// makes a source with no archive indistinguishable from one with.
    func testAFinishedDownloadIsAComic() throws {
        let d = try download(4)
        for page in 1...4 { try d.write(jpeg(), page: page) }
        try d.finish()

        let document = try ComicDocument(unpackedAt: directory)
        XCTAssertEqual(document.pageCount, 4)
    }

    /// The partial files an interrupted write leaves must not be counted as
    /// pages either.
    func testAPartFileIsNotAPage() throws {
        let d = try download(2)
        for page in 1...2 { try d.write(jpeg(), page: page) }
        try Data("half".utf8).write(
            to: directory.appendingPathComponent(".0003.jpg.part"))
        try d.finish()
        XCTAssertEqual(try ComicDocument(unpackedAt: directory).pageCount, 2)
    }

    // MARK: - Reaching the reader

    /// Every failure here must arrive as its own sentence.
    ///
    /// `Library.reason` matches error types explicitly, so a new one added
    /// without a line there renders as "SZKit.PageFetchError error 1" —
    /// which is exactly what shipped, and which threw away the only thing this
    /// error carries: which page failed, and why.
    func testEveryFailureReachesTheReaderAsASentence() {
        let all: [PageFetchError] = [
            .notAReaderPage, .chapterIsBroken, .noPages, .imagesNotInlined,
            .pageCountMismatch(stated: 94, listed: 40),
            .pageFailed(page: 7, reason: "timed out"),
        ]
        for error in all {
            XCTAssertEqual(Library.reason(error), error.description)
            XCTAssertFalse(Library.reason(error).contains("couldn’t be completed"),
                           "\(error) reaches the reader as a bridged NSError")
        }
    }

    /// The failing page and its reason are the whole payload, so they have to
    /// survive the trip.
    func testTheFailingPageIsNamed() {
        let reason = Library.reason(PageFetchError.pageFailed(
            page: 7, reason: "HTTP 403"))
        XCTAssertTrue(reason.contains("7"), reason)
        XCTAssertTrue(reason.contains("HTTP 403"), reason)
    }

    /// The bridged number is not the case as written: an enum's cases with
    /// associated values are numbered before the ones without, so `error 1` is
    /// `pageFailed` rather than the second case listed. Pinned because reading
    /// it as the second case sent a diagnosis after entirely the wrong bug.
    func testTheBridgedNumberIsNotTheCaseOrder() {
        XCTAssertEqual((PageFetchError.pageFailed(page: 1, reason: "x") as NSError).code, 1)
        XCTAssertEqual((PageFetchError.chapterIsBroken as NSError).code, 3)
    }
}

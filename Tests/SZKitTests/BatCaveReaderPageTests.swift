import XCTest
@testable import SZKit

/// Reading a BatCave reader page, which is where a download gets its pages.
///
/// The fixture is a real reader page cut to the one script block that is read,
/// with the session, user and feedback-challenge fields dropped. What is kept
/// is the shape that matters: 94 image addresses and the count beside them.
final class BatCaveReaderPageTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/batcave")

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - A real reader page

    func testItReadsTheWholePageList() throws {
        let reading = try XCTUnwrap(BatCaveReaderPage.reading(page("reader-94-pages.html")))
        XCTAssertEqual(reading.seriesID, 4454)
        XCTAssertEqual(reading.chapterID, 22724)
        XCTAssertEqual(reading.statedPages, 94)
        XCTAssertEqual(reading.pageCount, 94)
        XCTAssertFalse(reading.isBroken)
        XCTAssertFalse(reading.usesAjax)
    }

    /// The per-page hash is why the reader page has to be loaded at all: it is
    /// not derivable from anything the series page states, so there is no
    /// shortcut to an issue's images.
    func testThePageAddressesCarryAPerPageHash() throws {
        let reading = try XCTUnwrap(BatCaveReaderPage.reading(page("reader-94-pages.html")))
        let first = try XCTUnwrap(reading.images.first)
        XCTAssertTrue(first.hasPrefix("https://img.batcave.biz/img/5/4454/22724/1-"))
        XCTAssertTrue(first.hasSuffix(".jpg"))
        // 94 distinct addresses, not one repeated or a pattern filled in.
        XCTAssertEqual(Set(reading.images).count, 94)
    }

    /// A real page is downloadable, which is the case the refusals must not
    /// catch.
    func testARealPageIsNotRefused() throws {
        let reading = try XCTUnwrap(BatCaveReaderPage.reading(page("reader-94-pages.html")))
        XCTAssertNil(BatCaveReaderPage.refusal(reading))
    }

    // MARK: - Shapes the real page does not have

    private func payload(images: String, pages: String = "2",
                         broken: String = "false", ajax: String = "false") -> String {
        """
        <html><body><script>window.__DATA__ = {"news_id":11,"chapter_id":22,\
        "post_title":"A Series","images":[\(images)],"pages":\(pages),\
        "broken":\(broken),"rdr_ajax":\(ajax),"bookmark":0,"user_hash":"",\
        "feedback_challenge":{"a":5,"b":9,"nonce":"x"}};</script></body></html>
        """
    }

    private static let two = #""https://img.batcave.biz/img/5/11/22/1-aa.jpg","https://img.batcave.biz/img/5/11/22/2-bb.jpg""#

    func testTheUnusedFieldsOfARealPayloadAreIgnored() {
        XCTAssertNotNil(BatCaveReaderPage.reading(payload(images: Self.two)))
    }

    func testABrokenChapterIsRefusedBeforeAnythingIsFetched() throws {
        let reading = try XCTUnwrap(
            BatCaveReaderPage.reading(payload(images: Self.two, broken: "true")))
        XCTAssertEqual(BatCaveReaderPage.refusal(reading), .chapterIsBroken)
    }

    /// An empty list means two different things, and the reader is owed the
    /// difference: nothing to read, or pages this app has not been taught to
    /// find.
    func testAnEmptyListIsReadDifferentlyDependingOnAjax() throws {
        let plain = try XCTUnwrap(BatCaveReaderPage.reading(payload(images: "", pages: "0")))
        XCTAssertEqual(BatCaveReaderPage.refusal(plain), .noPages)

        let deferred = try XCTUnwrap(
            BatCaveReaderPage.reading(payload(images: "", pages: "0", ajax: "true")))
        XCTAssertEqual(BatCaveReaderPage.refusal(deferred), .imagesNotInlined)
    }

    /// A half-formed page must not become a comic quietly missing its end.
    func testACountThatDisagreesWithTheListIsRefused() throws {
        let reading = try XCTUnwrap(
            BatCaveReaderPage.reading(payload(images: Self.two, pages: "94")))
        XCTAssertEqual(BatCaveReaderPage.refusal(reading),
                       .pageCountMismatch(stated: 94, listed: 2))
    }

    /// A blank entry is not an address, and fetching one would write a
    /// zero-byte page into the middle of the issue.
    func testBlankEntriesAreDropped() throws {
        let reading = try XCTUnwrap(
            BatCaveReaderPage.reading(payload(images: Self.two + #","""#, pages: "2")))
        XCTAssertEqual(reading.pageCount, 2)
    }

    /// The array is the site's stated reading order. Sorting on the number
    /// leading each filename would reorder a run whose pages are named any
    /// other way — and the site is free to name them any other way.
    func testTheListedOrderIsKeptRatherThanDerivedFromTheFilename() throws {
        let shuffled = #""https://img.batcave.biz/img/5/11/22/9-aa.jpg","https://img.batcave.biz/img/5/11/22/1-bb.jpg""#
        let reading = try XCTUnwrap(BatCaveReaderPage.reading(payload(images: shuffled)))
        XCTAssertTrue(try XCTUnwrap(reading.images.first).contains("/9-aa.jpg"))
    }

    func testAPageThatIsNotAReaderPageIsNotRead() {
        XCTAssertNil(BatCaveReaderPage.reading("<html><body>the front page</body></html>"))
    }
}

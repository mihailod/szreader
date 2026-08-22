import XCTest
@testable import SZKit

/// Reading a BatCave series page, which is the whole of the import.
///
/// The two fixtures are real pages cut to the two script blocks the parser
/// reads — `window.__DATA__` and the JSON-LD graph — with the site's synopsis
/// prose dropped, since nothing reads it. What is kept is the structure that
/// matters: a two-chapter series and a 194-chapter one.
///
/// The long run is the important fixture. Its JSON-LD `hasPart` lists twenty
/// chapters and its `__DATA__` lists all 194, which is the single fact that
/// decides where the chapter list is read from.
final class BatCavePageTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/batcave")

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - A short series

    func testATwoChapterSeries() throws {
        let series = try XCTUnwrap(BatCavePage.series(page("series-two-chapters.html")))
        XCTAssertEqual(series.id, 4454)
        XCTAssertEqual(series.title, "Republic of the Skull (2022-)")
        XCTAssertEqual(series.publisher, "Europe Comics")
        XCTAssertEqual(series.year, 2022)
        XCTAssertEqual(series.coverURL,
            "https://batcave.biz/uploads/posts/poster/93/4454-republic-of-the-skull-2022.jpg")

        // Ascending, which is not the order the site states them in: its list
        // is newest first, and the shelf wants a run in reading order.
        XCTAssertEqual(series.chapters.map(\.position), [1, 2])
        XCTAssertEqual(series.chapters.map(\.id), [22724, 22723])
        XCTAssertEqual(series.chapters.map(\.number), [1, 2])
        XCTAssertEqual(series.chapters.map(\.pages), [94, 116])
    }

    // MARK: - A long run

    /// The reason `__DATA__` is read rather than the linked data.
    func testTheWholeRunIsRead() throws {
        let series = try XCTUnwrap(BatCavePage.series(page("series-long-run.html")))
        XCTAssertEqual(series.id, 6112)
        XCTAssertEqual(series.publisher, "Image Comics")
        XCTAssertEqual(series.year, 2003)
        XCTAssertEqual(series.chapters.count, 194,
                       "the linked data lists 20 of these — reading it would import 20")
    }

    /// Position is not the issue number, and this run is where that shows.
    ///
    /// A tenth-anniversary reissue of #1 sorts at position 1 while #193 sorts
    /// at 194, so anything keyed on position would number the whole run one
    /// off — silently, and only for series carrying a reissue.
    func testPositionIsNotTheIssueNumber() throws {
        let series = try XCTUnwrap(BatCavePage.series(page("series-long-run.html")))
        let first = try XCTUnwrap(series.chapters.first)
        XCTAssertEqual(first.position, 1)
        XCTAssertEqual(first.number, 1)
        XCTAssertEqual(first.title, "The Walking Dead (2003-) #1 10th Anniversary")

        let last = try XCTUnwrap(series.chapters.last)
        XCTAssertEqual(last.position, 194)
        XCTAssertEqual(last.number, 193)
    }

    /// The series name carries a year, so an unanchored number pattern reads
    /// 2003 as the issue number for all 194 of them.
    func testTheYearInTheSeriesNameIsNotReadAsAnIssueNumber() throws {
        let series = try XCTUnwrap(BatCavePage.series(page("series-long-run.html")))
        XCTAssertFalse(series.chapters.contains { $0.number == 2003 })
    }

    /// 160 of the 194 state no `title_en`, so the fallback is the ordinary
    /// path here rather than a rare one.
    func testEveryChapterEndsUpWithATitle() throws {
        let series = try XCTUnwrap(BatCavePage.series(page("series-long-run.html")))
        XCTAssertFalse(series.chapters.contains { $0.title.isEmpty })
    }

    // MARK: - Shapes the real fixtures do not contain

    /// Neither saved page holds a broken chapter or a zero page count, so
    /// these are stated here rather than left to a fixture that happens not to
    /// exercise them.
    private func synthetic(chapters: String) -> String {
        """
        <html><body><script>window.__DATA__ = {"news_id":11,"title":"A Series",\
        "chapters":[\(chapters)],"limit":30,"readed":[],"xhash":"",\
        "bulkdl":{"quota":150,"blocked":false,"remaining":null}};</script></body></html>
        """
    }

    private static let intact =
        #"{"id":1,"posi":1,"pages":20,"title":"A Series #1","title_en":"","date":"01.02.2023","broken":false}"#
    private static let broken =
        #"{"id":2,"posi":2,"pages":0,"title":"A Series #2","title_en":"","date":"01.02.2023","broken":true}"#

    func testABrokenChapterIsStillRead() throws {
        let series = try XCTUnwrap(
            BatCavePage.series(synthetic(chapters: "\(Self.intact),\(Self.broken)")))
        XCTAssertEqual(series.chapters.map(\.isBroken), [false, true])
    }

    /// Zero pages is "not stated", not "an issue of no pages" — and a
    /// page-by-page download is the one thing that cannot be asked for zero
    /// of.
    func testAZeroPageCountIsNotAPageCount() throws {
        let series = try XCTUnwrap(
            BatCavePage.series(synthetic(chapters: "\(Self.intact),\(Self.broken)")))
        XCTAssertEqual(series.chapters.map(\.pages), [20, nil])
    }

    /// The unused fields of a real payload — quota block, `readed`, `xhash` —
    /// must not be a decode failure, which is why only what is used is
    /// declared.
    func testUnknownFieldsAreIgnored() throws {
        XCTAssertNotNil(BatCavePage.series(synthetic(chapters: Self.intact)))
    }

    // MARK: - Finding the payload

    /// A regex cannot take this object out of the page: greedy runs past its
    /// end, lazy stops at the first nested close, and both fail silently.
    func testTheObjectIsMatchedByCountingBraces() {
        let html = "junk{} window.__DATA__ = {\"a\":{\"b\":1},\"c\":2} trailing } junk"
        XCTAssertEqual(BatCavePage.balancedObject(in: html, after: "window.__DATA__"),
                       "{\"a\":{\"b\":1},\"c\":2}")
    }

    /// A brace inside a title must not unbalance the count, and an escaped
    /// quote must not end the string early. Comic titles contain both.
    func testBracesAndQuotesInsideStringsAreNotStructure() {
        let html = #"window.__DATA__ = {"t":"a } brace","u":"a \" quote","v":1}"#
        XCTAssertEqual(BatCavePage.balancedObject(in: html, after: "window.__DATA__"),
                       #"{"t":"a } brace","u":"a \" quote","v":1}"#)
    }

    /// A page cut off mid-object is not something to hand a decoder.
    func testAnUnclosedObjectIsRefused() {
        XCTAssertNil(BatCavePage.balancedObject(in: #"window.__DATA__ = {"a":1"#,
                                                after: "window.__DATA__"))
    }

    // MARK: - Whether Import lights up

    func testAPageWithNoChaptersIsNotASeriesPage() {
        XCTAssertFalse(BatCavePage.isSeriesPage(synthetic(chapters: "")))
        XCTAssertFalse(BatCavePage.isSeriesPage("<html><body>the front page</body></html>"))
    }

    func testASeriesPageIsOne() throws {
        XCTAssertTrue(BatCavePage.isSeriesPage(try page("series-two-chapters.html")))
    }
}

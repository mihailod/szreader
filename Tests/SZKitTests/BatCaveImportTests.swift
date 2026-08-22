import XCTest
@testable import SZKit

/// Reading a BatCave series page into the library.
///
/// The fixture is built here rather than loaded, because what these tests are
/// about is what the *import* does with a run — reissues, broken chapters,
/// a second visit — and those shapes are clearer stated than hunted for in a
/// 194-chapter page. `BatCavePageTests` is where the real pages are read.
final class BatCaveImportTests: XCTestCase {

    /// The linked-data block, which is where the poster, publisher and year
    /// come from. Its `hasPart` is deliberately absent: the parser must never
    /// read chapters from here.
    private let describedAs = """
    <script type="application/ld+json">{"@context":"https://schema.org","@graph":[\
    {"@type":"ComicSeries","@id":"https://batcave.biz/11-a-series.html#series",\
    "name":"A Series (2003-)","image":"https://batcave.biz/uploads/posts/poster/aa/11-a-series.jpg",\
    "publisher":{"@id":"https://batcave.biz/#publisher/deadbeef"},"startDate":"2003-01-01"},\
    {"@type":"Organization","@id":"https://batcave.biz/#publisher/deadbeef","name":"A Publisher"}]}</script>
    """

    private func page(_ chapters: String) -> String {
        """
        <html><head>\(describedAs)</head><body>
        <script>window.__DATA__ = {"news_id":11,"title":"A Series (2003-)",\
        "chapters":[\(chapters)],"limit":30,"readed":[],"xhash":""};</script>
        </body></html>
        """
    }

    private static func chapter(id: Int, posi: Int, pages: Int, title: String,
                                broken: Bool = false) -> String {
        """
        {"id":\(id),"posi":\(posi),"pages":\(pages),"title":"\(title)",\
        "title_en":"","date":"01.02.2023","broken":\(broken)}
        """
    }

    /// Two ordinary issues, listed newest first the way the site lists them.
    private let run = [
        chapter(id: 902, posi: 2, pages: 30, title: "A Series (2003-) #2"),
        chapter(id: 901, posi: 1, pages: 24, title: "A Series (2003-) #1"),
    ].joined(separator: ",")

    // MARK: - The import

    func testItImportsEveryChapterOnThePage() throws {
        let store = try Store()
        let report = try store.importBatCave(page: page(run))

        XCTAssertEqual(report.series, "A Series (2003-)")
        XCTAssertEqual(report.inserted, 2)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(report.broken, 0)
        XCTAssertEqual(store.issueCount, 2)
    }

    func testTheIssuesCarryTheSource() throws {
        let store = try Store()
        try store.importBatCave(page: page(run))
        let issues = try store.recent(limit: nil)
        XCTAssertEqual(issues.count, 2)
        for issue in issues { XCTAssertEqual(issue.site, .batcave) }
    }

    /// The series names the shelf column and the filter menu; the publisher is
    /// the one it was printed under, not the site.
    func testItFilesTheSeriesAndThePrintPublisher() throws {
        let store = try Store()
        try store.importBatCave(page: page(run))
        XCTAssertEqual(try store.editions(sites: [.batcave]), ["A Series (2003-)"])
        XCTAssertEqual(try store.publishers(sites: [.batcave]), ["A Publisher"])
    }

    /// The page count is the reason this source states more than the others:
    /// it is what a page-by-page fetch counts against, so it has to survive
    /// the import.
    func testThePageCountIsStored() throws {
        let store = try Store()
        try store.importBatCave(page: page(run))
        let counts = try store.recent(limit: nil)
            .sorted { ($0.number ?? 0) < ($1.number ?? 0) }
            .map(\.pageCount)
        XCTAssertEqual(counts, [24, 30])
    }

    /// The reader address is the only route to the scans, so it is the mirror.
    func testTheMirrorIsTheReaderAddress() throws {
        let store = try Store()
        try store.importBatCave(page: page(run))
        let issue = try XCTUnwrap(try store.recent(limit: nil)
            .first { $0.number == 1 })
        XCTAssertEqual(try store.liveMirrors(forIssue: issue.id).map(\.url),
                       ["https://batcave.biz/reader/11/901"])
    }

    // MARK: - Broken chapters

    /// A chapter the site marks broken has no scans behind it, so a row for
    /// one is a shelf entry whose only possible outcome is a failed download.
    func testABrokenChapterIsNotWritten() throws {
        let store = try Store()
        let withBroken = run + "," + Self.chapter(
            id: 903, posi: 3, pages: 0, title: "A Series (2003-) #3", broken: true)
        let report = try store.importBatCave(page: page(withBroken))

        XCTAssertEqual(report.inserted, 2)
        XCTAssertEqual(report.broken, 1)
        XCTAssertEqual(store.issueCount, 2)
    }

    // MARK: - A second visit

    /// Idempotent: revisiting a series that has gained an issue adds the one
    /// and leaves the rest alone.
    func testASecondVisitAddsOnlyWhatIsNew() throws {
        let store = try Store()
        try store.importBatCave(page: page(run))

        let grown = Self.chapter(id: 904, posi: 3, pages: 28,
                                 title: "A Series (2003-) #3") + "," + run
        let report = try store.importBatCave(page: page(grown))

        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(report.updated, 2)
        XCTAssertEqual(store.issueCount, 3)
    }

    /// A run is imported in reading order rather than in the newest-first
    /// order the site states, so the shelf reads as a run.
    func testTheRunArrivesInReadingOrder() throws {
        let store = try Store()
        try store.importBatCave(page: page(run))
        let series = try XCTUnwrap(BatCavePage.series(page(run)))
        XCTAssertEqual(series.chapters.map(\.id), [901, 902])
    }
}

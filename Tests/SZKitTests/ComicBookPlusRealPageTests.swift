import XCTest
@testable import SZKit

/// The parser against pages exactly as the site serves them.
///
/// The other two suites work from cut-down markup, which is right for saying
/// what a row means but proves nothing about a page with a hundred kilobytes
/// of furniture on it. These fixtures are whole responses — nav, index card,
/// sidebar widget, twelve inline script and style blocks, and the listing
/// somewhere in the middle.
///
/// Two of those script blocks contain the substrings `<tr` and `overrow`,
/// which is the specific reason these are saved untrimmed: the parser does not
/// strip scripts, so a page whose scripts talk about table rows is exactly the
/// page that would catch it reading code as markup.
final class ComicBookPlusRealPageTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/comicbookplus")

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - Series pages

    /// Three scans of a two-issue series, on a page carrying fifteen more
    /// `?dlid=` links in its sidebar.
    func testASmallSeries() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page("series-adventures-in-3d.html")))
        XCTAssertEqual(leaf.series, "Adventures in 3-D")
        XCTAssertEqual(leaf.publisher, "Harvey Comics")
        XCTAssertEqual(leaf.books.count, 3)
        XCTAssertEqual(leaf.books.map(\.dlid), [21035, 79869, 25968])
    }

    func testAMediumSeries() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page("series-alarming-tales.html")))
        XCTAssertEqual(leaf.series, "Alarming Tales")
        XCTAssertEqual(leaf.publisher, "Harvey Comics")
        XCTAssertEqual(leaf.books.count, 6)
    }

    func testALongSeries() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page("series-champ-comics.html")))
        XCTAssertEqual(leaf.series, "Champ Comics")
        XCTAssertEqual(leaf.books.count, 20)
    }

    /// Nothing on a real page arrives half-read.
    ///
    /// The fields are what the shelf is built out of, so a row that parsed but
    /// lost its date or its page count is a row that looks fine in a count and
    /// is wrong on screen.
    func testEveryRowOnEveryPageIsComplete() throws {
        for name in ["series-adventures-in-3d.html",
                     "series-alarming-tales.html",
                     "series-champ-comics.html"] {
            let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page(name)), name)
            for book in leaf.books {
                XCTAssertGreaterThan(book.dlid, 0, "\(name): \(book.title)")
                XCTAssertEqual(book.hash.count, 32, "\(name): \(book.title)")
                XCTAssertFalse(book.title.isEmpty, "\(name)")
                XCTAssertNotNil(book.number, "\(name): \(book.title)")
                XCTAssertNotNil(book.pages, "\(name): \(book.title)")
                XCTAssertNotNil(book.year, "\(name): \(book.title)")
                XCTAssertNotNil(book.contributor, "\(name): \(book.title)")
            }
            // Every scan is its own file: a repeated hash would mean two rows
            // pointing at one download.
            let hashes = leaf.books.map(\.hash)
            XCTAssertEqual(Set(hashes).count, hashes.count, "\(name): duplicate file hash")
            let ids = leaf.books.map(\.dlid)
            XCTAssertEqual(Set(ids).count, ids.count, "\(name): duplicate dlid")
        }
    }

    /// Dates land in the range the site actually covers, which is the check
    /// that would catch a column having been read instead of the microdata —
    /// "date added" is 2011 and 2021 on this very page, and a parser reading
    /// it would look entirely plausible until someone noticed the shelf
    /// sorting a 1953 comic under 2011.
    func testCoverDatesAreCoverDatesAndNotUploadDates() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page("series-champ-comics.html")))
        for book in leaf.books {
            let year = try XCTUnwrap(book.year)
            XCTAssertTrue((1930...1970).contains(year),
                          "\(book.title) dated \(year) — that is an upload date")
        }
    }

    // MARK: - Pages that are not series listings

    /// A publisher's index: seventy-seven series, and not one issue to import.
    func testAPublisherIndexIsNotImportable() throws {
        let html = try page("publisher-harvey.html")
        XCTAssertFalse(ComicBookPlusPage.isLeaf(html))
        XCTAssertNil(ComicBookPlusPage.leaf(html))
    }

    /// One book's own page.
    ///
    /// It carries more microdata than a listing row does — `ComicIssue`,
    /// `ComicStory`, the inker, the letterer — so this is not a page the
    /// parser fails to understand. It is a page it declines, because Import
    /// on it would mean something different from Import everywhere else.
    func testASingleBookPageIsNotImportable() throws {
        let html = try page("book-jesse-james-24.html")
        XCTAssertFalse(ComicBookPlusPage.isLeaf(html))
        XCTAssertNil(ComicBookPlusPage.leaf(html))
    }

    /// An Old Time Radio series, which the site lists in exactly the same
    /// catalogue table as a comic.
    ///
    /// Its fifteen rows carry a `?dlid=`, a file hash and a name — every field
    /// a book needs — and an mp3 behind them. Before the type was checked,
    /// this page lit Import up and would have filed radio episodes onto the
    /// shelf as comics.
    func testAnAudioSeriesIsNotImportable() throws {
        let html = try page("series-audio-2000-plus.html")
        // The rows are there; it is what they are that disqualifies them.
        XCTAssertEqual(html.components(separatedBy: "class=\"overrow\"").count - 1, 15)
        XCTAssertFalse(ComicBookPlusPage.isLeaf(html))
        XCTAssertNil(ComicBookPlusPage.leaf(html))
    }

    /// And nothing from it reaches the library.
    func testImportingAnAudioSeriesIsRefused() throws {
        let store = try Store()
        XCTAssertThrowsError(try store.importComicBookPlus(
            page: try page("series-audio-2000-plus.html")))
        XCTAssertEqual(store.issueCount, 0)
    }

    /// The readable categories all declare the same type, so narrowing to it
    /// must not have cost any of them.
    func testEveryReadableSeriesStillImports() throws {
        for name in ["series-adventures-in-3d.html",
                     "series-alarming-tales.html",
                     "series-champ-comics.html"] {
            XCTAssertTrue(ComicBookPlusPage.isLeaf(try page(name)), name)
        }
    }

    // MARK: - Through the Store

    /// The whole path, on a real page: parse, write, read back.
    func testARealPageImportsOntoTheShelf() throws {
        let store = try Store()
        let report = try store.importComicBookPlus(page: page("series-champ-comics.html"))

        XCTAssertEqual(report.inserted, 20)
        XCTAssertEqual(store.issueCount, 20)
        XCTAssertEqual(try store.editions(sites: [.comicbookplus]), ["Champ Comics"])

        // And again, unchanged.
        let again = try store.importComicBookPlus(page: page("series-champ-comics.html"))
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.updated, 20)
        XCTAssertEqual(store.issueCount, 20)
    }

    /// Two series in one library keep their own shelves.
    func testTwoSeriesDoNotBleedIntoEachOther() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page("series-adventures-in-3d.html"))
        try store.importComicBookPlus(page: page("series-champ-comics.html"))

        XCTAssertEqual(store.issueCount, 23)
        XCTAssertEqual(try store.editions(sites: [.comicbookplus]).sorted(),
                       ["Adventures in 3-D", "Champ Comics"])
    }
}

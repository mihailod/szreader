import XCTest
@testable import SZKit

/// Reading DLH's archive, against pages exactly as it serves them.
///
/// Three real fixtures, chosen because they are the three shapes the whole
/// tree is made of: a magazine run, a shelf of books, and a platform index
/// that links to both and holds no archives itself.
final class BombJackTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/bombjack")

    private func page(_ name: String) throws -> String {
        let url = Self.fixtures.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        // The site is twenty years of hand-edited HTML and not all of it is
        // UTF-8, which is exactly what the builder has to cope with too.
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    private let ahoyURL = "https://commodore.bombjack.org/commodore/magazines/ahoy/ahoy.htm"
    private let booksURL = "https://commodore.bombjack.org/commodore/books.htm"
    private let indexURL = "https://commodore.bombjack.org/commodore/index.htm"

    // MARK: - A magazine run

    func testItReadsEveryIssueOfAMagazine() throws {
        let entries = BombJack.entries(in: try page("magazine-ahoy.htm"), pageURL: ahoyURL)
        XCTAssertEqual(entries.count, 61)

        let first = try XCTUnwrap(entries.first)
        XCTAssertTrue(first.title.contains("Issue 01"), first.title)
        XCTAssertTrue(first.title.contains("1984"), first.title)
        XCTAssertEqual(first.file,
            "https://commodore.bombjack.org/magazines/commodore/ahoy/Ahoy_Issue_01_1984_Jan.zip")
        XCTAssertEqual(first.pages, 100)
    }

    /// Covers are relative to the page they sit on, not to the site root —
    /// resolving them against the wrong base gives a URL that 404s.
    func testCoversResolveAgainstTheirPage() throws {
        let entries = BombJack.entries(in: try page("magazine-ahoy.htm"), pageURL: ahoyURL)
        XCTAssertEqual(entries.first?.cover,
            "https://commodore.bombjack.org/commodore/magazines/ahoy/ahoy-01.jpg")
        XCTAssertTrue(entries.allSatisfy { $0.cover != nil }, "an issue lost its cover")
    }

    /// Nothing is counted twice, and nothing is a page rather than an archive.
    func testEveryEntryIsADistinctArchive() throws {
        for name in ["magazine-ahoy.htm", "books-commodore.htm"] {
            let url = name.hasPrefix("magazine") ? ahoyURL : booksURL
            let entries = BombJack.entries(in: try page(name), pageURL: url)
            let files = entries.map(\.file)
            XCTAssertEqual(Set(files).count, files.count, "\(name): a file was listed twice")
            XCTAssertTrue(files.allSatisfy { $0.hasSuffix(".zip") || $0.hasSuffix(".pdf") },
                          "\(name): something that is not an archive got in")
            XCTAssertTrue(entries.allSatisfy { !$0.title.isEmpty }, "\(name): an entry has no title")
        }
    }

    // MARK: - A shelf of books

    /// Books use the same cell as magazines and differ only in what the text
    /// around the link looks like: a title over three lines rather than an
    /// issue number and a date.
    func testItReadsBooksFromTheSameShapeOfCell() throws {
        let entries = BombJack.entries(in: try page("books-commodore.htm"), pageURL: booksURL)
        XCTAssertGreaterThan(entries.count, 200)

        let pascal = try XCTUnwrap(entries.first { $0.file.contains("Oxford_PASCAL") })
        // The `<br>`s inside the title are spacing, not structure — the shelf
        // wants one line back.
        XCTAssertEqual(pascal.title, "The Official Guide Oxford PASCAL on the Commodore 64")
        XCTAssertEqual(pascal.pages, 178)
        XCTAssertEqual(pascal.cover, "https://commodore.bombjack.org/commodore/books/thumbnails/"
                                   + "the-official-guide-oxford-pascal-on-the-commodore-654.jpg")
    }

    // MARK: - Directory listings

    /// Whole platforms are served as bare Apache listings rather than curated
    /// pages, and they carry no cover and no text above the link — the file
    /// name is the link. Read only what precedes the link and these yield
    /// nothing, which is exactly why Epson HX-20, Aquarius, Oric-1 and the
    /// rest came out of the first build empty.
    func testItReadsAFileFromADirectoryListing() throws {
        let url = "https://commodore.bombjack.org/other/epson-hx-20/"
        let entries = BombJack.entries(in: try page("listing-epson-hx20.htm"), pageURL: url)

        XCTAssertEqual(entries.count, 1)
        let only = try XCTUnwrap(entries.first)
        XCTAssertEqual(only.file,
            "https://commodore.bombjack.org/other/epson-hx-20/Epson_HX-20_Technical_Manual.pdf")
        // The file name, made readable — there is nothing else to call it.
        XCTAssertEqual(only.title, "Epson HX-20 Technical Manual")
        // A listing has no artwork, and inventing one would be worse.
        XCTAssertNil(only.cover)
    }

    /// The sort links in the same listing are not files.
    func testAListingsOwnFurnitureIsNotAnEntry() throws {
        let url = "https://commodore.bombjack.org/other/epson-hx-20/"
        let entries = BombJack.entries(in: try page("listing-epson-hx20.htm"), pageURL: url)
        XCTAssertFalse(entries.contains { $0.title.contains("Last modified") })
        XCTAssertFalse(entries.contains { $0.file.contains("?C=") })
    }

    // MARK: - A page that holds nothing

    /// A platform index is signposting. It must yield no entries, or every
    /// category link on it becomes a phantom issue.
    func testAnIndexPageHoldsNoArchives() throws {
        XCTAssertTrue(BombJack.entries(in: try page("index-commodore.htm"),
                                       pageURL: indexURL).isEmpty)
    }

    /// And it is what the walk follows.
    func testAnIndexPageIsWhereTheLinksAre() throws {
        let links = BombJack.pageLinks(in: try page("index-commodore.htm"), pageURL: indexURL)
        XCTAssertGreaterThan(links.count, 10)
        XCTAssertTrue(links.contains(
            "https://commodore.bombjack.org/commodore/magazines.htm"), "\(links.prefix(5))")
        // Same host only, and never an archive.
        XCTAssertTrue(links.allSatisfy { $0.contains("commodore.bombjack.org") })
        XCTAssertFalse(links.contains { $0.hasSuffix(".zip") || $0.hasSuffix(".pdf") })
    }

    /// Apache sort links are not four pages, they are one page four times.
    ///
    /// Much of this tree is served as directory listings, and every listing
    /// links to its own sorted forms. Followed, they multiply: the walk
    /// fetched one directory thirty-eight times and spent 62% of its requests
    /// on pages it already had.
    func testDirectorySortLinksCollapseToOnePage() {
        let html = """
        <a href="?C=N;O=D">Name</a>
        <a href="?C=M;O=A">Last modified</a>
        <a href="?C=S;O=A">Size</a>
        <a href="?C=D;O=A">Description</a>
        <a href="books/">Books</a>
        <a href="books/?C=N;O=D">Books sorted</a>
        """
        let links = BombJack.pageLinks(in: html,
                                       pageURL: "https://commodore.bombjack.org/commodore/")
        XCTAssertEqual(links, ["https://commodore.bombjack.org/commodore/",
                               "https://commodore.bombjack.org/commodore/books/"])
    }

    /// Off-site links are not followed. The tree links to expos, to Amazon and
    /// to the arcade side of bombjack.org, none of which are this archive.
    func testItStaysOnTheArchivesOwnHost() {
        let html = """
        <a href="https://www.indyclassic.org/">Expo</a>
        <a href="http://bombjack.org/arcade/joystik/index.htm">Joystik</a>
        <a href="commodore/index.htm">Commodore</a>
        """
        let links = BombJack.pageLinks(in: html, pageURL: "https://commodore.bombjack.org/")
        XCTAssertEqual(links, ["https://commodore.bombjack.org/commodore/index.htm"])
    }

    // MARK: - Categories

    /// Joystik is a magazine, and its path says so only once decoded.
    ///
    /// It sits on another host under "Magazines%20and%20Books", so the raw
    /// segment matches none of the category words and all ten issues filed as
    /// "Other".
    func testJoystikIsAMagazine() {
        let url = "https://arcarc.xmission.com/Magazines%20and%20Books/"
                + "Joystik%20Magazines%20(10%20Issues)/Joystik_Vol1-1_82-Sep.pdf"
        XCTAssertEqual(BombJack.category(of: url), .otherMagazines)
    }

    /// The categories the rest of the tree falls into, and the two orderings
    /// that were each got wrong once.
    func testCategoriesFollowThePath() {
        let base = "https://commodore.bombjack.org/"
        XCTAssertEqual(BombJack.category(of: base + "commodore/magazines/ahoy/a.zip"),
                       .commodoreMagazines)
        XCTAssertEqual(BombJack.category(of: base + "magazines/amiga/af/a.zip"),
                       .amigaMagazines)
        XCTAssertEqual(BombJack.category(of: base + "magazines/generic/byte/a.zip"),
                       .otherMagazines)
        XCTAssertEqual(BombJack.category(of: base + "books/commodore/books/b.zip"), .books)
        XCTAssertEqual(BombJack.category(of: base + "commodore/games/g.pdf"), .games)
        XCTAssertEqual(BombJack.category(of: base + "commodore/hardware/h.pdf"), .hardware)
        // Newsletters before hardware: this path carries "commodore" too.
        XCTAssertEqual(BombJack.category(of: base + "commodore/newsletters/sprite/s.pdf"),
                       .other)
        // And applications after it: a manual under a platform is a manual.
        XCTAssertEqual(BombJack.category(of: base + "commodore/applications/a.pdf"),
                       .hardware)
    }
}

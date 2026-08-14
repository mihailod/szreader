import XCTest
@testable import SZKit

/// Covers posted as one image holding a grid of them.
final class ContactSheetTests: XCTestCase {

    private static let pagesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spike/pages")

    private func blekPage() throws -> String {
        try String(contentsOf: Self.pagesDir.appendingPathComponent(
            "Veliki Blek - Lunov Magnus Strip - Veliki Blek - Stripzona.html"), encoding: .utf8)
    }

    func testReferenceRoundTrips() {
        let ref = CoverTile.reference("https://i.imgur.com/x.jpg", tile: 4, of: 6)
        XCTAssertEqual(ref, "https://i.imgur.com/x.jpg#tile=4/6")
        let tile = try? XCTUnwrap(CoverTile(reference: ref))
        XCTAssertEqual(tile?.sheet, "https://i.imgur.com/x.jpg")
        XCTAssertEqual(tile?.index, 4)
        XCTAssertEqual(tile?.count, 6)
        // Left to right, then down: tile 4 is the middle of the second row.
        XCTAssertEqual(tile?.column, 1)
        XCTAssertEqual(tile?.row, 1)
        XCTAssertEqual(tile?.rows, 2)
    }

    /// An ordinary cover URL is not a tile, however it is written.
    func testPlainURLsAreNotTiles() {
        for url in ["https://i.imgur.com/x.jpg",
                    "https://x/y.jpg#tile=",
                    "https://x/y.jpg#tile=6/6",     // index out of range
                    "https://x/y.jpg#tile=1/0",
                    "https://x/y.jpg#anchor"] {
            XCTAssertNil(CoverTile(reference: url), url)
        }
    }

    /// The six issues a sheet illustrates take its six tiles in order.
    ///
    /// Checked against the page itself: the sheet above LMS 140 shows Zov
    /// bubnjeva, Lažni Blek and Tragičan lov across the top, then Prokleta
    /// kula, Mač ima reč and Vitez od Sezana — which is 140, 141, 144, 145,
    /// 148, 149, the order the labels are listed in underneath.
    func testASheetIsSharedOutInReadingOrder() throws {
        let covers = Catalog.covers(in: Catalog.authoritativeHTML(try blekPage()))
        let wanted = [140, 141, 144, 145, 148, 149]
        for (tile, number) in wanted.enumerated() {
            let reference = try XCTUnwrap(covers[number], "no cover for \(number)")
            let parsed = try XCTUnwrap(CoverTile(reference: reference), reference)
            XCTAssertEqual(parsed.index, tile, "issue \(number) took the wrong tile")
            XCTAssertEqual(parsed.count, 6)
        }
        // All six come out of one image, so one download serves them.
        let sheets = Set(wanted.compactMap { covers[$0] }
            .compactMap { CoverTile(reference: $0)?.sheet })
        XCTAssertEqual(sheets.count, 1)
    }

    /// An issue with art of its own keeps it; only the gaps are filled.
    ///
    /// The first sheet on the page covers 128…137, but five of those six
    /// already have individual covers, so only 137 takes a tile — and it
    /// takes the sixth, its own place in the grid.
    func testASheetOnlyFillsWhatIsMissing() throws {
        let covers = Catalog.covers(in: Catalog.authoritativeHTML(try blekPage()))
        for number in [128, 129, 132, 133, 136] {
            let reference = try XCTUnwrap(covers[number], "no cover for \(number)")
            XCTAssertNil(CoverTile(reference: reference),
                         "issue \(number) had its own cover and should have kept it")
        }
        XCTAssertEqual(CoverTile(reference: try XCTUnwrap(covers[137]))?.index, 5)
    }

    /// The tier must not invent covers anywhere else in the corpus: it fires
    /// only on an image nothing claimed that is followed by exactly a grid's
    /// worth of issues.
    func testItFiresOnOneKnownPageOnly() throws {
        var pagesWithTiles: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: Self.pagesDir.path).sorted()
        where name.lowercased().contains(".htm") {
            let html = try String(contentsOf: Self.pagesDir.appendingPathComponent(name),
                                  encoding: .utf8)
            let tiles = Catalog.covers(in: Catalog.authoritativeHTML(html))
                .values.filter { CoverTile(reference: $0) != nil }
            if !tiles.isEmpty { pagesWithTiles.append("\(name.prefix(28))=\(tiles.count)") }
        }
        XCTAssertEqual(pagesWithTiles, ["Veliki Blek - Lunov Magnus S=13"])
    }

    /// A run of covers beside the run of issues it belongs to.
    ///
    /// The page posts six images then six issues. Four of the images name
    /// their issue in the filename; the other two are bare imgur ids that no
    /// tier can read — and they are 181 and 184, at exactly those positions.
    /// The four that agree are what make the other two safe to place.
    func testAnchoredRunsPlaceTheUnreadableImages() throws {
        let covers = Catalog.covers(in: Catalog.authoritativeHTML(try blekPage()))
        for number in [181, 184, 188, 192] {
            let url = try XCTUnwrap(covers[number], "no cover for \(number)")
            XCTAssertNil(CoverTile(reference: url), "\(number) should be a whole image")
            XCTAssertTrue(url.contains("imgur"), "\(number) took \(url)")
        }
        // The anchors themselves keep the covers their filenames name.
        for number in [176, 177, 180, 185, 189, 193, 196] {
            let url = try XCTUnwrap(covers[number], "no cover for \(number)")
            XCTAssertTrue(url.contains("_\(number).jpg"), "\(number) took \(url)")
        }
    }

    /// One image opposite the wrong issue throws the whole run away: the
    /// agreement is the only reason to trust any of it.
    func testADisagreeingAnchorVoidsTheRun() {
        let page = """
            <div><img src="https://x/TN_A_1.jpg"><img src="https://x/plain.jpg">\
            <img src="https://x/TN_A_3.jpg"></div>
            <div>1. https://mediafire.com/a</div>
            <div>2. https://mediafire.com/b</div>
            <div>3. https://mediafire.com/c</div>
            """
        // Anchors agree (1 and 3 sit opposite their own issues), so 2 is filled.
        XCTAssertEqual(Catalog.anchoredRunCovers(
            in: page, claimed: [1: "https://x/TN_A_1.jpg", 3: "https://x/TN_A_3.jpg"])[2],
                       "https://x/plain.jpg")
        // Now claim TN_A_1 for the wrong issue: the run proves nothing.
        XCTAssertTrue(Catalog.anchoredRunCovers(
            in: page, claimed: [9: "https://x/TN_A_1.jpg", 3: "https://x/TN_A_3.jpg"]).isEmpty)
    }

    /// A single agreement is as likely to be luck as alignment.
    func testOneAnchorIsNotEnough() {
        let page = """
            <div><img src="https://x/TN_A_1.jpg"><img src="https://x/plain.jpg"></div>
            <div>1. https://mediafire.com/a</div>
            <div>2. https://mediafire.com/b</div>
            """
        XCTAssertTrue(Catalog.anchoredRunCovers(
            in: page, claimed: [1: "https://x/TN_A_1.jpg"]).isEmpty)
    }
}

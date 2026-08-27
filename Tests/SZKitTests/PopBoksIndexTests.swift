import XCTest
@testable import SZKit

/// Reading the two magazines' indexes out of the scripts that draw them.
///
/// The fixtures are the archive's own `dzuboks.js` and `ritam.js`, saved
/// whole. Every count and date asserted below was read off the live archive
/// before it was written here, so these are assertions about the real site
/// rather than about the parser agreeing with itself.
final class PopBoksIndexTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()        // .../Tests/SZKitTests
        .deletingLastPathComponent()        // .../Tests
        .appendingPathComponent("Fixtures/popboks")

    private func script(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name),
                   encoding: .utf8)
    }

    private func dzuboks() throws -> [PopBoksIndex.Entry] {
        try PopBoksIndex.dzuboks(try script("dzuboks.js"))
    }

    private func ritam() throws -> [PopBoksIndex.Entry] {
        try PopBoksIndex.ritam(try script("ritam.js"))
    }

    // MARK: - Džuboks

    /// 194 issue slots, eleven of which were never scanned.
    func testDzuboksHoldsTheScannedIssues() throws {
        let entries = try dzuboks()
        XCTAssertEqual(entries.count, 183)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.pages }, 11549)
    }

    /// The eleven the archive lists with no pages. Their tiles *and* their
    /// cover thumbnails 403, so there is nothing behind them to show.
    func testDzuboksDropsTheUnscannedIssues() throws {
        let present = Set(try dzuboks().map(\.id))
        for missing in [9, 24, 172, 177, 183, 184, 186, 187, 188, 189, 191] {
            XCTAssertFalse(present.contains(missing), "issue \(missing) should be absent")
        }
    }

    /// The run is continuous apart from those eleven: 1 to 194 with no other
    /// holes. A gap anywhere else would mean the year ranges and the page
    /// counts had been read out of step with each other.
    func testDzuboksRunIsOtherwiseComplete() throws {
        let present = Set(try dzuboks().map(\.id))
        let expected = Set(1...194).subtracting([9, 24, 172, 177, 183, 184, 186,
                                                 187, 188, 189, 191])
        XCTAssertEqual(present, expected)
    }

    func testDzuboksYearsComeFromTheRanges() throws {
        let byID = Dictionary(uniqueKeysWithValues: try dzuboks().map { ($0.id, $0) })
        // The edges of the first, a middle and the last year range.
        XCTAssertEqual(byID[1]?.year, 1974)
        XCTAssertEqual(byID[3]?.year, 1974)
        XCTAssertEqual(byID[4]?.year, 1975)
        XCTAssertEqual(byID[104]?.year, 1980)
        XCTAssertEqual(byID[105]?.year, 1981)
        XCTAssertEqual(byID[194]?.year, 1985)
    }

    func testDzuboksIsNumberedByItsOwnCovers() throws {
        let entries = try dzuboks()
        // The identity, the ordering and the printed number are all the same
        // thing on this magazine.
        XCTAssertTrue(entries.allSatisfy { $0.id == $0.number })
        XCTAssertTrue(entries.allSatisfy { $0.firstPage == 1 })
        XCTAssertEqual(entries.first { $0.id == 50 }?.title, "Džuboks 50")
        XCTAssertEqual(entries.first { $0.id == 50 }?.label, "50")
    }

    // MARK: - Ritam

    func testRitamHoldsEveryIssue() throws {
        let entries = try ritam()
        XCTAssertEqual(entries.count, 25)
        XCTAssertEqual(entries.reduce(0) { $0 + $1.pages }, 2077)
    }

    /// The scan of issue 142 begins at page 3. Reading position one is that
    /// page — asking for page 1 gets tiles that are not on the server.
    func testRitamKeepsAScanThatStartsPartWayIn() throws {
        let entry = try XCTUnwrap(try ritam().first { $0.id == 142 })
        XCTAssertEqual(entry.firstPage, 3)
        XCTAssertEqual(entry.pages, 81)          // pages 3...83 inclusive
        XCTAssertEqual(entry.label, "4/5")
        XCTAssertEqual(entry.year, 1991)
        XCTAssertEqual(entry.month, 1)           // "Jan-Feb '91." — the first
    }

    /// The archive's running order is the only statement of chronology there
    /// is: the folder numbers are storage keys, and the magazine restarted its
    /// own numbering with each of four relaunches.
    func testRitamIsOrderedByTheArchivesRunningOrder() throws {
        let entries = try ritam()
        XCTAssertEqual(entries.map(\.number), Array(1...25))
        XCTAssertEqual(entries.first?.id, 155)           // "1 - Feb '89."
        XCTAssertEqual(entries.first?.year, 1989)
        XCTAssertEqual(entries.last?.id, 150)            // "5 - Jun '95."
        XCTAssertEqual(entries.last?.year, 1995)

        // Chronological, which the folder numbers are emphatically not.
        let dates = entries.map { $0.year * 12 + ($0.month ?? 1) }
        XCTAssertEqual(dates, dates.sorted(), "the run is out of order")
    }

    /// Four issues share the designation "1" because the magazine relaunched
    /// four times. That is why `number` is this app's own counting.
    func testRitamsOwnNumberingRepeats() throws {
        let firsts = try ritam().filter { $0.label == "1" }
        XCTAssertEqual(firsts.count, 4)
        XCTAssertEqual(firsts.map(\.year), [1989, 1990, 1992, 1994])
    }

    func testRitamLabelShapes() throws {
        let byID = Dictionary(uniqueKeysWithValues: try ritam().map { ($0.id, $0) })
        // A plain issue: "3 - Apr '89."
        XCTAssertEqual(byID[157]?.label, "3"); XCTAssertEqual(byID[157]?.month, 4)
        // A double, closed up.
        XCTAssertEqual(byID[160]?.label, "6/7")
        // A triple.
        XCTAssertEqual(byID[147]?.label, "6/7/8")
        // The yearbook, which carries no number at all.
        XCTAssertEqual(byID[154]?.label, "Godišnjak")
        XCTAssertEqual(byID[154]?.year, 1993)
        XCTAssertEqual(byID[154]?.title, "Ritam Godišnjak")
    }

    /// A double issue spanning the new year is filed under the month it began.
    func testRitamDoubleSpanningTheNewYear() throws {
        let entry = try XCTUnwrap(try ritam().first { $0.id == 163 })
        XCTAssertEqual(entry.label, "10/11")
        XCTAssertEqual(entry.year, 1989)         // "Dec '89-Jan '90."
        XCTAssertEqual(entry.month, 12)
    }

    // MARK: - The trap in ritam.js

    /// `ritam.js` opens with commented-out copies of *Džuboks's* arrays and a
    /// superseded copy of its own. Reading the dead ones builds a catalogue of
    /// the wrong magazine that decodes cleanly and seeds without complaint, so
    /// this is the test that says the live statement was the one taken.
    func testRitamIgnoresTheCommentedOutDzuboksArrays() throws {
        let entries = try ritam()
        // Džuboks's own first issue is 194 issues of a different magazine. If
        // the commented block had won, this would be 194 entries numbered 1...
        XCTAssertEqual(entries.count, 25)
        XCTAssertTrue(entries.allSatisfy { $0.id >= 140 && $0.id <= 166 })
        XCTAssertTrue(entries.allSatisfy { $0.year >= 1989 })
    }

    /// Both scripts are served with CRLF endings, and Swift counts `\r\n` as
    /// one `Character` — so a split on `"\n"` finds no separator, treats the
    /// file as a single line, sees that line begin `//` and discards
    /// everything. That is not a near miss: it is how this parser first
    /// behaved, and Džuboks passed anyway because its live array happens to
    /// sit on line one and needed no stripping.
    func testCommentStrippingHandlesCRLF() {
        let source = "//var numbers = [[1,52]];\r\nvar numbers = [[7,68]];\r\n"
        let stripped = PopBoksIndex.stripComments(source)
        XCTAssertFalse(stripped.isEmpty, "the whole file was discarded")
        XCTAssertFalse(stripped.contains("[[1,52]]"), "the dead array survived")
        XCTAssertTrue(stripped.contains("[[7,68]]"))
    }

    /// The same file read both ways must give the same catalogue. CRLF is what
    /// the site serves; LF is what a copy through an editor may become.
    func testBothLineEndingsReadAlike() throws {
        let crlf = try script("ritam.js")
        let lf = crlf.replacingOccurrences(of: "\r\n", with: "\n")
        XCTAssertEqual(try PopBoksIndex.ritam(crlf), try PopBoksIndex.ritam(lf))
    }

    func testCommentStrippingLeavesURLsAlone() {
        let source = """
            // var numbers = [[1,52]];
            var numbers = [[7,68]];   // the live one
            var home = "https://www.popboks.com/ritam/";
            """
        let stripped = PopBoksIndex.stripComments(source)
        XCTAssertFalse(stripped.contains("[[1,52]]"))
        XCTAssertTrue(stripped.contains("[[7,68]]"))
        // A trailing comment is left where it is: cutting at `//` anywhere
        // would cut this URL in half.
        XCTAssertTrue(stripped.contains("https://www.popboks.com/ritam/"))
    }

    // MARK: - Both

    /// Nothing in either catalogue may be unnamed, undated or empty — each of
    /// those is a row on the shelf that says nothing or opens onto nothing.
    func testEveryEntryIsUsable() throws {
        for entry in try dzuboks() + ritam() {
            XCTAssertFalse(entry.title.isEmpty, "\(entry.id) has no title")
            XCTAssertFalse(entry.label.isEmpty, "\(entry.id) has no label")
            XCTAssertGreaterThan(entry.pages, 0, "\(entry.id) has no pages")
            XCTAssertGreaterThanOrEqual(entry.firstPage, 1, "\(entry.id) starts before page 1")
            XCTAssertGreaterThanOrEqual(entry.year, 1974, "\(entry.id) predates the magazine")
            XCTAssertLessThanOrEqual(entry.year, 1995, "\(entry.id) postdates the magazine")
        }
    }
}

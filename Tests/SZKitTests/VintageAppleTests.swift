import XCTest
@testable import SZKit

/// The Vintage Apple parser, against saved copies of the real pages.
///
/// Four sections rather than one, because the month is encoded differently in
/// each: Byte stamps `197509_`, Macworld and Softalk use a two-digit `_8404_`,
/// and the book sections state no month at all. One parser reads all of them
/// only because the *year* comes from the table's own column rather than from
/// any filename.
final class VintageAppleTests: XCTestCase {

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath)      // .../Tests/SZKitTests/<this file>
            .deletingLastPathComponent()      // SZKitTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/vintageapple")
    }

    private func fixture(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent("\(name).html"),
                   encoding: .utf8)
    }

    // MARK: - Sections

    func testEverySectionIsClaimedByExactlyOneGroup() {
        XCTAssertEqual(VintageApple.sections.count, 16)
        XCTAssertEqual(Set(VintageApple.sections.map(\.slug)).count,
                       VintageApple.sections.count, "a section is listed twice")
        let magazines = VintageApple.sections.filter { $0.group == .magazines }
        let books = VintageApple.sections.filter { $0.group == .books }
        XCTAssertEqual(magazines.count, 6)
        XCTAssertEqual(books.count, 10)
    }

    /// The two mirrors hold no PDFs of their own and must stay out.
    func testMirrorSectionsAreNotShipped() {
        let slugs = Set(VintageApple.sections.map(\.slug))
        XCTAssertFalse(slugs.contains("macdrivers"))
        XCTAssertFalse(slugs.contains("gamba2"))
        // Not a mirror but not a listing either — see `sections`.
        XCTAssertFalse(slugs.contains("lisainfo"))
    }

    // MARK: - Byte

    func testByteRows() throws {
        let entries = VintageApple.entries(in: try fixture("byte"))
        XCTAssertEqual(entries.count, 287)

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.pdf,
                       "pdf/197509_Byte_Magazine_Vol_00-01_The_Worlds_Greatest_Toy.pdf")
        XCTAssertEqual(first.thumb,
                       "thumb/197509_Byte_Magazine_Vol_00-01_The_Worlds_Greatest_Toy.jpg")
        XCTAssertEqual(first.year, 1975)
        XCTAssertEqual(first.month, 9)
        // The leading date stamp is not part of the title — the row carries
        // year and month of its own.
        XCTAssertEqual(first.title, "Byte Magazine Vol 00-01 The Worlds Greatest Toy")
    }

    // MARK: - The two-digit sections

    func testMacworldReadsTheShortDateStamp() throws {
        let entries = VintageApple.entries(in: try fixture("macworld"))
        XCTAssertEqual(entries.count, 258)

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.pdf, "pdf/MacWorld_8404_April_1984_premier.pdf")
        XCTAssertEqual(first.year, 1984)
        XCTAssertEqual(first.month, 4)
    }

    func testSoftalkReadsTheShortDateStamp() throws {
        let entries = VintageApple.entries(in: try fixture("softalk"))
        XCTAssertEqual(entries.count, 48)

        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(first.pdf, "pdf/SOFTALK_8009_v1_n01.pdf")
        XCTAssertEqual(first.year, 1980)
        XCTAssertEqual(first.month, 9)
    }

    // MARK: - Books

    /// A book has a year and no month, and its filename must not be mined for
    /// one — there is nothing there to find.
    func testBooksCarryAYearAndNoMonth() throws {
        let entries = VintageApple.entries(in: try fixture("macbooks"))
        XCTAssertEqual(entries.count, 409)

        let withMonth = entries.filter { $0.month != nil }
        XCTAssertLessThan(withMonth.count * 5, entries.count,
                          "\(withMonth.count) of \(entries.count) books claim a month")
        let dated = entries.filter { $0.year != nil }
        XCTAssertGreaterThan(dated.count * 10, entries.count * 9)
    }

    // MARK: - Across every fixture

    func testEveryRowIsUsable() throws {
        for name in ["byte", "macworld", "softalk", "macbooks"] {
            for entry in VintageApple.entries(in: try fixture(name)) {
                XCTAssertTrue(entry.pdf.hasPrefix("pdf/"), "\(name): \(entry.pdf)")
                XCTAssertTrue(entry.pdf.hasSuffix(".pdf"), "\(name): \(entry.pdf)")
                XCTAssertFalse(entry.title.isEmpty, "\(name): \(entry.pdf) has no title")
                XCTAssertFalse(entry.title.lowercased().hasSuffix(".pdf"),
                               "\(name): title kept its extension — \(entry.title)")
                XCTAssertNotNil(entry.thumb, "\(name): \(entry.pdf) has no thumbnail")
            }
        }
    }

    // MARK: - The month rule

    /// The year is what makes the two-digit stamp safe to read. Without that
    /// check `PC_World_8303_V1N1` offers several plausible pairs.
    func testShortStampMustAgreeWithTheYearColumn() {
        XCTAssertEqual(VintageApple.month(inFilename: "PC_World_8303_V1N1_March_1983.pdf",
                                          year: 1983), 3)
        // Same filename, wrong year: the digits no longer describe a date, and
        // the spelled-out month is what remains.
        XCTAssertEqual(VintageApple.month(inFilename: "PC_World_8303_V1N1_March_1983.pdf",
                                          year: 1991), 3)
        // Nothing to find at all.
        XCTAssertNil(VintageApple.month(inFilename: "101_Ways_to_Use_a_Macintosh_1984.pdf",
                                        year: 1984))
    }

    func testSixDigitStampIsReadWhole() {
        XCTAssertEqual(VintageApple.month(inFilename: "197509_Byte_Magazine.pdf",
                                          year: 1975), 9)
        XCTAssertEqual(VintageApple.month(inFilename: "199807_Byte_Magazine.pdf",
                                          year: 1998), 7)
        // A stamp that contradicts the table is not a date.
        XCTAssertNil(VintageApple.month(inFilename: "197513_Byte_Magazine.pdf", year: 1975))
    }

    /// "May-June" is one issue dated May.
    func testSpelledMonthFallsBackToTheFirst() {
        XCTAssertEqual(VintageApple.month(inFilename: "MacWorld_May-June_1984.pdf",
                                          year: 1984), 5)
    }
}

import XCTest
@testable import SZKit

/// The Atarimania parser, against saved copies of the real pages.
///
/// Three titles rather than one, because the site's three naming conventions
/// are the whole difficulty: Antic labels issues "Vol. 1 - No. 01" and files
/// them as `Antic_Vol_1_No_1.pdf`, ANALOG labels them "01" and files them as
/// `analog_no_01.pdf`, and Page 6 uses "Issue 01" with a two-month cover date.
/// A parser written against any one of them alone would look finished.
final class AtarimaniaTests: XCTestCase {

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath)      // .../Tests/SZKitTests/<this file>
            .deletingLastPathComponent()      // SZKitTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/atarimania")
    }

    private func fixture(_ name: String) throws -> String {
        let url = Self.fixtures.appendingPathComponent("\(name).html")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - The index

    func testIndexNamesEveryTitle() throws {
        let ids = Atarimania.magazineIDs(in: try fixture("index"))
        XCTAssertEqual(ids.count, 85)
        XCTAssertEqual(Set(ids).count, ids.count, "an id is listed twice")
        XCTAssertTrue(ids.contains(20), "Antic (20) is missing")
        XCTAssertTrue(ids.contains(18), "ANALOG (18) is missing")
    }

    // MARK: - One title

    func testAnticIssues() throws {
        let html = try fixture("antic")
        XCTAssertEqual(Atarimania.name(in: html), "Antic")

        let issues = Atarimania.issues(in: html)
        XCTAssertEqual(issues.count, 88)

        let first = try XCTUnwrap(issues.first)
        XCTAssertEqual(first.pdf, "mags/pdf/Antic_Vol_1_No_1.pdf")
        XCTAssertEqual(first.cover, "mags/low_res/Antic_Vol_1_No_1.jpg")
        XCTAssertEqual(first.label, "Vol. 1 - No. 01")
        XCTAssertEqual(first.year, 1982)
        XCTAssertEqual(first.month, 4)
        XCTAssertEqual(first.stem, "Antic_Vol_1_No_1")
    }

    /// ANALOG's filenames share nothing with Antic's but the directory, which
    /// is why the build reads hrefs instead of generating them.
    func testAnalogUsesItsOwnNaming() throws {
        let html = try fixture("analog")
        XCTAssertEqual(Atarimania.name(in: html), "ANALOG")

        let issues = Atarimania.issues(in: html)
        XCTAssertEqual(issues.count, 79)

        let first = try XCTUnwrap(issues.first)
        XCTAssertEqual(first.pdf, "mags/pdf/analog_no_01.pdf")
        XCTAssertEqual(first.label, "01")
        XCTAssertEqual(first.year, 1981)
        // "January / February - 1981" — the first month is the cover date.
        XCTAssertEqual(first.month, 1)
    }

    func testPageSixIssues() throws {
        let html = try fixture("page6")
        XCTAssertEqual(Atarimania.name(in: html), "Page 6")

        let issues = Atarimania.issues(in: html)
        XCTAssertEqual(issues.count, 85)

        let first = try XCTUnwrap(issues.first)
        XCTAssertEqual(first.pdf, "mags/pdf/page-6-issue-01.pdf")
        XCTAssertEqual(first.label, "Issue 01")
        // "December / January - 1982": December is the issue's own month, and
        // taking the later one would sort this after issue 2.
        XCTAssertEqual(first.year, 1982)
        XCTAssertEqual(first.month, 12)
    }

    /// Every issue on every fixture must have a file to fetch and a label to
    /// show. A silently empty field is the failure this parser would otherwise
    /// produce on a redesign.
    func testEveryParsedIssueIsUsable() throws {
        for name in ["antic", "analog", "page6"] {
            for issue in Atarimania.issues(in: try fixture(name)) {
                XCTAssertTrue(issue.pdf.hasPrefix("mags/pdf/"), "\(name): \(issue.pdf)")
                XCTAssertTrue(issue.pdf.hasSuffix(".pdf"), "\(name): \(issue.pdf)")
                XCTAssertFalse(issue.label.isEmpty, "\(name): \(issue.pdf) has no label")
                XCTAssertFalse(issue.stem.isEmpty)
            }
        }
    }

    /// The covers are the only artwork the site offers, so losing them
    /// silently would leave a shelf of grey rectangles.
    func testMostIssuesHaveACover() throws {
        let issues = Atarimania.issues(in: try fixture("antic"))
        let withCover = issues.filter { $0.cover != nil }
        XCTAssertGreaterThan(withCover.count * 10, issues.count * 9)
    }

    // MARK: - Dates

    func testDateShapes() {
        XCTAssertEqual(Atarimania.date(in: "April - 1982").year, 1982)
        XCTAssertEqual(Atarimania.date(in: "April - 1982").month, 4)

        // A bi-monthly states both months; the first is the cover date.
        XCTAssertEqual(Atarimania.date(in: "January / February - 1981").month, 1)
        XCTAssertEqual(Atarimania.date(in: "December / January - 1982").month, 12)

        // Some issues are recorded with a year and no month at all.
        XCTAssertEqual(Atarimania.date(in: "1983").year, 1983)
        XCTAssertNil(Atarimania.date(in: "1983").month)

        XCTAssertNil(Atarimania.date(in: "").year)
        XCTAssertNil(Atarimania.date(in: "").month)
    }

    /// Month names are matched by position in the string, not by which is
    /// checked first — "December / January" must not come back as January
    /// merely because January is earlier in the calendar.
    func testEarliestMonthInTheStringWins() {
        XCTAssertEqual(Atarimania.date(in: "November / December - 1990").month, 11)
        XCTAssertEqual(Atarimania.date(in: "March / April - 1985").month, 3)
    }
}

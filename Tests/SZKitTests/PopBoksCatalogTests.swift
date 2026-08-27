import XCTest
@testable import SZKit

/// The two shipped PopBoks indexes, and the addresses they build.
///
/// Every address asserted below was requested from the live archive before it
/// was written here, so these are claims about the real site rather than about
/// the generator agreeing with itself.
final class PopBoksCatalogTests: XCTestCase {

    private func catalogue(_ magazine: PopBoks.Magazine) throws -> PopBoksCatalog {
        try PopBoksCatalog.shipped(magazine)
    }

    private func issue(_ id: Int, in magazine: PopBoks.Magazine) throws
        -> PopBoksCatalog.Issue {
        try XCTUnwrap(try catalogue(magazine).issues.first { $0.id == id })
    }

    // MARK: - What ships

    func testBothCataloguesAreThere() throws {
        let dzuboks = try catalogue(.dzuboks)
        XCTAssertEqual(dzuboks.version, PopBoksCatalog.currentVersion)
        XCTAssertEqual(dzuboks.kind, .dzuboks)
        XCTAssertEqual(dzuboks.issues.count, 183)
        XCTAssertEqual(dzuboks.issues.reduce(0) { $0 + $1.pages }, 11549)

        let ritam = try catalogue(.ritam)
        XCTAssertEqual(ritam.version, PopBoksCatalog.currentVersion)
        XCTAssertEqual(ritam.kind, .ritam)
        XCTAssertEqual(ritam.issues.count, 25)
        XCTAssertEqual(ritam.issues.reduce(0) { $0 + $1.pages }, 2077)
    }

    /// A catalogue that named the wrong magazine would build every address
    /// against the wrong directory and 403 on every tile.
    func testEachCatalogueKnowsWhichMagazineItIs() throws {
        XCTAssertEqual(try catalogue(.dzuboks).magazine, "dzuboks")
        XCTAssertEqual(try catalogue(.ritam).magazine, "ritam")
    }

    /// Nothing may be unnamed, undated, empty or shapeless. Each of those is
    /// a row on the shelf that says nothing, or one that can never open.
    func testEveryIssueIsUsable() throws {
        for magazine in PopBoks.Magazine.allCases {
            let file = try catalogue(magazine)
            for issue in file.issues {
                let name = "\(magazine.rawValue) \(issue.id)"
                XCTAssertFalse(issue.title.isEmpty, "\(name) has no title")
                XCTAssertFalse(issue.label.isEmpty, "\(name) has no label")
                XCTAssertGreaterThan(issue.pages, 0, "\(name) has no pages")
                XCTAssertGreaterThanOrEqual(issue.firstPage, 1, "\(name) starts before 1")
                XCTAssertGreaterThan(issue.columns, 0, "\(name) has no columns")
                XCTAssertGreaterThan(issue.rows, 0, "\(name) has no rows")
                XCTAssertNotNil(file.coverURL(issue), "\(name) has no cover")
                XCTAssertTrue((1974...1995).contains(issue.year), "\(name) is misdated")
            }
        }
    }

    /// The shelf orders on `number`, so a repeat puts two issues in one place.
    func testNumbersAndIdsAreUnique() throws {
        for magazine in PopBoks.Magazine.allCases {
            let issues = try catalogue(magazine).issues
            XCTAssertEqual(Set(issues.map(\.id)).count, issues.count, "\(magazine)")
            XCTAssertEqual(Set(issues.map(\.number)).count, issues.count, "\(magazine)")
        }
    }

    // MARK: - Addresses

    /// Both magazines, spelled differently on purpose: Džuboks keeps its
    /// scans under `dzuboksimages` and Ritam under a plain `images`.
    func testTileAddresses() throws {
        let dzuboks = try catalogue(.dzuboks)
        XCTAssertEqual(dzuboks.tileURL(try issue(1, in: .dzuboks), page: 1,
                                       column: 0, row: 0),
                       "https://www.popboks.com/dzuboks/dzuboksimages/1/1/2_0_0.jpg")

        let ritam = try catalogue(.ritam)
        XCTAssertEqual(ritam.tileURL(try issue(155, in: .ritam), page: 1,
                                     column: 0, row: 0),
                       "https://www.popboks.com/ritam/images/155/1/2_0_0.jpg")
        // The far corner of a seven-row page.
        XCTAssertEqual(ritam.tileURL(try issue(155, in: .ritam), page: 1,
                                     column: 4, row: 6),
                       "https://www.popboks.com/ritam/images/155/1/2_4_6.jpg")
    }

    /// Always under page 1, even for the issue whose scan starts at page 3.
    func testCoverAddresses() throws {
        XCTAssertEqual(try catalogue(.dzuboks).coverURL(try issue(50, in: .dzuboks)),
                       "https://www.popboks.com/dzuboks/dzuboksimages/50/1/icon.jpg")
        XCTAssertEqual(try catalogue(.ritam).coverURL(try issue(155, in: .ritam)),
                       "https://www.popboks.com/ritam/images/155/1/icon.jpg")
        // Its own first *page* is 3, and its cover is still at 1.
        XCTAssertEqual(try catalogue(.ritam).coverURL(try issue(142, in: .ritam)),
                       "https://www.popboks.com/ritam/images/142/1/icon.jpg")
    }

    // MARK: - Where a page really is

    /// Ritam 142's scan begins at page 3. Reading position one is that page,
    /// and asking for page 1 gets tiles the archive does not have.
    func testAScanThatStartsPartWayIn() throws {
        let entry = try issue(142, in: .ritam)
        XCTAssertEqual(entry.firstPage, 3)
        XCTAssertEqual(entry.pages, 81)
        XCTAssertEqual(entry.sourcePage(at: 1), 3)
        XCTAssertEqual(entry.sourcePage(at: 81), 83)
        // Past the end, rather than a plausible address for a page that is
        // not there.
        XCTAssertNil(entry.sourcePage(at: 82))
        XCTAssertNil(entry.sourcePage(at: 0))

        let file = try catalogue(.ritam)
        XCTAssertEqual(file.tileURL(entry, page: entry.sourcePage(at: 1)!,
                                    column: 0, row: 0),
                       "https://www.popboks.com/ritam/images/142/3/2_0_0.jpg")
    }

    /// Everything else starts at page one, so a bug in the mapping would show
    /// up here rather than in one special case.
    func testEveryOtherScanStartsAtPageOne() throws {
        var late: [String] = []
        for magazine in PopBoks.Magazine.allCases {
            for issue in try catalogue(magazine).issues where issue.firstPage != 1 {
                late.append("\(magazine.rawValue) \(issue.id) at \(issue.firstPage)")
            }
        }
        XCTAssertEqual(late, ["ritam 142 at 3"])
    }

    // MARK: - The grid

    /// Five columns everywhere, and seven rows almost everywhere.
    func testTheUsualShape() throws {
        for magazine in PopBoks.Magazine.allCases {
            for issue in try catalogue(magazine).issues {
                XCTAssertEqual(issue.columns, 5, "\(magazine.rawValue) \(issue.id)")
                XCTAssertEqual(issue.tilesPerPage, 5 * issue.rows)
            }
        }
    }

    /// The two Ritam issues that are eight rows tall.
    ///
    /// The archive's own reader loops over a fixed seven rows, so on that site
    /// the bottom strip of every page in these two is never requested and
    /// never drawn. Recording eight is what recovers it.
    func testTheTwoIssuesTallerThanTheSitesOwnViewer() throws {
        let tall = try catalogue(.ritam).issues.filter { $0.rows > 7 }
        XCTAssertEqual(tall.map(\.id), [155, 156])
        XCTAssertTrue(tall.allSatisfy { $0.rows == 8 })
        // And nothing in Džuboks is.
        XCTAssertTrue(try catalogue(.dzuboks).issues.allSatisfy { $0.rows == 7 })
    }

    // MARK: - Runs

    /// Džuboks is numbered by its own covers: the id, the number and the
    /// printed issue number are all the same thing.
    func testDzuboksNumbering() throws {
        let issues = try catalogue(.dzuboks).issues
        XCTAssertTrue(issues.allSatisfy { $0.id == $0.number })
        XCTAssertTrue(issues.allSatisfy { $0.label == String($0.id) })
        XCTAssertEqual(issues.first?.number, 1)
        XCTAssertEqual(issues.last?.number, 194)
        XCTAssertEqual(try issue(50, in: .dzuboks).title, "Džuboks 50")
    }

    /// Ritam's `number` is this app's own counting, because the magazine
    /// restarted at 1 with each of its four relaunches.
    func testRitamIsCountedByThisApp() throws {
        let issues = try catalogue(.ritam).issues
        XCTAssertEqual(issues.map(\.number), Array(1...25))
        // Its folder numbers are storage keys and say nothing about order.
        XCTAssertNotEqual(issues.map(\.id), issues.map(\.id).sorted())
        // Chronological, which is the whole point of the renumbering.
        let dates = issues.map { $0.year * 12 + ($0.month ?? 1) }
        XCTAssertEqual(dates, dates.sorted())
        // Four issues called "1".
        XCTAssertEqual(issues.filter { $0.label == "1" }.count, 4)
    }
}

import XCTest
@testable import SZKit

/// Putting the shipped Stripovi index onto the shelf.
final class StripoviSeedTests: XCTestCase {

    private func seeded() throws -> Store {
        let store = try Store()
        try store.seedStripovi(try StripoviCatalog.shipped())
        return store
    }

    func testItSeedsEveryComic() throws {
        let store = try Store()
        let report = try store.seedStripovi(try StripoviCatalog.shipped())
        XCTAssertEqual(report.inserted, 31)
        XCTAssertEqual(report.updated, 0)
        XCTAssertFalse(report.skipped)
        XCTAssertEqual(store.issueCount, 31)
    }

    func testTheRowsCarryTheSource() throws {
        let store = try seeded()
        let issues = try store.recent(limit: nil)
        XCTAssertEqual(issues.count, 31)
        for issue in issues { XCTAssertEqual(issue.site, .stripovi) }
    }

    /// The page count comes from the site and is stored, which is what lets a
    /// page-by-page download show a bar against a real number.
    func testThePageCountIsStored() throws {
        let store = try seeded()
        let total = try store.recent(limit: nil).compactMap(\.pageCount).reduce(0, +)
        XCTAssertEqual(total, 1442)
    }

    /// The run is a series; the other twenty-six are filed under their own
    /// names so the filter never shows a blank.
    func testTheSeriesFilterIsPopulatedForEveryRow() throws {
        let store = try seeded()
        let editions = try store.editions(sites: [.stripovi])
        XCTAssertTrue(editions.contains("Martina Mjesec"), "\(editions)")
        XCTAssertEqual(editions.count, 27, "one run plus twenty-six singles")
        XCTAssertFalse(editions.contains(where: \.isEmpty))
    }

    func testThePublisherIsTheSite() throws {
        let store = try seeded()
        XCTAssertEqual(try store.publishers(sites: [.stripovi]), ["Stripovi.com"])
    }

    /// The mirror is the comic's own page — the address a download falls back
    /// to reading when the page-address rule stops being true.
    func testTheMirrorIsTheComicPage() throws {
        let store = try seeded()
        let snijeg = try XCTUnwrap(try store.recent(limit: nil)
            .first { $0.title == "Snijeg u kolovozu" })
        let mirrors = try store.liveMirrors(forIssue: snijeg.id)
        XCTAssertEqual(mirrors.map(\.host), [Stripovi.host])
        XCTAssertTrue(try XCTUnwrap(mirrors.first?.url).contains("ComicID=6"))
    }

    /// A cover for every row: these comics have no artwork of their own and
    /// the site's tile is the only picture there is.
    func testEveryRowGetsArtwork() throws {
        let store = try seeded()
        var without: [String] = []
        for issue in try store.recent(limit: nil) {
            if ((try? store.coverURL(forIssue: issue.id)) ?? nil) == nil {
                without.append(issue.title ?? "?")
            }
        }
        XCTAssertEqual(without, [])
    }

    // MARK: - Seeding twice

    func testASecondPassIsSkippedByTheStamp() throws {
        let store = try seeded()
        let again = try store.seedStripovi(try StripoviCatalog.shipped())
        XCTAssertTrue(again.skipped)
        XCTAssertEqual(store.issueCount, 31)
    }

    /// Forced, it updates rather than duplicating — the identity is the site's
    /// own id, so a corrected title is an edit and not a second row.
    func testAForcedSecondPassUpdatesRatherThanDuplicating() throws {
        let store = try seeded()
        let again = try store.seedStripovi(try StripoviCatalog.shipped(), force: true)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.updated, 31)
        XCTAssertEqual(store.issueCount, 31)
    }

    /// Reseeding must not disturb what the reader owns.
    func testReseedingLeavesTheReadersOwnStateAlone() throws {
        let store = try seeded()
        let issue = try XCTUnwrap(try store.recent(limit: nil).first)
        try store.setRead(true, issueID: issue.id)

        try store.seedStripovi(try StripoviCatalog.shipped(), force: true)
        let after = try XCTUnwrap(try store.recent(limit: nil).first { $0.id == issue.id })
        XCTAssertTrue(after.isRead, "a reseed marked a finished comic unread")
    }
}

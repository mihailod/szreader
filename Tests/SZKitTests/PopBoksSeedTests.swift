import XCTest
@testable import SZKit

/// Putting the shipped PopBoks indexes onto the shelf.
final class PopBoksSeedTests: XCTestCase {

    private func seeded(_ magazine: PopBoks.Magazine = .ritam) throws -> Store {
        let store = try Store()
        try store.seedPopBoks(try PopBoksCatalog.shipped(magazine))
        return store
    }

    /// Both, in one library, which is how the app has them.
    private func seededBoth() throws -> Store {
        let store = try Store()
        for magazine in PopBoks.Magazine.allCases {
            try store.seedPopBoks(try PopBoksCatalog.shipped(magazine))
        }
        return store
    }

    func testItSeedsEveryIssue() throws {
        let store = try Store()
        let report = try store.seedPopBoks(try PopBoksCatalog.shipped(.dzuboks))
        XCTAssertEqual(report.inserted, 183)
        XCTAssertEqual(report.updated, 0)
        XCTAssertFalse(report.skipped)
        XCTAssertEqual(store.issueCount, 183)
    }

    /// Two magazines in one library, and neither treads on the other. Their
    /// ids overlap — Džuboks runs 1 to 194 and Ritam 140 to 166 — so this is
    /// the test that says the natural key is scoped by site.
    func testTheTwoMagazinesDoNotCollide() throws {
        let store = try seededBoth()
        XCTAssertEqual(store.issueCount, 183 + 25)

        let dzuboks = try store.recent(limit: nil).filter { $0.site == .popboksDzuboks }
        let ritam = try store.recent(limit: nil).filter { $0.site == .popboksRitam }
        XCTAssertEqual(dzuboks.count, 183)
        XCTAssertEqual(ritam.count, 25)

        // Both magazines have an issue filed under code "155", and they are
        // different rows.
        let both = try store.recent(limit: nil).filter { $0.code == "155" }
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(Set(both.map(\.site)), [.popboksDzuboks, .popboksRitam])
    }

    func testTheRowsCarryTheirSource() throws {
        let store = try seeded(.ritam)
        let issues = try store.recent(limit: nil)
        XCTAssertEqual(issues.count, 25)
        for issue in issues { XCTAssertEqual(issue.site, .popboksRitam) }
    }

    /// The page count is stored, which is what lets a page-by-page download
    /// show a bar against a real number — and on this source that bar is the
    /// only sign of progress for minutes at a time.
    func testThePageCountIsStored() throws {
        let store = try seeded(.dzuboks)
        let total = try store.recent(limit: nil).compactMap(\.pageCount).reduce(0, +)
        XCTAssertEqual(total, 11549)
    }

    func testThePublisherNamesTheArchiveAndTheMagazine() throws {
        XCTAssertEqual(try seeded(.dzuboks).publishers(sites: [.popboksDzuboks]),
                       ["PopBoks: Džuboks"])
        XCTAssertEqual(try seeded(.ritam).publishers(sites: [.popboksRitam]),
                       ["PopBoks: Ritam"])
    }

    /// One magazine is one run, so the Series filter has exactly one entry and
    /// never a blank.
    func testTheSeriesFilterIsTheMagazine() throws {
        let store = try seededBoth()
        XCTAssertEqual(try store.editions(sites: [.popboksDzuboks]), ["Džuboks"])
        XCTAssertEqual(try store.editions(sites: [.popboksRitam]), ["Ritam"])
    }

    /// Every row has artwork. Without it the shelf is 208 grey rectangles.
    func testEveryRowHasACover() throws {
        let store = try seededBoth()
        let without = try store.recent(limit: nil).filter {
            ($0.coverURL ?? "").isEmpty
        }
        XCTAssertEqual(without.map(\.title), [])
    }

    /// Every issue says where it came from.
    ///
    /// Local Files is the only source on the shelf with nothing behind it to
    /// name; everything else, this one included, shows its archive in the info
    /// panel. There is no file here to point at — an issue is thousands of
    /// tiles — so the mirror is the folder they all sit under, which is unique
    /// per issue and on the right host.
    func testEveryIssueRecordsWhereItCameFrom() throws {
        let store = try seededBoth()
        for issue in try store.recent(limit: nil) {
            let mirrors = try store.liveMirrors(forIssue: issue.id)
            XCTAssertEqual(mirrors.count, 1, "\(issue.title ?? "?")")
            XCTAssertEqual(mirrors.first?.host, PopBoks.host)
        }
    }

    /// The folder, per magazine, spelled the way each magazine spells it.
    func testTheMirrorIsTheIssuesOwnFolder() throws {
        let store = try seededBoth()
        let issues = try store.recent(limit: nil)

        let dzuboks = try XCTUnwrap(issues.first {
            $0.site == .popboksDzuboks && $0.code == "50"
        })
        XCTAssertEqual(try store.liveMirrors(forIssue: dzuboks.id).first?.url,
                       "https://www.popboks.com/dzuboks/dzuboksimages/50/")

        let ritam = try XCTUnwrap(issues.first {
            $0.site == .popboksRitam && $0.code == "155"
        })
        XCTAssertEqual(try store.liveMirrors(forIssue: ritam.id).first?.url,
                       "https://www.popboks.com/ritam/images/155/")
    }

    /// One per issue and no sharing, which `mirror.url` being `UNIQUE` would
    /// otherwise turn into 207 issues filed under nothing.
    func testTheMirrorsAreDistinct() throws {
        let store = try seededBoth()
        let urls = try store.recent(limit: nil).flatMap {
            try store.liveMirrors(forIssue: $0.id).map(\.url)
        }
        XCTAssertEqual(urls.count, 183 + 25)
        XCTAssertEqual(Set(urls).count, urls.count, "two issues share a mirror")
    }

    /// A second pass changes nothing and adds nothing.
    func testReseedingIsIdempotent() throws {
        let store = try Store()
        let file = try PopBoksCatalog.shipped(.ritam)
        try store.seedPopBoks(file)
        let again = try store.seedPopBoks(file, force: true)
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.updated, 25)
        XCTAssertEqual(store.issueCount, 25)
    }

    /// The stamp is what makes a launch cheap: the second call does no work.
    func testTheStampSkipsTheSecondPass() throws {
        let store = try Store()
        let file = try PopBoksCatalog.shipped(.ritam)
        try store.seedPopBoks(file)
        XCTAssertTrue(try store.seedPopBoks(file).skipped)
    }

    /// Searchable by the year it came out and by the designation on its cover,
    /// neither of which is a column.
    func testTheYearAndTheLabelAreSearchable() throws {
        let store = try seededBoth()
        XCTAssertFalse(try store.search("1979", limit: nil).isEmpty,
                       "no Džuboks found by year")
        let doubles = try store.search("6/7", limit: nil)
        XCTAssertTrue(doubles.contains { $0.title == "Ritam 6/7" }, "\(doubles.count) hits")
    }

    /// The stamp carries the seed's revision, not only the file's digest.
    func testTheStampRecordsTheSeedRevision() throws {
        let store = try Store()
        try store.seedCatalogue(for: .popboksRitam)
        let stamp = try XCTUnwrap(try store.meta(Store.catalogueStamp(for: .popboksRitam)))
        XCTAssertTrue(stamp.hasSuffix("/r1"), stamp)

        // A source whose seed has not changed carries the bare digest, so
        // nobody re-seeds eighteen thousand rows to fix two hundred.
        try store.seedCatalogue(for: .stripovi)
        let plain = try XCTUnwrap(try store.meta(Store.catalogueStamp(for: .stripovi)))
        XCTAssertFalse(plain.contains("/r"), plain)
    }

    /// **A library seeded by the previous build gets the correction.**
    ///
    /// That build wrote these issues with no mirror, and stamped them with the
    /// catalogue's digest alone. The catalogue has not changed by a byte
    /// since, so without the revision in the stamp the digest would still
    /// match, the seed would skip, and those issues would never be able to say
    /// where they came from.
    func testALibrarySeededByThePreviousBuildIsPutRight() throws {
        let store = try Store()
        try store.seedCatalogue(for: .popboksRitam)

        // Wind the stamp back to what the previous build wrote: the digest of
        // these very bytes, with no revision after it.
        let key = Store.catalogueStamp(for: .popboksRitam)
        let current = try XCTUnwrap(try store.meta(key))
        XCTAssertTrue(current.hasSuffix("/r1"), current)
        try store.setMeta(key, String(current.dropLast("/r1".count)))

        // The next launch notices, rather than matching on the digest and
        // skipping. That it re-runs at all is the whole mechanism; the mirrors
        // it writes are covered by the tests above.
        let report = try store.seedCatalogue(for: .popboksRitam)
        XCTAssertFalse(report.skipped, "the correction was skipped")
        XCTAssertEqual(report.updated, 25)
        for issue in try store.recent(limit: nil) {
            XCTAssertEqual(try store.liveMirrors(forIssue: issue.id).count, 1,
                           "\(issue.title ?? "?") has no mirror")
        }

        // And it settles: a third launch matches the new stamp and skips.
        XCTAssertTrue(try store.seedCatalogue(for: .popboksRitam).skipped)
    }

    /// Routed through the shared entry point, so the app asks one question —
    /// "does this source have a shipped index?" — and gets one answer,
    /// whichever of the three catalogue shapes is behind it.
    func testSeedingThroughTheSharedEntryPoint() throws {
        for site in IssueSite.popboksSites {
            let store = try Store()
            let report = try store.seedCatalogue(for: site)
            XCTAssertFalse(report.skipped, "\(site)")
            XCTAssertGreaterThan(report.inserted, 0, "\(site)")
        }
    }
}

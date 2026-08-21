import XCTest
@testable import SZKit

/// The seven BombJack catalogues as they will ship, read the way the app reads
/// them.
///
/// The other shipped catalogues have tests like this for the same reason: the
/// files are generated, so nothing else would notice if a rebuild produced
/// something the seed cannot use, or could use and would be wrong about.
///
/// Seven rather than one because a single 18,219-row catalogue took fifteen
/// seconds to seed — long enough for iOS to kill the app during launch, and
/// for the kill to roll the whole thing back and do it again next time.
final class ShippedBombJackCatalogTests: XCTestCase {

    private func catalogue(_ site: IssueSite) throws -> ShippedCatalog {
        let name = try XCTUnwrap(site.catalogueResource, "\(site) ships no catalogue")
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"),
                                "\(name).json is not in the bundle")
        return try ShippedCatalog.decode(try Data(contentsOf: url))
    }

    private func everything() throws -> [(IssueSite, ShippedCatalog)] {
        try IssueSite.bombjackSites.map { ($0, try catalogue($0)) }
    }

    func testThereAreSevenAndTheyAreSubstantial() throws {
        XCTAssertEqual(IssueSite.bombjackSites.count, 7)
        let all = try everything()
        let total = all.reduce(0) { $0 + $1.1.issues.count }
        XCTAssertGreaterThan(total, 15_000)

        // The point of the split: none of them is big enough to be a problem
        // on its own. The single catalogue this replaced was 18,219.
        for (site, file) in all {
            XCTAssertLessThan(file.issues.count, 5_000,
                              "\(site.display) is large enough to stall a launch")
            XCTAssertGreaterThan(file.issues.count, 0, "\(site.display) is empty")
        }
    }

    /// No issue appears in two catalogues, or switching two categories on
    /// would put the same magazine on the shelf twice.
    func testTheCataloguesDoNotOverlap() throws {
        var seen: [String: IssueSite] = [:]
        for (site, file) in try everything() {
            for issue in file.issues {
                if let already = seen[issue.zip] {
                    XCTFail("\(issue.id) is in both \(already.display) and \(site.display)")
                }
                seen[issue.zip] = site
            }
        }
    }

    /// Every address is one the app can actually fetch.
    func testEveryAddressIsUsable() throws {
        let allowed = ["commodore.bombjack.org", "www.bombjack.org",
                       "bombjack.org", "arcarc.xmission.com"]
        for (site, file) in try everything() {
            for issue in file.issues {
                let url = try XCTUnwrap(URL(string: issue.zipURL(base: file.base)), issue.id)
                XCTAssertEqual(url.scheme, "https", "\(site.display): \(issue.id)")
                let host = try XCTUnwrap(url.host, issue.id)
                XCTAssertTrue(allowed.contains(host), "\(issue.id) points at \(host)")
            }
        }
    }

    /// One file, one row — within a catalogue and across all seven.
    func testNoArchiveIsListedTwice() throws {
        for (site, file) in try everything() {
            let files = file.issues.map(\.zip)
            XCTAssertEqual(Set(files).count, files.count, "\(site.display) repeats a file")
            let ids = file.issues.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "\(site.display) repeats an id")
        }
    }

    /// Runs are told apart by name, because the name is all the Series filter
    /// shows.
    func testRunNamesAreDistinctWithinACatalogue() throws {
        for (site, file) in try everything() {
            let names = file.series.map(\.name)
            XCTAssertEqual(Set(names).count, names.count, "\(site.display) repeats a run name")
        }
    }

    /// Every issue belongs to a run that its own catalogue carries, or the
    /// seed silently skips it — which is how a category could ship half empty.
    func testEveryIssueHasItsRun() throws {
        for (site, file) in try everything() {
            let keys = Set(file.series.map(\.key))
            for issue in file.issues {
                XCTAssertTrue(keys.contains(issue.series),
                              "\(site.display): \(issue.id) -> \(issue.series)")
            }
        }
    }

    /// And each one goes into a library under its own site, which is the only
    /// test that proves the files are usable rather than merely well-formed.
    func testEachCatalogueSeedsUnderItsOwnSite() throws {
        let store = try Store()
        var expected = 0
        for (site, file) in try everything() {
            let report = try store.seed(file, site: site, force: true)
            XCTAssertEqual(report.inserted, file.issues.count, site.display)
            expected += file.issues.count
        }
        XCTAssertEqual(store.issueCount, expected)

        // And each is independently hideable, which is the whole reason they
        // are separate sites.
        let books = try store.recent(limit: nil, sites: [.bombjackBooks])
        XCTAssertFalse(books.isEmpty)
        XCTAssertTrue(books.allSatisfy { $0.site == .bombjackBooks })
    }
}

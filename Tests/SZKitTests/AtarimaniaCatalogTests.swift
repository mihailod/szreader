import XCTest
@testable import SZKit

/// The shipped Atarimania catalogue: the file that goes out, and what seeding
/// it does.
final class AtarimaniaCatalogTests: XCTestCase {

    private func catalogue() throws -> ShippedCatalog {
        let name = try XCTUnwrap(IssueSite.atarimania.catalogueResource)
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "\(name).json is not in the bundle — run `swift run atarimania-build`")
        return try ShippedCatalog.decode(try Data(contentsOf: url))
    }

    func testCatalogueDecodes() throws {
        let file = try catalogue()
        XCTAssertEqual(file.version, ShippedCatalog.currentVersion)
        XCTAssertEqual(file.base, Atarimania.base)
        XCTAssertGreaterThan(file.issues.count, 1_500)
        XCTAssertGreaterThan(file.series.count, 60)
    }

    /// Every row has to be addressable, and every path has to be relative —
    /// the base is stored once rather than on 1,900 rows.
    func testEveryIssueIsAddressable() throws {
        let file = try catalogue()
        let keys = Set(file.series.map(\.key))
        var ids: Set<String> = []
        for issue in file.issues {
            XCTAssertTrue(ids.insert(issue.id).inserted, "duplicate id \(issue.id)")
            XCTAssertTrue(keys.contains(issue.series),
                          "\(issue.id) belongs to unknown series \(issue.series)")
            XCTAssertFalse(issue.title.isEmpty, "\(issue.id) has no title")
            XCTAssertTrue(issue.zip.hasPrefix("mags/pdf/"), "\(issue.id): \(issue.zip)")
            XCTAssertFalse(issue.zip.hasPrefix("http"),
                           "\(issue.id) carries an absolute URL")
        }
    }

    /// Every PDF on the site lives in one flat directory, so two rows naming
    /// the same file would mean the parse invented one.
    func testNoTwoIssuesShareAFile() throws {
        var owner: [String: String] = [:]
        for issue in try catalogue().issues {
            if let first = owner[issue.zip] {
                XCTFail("\(issue.id) and \(first) both point at \(issue.zip)")
            }
            owner[issue.zip] = issue.id
        }
    }

    /// The site's listings state no size, so the build asks each PDF directly.
    /// Missing sizes mean that pass silently failed and the shelf could not
    /// say how large a download is before starting it.
    func testIssuesCarryRealSizes() throws {
        let file = try catalogue()
        let live = file.issues.filter { $0.dead != true }
        let sized = live.filter { ($0.bytes ?? 0) > 0 }
        XCTAssertGreaterThan(sized.count * 10, live.count * 9,
                             "only \(sized.count) of \(live.count) have a size")
    }

    /// Covers are the only artwork the site offers. Without them the shelf is
    /// a wall of grey rectangles.
    func testMostIssuesHaveACover() throws {
        let file = try catalogue()
        let withCover = file.issues.filter { $0.cover != nil }
        XCTAssertGreaterThan(withCover.count * 10, file.issues.count * 9)
    }

    /// Every run counts from one and climbs without repeating.
    func testEachSeriesIsNumberedFromOne() throws {
        var numbers: [String: [Int]] = [:]
        for issue in try catalogue().issues {
            numbers[issue.series, default: []].append(issue.number)
        }
        for (series, found) in numbers {
            let sorted = found.sorted()
            XCTAssertEqual(sorted, Array(1...sorted.count),
                           "\(series) is not numbered 1...\(sorted.count)")
        }
    }

    /// The Atari 8-bit press is the reason this source is worth shipping —
    /// none of it is in BombJack, and archive.org has almost none of it. If a
    /// rebuild loses these, the site changed and it should not go out unseen.
    func testTheAtariEightBitPressIsPresent() throws {
        let names = Set(try catalogue().series.map(\.name))
        for title in ["Antic", "ANALOG", "Page 6", "STart", "Atari User"] {
            XCTAssertTrue(names.contains(title), "\(title) is missing from the shelf")
        }
    }

    /// Seeding is what the switch does: one row per issue, and nothing new on
    /// the second pass.
    func testSeedingLoadsEveryIssueOnce() throws {
        let store = try Store()
        let file = try catalogue()
        XCTAssertEqual(try store.seed(file, site: .atarimania).inserted, file.issues.count)
        XCTAssertEqual(try store.seed(file, site: .atarimania).inserted, 0)
        XCTAssertEqual(store.issueCount, file.issues.count)
    }
}

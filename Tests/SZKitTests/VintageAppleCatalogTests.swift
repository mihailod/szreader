import XCTest
@testable import SZKit

/// The two shipped Vintage Apple catalogues.
final class VintageAppleCatalogTests: XCTestCase {

    private func catalogue(_ site: IssueSite) throws -> ShippedCatalog {
        let name = try XCTUnwrap(site.catalogueResource)
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "\(name).json is not in the bundle — run `swift run vintageapple-build`")
        return try ShippedCatalog.decode(try Data(contentsOf: url))
    }

    // MARK: - Wiring

    func testEachGroupHasExactlyOneSite() {
        XCTAssertEqual(IssueSite.vintageAppleSites.count, VintageApple.Group.allCases.count)
        XCTAssertEqual(IssueSite.vintageAppleSites.compactMap(\.vintageAppleGroup),
                       VintageApple.Group.inMenuOrder)
    }

    /// The publisher column of every seeded row carries this, and three
    /// sources now ship something called "Books".
    func testDisplayNamesTheArchive() {
        for site in IssueSite.vintageAppleSites {
            XCTAssertTrue(site.display.hasPrefix("Vintage Apple: "), "\(site.display)")
        }
        XCTAssertNotEqual(IssueSite.vintageAppleBooks.display, IssueSite.bombjackBooks.display)
        XCTAssertNotEqual(IssueSite.vintageAppleBooks.display, IssueSite.spectrumBooks.display)
    }

    func testVintageAppleSitesAreNotOtherGroupings() {
        for site in IssueSite.vintageAppleSites {
            XCTAssertNil(site.bombjackCategory)
            XCTAssertNil(site.spectrumGroup)
        }
    }

    // MARK: - The catalogues

    func testBothCataloguesDecode() throws {
        for site in IssueSite.vintageAppleSites {
            let file = try catalogue(site)
            XCTAssertEqual(file.version, ShippedCatalog.currentVersion, "\(site)")
            XCTAssertEqual(file.base, VintageApple.base, "\(site)")
            XCTAssertFalse(file.issues.isEmpty, "\(site) is empty")
        }
    }

    /// The magazines are six sections and the books ten — a section landing
    /// on the wrong shelf is the mistake the split invites.
    func testSectionsLandOnTheRightShelf() throws {
        let magazines = Set(try catalogue(.vintageAppleMagazines).series.map(\.key))
        let books = Set(try catalogue(.vintageAppleBooks).series.map(\.key))
        XCTAssertEqual(magazines.count, 6)
        XCTAssertEqual(books.count, 10)
        XCTAssertTrue(magazines.isDisjoint(with: books), "a section is on both shelves")
        XCTAssertTrue(magazines.contains("byte"))
        XCTAssertTrue(books.contains("macbooks"))
    }

    func testEveryRowIsAddressable() throws {
        for site in IssueSite.vintageAppleSites {
            let file = try catalogue(site)
            let keys = Set(file.series.map(\.key))
            var ids: Set<String> = []
            for issue in file.issues {
                XCTAssertTrue(ids.insert(issue.id).inserted, "\(site): duplicate \(issue.id)")
                XCTAssertTrue(keys.contains(issue.series),
                              "\(site): \(issue.id) has unknown section \(issue.series)")
                XCTAssertFalse(issue.title.isEmpty, "\(site): \(issue.id) has no title")
                XCTAssertTrue(issue.zip.hasSuffix(".pdf"), "\(site): \(issue.zip)")
                XCTAssertFalse(issue.zip.hasPrefix("http"),
                               "\(site): \(issue.id) carries an absolute URL")
            }
        }
    }

    /// Two rows must not name one file. Filenames repeat across sections, so
    /// the id and the path both carry the section.
    func testNoTwoRowsShareAFile() throws {
        for site in IssueSite.vintageAppleSites {
            var owner: [String: String] = [:]
            for issue in try catalogue(site).issues {
                if let first = owner[issue.zip] {
                    XCTFail("\(site): \(issue.id) and \(first) share \(issue.zip)")
                }
                owner[issue.zip] = issue.id
            }
        }
    }

    func testRowsCarryRealSizes() throws {
        for site in IssueSite.vintageAppleSites {
            let file = try catalogue(site)
            let live = file.issues.filter { $0.dead != true }
            let sized = live.filter { ($0.bytes ?? 0) > 0 }
            XCTAssertGreaterThan(sized.count * 10, live.count * 9,
                                 "\(site): only \(sized.count) of \(live.count) sized")
        }
    }

    /// Every row on every section of this site has a thumbnail.
    func testEveryRowHasACover() throws {
        for site in IssueSite.vintageAppleSites {
            let file = try catalogue(site)
            let withCover = file.issues.filter { $0.cover != nil }
            XCTAssertEqual(withCover.count, file.issues.count, "\(site)")
        }
    }

    func testEachSectionIsNumberedFromOne() throws {
        for site in IssueSite.vintageAppleSites {
            var numbers: [String: [Int]] = [:]
            for issue in try catalogue(site).issues {
                numbers[issue.series, default: []].append(issue.number)
            }
            for (section, found) in numbers {
                let sorted = found.sorted()
                XCTAssertEqual(sorted, Array(1...sorted.count),
                               "\(site): \(section) is not 1...\(sorted.count)")
            }
        }
    }

    /// Byte is the flagship run and the reason the magazine shelf exists at
    /// all; the Mac bookshelf is the reason the other one does.
    func testTheHeadlineRunsArePresent() throws {
        let magazines = try catalogue(.vintageAppleMagazines)
        let byte = magazines.issues.filter { $0.series == "byte" }
        XCTAssertGreaterThan(byte.count, 250, "Byte is short — \(byte.count) issues")
        XCTAssertTrue(byte.contains { $0.year == 1975 }, "Byte's first year is missing")

        let books = try catalogue(.vintageAppleBooks)
        XCTAssertGreaterThan(books.issues.filter { $0.series == "macbooks" }.count, 380)
    }

    /// Magazines are dated to the month; books mostly are not, and must not
    /// pretend otherwise.
    func testMagazinesAreDatedAndBooksAreNot() throws {
        let magazines = try catalogue(.vintageAppleMagazines)
        let dated = magazines.issues.filter { $0.month != nil }
        XCTAssertGreaterThan(dated.count * 10, magazines.issues.count * 8,
                             "only \(dated.count) of \(magazines.issues.count) magazines "
                             + "have a month")

        let books = try catalogue(.vintageAppleBooks)
        let withMonth = books.issues.filter { $0.month != nil }
        XCTAssertLessThan(withMonth.count * 3, books.issues.count,
                          "\(withMonth.count) of \(books.issues.count) books claim a month")
    }

    func testSeedingLoadsEveryRowOnce() throws {
        for site in IssueSite.vintageAppleSites {
            let store = try Store()
            let file = try catalogue(site)
            XCTAssertEqual(try store.seed(file, site: site).inserted, file.issues.count,
                           "\(site)")
            XCTAssertEqual(try store.seed(file, site: site).inserted, 0, "\(site)")
        }
    }
}

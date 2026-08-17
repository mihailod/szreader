import XCTest
@testable import SZKit

/// Checks the catalogue that actually ships.
///
/// `RetroSpecCatalogTests` proves the parser reads the pages correctly; this
/// proves the file built from it is the file in the bundle. They are separate
/// failures: a parser can be perfect and the committed catalogue still be six
/// months stale, and nothing else would notice.
final class ShippedRetroSpecCatalogTests: XCTestCase {

    private static var shipped: ShippedCatalog = {
        guard let url = Bundle.module.url(forResource: "retrospec-catalog",
                                          withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let file = try? ShippedCatalog.decode(data) else {
            fatalError("the catalogue is missing from the bundle — "
                       + "run `swift run retrospec-build`")
        }
        return file
    }()

    private var catalogue: ShippedCatalog { Self.shipped }

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/retrospec/index")
    }

    // MARK: - Shape

    func testCatalogueIsTheVersionThisBuildUnderstands() {
        XCTAssertEqual(catalogue.version, ShippedCatalog.currentVersion)
        XCTAssertEqual(catalogue.base, "https://retrospec.elite.org/pcsux/")
        XCTAssertFalse(catalogue.generated.isEmpty)
    }

    func testEveryIssueIsPresentAndWhole() {
        XCTAssertEqual(catalogue.issues.count, 653)
        XCTAssertEqual(catalogue.series.count, 19)

        let keys = Set(catalogue.series.map(\.key))
        for issue in catalogue.issues {
            XCTAssertTrue(keys.contains(issue.series), "\(issue.id): unknown series")
            XCTAssertFalse(issue.title.isEmpty, "\(issue.id): no title")
            XCTAssertFalse(issue.zip.isEmpty, "\(issue.id): no archive")
            XCTAssertNotNil(issue.cover, "\(issue.id): no cover")
        }
        XCTAssertEqual(Set(catalogue.issues.map(\.id)).count, 653, "duplicate id")
    }

    /// The shipped catalogue lists exactly what the committed pages contain.
    ///
    /// This is the one that catches a stale file: rebuild the parser, forget
    /// to rebuild the catalogue, and every other test here still passes
    /// because they only ask the catalogue about itself.
    func testCatalogueMatchesThePagesItWasBuiltFrom() throws {
        var parsed: Set<String> = []
        let names = try FileManager.default
            .contentsOfDirectory(atPath: Self.fixtures.path)
            .filter { $0.hasSuffix(".html") }
        for name in names {
            let data = try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
            let html = try XCTUnwrap(RetroSpecCatalog.decode(data))
            parsed.formUnion(RetroSpecCatalog.entries(in: html).map(\.id))
        }
        // Reported as the difference rather than by comparing the two sets
        // directly. XCTAssertEqual on 653 ids prints both of them in full,
        // which buries the handful of ids that actually differ in two screens
        // of noise — and this test exists precisely to be read when it fails.
        let shipped = Set(catalogue.issues.map(\.id))
        let missing = parsed.subtracting(shipped).sorted()
        let extra = shipped.subtracting(parsed).sorted()
        XCTAssertTrue(missing.isEmpty && extra.isEmpty, """
            the catalogue and the fixtures disagree — run `swift run retrospec-build`
              on the pages but not in the catalogue: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))
              in the catalogue but not on the pages: \(extra.isEmpty ? "none" : extra.joined(separator: ", "))
            """)
    }

    /// Every run is numbered from one with no gaps, which is what sorting a
    /// series by number rests on.
    func testEachRunIsNumberedFromOne() {
        for series in catalogue.series {
            let numbers = catalogue.issues.filter { $0.series == series.key }
                .map(\.number).sorted()
            XCTAssertFalse(numbers.isEmpty, "\(series.key) has no issues")
            XCTAssertEqual(numbers, Array(1...numbers.count), "\(series.key)")
        }
    }

    /// Numbering follows the calendar, not the order the grid happens to
    /// print. Računari's 1988 special is parked at the end of its page; it
    /// belongs beside the April 1988 issue, and just after it.
    func testNumberingIsChronological() throws {
        for series in catalogue.series {
            let dated = catalogue.issues
                .filter { $0.series == series.key && $0.year != nil }
                .sorted { $0.number < $1.number }
            for (earlier, later) in zip(dated, dated.dropFirst()) {
                let a = (earlier.year ?? 0, earlier.month ?? 0)
                let b = (later.year ?? 0, later.month ?? 0)
                XCTAssertTrue(a <= b, "\(series.key): \(earlier.id) sorts before \(later.id)")
            }
        }
        let ra = catalogue.issues.filter { $0.series == "RA" }
        let april = try XCTUnwrap(ra.first { $0.id == "RA_88_04" })
        let special = try XCTUnwrap(ra.first { $0.id == "RA_88_04S" })
        XCTAssertEqual(special.number, april.number + 1)
    }

    // MARK: - Per-issue metadata

    /// Sizes come from the site's own headers at build time, which is what
    /// lets a download that will not fit be refused before it starts.
    func testLiveArchivesCarryTheirSize() {
        for issue in catalogue.issues where issue.dead != true {
            XCTAssertNotNil(issue.bytes, "\(issue.id) has no size")
            XCTAssertGreaterThan(issue.bytes ?? 0, 0, issue.id)
        }
    }

    /// The eight archives that 404. They stay in the catalogue: the covers
    /// and metadata are real, and the site may restore the files.
    func testTheDeadArchivesAreListedAndFlagged() {
        let expected = Set(["MMH_90_06", "MMH_90_07", "MMH_90_09", "MMH_91_03",
                            "MMS_91_11", "MMS_91_12", "BIT_86_02", "GAL_72_05"])
        let flagged = Set(catalogue.issues.filter { $0.dead == true }.map(\.id))
        XCTAssertEqual(flagged, expected)
        for issue in catalogue.issues where issue.dead == true {
            XCTAssertNil(issue.bytes, "\(issue.id): a missing archive has no size")
            XCTAssertNotNil(issue.cover, "\(issue.id): its cover still exists")
        }
    }

    func testPageCountsAreRecorded() {
        let withPages = catalogue.issues.filter { ($0.pages ?? 0) > 0 }
        XCTAssertEqual(withPages.count, catalogue.issues.count,
                       "every issue should know how many pages it has")
    }

    /// Paths are stored relative and composed against the base, so the whole
    /// archive moving host is a one-line change rather than 653.
    func testRelativePathsComposeIntoRealURLs() throws {
        let sk = try XCTUnwrap(catalogue.issues.first { $0.id == "SK_84_10" })
        XCTAssertEqual(sk.zip, "SKH/ZIP/1984_10.zip")
        XCTAssertEqual(sk.zipURL(base: catalogue.base),
                       "https://retrospec.elite.org/pcsux/SKH/ZIP/1984_10.zip")
        XCTAssertEqual(sk.coverURL(base: catalogue.base),
                       "https://retrospec.elite.org/pcsux/SKH/Covers/SK8410-00.jpg")
        for issue in catalogue.issues {
            XCTAssertFalse(issue.zip.hasPrefix("http"), "\(issue.id): path is absolute")
        }
    }

    // MARK: - Titles

    /// A magazine is titled by the month it was printed, in the language it
    /// was printed in — the month comes from the site's database rather than
    /// the caption on the grid, three of which are copied from the cell above.
    func testMagazinesAreTitledByTheirMonth() throws {
        let sk = try XCTUnwrap(catalogue.issues.first { $0.id == "SK_84_10" })
        XCTAssertEqual(sk.title, "Oktobar 1984")
        XCTAssertEqual(sk.number, 1)
        XCTAssertEqual(sk.pages, 48)

        // A double issue already reads as one on the site.
        let double = try XCTUnwrap(catalogue.issues.first { $0.id == "RA_85_02" })
        XCTAssertEqual(double.title, "Februar/Mart 1985")

        // Croatian months, not translated into Serbian ones.
        let master = try XCTUnwrap(catalogue.issues.first { $0.id == "MA_94_12" })
        XCTAssertEqual(master.title, "Prosinac 1994")

        // The caption on the page says 1994; the id, the archive and the
        // site's database all say June 1991.
        let mcw = try XCTUnwrap(catalogue.issues.first { $0.id == "MCW_91_06" })
        XCTAssertEqual(mcw.year, 1991)
        XCTAssertEqual(mcw.month, 6)
        XCTAssertEqual(mcw.title, "Juni 1991")
    }

    /// A book has no date; its title is its whole identity.
    func testBooksAreTitledByName() throws {
        let books = catalogue.issues.filter { $0.series == "Knjige" }
        XCTAssertEqual(books.count, 12)
        for book in books {
            XCTAssertNil(book.year, book.id)
            XCTAssertNil(book.month, book.id)
        }
        let mirko = try XCTUnwrap(books.first { $0.id == "Knjige_Mirko" })
        XCTAssertEqual(mirko.title, "Mirko Tipka Na Radirko")
        XCTAssertEqual(mirko.pages, 172)
    }

    // MARK: - Series

    /// The series block carries what the shelf needs, including the two names
    /// the site's own database has lost a character from.
    func testSeriesCarryNamesCodesAndLanguages() throws {
        let byKey = Dictionary(uniqueKeysWithValues: catalogue.series.map { ($0.key, $0) })
        XCTAssertEqual(byKey["SK"]?.name, "Svet Kompjutera")
        XCTAssertEqual(byKey["RA"]?.name, "Računari")
        XCTAssertEqual(byKey["MR"]?.name, "Mala Računala")
        XCTAssertEqual(byKey["MMS"]?.language, "slovenian")
        XCTAssertEqual(byKey["MMH"]?.language, "croatian")
        // The books are the one run with no language of their own.
        XCTAssertNil(byKey["Knjige"]?.language)

        XCTAssertEqual(Set(catalogue.series.map(\.name)).count, 19, "two runs share a name")
        XCTAssertEqual(Set(catalogue.series.map(\.code)).count, 19, "two runs share a code")
    }

    /// The two Moj Mikro runs are separate, each numbering from one.
    func testMojMikroIsTwoIndependentRuns() {
        let slovenian = catalogue.issues.filter { $0.series == "MMS" }
        let croatian = catalogue.issues.filter { $0.series == "MMH" }
        XCTAssertEqual(slovenian.count, 106)
        XCTAssertEqual(croatian.count, 76)
        XCTAssertEqual(slovenian.map(\.number).min(), 1)
        XCTAssertEqual(croatian.map(\.number).min(), 1)
        XCTAssertTrue(Set(slovenian.map(\.id)).isDisjoint(with: Set(croatian.map(\.id))))
    }
}

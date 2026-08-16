import XCTest
@testable import SZKit

/// Measurements of RetroSpec's twelve index pages.
///
/// Unlike the StripZona fixtures, these pages are committed to the repository
/// (`Tests/Fixtures/retrospec/`). They are a public, static archive that has
/// not changed since 2023, they carry no private mirror links — every URL on
/// them is a plain file on the same public host — and they are small. So the
/// tests run on a fresh clone with no network and no setup, which is the
/// whole point of building the catalogue offline.
final class RetroSpecCatalogTests: XCTestCase {

    private static var fixtures: URL {
        URL(fileURLWithPath: #filePath)      // .../Tests/SZKitTests/<this file>
            .deletingLastPathComponent()      // SZKitTests
            .deletingLastPathComponent()      // Tests
            .appendingPathComponent("Fixtures/retrospec")
    }

    private func page(_ name: String) throws -> String {
        let url = Self.fixtures.appendingPathComponent("index/\(name).html")
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(RetroSpecCatalog.decode(data), "could not decode \(name)")
    }

    private func magshow(_ id: String) throws -> String {
        let url = Self.fixtures.appendingPathComponent("magshow/\(id).html")
        return try XCTUnwrap(RetroSpecCatalog.decode(try Data(contentsOf: url)))
    }

    private static let indexPages = [
        "indexAS", "indexBIT", "indexCN", "indexGal", "indexKnjige", "indexMG",
        "indexMMHrv", "indexMMSlo", "indexPJ", "indexRA", "indexSK", "indexSpecial",
    ]

    private func allEntries() throws -> [RetroSpecEntry] {
        try Self.indexPages.flatMap { RetroSpecCatalog.entries(in: try page($0)) }
    }

    // MARK: - Counts

    /// Issues per run, counted by hand against the live site.
    ///
    /// Five of these runs are absent from the local mirror on the SSD, which
    /// is three index pages out of date — Galaksija's ninety-three issues
    /// among them. The fixtures are the live pages for that reason.
    private let expected: [(String, Int)] = [
        ("SK", 145), ("RA", 142), ("MMS", 106), ("GAL", 93), ("MMH", 76),
        ("MG", 23), ("BIT", 15), ("SI", 14), ("Knjige", 12), ("CN", 8),
        ("AmSt", 7), ("PV", 3), ("Warp", 2), ("MR", 2),
        ("AmSv", 1), ("KOM", 1), ("MA", 1), ("MCW", 1), ("PJ", 1),
    ]

    func testEveryIssueIsFound() throws {
        let entries = try allEntries()
        XCTAssertEqual(entries.count, 653)

        var counted: [String: Int] = [:]
        for entry in entries { counted[entry.seriesKey, default: 0] += 1 }
        for (key, n) in expected {
            XCTAssertEqual(counted[key], n, "\(key) should have \(n) issues")
        }
        XCTAssertEqual(counted.count, expected.count, "an unknown series key appeared")
    }

    /// Every run in the table is one the pages actually carry, and vice versa.
    func testSeriesTableMatchesThePages() throws {
        let keys = Set(try allEntries().map(\.seriesKey))
        XCTAssertEqual(keys, Set(RetroSpecSeriesTable.all.map(\.key)))
    }

    func testSeriesTableIsUnambiguous() {
        let all = RetroSpecSeriesTable.all
        XCTAssertEqual(Set(all.map(\.key)).count, all.count, "duplicate series key")
        XCTAssertEqual(Set(all.map(\.name)).count, all.count, "two runs share a name")
        XCTAssertEqual(Set(all.map(\.code)).count, all.count, "two runs share a shelf code")
    }

    /// An id identifies exactly one issue across the whole site.
    ///
    /// This is what the seed's natural key will rest on, so it is worth
    /// proving rather than assuming.
    func testIssueIDsAreUnique() throws {
        let ids = try allEntries().map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: - Links

    func testEveryIssueHasAnArchiveAndACover() throws {
        for entry in try allEntries() {
            XCTAssertTrue(entry.zipURL.hasPrefix("https://retrospec.elite.org/pcsux/"),
                          "\(entry.id): \(entry.zipURL)")
            XCTAssertTrue(entry.zipURL.hasSuffix(".zip"), entry.id)
            XCTAssertNotNil(entry.coverURL, "\(entry.id) has no cover")
            XCTAssertNotNil(entry.thumbnailURL, "\(entry.id) has no thumbnail")
        }
    }

    /// The eight issues whose archive is a 404, confirmed by sweeping all 653.
    ///
    /// They are imported anyway. The covers exist and the rows are real, the
    /// site may restore the files, and a shelf that quietly omitted them
    /// would be lying about what the archive contains. Six of the eight are
    /// Moj Mikro in 1990-91, which reads as one bad patch of that upload
    /// rather than random rot.
    ///
    /// Asserted as *present* — this test exists so that the day the parse
    /// starts dropping issues, it fails here rather than in a shelf nobody
    /// is counting.
    func testKnownDeadArchivesAreStillImported() throws {
        let dead = ["MMH_90_06", "MMH_90_07", "MMH_90_09", "MMH_91_03",
                    "MMS_91_11", "MMS_91_12", "BIT_86_02", "GAL_72_05"]
        let ids = Set(try allEntries().map(\.id))
        for id in dead { XCTAssertTrue(ids.contains(id), "\(id) was dropped") }
    }

    /// Cells with no scan behind them are not issues.
    ///
    /// The grid is a calendar — twelve columns to a year — so a month that
    /// was never scanned is a cell holding a placeholder graphic. Amiga Style
    /// runs seven issues across a page of forty-two such cells.
    func testEmptyCalendarCellsAreSkipped() throws {
        let entries = RetroSpecCatalog.entries(in: try page("indexAS"))
        XCTAssertEqual(entries.count, 10)
        XCTAssertEqual(Set(entries.map(\.seriesKey)), ["AmSt", "Warp", "AmSv"])
    }

    /// An issue inside a nested table is counted once, not twice.
    ///
    /// Synthetic, and deliberately so. The site's generator does emit nested
    /// tables inside the content region — `indexMMHrv` and `indexMMSlo` each
    /// have one — but on today's pages no issue happens to sit inside one, so
    /// the corpus cannot exercise this. Without the rule that a cell ends at
    /// the next `<td>` as well as at its own `</td>`, the outer cell here
    /// swallows the inner one and Svet Kompjutera gains a phantom issue.
    ///
    /// It is worth guarding rather than assuming flat markup: `indexSpecial`
    /// already groups five runs on one page, and grouping them one table
    /// deeper is exactly the edit that would trigger this.
    ///
    /// The wrapping cell carries a heading of its own, because that is what
    /// separates this rule from the duplicate-id guard beside it. Both stop
    /// the phantom issue; only this one stops the surviving issue from
    /// taking the heading into its caption.
    func testAnIssueInsideANestedTableIsCountedOnce() {
        let html = """
            <!-- CONTENT -->
            <table><tr>
              <td width="70" align="center">
                <b>SVET IGARA</b>
                <table><tr>
                  <td width="70" align="center">
                    <font size="1">1984 - 10<br>
                    <a href="http://retrospec.sgn.net/users/tomcat/yu/magshow.php?all=SK_84_10">\
                    <img src="SKH/SK8410-00.jpg"></a><br>
                    <a href="SKH/ZIP/1984_10.zip">zip</a>
                    <a href="SKH/Covers/SK8410-00.jpg">cover</a>
                    </font>
                  </td>
                </tr></table>
              </td>
            </tr></table>
            <!-- /CONTENT -->
            """
        let entries = RetroSpecCatalog.entries(in: html)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.id, "SK_84_10")
        XCTAssertEqual(entries.first?.label, "1984 - 10")
    }

    // MARK: - Dates

    /// The printed caption is not the issue's date.
    ///
    /// `indexSpecial.html` captions Micro Computer's only issue "1994 - 12",
    /// copied from the Master cell above it. Its id, its archive
    /// (`MCWH/ZIP/1991_06.zip`) and the site's own database all say June
    /// 1991. Reading the date off the id is what makes this come out right.
    func testDateComesFromTheIDNotTheCaption() throws {
        let entries = RetroSpecCatalog.entries(in: try page("indexSpecial"))
        let mcw = try XCTUnwrap(entries.first { $0.id == "MCW_91_06" })
        XCTAssertEqual(mcw.label, "1994 - 12", "the caption really is wrong on the page")
        XCTAssertEqual(mcw.year, 1991)
        XCTAssertEqual(mcw.month, 6)
        XCTAssertTrue(mcw.zipURL.hasSuffix("MCWH/ZIP/1991_06.zip"))
    }

    func testTwoDigitYearsPivotAtSeventy() {
        XCTAssertEqual(RetroSpecCatalog.dateComponents(ofIssueID: "GAL_72_03").year, 1972)
        XCTAssertEqual(RetroSpecCatalog.dateComponents(ofIssueID: "SK_84_10").year, 1984)
        XCTAssertEqual(RetroSpecCatalog.dateComponents(ofIssueID: "SK_97_12").year, 1997)
        // Galaksija ran to January 2001, which is the only side of the pivot
        // the archive reaches.
        XCTAssertEqual(RetroSpecCatalog.dateComponents(ofIssueID: "GAL_01_01").year, 2001)
    }

    func testSpecialIssuesAreFlagged() throws {
        let ra = RetroSpecCatalog.entries(in: try page("indexRA"))
        let special = try XCTUnwrap(ra.first { $0.id == "RA_88_04S" })
        XCTAssertTrue(special.isSpecial)
        XCTAssertEqual(special.year, 1988)
        XCTAssertEqual(special.month, 4)
        XCTAssertEqual(ra.filter(\.isSpecial).count, 1)
    }

    /// Books are not dated, and their caption is their title.
    func testBooksCarryATitleRatherThanADate() throws {
        let books = RetroSpecCatalog.entries(in: try page("indexKnjige"))
        XCTAssertEqual(books.count, 12)
        for book in books {
            XCTAssertNil(book.year, book.id)
            XCTAssertNil(book.month, book.id)
        }
        let mirko = try XCTUnwrap(books.first { $0.id == "Knjige_Mirko" })
        // The "zip" and "cover" links sit inside the same cell; leaving them
        // in would make every caption end in "zip cover".
        XCTAssertEqual(mirko.label, "Mirko Tipka Na Radirko")
    }

    /// A double issue's second month survives only in the caption.
    func testDoubleIssueCaptionsAreKept() throws {
        let ra = RetroSpecCatalog.entries(in: try page("indexRA"))
        let double = try XCTUnwrap(ra.first { $0.id == "RA_85_02" })
        XCTAssertEqual(double.label, "1985 - 02/03")
        XCTAssertEqual(double.month, 2)
    }

    // MARK: - Encoding

    /// The pages declare windows-1250 and only some of them mean it.
    ///
    /// `indexKnjige` is genuinely cp1250; `indexMMHrv` is UTF-8 behind the
    /// same meta tag. Getting either one wrong is silent — it produces a
    /// title with mojibake in it rather than an error.
    func testDiacriticsSurviveBothEncodings() throws {
        let books = RetroSpecCatalog.entries(in: try page("indexKnjige"))
        let labels = books.map(\.label)
        XCTAssertTrue(labels.contains("Spektrum Priručnik"), "cp1250 page: \(labels)")
        XCTAssertTrue(labels.contains("Kompjutor u Kući"), "cp1250 page: \(labels)")

        // The UTF-8 page's diacritic is in its header rather than a cell, so
        // this checks the decode directly.
        let croatian = try page("indexMMHrv")
        XCTAssertTrue(croatian.contains("Slovenačko izdanje"))
        XCTAssertFalse(croatian.contains("Ä"), "UTF-8 page was decoded as cp1250")
    }

    // MARK: - magshow.php metadata

    /// The index pages head each run with a picture of its logo, so this is
    /// the only machine-readable place the real names exist.
    func testIssueMetadataIsRead() throws {
        let sk = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("SK_84_10")))
        XCTAssertEqual(sk.seriesName, "Svet Kompjutera")
        XCTAssertEqual(sk.year, 1984)
        XCTAssertEqual(sk.monthText, "Oktobar")
        XCTAssertEqual(sk.numberInYear, 1)
        XCTAssertEqual(sk.language, .serbian)
        XCTAssertEqual(sk.pageCount, 48)
    }

    /// Moj Mikro is one title and two runs. The site tells them apart by a
    /// suffix on the name and by the language, which is why they are two
    /// series here.
    func testMojMikroIsTwoRuns() throws {
        let slovenian = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("MMS_84_06")))
        let croatian = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("MMH_85_01")))
        XCTAssertEqual(slovenian.seriesName, "Moj Mikro")
        XCTAssertEqual(slovenian.language, .slovenian)
        XCTAssertEqual(croatian.seriesName, "Moj Mikro [Hrv]")
        XCTAssertEqual(croatian.language, .croatian)

        XCTAssertEqual(RetroSpecSeriesTable.series(forKey: "MMS")?.language, .slovenian)
        XCTAssertEqual(RetroSpecSeriesTable.series(forKey: "MMH")?.language, .croatian)
    }

    /// Months come in three languages and are sometimes not months at all,
    /// which is why they are carried as text.
    func testMonthTextIsLeftAsPrinted() throws {
        let croatian = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("MA_94_12")))
        XCTAssertEqual(croatian.monthText, "Prosinac")
        let slovenian = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("CN_93_07")))
        XCTAssertEqual(slovenian.monthText, "Julij/Avgust")
        // A special issue: numbered zero, and its "month" says so.
        let special = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("RA_88_04S")))
        XCTAssertEqual(special.numberInYear, 0)
    }

    /// A book has a title where an issue has a date.
    func testBookMetadataHasNoDate() throws {
        let book = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("Knjige_Mirko")))
        XCTAssertEqual(book.seriesName, "Mirko Tipka Na Radirko")
        XCTAssertNil(book.year)
        XCTAssertNil(book.language)
        XCTAssertEqual(book.pageCount, 172)
    }

    /// The site's database has lost a character in two of its names — it
    /// serves a literal "?" where the "č" belongs, in every encoding. The
    /// table spells them correctly rather than reproducing the fault.
    func testCorruptedSiteNamesAreCorrected() throws {
        let racunari = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("RA_84_01")))
        XCTAssertEqual(racunari.seriesName, "Ra?unari", "the site really does serve this")
        XCTAssertEqual(RetroSpecSeriesTable.series(forKey: "RA")?.name, "Računari")
        XCTAssertEqual(RetroSpecSeriesTable.series(forKey: "MR")?.name, "Mala Računala")
    }

    /// A month the site's database has lost a character from is put back.
    ///
    /// `Warp_98_02` is served as "Velja?a/Februar 1998" — a `?` byte where
    /// the `č` belongs, in every encoding. Found on the iPad, in the one
    /// Croatian February the whole archive contains.
    func testALostMonthCharacterIsRestored() throws {
        XCTAssertEqual(RetroSpecCatalog.repaired("Velja?a/Februar"), "Veljača/Februar")
        XCTAssertEqual(RetroSpecCatalog.repaired("Sije?anj"), "Siječanj")
        // Compounds keep their shape.
        XCTAssertEqual(RetroSpecCatalog.repaired("Svibanj-Maj"), "Svibanj-Maj")
        // Anything without the fault is returned untouched — including the
        // diacritics the database did keep.
        XCTAssertEqual(RetroSpecCatalog.repaired("Oktobar"), "Oktobar")
        XCTAssertEqual(RetroSpecCatalog.repaired("Održavanje"), "Održavanje")

        let warp = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("Warp_98_02")))
        XCTAssertEqual(warp.monthText, "Veljača/Februar")
    }

    /// The books' titles come off the index page, which is not broken.
    ///
    /// `magshow.php` offers the same strings from the database that lost the
    /// characters — "Spektrum Priru?nik", "Kompjutor u Ku?i". A month can be
    /// repaired against a closed vocabulary of twelve names; an arbitrary
    /// book title cannot, so the fix is to read the source that has them.
    func testBookTitlesAreIntactOnTheIndexPage() throws {
        let books = RetroSpecCatalog.entries(in: try page("indexKnjige"))
        let labels = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0.label) })
        XCTAssertEqual(labels["Knjige_SP"], "Spektrum Priručnik")
        XCTAssertEqual(labels["Knjige_KUK"], "Kompjutor u Kući")
        // The database's version of the same two, for contrast.
        let broken = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow("Knjige_SP")))
        XCTAssertEqual(broken.seriesName, "Spektrum Priru?nik",
                       "the site really does serve this")
        // And no book label is missing a character.
        for book in books {
            XCTAssertFalse(book.label.contains("?"), "\(book.id): \(book.label)")
        }
    }

    /// Every run's name in the table is one a real page confirms, so a typo
    /// in the table cannot pass unnoticed.
    func testTableNamesMatchTheSiteWhereTheyShould() throws {
        let sampled: [(String, String)] = [
            ("SK_84_10", "Svet Kompjutera"), ("SI_86_01", "Svet Igara"),
            ("GAL_72_03", "Galaksija"), ("MG_93_08", "Megazin"),
            ("BIT_84_06", "BIT"), ("CN_93_07", "Club Nintendo"),
            ("AmSt_92_11", "Amiga Style"), ("AmSv_95_07", "Amiga Svet"),
            ("Warp_97_05", "Warp"), ("PV_85_03", "Pilot Video"),
            ("KOM_84_05", "Kompjuter"), ("MA_94_12", "Master"),
            ("MCW_91_06", "Micro Computer"), ("PJ_95_10", "PlayJoy"),
        ]
        for (id, name) in sampled {
            let info = try XCTUnwrap(RetroSpecCatalog.info(in: try magshow(id)))
            XCTAssertEqual(info.seriesName, name, id)
            XCTAssertEqual(RetroSpecSeriesTable.series(forIssueID: id)?.name, name, id)
        }
    }
}

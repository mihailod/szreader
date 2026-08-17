import XCTest
@testable import SZKit

/// The archive.org catalogue: the file that ships, and what seeding it does.
///
/// Small enough to check exhaustively, and worth checking that way — four
/// issues named by hand is exactly the kind of list where a typo in an
/// identifier produces a row that looks right on the shelf and 404s the first
/// time anyone taps it.
final class ArchiveCatalogTests: XCTestCase {

    private func bundledCatalogue() throws -> ShippedCatalog {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "archive-catalog",
                                                  withExtension: "json"))
        return try ShippedCatalog.decode(try Data(contentsOf: url))
    }

    private func seededStore() throws -> (Store, ShippedCatalog) {
        let store = try Store()
        let file = try bundledCatalogue()
        try store.seed(file, site: .archive)
        return (store, file)
    }

    // MARK: - The shipped file

    /// Everything the table names is in the file, and nothing else is.
    func testTheFileHoldsExactlyWhatTheLibraryLists() throws {
        let file = try bundledCatalogue()
        XCTAssertEqual(file.issues.map(\.id), ArchiveOrgLibrary.items)
        XCTAssertEqual(file.series.map(\.key), ArchiveOrgLibrary.series.map(\.key))
        XCTAssertEqual(file.base, ArchiveOrg.base)
    }

    /// Every issue carries what the shelf and the downloader need. A missing
    /// size means `checkSpace` has nothing to check; a missing page count
    /// means the reader cannot say "page 4 of 19" until the scan is open.
    func testEveryIssueIsCompletelyDescribed() throws {
        let file = try bundledCatalogue()
        for issue in file.issues {
            XCTAssertFalse(issue.title.isEmpty, issue.id)
            XCTAssertNotNil(issue.year, issue.id)
            XCTAssertNotNil(issue.month, issue.id)
            XCTAssertGreaterThan(issue.bytes ?? 0, 0, issue.id)
            XCTAssertGreaterThan(issue.pages ?? 0, 0, issue.id)
            XCTAssertNil(issue.dead, issue.id)
            // The scan, not one of the derivatives beside it. `_text.pdf` is
            // the OCR copy at a third of the size and visibly worse.
            XCTAssertTrue(issue.zip.hasSuffix(".pdf"), issue.zip)
            XCTAssertFalse(issue.zip.contains("_text.pdf"), issue.zip)
            XCTAssertEqual(issue.cover, "\(issue.id)/page/n0_w1024.jpg")
        }
    }

    /// Both runs read as dated magazines, in the language they were printed
    /// in — the same shape RetroSpec's titles carry, so one shelf showing both
    /// reads as one shelf.
    func testIssuesAreTitledByMonthAndYear() throws {
        let file = try bundledCatalogue()
        let byID = Dictionary(uniqueKeysWithValues: file.issues.map { ($0.id, $0.title) })
        XCTAssertEqual(byID["a-profy-yugoslav-amiga-fanzine-1-july-1990"], "Jul 1990")
        XCTAssertEqual(byID["a-profy-yugoslav-amiga-fanzine-2-august-1990"], "Avgust 1990")
        XCTAssertEqual(byID["amiga-bilten-1"], "Septembar 1988")
        XCTAssertEqual(byID["amiga-bilten-2"], "Oktobar 1988")
    }

    /// Every URL the file builds is one a downloader can actually use: the
    /// paths are escaped, which the scans need — they are named "Amiga Bilten
    /// 1.pdf" — and `URL(string:)` is what would reject them if they were not.
    func testEveryURLResolves() throws {
        let file = try bundledCatalogue()
        for issue in file.issues {
            let zip = issue.zipURL(base: file.base)
            let url = try XCTUnwrap(URL(string: zip), zip)
            XCTAssertEqual(url.host, "archive.org")
            XCTAssertTrue(DirectHost().canHandle(url), zip)
            XCTAssertNotNil(URL(string: try XCTUnwrap(issue.coverURL(base: file.base))))
        }
    }

    // MARK: - Seeding

    func testTheCatalogueLands() throws {
        let (store, file) = try seededStore()
        XCTAssertEqual(store.issueCount, file.issues.count)
        XCTAssertEqual(store.mirrorCount, file.issues.count)

        let issues = try store.recent(limit: nil)
        XCTAssertTrue(issues.allSatisfy { $0.site == .archive })
    }

    func testAnIssueCarriesWhatTheShelfNeeds() throws {
        let (store, _) = try seededStore()
        let issues = try store.recent(limit: nil)
        let bilten = try XCTUnwrap(issues.first { $0.code == "amiga-bilten-1" })

        XCTAssertEqual(bilten.title, "Septembar 1988")
        XCTAssertEqual(bilten.series, "Amiga Bilten")
        XCTAssertEqual(bilten.edition, "Amiga Bilten")
        XCTAssertEqual(bilten.publisher, "Archive.org")
        XCTAssertEqual(bilten.number, 1)
        // What the scan actually holds, which the reader confirms when the PDF
        // opens. Counted from the scandata rather than from the page-number
        // derivative, which lists only the leaves OCR read a number off.
        XCTAssertEqual(bilten.pageCount, 18)
        XCTAssertNil(bilten.hero, "a magazine has no character to file it under")
        XCTAssertEqual(bilten.shelfMark, "AB 1")
        XCTAssertEqual(try store.knownSize(forIssue: bilten.id), 7_174_738)
    }

    /// The name the download lands under, which is the one the archive gives
    /// it — not the escaped form the URL has to carry.
    func testTheScanIsNamedAsItIsOnTheArchive() throws {
        let (store, _) = try seededStore()
        let bilten = try XCTUnwrap(try store.recent(limit: nil)
            .first { $0.code == "amiga-bilten-1" })
        let mirror = try XCTUnwrap(try store.liveMirrors(forIssue: bilten.id).first)
        XCTAssertEqual(try store.filename(forMirrorAt: mirror.url), "Amiga Bilten 1.pdf")
    }

    func testSeededIssuesAreSearchable() throws {
        let (store, _) = try seededStore()
        // By the run's name, which is not in the issue's own title.
        XCTAssertEqual(try store.search("amiga bilten", limit: nil).count, 2)
        XCTAssertEqual(try store.search("a-profy", limit: nil).count, 2)
        // By the source itself.
        XCTAssertEqual(try store.search("archive.org", limit: nil).count, 4)
    }

    func testBothRunsReachTheFilterMenu() throws {
        let (store, _) = try seededStore()
        XCTAssertEqual(Set(try store.editions(sites: [.archive])),
                       ["A-Profy", "Amiga Bilten"])
    }

    // MARK: - Running it again

    func testASecondLaunchSkipsTheWorkEntirely() throws {
        let (store, file) = try seededStore()
        let again = try store.seed(file, site: .archive)
        XCTAssertTrue(again.skipped)
    }

    func testASecondPassOverTheSameDataChangesNothing() throws {
        let (store, file) = try seededStore()
        let report = try store.seed(file, site: .archive, force: true)

        XCTAssertEqual(report.inserted, 0, "the catalogue was inserted twice")
        XCTAssertEqual(report.updated, 4)
        XCTAssertEqual(store.issueCount, 4)
        XCTAssertEqual(store.mirrorCount, 4)
        XCTAssertEqual(try store.search("archive.org", limit: nil).count, 4,
                       "the search index gained duplicates")
    }

    // MARK: - Living alongside the other catalogue

    /// Two shipped catalogues, one library, and neither in the other's way.
    ///
    /// The stamp is what makes this worth checking: a single key would have
    /// the second seed of a launch read the first one's fingerprint, decide
    /// it was already current, and skip a catalogue that had never been
    /// applied at all.
    func testBothCataloguesSeedIndependently() throws {
        let store = try Store()
        let retrospec = try store.seedCatalogue(for: .retrospec)
        let archive = try store.seedCatalogue(for: .archive)

        XCTAssertEqual(retrospec.inserted, 653)
        XCTAssertEqual(archive.inserted, 4)
        XCTAssertEqual(store.issueCount, 657)

        XCTAssertEqual(try store.recent(limit: nil, sites: [.archive]).count, 4)
        XCTAssertEqual(try store.recent(limit: nil, sites: [.retrospec]).count, 653)
        // And each stamp only answers for its own source.
        XCTAssertTrue(try store.seedCatalogue(for: .retrospec).skipped)
        XCTAssertTrue(try store.seedCatalogue(for: .archive).skipped)
    }

    /// The name RetroSpec's stamp has always been written under.
    ///
    /// Spelled out here because every shipped device holds a row under this
    /// exact key. Renaming it — tidying it into the site's display name, say —
    /// would make every one of those libraries re-seed 653 issues on the first
    /// launch after the update, which is the slow launch this stamp exists to
    /// prevent.
    func testTheStampKeepsTheNameTheShippedBuildWrote() {
        XCTAssertEqual(Store.catalogueStamp(for: .retrospec), "retrospec_catalogue")
        XCTAssertEqual(Store.catalogueStamp(for: .archive), "archive_catalogue")
    }

    /// An update finds the library exactly as the previous build left it.
    ///
    /// The realistic shape of it: a library seeded and read on one build, then
    /// reopened by the next. Nothing about the catalogue has changed, so the
    /// stamp matches, nothing is re-read, and neither the reading state nor
    /// the second source's absence is disturbed by the launch.
    func testAnUpdateReopensTheLibraryUntouched() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("upgrade-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let readID: Int
        do {   // the build the reader already has
            let store = try Store(path: path)
            try store.seedCatalogue(for: .retrospec)
            try store.seedCatalogue(for: .archive)
            let issue = try XCTUnwrap(try store.recent(limit: nil, sites: [.archive])
                .first { $0.code == "amiga-bilten-1" })
            readID = issue.id
            try store.setRead(true, issueID: issue.id)
            try store.setLastPage(9, issueID: issue.id)
        }

        // the build that replaces it
        let store = try Store(path: path)
        XCTAssertTrue(try store.seedCatalogue(for: .retrospec).skipped)
        XCTAssertTrue(try store.seedCatalogue(for: .archive).skipped)
        XCTAssertEqual(store.issueCount, 657)

        let after = try XCTUnwrap(try store.recent(limit: nil)
            .first { $0.id == readID })
        XCTAssertEqual(after.readState, .read)
        XCTAssertEqual(after.lastPage, 9)
    }

    /// The filter menus keep the two apart, which is what a reader uses to
    /// find one run among nineteen others.
    func testTheMenusKeepTheSourcesApart() throws {
        let store = try Store()
        try store.seedCatalogue(for: .retrospec)
        try store.seedCatalogue(for: .archive)

        XCTAssertFalse(try store.editions(sites: [.retrospec]).contains("A-Profy"))
        XCTAssertFalse(try store.editions(sites: [.archive]).contains("Svet Kompjutera"))
        XCTAssertTrue(try store.search("amiga bilten", limit: nil,
                                       sites: [.retrospec]).isEmpty)
    }

    /// An id is only unique within its own catalogue, so the seed's lookup is
    /// scoped to the source. Without that, a source whose ids happened to
    /// collide with another's would overwrite that one's rows in place.
    func testAnIdIsOnlyLookedUpWithinItsOwnSource() throws {
        let store = try Store()
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion, generated: "2026-01-01",
            base: "https://example.com/", series: [
                .init(key: "R", name: "Run", code: "R", language: nil)],
            issues: [.init(id: "shared-id", series: "R", number: 1, title: "One",
                           year: 1990, month: 1, zip: "one.pdf", cover: nil,
                           thumb: nil, bytes: 1, pages: 1, dead: nil)])

        XCTAssertEqual(try store.seed(file, site: .retrospec).inserted, 1)
        XCTAssertEqual(try store.seed(file, site: .archive).inserted, 1,
                       "the second source updated the first one's row")
        XCTAssertEqual(store.issueCount, 2)
    }

    // MARK: - The month table

    /// Serbian and Bosnian name the months identically, which is why one
    /// table serves both runs. Croatian and Slovenian are deliberately absent:
    /// RetroSpec reads its month names off the site and would never consult
    /// this, so a table for them would be one nothing ever checks.
    func testMonthNamesCoverTheLanguagesThatShip() throws {
        XCTAssertEqual(ArchiveOrgLibrary.monthName(9, in: .serbian), "Septembar")
        XCTAssertEqual(ArchiveOrgLibrary.monthName(9, in: .bosnian), "Septembar")
        XCTAssertNil(ArchiveOrgLibrary.monthName(9, in: .croatian))
        XCTAssertNil(ArchiveOrgLibrary.monthName(0, in: .serbian))
        XCTAssertNil(ArchiveOrgLibrary.monthName(13, in: .serbian))

        // An item dated to the year alone is titled by the year rather than
        // going untitled.
        XCTAssertEqual(ArchiveOrgLibrary.title(year: 1990, month: nil,
                                               language: .serbian), "1990")
        XCTAssertNil(ArchiveOrgLibrary.title(year: nil, month: 7, language: .serbian))
    }
}

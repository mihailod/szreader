import XCTest
@testable import SZKit

/// Loading the shipped catalogue into a library.
///
/// The seed runs on every launch, over a database the reader has been using,
/// so the two things that matter are that a second pass changes nothing and
/// that no pass ever touches what the reader owns.
final class RetroSpecSeedTests: XCTestCase {

    private func bundledCatalogue() throws -> ShippedCatalog {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "retrospec-catalog",
                                                  withExtension: "json"))
        return try ShippedCatalog.decode(try Data(contentsOf: url))
    }

    private func seededStore() throws -> (Store, ShippedCatalog) {
        let store = try Store()
        let file = try bundledCatalogue()
        try store.seed(file)
        return (store, file)
    }

    // MARK: - The first pass

    func testTheWholeCatalogueLands() throws {
        let (store, file) = try seededStore()
        XCTAssertEqual(store.issueCount, 653)
        XCTAssertEqual(store.mirrorCount, 653)

        let issues = try store.recent(limit: nil)
        XCTAssertEqual(issues.count, file.issues.count)
        XCTAssertTrue(issues.allSatisfy { $0.site == .retrospec })
    }

    func testAnIssueCarriesWhatTheShelfNeeds() throws {
        let (store, _) = try seededStore()
        let issues = try store.recent(limit: nil)
        let sk = try XCTUnwrap(issues.first { $0.code == "SK_84_10" })

        XCTAssertEqual(sk.title, "Oktobar 1984")
        XCTAssertEqual(sk.series, "Svet Kompjutera")
        XCTAssertEqual(sk.edition, "Svet Kompjutera")
        XCTAssertEqual(sk.publisher, "RetroSpec")
        XCTAssertEqual(sk.number, 1)
        XCTAssertEqual(sk.pageCount, 48)
        XCTAssertNil(sk.hero, "a magazine has no character to file it under")
        XCTAssertEqual(sk.coverURL,
                       "https://retrospec.elite.org/pcsux/SKH/Covers/SK8410-00.jpg")
        // "SK 1" — the run's short code and its place in it.
        XCTAssertEqual(sk.shelfMark, "SK 1")
    }

    /// The archive's size travels with it, which is what lets a download too
    /// large for the device be refused before it starts. Without it
    /// `checkSpace` has nothing to check and silently passes.
    func testArchiveSizesAreRecorded() throws {
        let (store, _) = try seededStore()
        let issues = try store.recent(limit: nil)
        let sk = try XCTUnwrap(issues.first { $0.code == "SK_84_10" })
        XCTAssertEqual(try store.knownSize(forIssue: sk.id), 17_766_642)

        // Every live archive, not just that one.
        var missing: [String] = []
        for issue in issues where issue.code.map({ !deadIDs.contains($0) }) ?? false {
            if (try store.knownSize(forIssue: issue.id)) == nil {
                missing.append(issue.code ?? "?")
            }
        }
        XCTAssertTrue(missing.isEmpty, "no recorded size for \(missing.prefix(5))")
    }

    private let deadIDs = Set(["MMH_90_06", "MMH_90_07", "MMH_90_09", "MMH_91_03",
                               "MMS_91_11", "MMS_91_12", "BIT_86_02", "GAL_72_05"])

    /// The eight missing archives are seeded like any other, with a mirror
    /// and no size. Marking them dead here would freeze today's answer: the
    /// site may restore them, and nothing in the app ever clears that flag.
    func testMissingArchivesAreSeededUnflagged() throws {
        let (store, _) = try seededStore()
        let issues = try store.recent(limit: nil)
        for id in deadIDs {
            let issue = try XCTUnwrap(issues.first { $0.code == id }, id)
            XCTAssertEqual(issue.mirrorCount, 1, "\(id) should still offer its link")
            XCTAssertNil(try store.knownSize(forIssue: issue.id), id)
            XCTAssertNotNil(issue.coverURL, "\(id)'s cover still exists")
        }
    }

    // MARK: - Searching and filtering

    func testSeededIssuesAreSearchable() throws {
        let (store, _) = try seededStore()
        // By the run's name, which is not in the issue's own title.
        XCTAssertFalse(try store.search("svet kompjutera", limit: nil).isEmpty)
        // Without diacritics, against a name that has them.
        XCTAssertFalse(try store.search("racunari", limit: nil).isEmpty)
        // By the site's id, which is split on underscores when indexed.
        XCTAssertFalse(try store.search("sk 84", limit: nil).isEmpty)
        // By the source itself.
        XCTAssertEqual(try store.search("retrospec", limit: nil).count, 653)
    }

    func testEveryRunReachesTheFilterMenu() throws {
        let (store, file) = try seededStore()
        let editions = try store.editions(sites: [.retrospec])
        XCTAssertEqual(Set(editions), Set(file.series.map(\.name)))
        XCTAssertEqual(editions.count, 19)
    }

    /// The two Moj Mikro runs filter independently, which is the whole
    /// reason they are separate series.
    func testTheTwoMojMikroRunsFilterApart() throws {
        let (store, _) = try seededStore()
        let slovenian = try store.recent(limit: nil, editions: ["Moj Mikro (SLO)"])
        let croatian = try store.recent(limit: nil, editions: ["Moj Mikro (HR)"])
        XCTAssertEqual(slovenian.count, 106)
        XCTAssertEqual(croatian.count, 76)
    }

    // MARK: - Running it again

    /// The stamp means the common launch reads one row and stops.
    func testASecondLaunchSkipsTheWorkEntirely() throws {
        let (store, file) = try seededStore()
        let again = try store.seed(file)
        XCTAssertTrue(again.skipped)
        XCTAssertTrue(again.isEmpty)
    }

    /// And with the stamp ignored, a second pass over the same data still
    /// adds nothing — the skip is an optimisation, not the thing keeping the
    /// library from doubling.
    func testASecondPassOverTheSameDataChangesNothing() throws {
        let (store, file) = try seededStore()
        let report = try store.seed(file, force: true)

        XCTAssertEqual(report.inserted, 0, "the catalogue was inserted twice")
        XCTAssertEqual(report.updated, 653)
        XCTAssertEqual(store.issueCount, 653)
        XCTAssertEqual(store.mirrorCount, 653)
        XCTAssertEqual(try store.search("retrospec", limit: nil).count, 653,
                       "the search index gained duplicates")
    }

    /// A rebuilt catalogue that corrects a title edits the row rather than
    /// adding a second one.
    ///
    /// This is why the seed keys on the site's id and not on the natural key:
    /// `title_folded` is part of that key, so a corrected title would arrive
    /// as a new issue and the old one would linger beside it — the same fault
    /// the forum importer carries healing code for.
    func testACorrectedTitleUpdatesTheRowInPlace() throws {
        let (store, file) = try seededStore()

        let revised = ShippedCatalog(
            version: file.version, generated: "2099-01-01", base: file.base,
            series: file.series,
            issues: file.issues.map { issue in
                issue.id != "SK_84_10" ? issue : ShippedCatalog.Issue(
                    id: issue.id, series: issue.series, number: issue.number,
                    title: "Listopad 1984", year: issue.year, month: issue.month,
                    zip: issue.zip, cover: issue.cover, thumb: issue.thumb,
                    bytes: issue.bytes, pages: issue.pages, dead: issue.dead)
            })
        let report = try store.seed(revised)

        XCTAssertEqual(report.inserted, 0)
        XCTAssertEqual(store.issueCount, 653, "the retitled issue arrived as a new row")
        let issues = try store.recent(limit: nil)
        XCTAssertEqual(issues.filter { $0.code == "SK_84_10" }.count, 1)
        XCTAssertEqual(issues.first { $0.code == "SK_84_10" }?.title, "Listopad 1984")
        // The old title is gone from the index, not merely joined by the new.
        XCTAssertTrue(try store.search("oktobar 1984", limit: nil)
            .allSatisfy { $0.code != "SK_84_10" })
    }

    /// Re-seeding must never touch what the reader owns.
    ///
    /// A corrected title arriving in an app update cannot be allowed to mark
    /// a finished magazine unread or forget where someone stopped reading.
    func testReseedingPreservesWhatTheReaderOwns() throws {
        let (store, file) = try seededStore()
        let issues = try store.recent(limit: nil)
        let read = try XCTUnwrap(issues.first { $0.code == "SK_84_10" })
        let reading = try XCTUnwrap(issues.first { $0.code == "SK_84_11" })

        try store.setRead(true, issueID: read.id)
        try store.setLastPage(17, issueID: reading.id)

        try store.seed(file, force: true)

        let after = try store.recent(limit: nil)
        XCTAssertEqual(after.first { $0.code == "SK_84_10" }?.readState, .read)
        XCTAssertEqual(after.first { $0.code == "SK_84_11" }?.lastPage, 17)
        XCTAssertEqual(after.first { $0.code == "SK_84_11" }?.readState, .reading)
    }

    // MARK: - Living alongside the forum

    /// Seeding a library that already holds forum issues leaves them alone,
    /// and the two sources stay separable afterwards.
    func testSeedingDoesNotDisturbAnImportedLibrary() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            """)
        let forumIssues = store.issueCount
        let forumMirrors = store.mirrorCount
        XCTAssertGreaterThan(forumIssues, 0)

        try store.seed(try bundledCatalogue())

        XCTAssertEqual(store.issueCount, forumIssues + 653)
        XCTAssertEqual(store.mirrorCount, forumMirrors + 653)
        XCTAssertEqual(try store.recent(limit: nil, sites: [.stripzona]).count, forumIssues)
        XCTAssertEqual(try store.recent(limit: nil, sites: [.retrospec]).count, 653)
        // The forum's own edition is still the only one showing when its
        // source is the one selected.
        XCTAssertFalse(try store.editions(sites: [.stripzona]).contains("Svet Kompjutera"))
    }

    // MARK: - Versioning

    /// A catalogue from a future build is refused rather than half-read.
    func testACatalogueFromANewerBuildIsRefused() throws {
        let store = try Store()
        let file = try bundledCatalogue()
        let future = ShippedCatalog(
            version: ShippedCatalog.currentVersion + 1,
            generated: file.generated, base: file.base,
            series: file.series, issues: file.issues)

        XCTAssertThrowsError(try store.seed(future)) { error in
            guard case SeedError.tooNew = error else {
                return XCTFail("wrong error: \(error)")
            }
        }
        XCTAssertEqual(store.issueCount, 0, "a refused catalogue left rows behind")
    }

    /// A corrected catalogue built the same day still reaches the device.
    ///
    /// Found the hard way. The stamp used to be `version/generated`, and
    /// `generated` is a calendar day — so the rebuild that fixed three
    /// mangled titles carried the same stamp as the build that shipped them,
    /// and every device that had already seeded would have skipped the
    /// correction and kept the damage. Stamping by content instead means the
    /// question asked is "is this the catalogue I have?", which is the
    /// question that was always meant.
    func testARebuildOnTheSameDayIsNotMistakenForTheSameCatalogue() throws {
        let store = try Store()
        let file = try bundledCatalogue()

        let broken = ShippedCatalog(
            version: file.version, generated: file.generated, base: file.base,
            series: file.series,
            issues: file.issues.map { issue in
                issue.id != "Knjige_SP" ? issue : ShippedCatalog.Issue(
                    id: issue.id, series: issue.series, number: issue.number,
                    title: "Spektrum Priru?nik", year: issue.year, month: issue.month,
                    zip: issue.zip, cover: issue.cover, thumb: issue.thumb,
                    bytes: issue.bytes, pages: issue.pages, dead: issue.dead)
            })

        let encoder = ShippedCatalog.encoder()
        try store.seed(broken, stamp: Store.digest(try encoder.encode(broken)))
        XCTAssertEqual(try store.recent(limit: nil)
            .first { $0.code == "Knjige_SP" }?.title, "Spektrum Priru?nik")

        // The same calendar day, different content.
        XCTAssertEqual(broken.generated, file.generated)
        let report = try store.seed(file, stamp: Store.digest(try encoder.encode(file)))

        XCTAssertFalse(report.skipped, "the corrected catalogue was skipped")
        XCTAssertEqual(try store.recent(limit: nil)
            .first { $0.code == "Knjige_SP" }?.title, "Spektrum Priručnik")
    }

    /// The three titles the site's own database has lost characters from.
    ///
    /// Two are books, read off the index page instead; one is a month, put
    /// back from a closed vocabulary. All three were spotted on the iPad.
    func testNoShippedTitleIsMissingACharacter() throws {
        let file = try bundledCatalogue()
        let damaged = file.issues.filter { $0.title.contains("?") }
        XCTAssertTrue(damaged.isEmpty,
                      "still mangled: \(damaged.map { "\($0.id): \($0.title)" })")

        let byID = Dictionary(uniqueKeysWithValues: file.issues.map { ($0.id, $0) })
        XCTAssertEqual(byID["Knjige_SP"]?.title, "Spektrum Priručnik")
        XCTAssertEqual(byID["Knjige_KUK"]?.title, "Kompjutor u Kući")
        XCTAssertEqual(byID["Warp_98_02"]?.title, "Veljača/Februar 1998")
    }

    /// The bundled entry point is the one the app calls, so it is worth
    /// checking that the resource resolves from the module bundle at all.
    func testTheBundledCatalogueLoads() throws {
        let store = try Store()
        let report = try store.seedCatalogue(for: .retrospec)
        XCTAssertEqual(report.inserted, 653)
        XCTAssertFalse(report.skipped)
        // And the stamp took, so the next launch does nothing.
        XCTAssertTrue(try store.seedCatalogue(for: .retrospec).skipped)
    }
}

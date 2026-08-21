import XCTest
@testable import SZKit

/// The wall between the two archives.
///
/// Both catalogues share one table, because everything downstream of an issue
/// is keyed on `issue.id` as a globally unique number. That is only safe if
/// the source travels with the row and every query that should respect it
/// does — which is what these check.
final class IssueSiteTests: XCTestCase {

    /// A RetroSpec row, written the way the seed will write one.
    ///
    /// Phase 4 builds the real seed; this puts a row in by hand so the
    /// isolation can be proved before anything depends on it.
    /// `folded` is separate because it is what the natural key actually
    /// compares, and the collision test below needs to hand it a value the
    /// title would not produce.
    @discardableResult
    private func insertRetroSpec(_ store: Store, code: String, number: Int,
                                 title: String, series: String,
                                 folded: String? = nil) throws -> Int64 {
        let key = folded ?? Fold.fold(title)
        let searchText = Store.searchText(title: title, code: code, number: number,
                                          series: series, context: series)
        let id = try store.db.run("""
            INSERT OR IGNORE INTO issue
              (code, number, title, title_folded, series, edition, style,
               search_text, site)
            VALUES (?, ?, ?, ?, ?, ?, 'labeledBlock', ?, 'retrospec')
            """, [.text(code), .int(Int64(number)), .text(title), .text(key),
                  .text(series), .text(series), .text(searchText)])
        try store.db.run("INSERT INTO issue_fts (rowid, search_text) VALUES (?, ?)",
                         [.int(id), .text(searchText)])
        return id
    }

    /// A small forum import, with the page chrome that gives its issues an
    /// edition — otherwise the rows carry no edition at all and the menu
    /// assertions below would be comparing two empty lists.
    private func stripzonaLibrary() throws -> Store {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            """)
        return store
    }

    // MARK: - The column

    /// Every issue that existed before the column was a StripZona issue, and
    /// the default is what says so without a backfill statement.
    func testImportedIssuesAreStripzona() throws {
        let store = try stripzonaLibrary()
        let issues = try store.recent()
        XCTAssertFalse(issues.isEmpty)
        for issue in issues { XCTAssertEqual(issue.site, .stripzona) }
    }

    func testSeededIssuesAreRetrospec() throws {
        let store = try Store()
        try insertRetroSpec(store, code: "SK_84_10", number: 1,
                            title: "Oktobar 1984", series: "Svet Kompjutera")
        XCTAssertEqual(try store.recent().first?.site, .retrospec)
    }

    /// A library written before the column opens with every row attributed,
    /// rather than with a column full of nulls the filters cannot read.
    ///
    /// Simulated by removing the column from a live database and reopening
    /// it, which is exactly what an upgrade from the shipped build does.
    func testAnOlderLibraryIsBackfilledOnOpen() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-migration-\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        do {
            let store = try Store(path: path)
            try store.ingest(html: """
                <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
                <div>http://www.mediafire.com/?FAKEKEY003</div>
                """)
            XCTAssertGreaterThan(store.issueCount, 0)
            // Wind the schema back: every index naming the column has to go
            // first, because SQLite will not drop a column one still stands
            // on. A library old enough to lack `site` has none of these, so
            // dropping them is part of simulating one — and this test is what
            // says so, having failed the moment the menu indexes were added.
            for index in ["issue_identity_v3", "issue_site_edition",
                          "issue_site_publisher", "issue_site_hero"] {
                try store.db.execute("DROP INDEX IF EXISTS \(index)")
            }
            try store.db.execute("ALTER TABLE issue DROP COLUMN site")
        }

        let reopened = try Store(path: path)
        let issues = try reopened.recent()
        XCTAssertGreaterThan(issues.count, 0)
        for issue in issues { XCTAssertEqual(issue.site, .stripzona) }
    }

    // MARK: - Filtering

    func testFilteringToOneSourceExcludesTheOther() throws {
        let store = try stripzonaLibrary()
        try insertRetroSpec(store, code: "SK_84_10", number: 1,
                            title: "Oktobar 1984", series: "Svet Kompjutera")

        let stripzona = try store.recent(limit: nil, sites: [.stripzona])
        let retrospec = try store.recent(limit: nil, sites: [.retrospec])

        XCTAssertFalse(stripzona.isEmpty)
        XCTAssertFalse(retrospec.isEmpty)
        XCTAssertTrue(stripzona.allSatisfy { $0.site == .stripzona })
        XCTAssertTrue(retrospec.allSatisfy { $0.site == .retrospec })
        XCTAssertEqual(stripzona.count + retrospec.count, try store.recent(limit: nil).count)
    }

    /// Search is filtered in SQL alongside everything else, so a hidden
    /// source cannot be reached by typing its name.
    func testSearchRespectsTheSourceFilter() throws {
        let store = try stripzonaLibrary()
        try insertRetroSpec(store, code: "SK_84_10", number: 1,
                            title: "Oktobar 1984", series: "Svet Kompjutera")

        XCTAssertEqual(try store.search("oktobar", limit: nil).count, 1)
        XCTAssertTrue(try store.search("oktobar", limit: nil, sites: [.stripzona]).isEmpty)
        XCTAssertEqual(try store.search("oktobar", limit: nil, sites: [.retrospec]).count, 1)
        // And the other way: StripZona's rows are unreachable with only
        // RetroSpec showing.
        XCTAssertTrue(try store.search("pierrea", limit: nil, sites: [.retrospec]).isEmpty)
    }

    /// Naming every source is the same as naming none — both mean the whole
    /// library — and an empty set is "no opinion" so that every existing
    /// caller keeps seeing everything.
    func testNamingEverySourceIsTheSameAsNamingNone() throws {
        let store = try stripzonaLibrary()
        try insertRetroSpec(store, code: "SK_84_10", number: 1,
                            title: "Oktobar 1984", series: "Svet Kompjutera")

        let all = try store.recent(limit: nil).count
        XCTAssertEqual(try store.recent(limit: nil, sites: []).count, all)
        XCTAssertEqual(try store.recent(limit: nil, sites: Set(IssueSite.allCases)).count, all)
    }

    /// A hidden source leaves the filter menu too. Otherwise switching
    /// RetroSpec off still fills half the Series list with entries that
    /// select nothing.
    func testTheMenusFollowTheSourceFilter() throws {
        let store = try stripzonaLibrary()
        try insertRetroSpec(store, code: "SK_84_10", number: 1,
                            title: "Oktobar 1984", series: "Svet Kompjutera")

        XCTAssertTrue(try store.editions().contains("Svet Kompjutera"))
        XCTAssertFalse(try store.editions(sites: [.stripzona]).contains("Svet Kompjutera"))
        XCTAssertEqual(try store.editions(sites: [.retrospec]), ["Svet Kompjutera"])
        // The forum's own editions survive the same filter.
        XCTAssertFalse(try store.editions(sites: [.stripzona]).isEmpty)
        XCTAssertTrue(try store.heroes(sites: [.retrospec]).isEmpty)
    }

    // MARK: - Identity

    /// Two archives are two namespaces.
    ///
    /// RetroSpec's Galaksija is a Belgrade science monthly; StripZona's is an
    /// SF magazine. Both have an issue 1, and nothing but the source tells
    /// them apart. With the source out of the natural key they are one row —
    /// and the second to arrive is silently dropped, its links handed to the
    /// first, which is the failure the v2 index was written to stop happening
    /// *within* one catalogue.
    ///
    /// The seeded row is built to collide exactly: `<div>Galaksija 1</div>`
    /// imports as code nil, number 1, no title — so `title_folded` is empty —
    /// and series "Galaksija", and the row below matches it term for term.
    /// Today's catalogue could not produce that shape on its own, because
    /// every seeded issue carries a title and a code. That is the point: the
    /// guarantee should hold because the key says so, not because of what the
    /// current data happens to look like.
    /// The order matters, and is the realistic one: the forum page is
    /// imported, the catalogue is seeded underneath it, and then the same
    /// page is imported again — which is what a second visit to a topic does
    /// on any device that has the shipped catalogue.
    ///
    /// That second import is where the lookup behind the upsert is consulted
    /// with both rows already present. A lookup narrower than the index it
    /// stands for matches them both and keeps the last one it sees, which by
    /// rowid is the newer seeded row — so the forum's second link is filed
    /// against a magazine from the other archive.
    func testTheSameIssueNumberInTwoArchivesIsTwoRows() throws {
        let store = try Store()
        let page = """
            <div>Galaksija 1</div>
            <div>http://www.mediafire.com/?FAKEKEYGAL1</div>
            """
        try store.ingest(html: page)
        XCTAssertEqual(store.issueCount, 1)

        try insertRetroSpec(store, code: "", number: 1, title: "Galaksija",
                            series: "Galaksija", folded: "")
        XCTAssertEqual(store.issueCount, 2,
                       "the two archives' issue 1 collapsed into one row")

        // The same topic, revisited, now carrying a second scan.
        try store.ingest(html: page + """
            \n<div>drugi sken: http://www.mediafire.com/?FAKEKEYGAL1B</div>
            """)

        let all = try store.recent(limit: nil)
        XCTAssertEqual(all.count, 2, "re-import created a third row")
        XCTAssertEqual(Set(all.map(\.site)), [.stripzona, .retrospec])

        let forum = try XCTUnwrap(all.first { $0.site == .stripzona })
        let seeded = try XCTUnwrap(all.first { $0.site == .retrospec })
        XCTAssertEqual(forum.mirrorCount, 2, "the forum's links landed on the wrong row")
        XCTAssertEqual(seeded.mirrorCount, 0, "the seeded row was given a forum link")
    }

    /// Re-importing a forum page is still a no-op, with the source in the key.
    ///
    /// The lookup behind that has to name `site` exactly as the index does; a
    /// narrower one matches the wrong catalogue's row, and a wider one stops
    /// recognising the page it already read.
    func testReimportingAPageStillAddsNothing() throws {
        let store = try Store()
        let page = """
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            <div>001 (SSB 089/001) - Šuplji zub - https://mega.nz/file/FAKEID#K</div>
            """
        try store.ingest(html: page)
        let first = store.issueCount
        let mirrors = store.mirrorCount
        XCTAssertGreaterThan(first, 0)

        try store.ingest(html: page)
        XCTAssertEqual(store.issueCount, first, "re-import duplicated issues")
        XCTAssertEqual(store.mirrorCount, mirrors, "re-import duplicated mirrors")
    }
}

import XCTest
@testable import SZKit

/// The sort orders offered next to the filter.
final class ShelfSortTests: XCTestCase {

    private func issue(_ id: Int, edition: String? = nil, number: Int? = nil,
                       title: String? = nil, hero: String? = nil) -> StoredIssue {
        StoredIssue(id: id, code: "C\(id)", number: number, title: title, series: nil,
                    hero: hero, edition: edition, publisher: nil, style: .labeledBlock,
                    mirrorCount: 1, coverURL: nil, isDownloaded: false)
    }

    private func order(_ issues: [StoredIssue], by sort: ShelfSort) -> [Int] {
        guard let comparator = StoredIssue.comparator(for: sort) else { return issues.map(\.id) }
        return issues.sorted(by: comparator).map(\.id)
    }

    /// Import order keeps whatever the query returned — insertion order when
    /// browsing, relevance when searching.
    func testImportOrderLeavesTheQueryAlone() {
        XCTAssertNil(StoredIssue.comparator(for: .imported))
        let shelf = [issue(3, title: "c"), issue(1, title: "a"), issue(2, title: "b")]
        XCTAssertEqual(order(shelf, by: .imported), [3, 1, 2])
    }

    func testByTitle() {
        let shelf = [issue(1, title: "Zoo simfonija"), issue(2, title: "Grupa TNT"),
                     issue(3, title: "Kuća duhova")]
        XCTAssertEqual(order(shelf, by: .title), [2, 3, 1])
    }

    /// Diacritics file with their base letter, not after Z.
    func testByTitleIgnoresDiacritics() {
        let shelf = [issue(1, title: "Zoo"), issue(2, title: "Šuplji zub"), issue(3, title: "Sam")]
        XCTAssertEqual(order(shelf, by: .title), [3, 2, 1])
    }

    /// Series groups the run, and numbers it correctly inside the group.
    func testBySeriesThenNumber() {
        let shelf = [issue(1, edition: "Zlatna Serija", number: 13),
                     issue(2, edition: "Lunov Magnus Strip", number: 511),
                     issue(3, edition: "Zlatna Serija", number: 2),
                     issue(4, edition: "Lunov Magnus Strip", number: 3)]
        XCTAssertEqual(order(shelf, by: .series), [4, 2, 3, 1])
    }

    func testByHeroThenSeriesThenNumber() {
        let shelf = [issue(1, edition: "Zlatna Serija", number: 5, hero: "Zagor"),
                     issue(2, edition: "Lunov Magnus Strip", number: 511, hero: "Mister No"),
                     issue(3, edition: "Zlatna Serija", number: 2, hero: "Zagor"),
                     issue(4, edition: "Super Strip Biblioteka", number: 1, hero: "Alan Ford")]
        XCTAssertEqual(order(shelf, by: .hero), [4, 2, 3, 1])
    }

    /// The hero alias applies, so Zagor files under Z-a-g rather than under
    /// its full registered name.
    func testHeroSortUsesTheDisplayName() {
        let shelf = [issue(1, number: 1, hero: "Zagor Te-Nay"), issue(2, number: 2, hero: "Zorro")]
        XCTAssertEqual(order(shelf, by: .hero), [1, 2])
    }

    /// Numeric, not lexicographic.
    func testByNumberIsNumeric() {
        let shelf = [issue(1, number: 100), issue(2, number: 9), issue(3, number: 21)]
        XCTAssertEqual(order(shelf, by: .number), [2, 3, 1])
    }

    /// Rows missing the key sort last, whichever key it is.
    func testMissingValuesSortLast() {
        XCTAssertEqual(order([issue(1), issue(2, number: 7)], by: .number), [2, 1])
        XCTAssertEqual(order([issue(1), issue(2, title: "a")], by: .title), [2, 1])
        XCTAssertEqual(order([issue(1), issue(2, edition: "Zlatna Serija")], by: .series), [2, 1])
    }

    /// Equal keys must not shuffle between refreshes.
    func testEveryOrderIsStable() {
        for sort in ShelfSort.allCases where sort != .imported {
            let shelf = [issue(9, edition: "ZS", number: 5, title: "same", hero: "Zagor"),
                         issue(4, edition: "ZS", number: 5, title: "same", hero: "Zagor")]
            XCTAssertEqual(order(shelf, by: sort), [4, 9], "\(sort) is unstable")
            XCTAssertEqual(order(shelf.reversed(), by: sort), [4, 9], "\(sort) is unstable")
        }
    }
}

/// Filtering by series, on top of the Downloaded switch.
final class SeriesFilterTests: XCTestCase {

    private func populated() throws -> Store {
        let store = try Store()
        // Three pages, three editions, so the filter has something to separate.
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>511-Dijamantska klopka</div><div>http://www.mediafire.com/?FAKE511</div>
            <div>513-Uzareni kotao</div><div>http://www.mediafire.com/?FAKE513</div>
            """)
        try store.ingest(html: """
            <title>Kit Teler - ZLATNA SERIJA - Kit Teler - Stripzona</title>
            <div>021-Neki naslov</div><div>http://www.mediafire.com/?FAKE021</div>
            """)
        try store.ingest(html: """
            <title>Alan Ford Super Strip Biblioteka - Alan Ford - Stripzona</title>
            <div>001-Grupa TNT</div><div>http://www.mediafire.com/?FAKE001</div>
            """)
        return store
    }

    func testEditionsListsWhatWasImported() throws {
        let editions = try populated().editions()
        XCTAssertTrue(editions.contains("LUNOV MAGNUS STRIP"), "\(editions)")
        XCTAssertTrue(editions.contains("ZLATNA SERIJA"), "\(editions)")
        XCTAssertEqual(Set(editions).count, editions.count, "duplicates: \(editions)")
    }

    func testOneSeriesNarrowsTheShelf() throws {
        let store = try populated()
        let rows = try store.recent(limit: nil, editions: ["LUNOV MAGNUS STRIP"])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { $0.edition == "LUNOV MAGNUS STRIP" })
    }

    /// Additive: two series means either of them, not both at once — which
    /// nothing could satisfy.
    func testSeriesAreAdditive() throws {
        let store = try populated()
        let rows = try store.recent(limit: nil,
                                    editions: ["LUNOV MAGNUS STRIP", "ZLATNA SERIJA"])
        XCTAssertEqual(rows.count, 3)
    }

    /// Downloaded narrows whatever the series filter left.
    func testDownloadedAndSeriesCombine() throws {
        let store = try populated()
        let lms = try XCTUnwrap(try store.recent(limit: nil,
                                                 editions: ["LUNOV MAGNUS STRIP"]).first)
        try store.recordDownload(issueID: lms.id, mirrorURL: "http://x/1",
                                 path: URL(fileURLWithPath: "/tmp/a.cbz"), bytes: 1)

        XCTAssertEqual(try store.recent(limit: nil, downloadedOnly: true,
                                        editions: ["LUNOV MAGNUS STRIP"]).count, 1)
        // The download is not in Zlatna Serija, so that combination is empty.
        XCTAssertTrue(try store.recent(limit: nil, downloadedOnly: true,
                                       editions: ["ZLATNA SERIJA"]).isEmpty)
    }

    func testNoSeriesSelectedMeansEverySeries() throws {
        let store = try populated()
        XCTAssertEqual(try store.recent(limit: nil, editions: []).count, store.issueCount)
    }

    /// The filter must apply to search too, not only to browsing.
    func testSearchRespectsTheSeriesFilter() throws {
        let store = try populated()
        XCTAssertFalse(try store.search("naslov", limit: nil).isEmpty)
        XCTAssertTrue(try store.search("naslov", limit: nil,
                                       editions: ["LUNOV MAGNUS STRIP"]).isEmpty)
        XCTAssertFalse(try store.search("naslov", limit: nil,
                                        editions: ["ZLATNA SERIJA"]).isEmpty)
    }

    /// A series name is bound, never interpolated — an apostrophe in an
    /// edition must not be able to break the statement.
    func testSeriesNamesAreBoundNotInterpolated() throws {
        let store = try populated()
        XCTAssertNoThrow(try store.recent(limit: nil, editions: ["'; DROP TABLE issue; --"]))
        XCTAssertEqual(store.issueCount, 4)
    }
}

/// Telling a magazine apart from a character's edition.
///
/// Both are written "<name> - <SHOUTED> - <section>", so the shouted part is
/// not enough to go on: for Mister No it is the edition (Lunov Magnus Strip),
/// for Kolorka it is the publisher (FIBRA). The difference is that the forum
/// indexes its characters as breadcrumbs and its magazines not at all.
final class MagazineEditionTests: XCTestCase {

    private func context(topic: String, crumbs: [String]) -> PageContext {
        PageContext(topic: topic, trail: crumbs)
    }

    /// All four FIBRA magazines shared one "FIBRA" entry in the filter, which
    /// made them indistinguishable.
    func testMagazinesKeepTheirOwnName() {
        let names = ["Kolorka", "Orka", "Kolorka Specijal", "Orka Specijal"]
        for name in names {
            let page = context(topic: "\(name) - FIBRA - Vas upload razno",
                               crumbs: ["Strip Revije", "Vas upload razno"])
            XCTAssertEqual(page.edition, name)
            XCTAssertEqual(page.publisher, "FIBRA", "publisher lost for \(name)")
            XCTAssertNil(page.hero, "a magazine has no hero")
        }
    }

    /// The four must not collapse back into one entry.
    func testTheFourMagazinesAreDistinct() {
        let editions = ["Kolorka", "Orka", "Kolorka Specijal", "Orka Specijal"].map { name in
            context(topic: "\(name) - FIBRA - Vas upload razno",
                    crumbs: ["Strip Revije", "Vas upload razno"]).edition
        }
        XCTAssertEqual(Set(editions.compactMap { $0 }).count, 4)
    }

    /// A character's topic still yields the shouted edition, not the hero.
    func testCharacterTopicsAreUnchanged() {
        let misterNo = context(topic: "Mister No - LUNOV MAGNUS STRIP - Mister No",
                               crumbs: ["BONELLI", "Mister No"])
        XCTAssertEqual(misterNo.edition, "LUNOV MAGNUS STRIP")
        XCTAssertEqual(misterNo.hero, "Mister No")
        XCTAssertEqual(misterNo.publisher, "BONELLI")

        // The fuller forum spelling of the hero still matches the shorter one
        // in the topic.
        let zagor = context(topic: "Zagor - ZLATNA SERIJA - ZS i LMS",
                            crumbs: ["BONELLI", "Zagor Te-Nay", "ZS i LMS"])
        XCTAssertEqual(zagor.edition, "ZLATNA SERIJA")
        XCTAssertEqual(zagor.hero, "Zagor Te-Nay")
    }

    /// Alan Ford writes hero and edition as one run, with no shouted part.
    func testEditionRunTogetherWithTheHero() {
        let page = context(topic: "Alan Ford Super Strip Biblioteka [425] [Vjesnik] - Alan Ford",
                           crumbs: ["Magnus - Bunker", "Alan Ford"])
        XCTAssertEqual(page.edition, "Super Strip Biblioteka")
        XCTAssertEqual(page.hero, "Alan Ford")
    }
}

/// A page whose breadcrumbs did not parse.
///
/// "No crumb matches the topic" is what marks a magazine — but only when there
/// were crumbs to check. With none, the shouted part is the better guess, and
/// falling the other way would file every issue under its hero's name.
extension MagazineEditionTests {

    func testNoBreadcrumbsFallsBackToTheShoutedEdition() {
        let page = PageContext(topic: "Mister No - LUNOV MAGNUS STRIP - Mister No", trail: [])
        XCTAssertEqual(page.edition, "LUNOV MAGNUS STRIP")
    }

    func testNoBreadcrumbsAndNothingShouted() {
        let page = PageContext(topic: "Alan Ford Super Strip Biblioteka - Alan Ford", trail: [])
        XCTAssertNotNil(page.edition)
    }
}

/// Searching by series and publisher, not just by title.
final class SeriesSearchTests: XCTestCase {

    /// Matched on a fragment, not an exact name: saved pages pick up suffixes
    /// (one is "… - Stripzona.html 3"), and an exact match that misses skips
    /// the test silently — which proves nothing at all.
    private func page(_ fragment: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let hit = names.first(where: { $0.contains(fragment) }),
              let html = try? String(contentsOf: dir.appendingPathComponent(hit),
                                     encoding: .utf8)
        else { throw XCTSkip("no saved page matching “\(fragment)”") }
        return html
    }

    /// Three pages that actually carry issues.
    ///
    /// Deliberately not the Kit Teler ZLATNA SERIJA page: every block on it is
    /// still behind "Hidden Content", so it imports zero issues — and a test
    /// built on it fails looking exactly like a broken search.
    private func library() throws -> Store {
        let store = try Store()
        try store.ingest(html: try page(
            "Mister No - LUNOV MAGNUS STRIP"))
        try store.ingest(html: try page(
            "Orka - FIBRA"))
        try store.ingest(html: try page(
            "Zagor - ZLATNA SERIJA"))
        // Fail on an empty fixture rather than on the assertion it breaks.
        XCTAssertGreaterThan(store.issueCount, 0, "fixtures imported nothing")
        return store
    }

    func testSearchBySeriesName() throws {
        let store = try library()
        XCTAssertFalse(try store.search("lunov magnus", limit: nil).isEmpty)
        XCTAssertFalse(try store.search("zlatna serija", limit: nil).isEmpty)
    }

    /// The one that prompted this: every FIBRA comic, by publisher.
    func testSearchByPublisher() throws {
        let store = try library()
        let hits = try store.search("fibra", limit: nil)
        XCTAssertFalse(hits.isEmpty, "no results for the publisher")
        XCTAssertTrue(hits.allSatisfy { $0.publisher?.caseInsensitiveCompare("FIBRA")
                                         == .orderedSame },
                      "publisher search returned something else")
    }

    func testSearchByHero() throws {
        let store = try library()
        XCTAssertFalse(try store.search("mister no", limit: nil).isEmpty)
        XCTAssertFalse(try store.search("zagor", limit: nil).isEmpty)
    }

    /// Publisher is stored per issue, so the row can show it.
    func testPublisherIsStoredAndShown() throws {
        let store = try library()
        let orka = try XCTUnwrap(try store.recent(limit: nil).first { $0.edition == "Orka" })
        XCTAssertEqual(orka.publisher, "FIBRA")
        let line = try XCTUnwrap(orka.provenance)
        XCTAssertTrue(line.contains("Orka"), line)
        XCTAssertTrue(line.contains("FIBRA"), line)
    }

    /// Publisher narrows the shelf, and combines with the series filter.
    func testPublisherFilter() throws {
        let store = try library()
        let fibra = try store.recent(limit: nil, publishers: ["FIBRA"])
        XCTAssertFalse(fibra.isEmpty)
        XCTAssertTrue(fibra.allSatisfy { $0.publisher == "FIBRA" })
        // A series from another publisher cannot also be FIBRA.
        XCTAssertTrue(try store.recent(limit: nil, editions: ["ZLATNA SERIJA"],
                                       publishers: ["FIBRA"]).isEmpty)
    }
}

/// Filtering by hero.
final class HeroFilterTests: XCTestCase {

    private func page(_ fragment: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let hit = names.first(where: { $0.contains(fragment) }),
              let html = try? String(contentsOf: dir.appendingPathComponent(hit),
                                     encoding: .utf8)
        else { throw XCTSkip("no saved page matching “\(fragment)”") }
        return html
    }

    private func library() throws -> Store {
        let store = try Store()
        try store.ingest(html: try page("Mister No - LUNOV MAGNUS STRIP"))
        try store.ingest(html: try page("Zagor - ZLATNA SERIJA"))
        XCTAssertGreaterThan(store.issueCount, 0, "fixtures imported nothing")
        return store
    }

    func testHeroesListsWhatWasImported() throws {
        let heroes = try library().heroes()
        XCTAssertTrue(heroes.contains("Mister No"), "\(heroes)")
        // The stored spelling, which is what the rows can be filtered on.
        XCTAssertTrue(heroes.contains("Zagor Te-Nay"), "\(heroes)")
    }

    func testOneHeroNarrowsTheShelf() throws {
        let store = try library()
        let rows = try store.recent(limit: nil, heroes: ["Mister No"])
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.hero == "Mister No" })
        XCTAssertLessThan(rows.count, store.issueCount)
    }

    /// Additive, like the others.
    func testHeroesAreAdditive() throws {
        let store = try library()
        let both = try store.recent(limit: nil, heroes: ["Mister No", "Zagor Te-Nay"])
        XCTAssertEqual(both.count, store.issueCount)
    }

    /// The menu offers the short name but must filter on the stored one.
    func testDisplayNameIsNotWhatWeFilterOn() throws {
        let store = try library()
        XCTAssertEqual(PageContext.displayName(forHero: "Zagor Te-Nay"), "Zagor")
        XCTAssertFalse(try store.recent(limit: nil, heroes: ["Zagor Te-Nay"]).isEmpty)
        // Filtering on the display name would silently return nothing.
        XCTAssertTrue(try store.recent(limit: nil, heroes: ["Zagor"]).isEmpty)
    }

    /// Hero narrows whatever series and Downloaded left.
    func testHeroCombinesWithTheOtherFilters() throws {
        let store = try library()
        XCTAssertFalse(try store.recent(limit: nil, editions: ["LUNOV MAGNUS STRIP"],
                                        heroes: ["Mister No"]).isEmpty)
        // Mister No is not in Zlatna Serija, so that pairing is empty.
        XCTAssertTrue(try store.recent(limit: nil, editions: ["ZLATNA SERIJA"],
                                       heroes: ["Mister No"]).isEmpty)
    }

    func testNoHeroSelectedMeansEveryHero() throws {
        let store = try library()
        XCTAssertEqual(try store.recent(limit: nil, heroes: []).count, store.issueCount)
    }
}

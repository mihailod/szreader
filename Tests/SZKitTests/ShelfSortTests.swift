import XCTest
@testable import SZKit

/// The sort orders offered next to the filter.
final class ShelfSortTests: XCTestCase {

    private func issue(_ id: Int, edition: String? = nil, number: Int? = nil,
                       title: String? = nil, hero: String? = nil,
                       isRead: Bool = false, openedAt: Date? = nil) -> StoredIssue {
        StoredIssue(id: id, code: "C\(id)", number: number, title: title, series: nil,
                    hero: hero, edition: edition, publisher: nil, isRead: isRead, lastPage: nil, numberTo: nil, started: false, downloadFailed: false, style: .labeledBlock,
                    mirrorCount: 1, coverURL: nil, isDownloaded: false,
                    openedAt: openedAt)
    }

    /// Minutes ago, so a test reads as the reader would describe it.
    private func ago(_ minutes: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000 - Double(minutes) * 60)
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

    /// What arrived last is at the top, where someone who has just imported it
    /// will actually see it.
    ///
    /// A real comparator rather than "reverse whatever came back". The rows a
    /// search hands over are in relevance order, and the reverse of that is
    /// the least relevant first — which is not newest by any reading.
    func testNewestSortsByArrival() {
        let shelf = [issue(3, title: "c"), issue(1, title: "a"), issue(2, title: "b")]
        XCTAssertEqual(order(shelf, by: .newest), [3, 2, 1])
    }

    /// The default, and the head of the menu.
    ///
    /// Both matter and neither implies the other: `default` is what a reader
    /// who has never chosen gets, `allCases.first` is where the one they are
    /// most likely to want sits when they go looking.
    func testRecentlyOpenIsTheDefaultAndComesFirst() {
        XCTAssertEqual(ShelfSort.default, .opened)
        XCTAssertEqual(ShelfSort.allCases.first, .opened, "and it is offered first")
        XCTAssertEqual(ShelfSort.opened.label, "Recently Open")
    }

    /// Most recently opened first.
    func testRecentlyOpenSortsByOpeningTime() {
        let shelf = [issue(1, openedAt: ago(90)),
                     issue(2, openedAt: ago(5)),
                     issue(3, openedAt: ago(60))]
        XCTAssertEqual(order(shelf, by: .opened), [2, 3, 1])
    }

    /// Read state has nothing to do with it. A comic finished last night is
    /// more recently opened than one abandoned half-read a month ago, and the
    /// order says so.
    func testRecentlyOpenIgnoresReadState() {
        let shelf = [issue(1, isRead: false, openedAt: ago(60 * 24 * 30)),
                     issue(2, isRead: true, openedAt: ago(600))]
        XCTAssertEqual(order(shelf, by: .opened), [2, 1])
    }

    /// A sort rearranges the shelf; it never shortens it. Everything never
    /// opened follows everything that has been, and nothing goes missing.
    func testNeverOpenedIssuesSortToTheBottomAndAreStillThere() {
        let shelf = [issue(1), issue(2, openedAt: ago(90)),
                     issue(3), issue(4, openedAt: ago(5))]
        let sorted = order(shelf, by: .opened)
        XCTAssertEqual(sorted, [4, 2, 3, 1])
        XCTAssertEqual(Set(sorted), Set(shelf.map(\.id)), "the sort dropped a row")
    }

    /// The never-opened tail is one big tie, so it needs an order of its own:
    /// reverse import, which is the direction the rows above it run in and the
    /// order this shelf had before Recently Open became the default.
    func testTheNeverOpenedTailIsInReverseImportOrder() {
        let shelf = [issue(1), issue(3), issue(2)]
        XCTAssertEqual(order(shelf, by: .opened), [3, 2, 1])
        XCTAssertEqual(order(shelf.reversed(), by: .opened), [3, 2, 1])
    }

    /// Asked for by name, so it survives a search, like the four keys below
    /// it. Someone who picked Recently Open and then typed asked for their
    /// reading history narrowed to a word, not for relevance rank.
    func testRecentlyOpenAppliesWhileSearching() {
        XCTAssertNotNil(StoredIssue.comparator(for: .opened, whileSearching: true))
    }

    /// The stored value is a reader's choice, like the two import orders.
    func testRecentlyOpenIsItsOwnStoredValue() {
        XCTAssertEqual(ShelfSort.opened.rawValue, "opened")
        XCTAssertEqual(ShelfSort(rawValue: "opened"), .opened)
    }

    /// A search stays in the order the search produced.
    ///
    /// The shelf answers "what have I got", and newest-first is the right
    /// answer to that. A search answers "where is the thing I typed", which
    /// the query has already ranked — re-sorting those hits by age buries the
    /// best match under whatever was imported most recently.
    func testNewestDefersToRelevanceWhileSearching() {
        XCTAssertNil(StoredIssue.comparator(for: .newest, whileSearching: true))
        XCTAssertNil(StoredIssue.comparator(for: .imported, whileSearching: true))
        XCTAssertNotNil(StoredIssue.comparator(for: .newest, whileSearching: false))

        // The four explicit keys are unaffected: asking for Title means Title,
        // question or no question.
        for sort in [ShelfSort.title, .series, .hero, .number] {
            XCTAssertNotNil(StoredIssue.comparator(for: sort, whileSearching: true),
                            "\(sort) was asked for by name and must still apply")
        }
    }

    /// The stored value is what a reader picked, so the two import orders must
    /// never be confusable: renaming `imported` to mean its opposite would
    /// silently reverse the shelf of everyone who had chosen it.
    func testTheTwoImportOrdersAreDistinctStoredValues() {
        XCTAssertEqual(ShelfSort.imported.rawValue, "imported")
        XCTAssertEqual(ShelfSort.newest.rawValue, "newest")
        XCTAssertEqual(ShelfSort(rawValue: "imported"), .imported)
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
    ///
    /// `imported` has no comparator to be unstable, and `newest` sorts on the
    /// id itself — which is unique, so it has no ties to break and is one of
    /// the two orders that legitimately put the higher id first. `opened` is
    /// the other, and is checked separately below for the same reason.
    func testEveryOrderIsStable() {
        for sort in ShelfSort.allCases
        where sort != .imported && sort != .newest && sort != .opened {
            let shelf = [issue(9, edition: "ZS", number: 5, title: "same", hero: "Zagor"),
                         issue(4, edition: "ZS", number: 5, title: "same", hero: "Zagor")]
            XCTAssertEqual(order(shelf, by: sort), [4, 9], "\(sort) is unstable")
            XCTAssertEqual(order(shelf.reversed(), by: sort), [4, 9], "\(sort) is unstable")
        }
        // And the two reverse-chronological orders are stable in their own
        // direction, whichever way they are fed: ties break on the id
        // descending, matching the way the rest of the order runs.
        let shelf = [issue(9), issue(4)]
        XCTAssertEqual(order(shelf, by: .newest), [9, 4])
        XCTAssertEqual(order(shelf.reversed(), by: .newest), [9, 4])

        let sameInstant = [issue(9, openedAt: ago(3)), issue(4, openedAt: ago(3))]
        XCTAssertEqual(order(sameInstant, by: .opened), [9, 4])
        XCTAssertEqual(order(sameInstant.reversed(), by: .opened), [9, 4])
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

/// Marking issues read, and filtering on it.
final class ReadStateTests: XCTestCase {

    private func populated() throws -> (Store, [StoredIssue]) {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>
            <div>002-Drugi</div><div>http://www.mediafire.com/?FAKE002</div>
            <div>003-Treci</div><div>http://www.mediafire.com/?FAKE003</div>
            """)
        return (store, try store.recent(limit: nil))
    }

    func testIssuesStartUnread() throws {
        let (store, rows) = try populated()
        XCTAssertTrue(rows.allSatisfy { !$0.isRead })
        XCTAssertEqual(try store.recent(limit: nil, states: [.unread]).count, 3)
        XCTAssertTrue(try store.recent(limit: nil, states: [.read]).isEmpty)
    }

    func testMarkingReadAndBack() throws {
        let (store, rows) = try populated()
        try store.setRead(true, issueID: rows[0].id)

        XCTAssertEqual(try store.recent(limit: nil, states: [.read]).map(\.id), [rows[0].id])
        XCTAssertEqual(try store.recent(limit: nil, states: [.unread]).count, 2)
        XCTAssertTrue(try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id }).isRead)

        try store.setRead(false, issueID: rows[0].id)
        XCTAssertTrue(try store.recent(limit: nil, states: [.read]).isEmpty)
        XCTAssertFalse(try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id }).isRead)
    }

    /// Asking for read *and* unread is the same as not asking.
    func testAnyMeansEverything() throws {
        let (store, rows) = try populated()
        try store.setRead(true, issueID: rows[0].id)
        XCTAssertEqual(try store.recent(limit: nil, states: []).count, 3)
    }

    /// Read state narrows whatever the other filters left.
    func testCombinesWithTheOtherFilters() throws {
        let (store, rows) = try populated()
        try store.setRead(true, issueID: rows[0].id)
        try store.recordDownload(issueID: rows[1].id, mirrorURL: "http://x/2",
                                 path: URL(fileURLWithPath: "/tmp/b.cbz"), bytes: 1)
        // Downloaded and read describe different issues here, so together they
        // match nothing.
        XCTAssertTrue(try store.recent(limit: nil, downloadedOnly: true,
                                       states: [.read]).isEmpty)
        XCTAssertEqual(try store.recent(limit: nil, downloadedOnly: true,
                                        states: [.unread]).count, 1)
    }

    /// Search honours it too, not only browsing.
    func testSearchRespectsReadState() throws {
        let (store, rows) = try populated()
        try store.setRead(true, issueID: rows[0].id)
        XCTAssertEqual(try store.search("prvi", limit: nil, states: [.read]).count, 1)
        XCTAssertTrue(try store.search("prvi", limit: nil, states: [.unread]).isEmpty)
    }
}

/// Remembering where reading stopped.
final class ReadingProgressTests: XCTestCase {

    private func populated() throws -> (Store, [StoredIssue]) {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>
            <div>002-Drugi</div><div>http://www.mediafire.com/?FAKE002</div>
            """)
        return (store, try store.recent(limit: nil))
    }

    /// Opening a comic to look at the cover is not reading it.
    func testFirstPageDoesNotCountAsReading() throws {
        let (store, rows) = try populated()
        try store.setLastPage(0, issueID: rows[0].id)
        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertEqual(issue.readState, .unread)
        XCTAssertTrue(try store.recent(limit: nil, states: [.reading]).isEmpty)
    }

    /// The second page does.
    func testSecondPageStartsReading() throws {
        let (store, rows) = try populated()
        try store.setLastPage(1, issueID: rows[0].id)
        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertEqual(issue.readState, .reading)
        XCTAssertEqual(try store.recent(limit: nil, states: [.reading]).map(\.id), [rows[0].id])
        XCTAssertEqual(try store.recent(limit: nil, states: [.unread]).map(\.id), [rows[1].id])
    }

    func testPlaceIsRemembered() throws {
        let (store, rows) = try populated()
        try store.setLastPage(17, issueID: rows[0].id)
        XCTAssertEqual(try store.lastPage(forIssue: rows[0].id), 17)
    }

    /// The place is where reading stopped, which is not always the furthest
    /// page reached: scrubbing back and closing has to reopen where you left
    /// off, not at the far end of the comic.
    func testPlaceFollowsTheReaderBackwards() throws {
        let (store, rows) = try populated()
        try store.setLastPage(17, issueID: rows[0].id)
        try store.setLastPage(3, issueID: rows[0].id)
        XCTAssertEqual(try store.lastPage(forIssue: rows[0].id), 3)
    }

    /// Having started a comic is not undone by moving around inside it.
    /// Scrubbing back to the cover changes where you resume, and nothing else.
    func testGoingBackToTheFirstPageStaysReading() throws {
        let (store, rows) = try populated()
        try store.setLastPage(30, issueID: rows[0].id)
        try store.setLastPage(0, issueID: rows[0].id)

        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertEqual(issue.readState, .reading, "going back to the cover cleared Reading")
        XCTAssertEqual(try store.lastPage(forIssue: rows[0].id), 0, "the place did not follow")
        XCTAssertEqual(try store.recent(limit: nil, states: [.reading]).map(\.id), [rows[0].id])
    }

    /// Finishing, then unmarking, is still the only way out of Reading.
    func testFinishingAndUnmarkingIsTheWayOut() throws {
        let (store, rows) = try populated()
        try store.setLastPage(30, issueID: rows[0].id)
        try store.setRead(true, issueID: rows[0].id)
        try store.setRead(false, issueID: rows[0].id)

        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertEqual(issue.readState, .unread)
        XCTAssertTrue(try store.recent(limit: nil, states: [.reading]).isEmpty)
    }

    /// A library written before there was a column for this must not lose its
    /// Reading badges the first time this build opens it.
    func testOlderLibraryKeepsItsReadingBadges() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).sqlite").path
        defer { try? FileManager.default.removeItem(atPath: path) }

        let id: Int
        do {
            let store = try Store(path: path)
            try store.ingest(html: """
                <div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>
                """)
            id = try XCTUnwrap(store.recent(limit: nil).first).id
            try store.setLastPage(12, issueID: id)
            // What such a library looks like: a place recorded, and nothing
            // saying the comic was started.
            try store.db.run("UPDATE issue SET started_at = NULL WHERE id = ?",
                             [.int(Int64(id))])
        }

        let reopened = try Store(path: path)
        let issue = try XCTUnwrap(reopened.recent(limit: nil).first { $0.id == id })
        XCTAssertEqual(issue.readState, .reading, "the migration lost a Reading badge")
    }

    /// Finishing clears the place — otherwise unmarking read would drop the
    /// issue straight back into Reading, with no way out of that state.
    func testMarkingReadClearsThePlace() throws {
        let (store, rows) = try populated()
        try store.setLastPage(9, issueID: rows[0].id)
        try store.setRead(true, issueID: rows[0].id)
        XCTAssertEqual(try store.lastPage(forIssue: rows[0].id), 0)

        try store.setRead(false, issueID: rows[0].id)
        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertEqual(issue.readState, .unread, "unmarking left it stuck in Reading")
    }

    /// The three states partition the library — every issue is in exactly one.
    func testStatesArePartition() throws {
        let (store, rows) = try populated()
        try store.setLastPage(4, issueID: rows[0].id)
        try store.setRead(true, issueID: rows[1].id)

        let unread = try store.recent(limit: nil, states: [.unread]).count
        let reading = try store.recent(limit: nil, states: [.reading]).count
        let read = try store.recent(limit: nil, states: [.read]).count
        XCTAssertEqual(unread + reading + read, store.issueCount)
        XCTAssertEqual([unread, reading, read], [0, 1, 1])
    }

    /// Selecting every state is the same as selecting none.
    func testAllStatesMeansEverything() throws {
        let (store, rows) = try populated()
        try store.setLastPage(4, issueID: rows[0].id)
        XCTAssertEqual(try store.recent(limit: nil, states: Set(ReadState.allCases)).count,
                       store.issueCount)
        XCTAssertEqual(try store.recent(limit: nil, states: []).count, store.issueCount)
    }

    /// Two of the three, additively.
    func testStatesAreAdditive() throws {
        let (store, rows) = try populated()
        try store.setLastPage(4, issueID: rows[0].id)
        try store.setRead(true, issueID: rows[1].id)
        XCTAssertEqual(try store.recent(limit: nil, states: [.reading, .read]).count, 2)
        XCTAssertTrue(try store.recent(limit: nil, states: [.unread]).isEmpty)
    }
}

/// Remembering that a download failed.
///
/// Some links really are dead. A shelf that looks identical before and after
/// trying one is a shelf you keep retrying from tomorrow.
final class DownloadFailureMarkTests: XCTestCase {

    private func populated() throws -> (Store, [StoredIssue]) {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>
            <div>002-Drugi</div><div>http://www.mediafire.com/?FAKE002</div>
            """)
        return (store, try store.recent(limit: nil))
    }

    func testIssuesStartUnmarked() throws {
        let (_, rows) = try populated()
        XCTAssertTrue(rows.allSatisfy { !$0.downloadFailed })
    }

    func testFailureIsRemembered() throws {
        let (store, rows) = try populated()
        try store.setDownloadFailed(true, issueID: rows[0].id)

        let marked = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertTrue(marked.downloadFailed)
        let other = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[1].id })
        XCTAssertFalse(other.downloadFailed, "the mark spread to another issue")
    }

    /// A success clears it, so the mark always describes the latest attempt.
    func testSuccessClearsTheMark() throws {
        let (store, rows) = try populated()
        try store.setDownloadFailed(true, issueID: rows[0].id)
        try store.setDownloadFailed(false, issueID: rows[0].id)
        XCTAssertFalse(try XCTUnwrap(store.recent(limit: nil)
            .first { $0.id == rows[0].id }).downloadFailed)
    }

    /// It survives a reopen — a dead link is still dead next launch.
    func testMarkPersists() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("library.sqlite").path

        let store = try Store(path: file)
        try store.ingest(html:
            "<div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>")
        let id = try XCTUnwrap(try store.recent().first).id
        try store.setDownloadFailed(true, issueID: id)

        let reopened = try Store(path: file)
        XCTAssertTrue(try XCTUnwrap(reopened.recent().first).downloadFailed)
    }

    /// The mark is about downloading, not reading: the two are independent.
    func testFailureIsIndependentOfReadState() throws {
        let (store, rows) = try populated()
        try store.setDownloadFailed(true, issueID: rows[0].id)
        try store.setLastPage(3, issueID: rows[0].id)

        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.id == rows[0].id })
        XCTAssertTrue(issue.downloadFailed)
        XCTAssertEqual(issue.readState, .reading)
    }
}

/// Labels that separate the name from the number with a dash.
final class DashedNameLabelTests: XCTestCase {

    /// Korto Malteze writes "Corto Maltese - 01 - Mladost". A separator that
    /// allows only whitespace stops at the dash, which left that topic with 34
    /// links and no issues at all.
    func testNameDashNumberDashTitle() {
        let match = Labels.matchNameFirst("Corto Maltese - 01 - Mladost")
        XCTAssertEqual(match?.number, "01")
        XCTAssertEqual(match?.name, "Corto Maltese")
        XCTAssertEqual(match?.title, "Mladost")
    }

    /// A size stuck to the end describes the file, not the comic. Left in, it
    /// splits one issue into two rows, because the title is part of the key
    /// that decides whether two entries are the same comic.
    func testTrailingSizeIsNotPartOfTheTitle() {
        XCTAssertEqual(Labels.matchNameFirst("Corto Maltese - 01 - Mladost 24Mb")?.title,
                       "Mladost")
        XCTAssertEqual(Labels.matchNameFirst("Corto Maltese - 02 - Balada 77.43Mb")?.title,
                       "Balada")
        XCTAssertEqual(Labels.matchNameFirst("Corto Maltese - 05 - Kelti [120 MB]")?.title,
                       "Kelti")
    }

    /// Nor is a filename extension — and the bracket only becomes trailing
    /// once the extension is gone.
    func testTrailingExtensionIsRemoved() {
        XCTAssertEqual(Labels.matchNameFirst(
            "Corto Maltese - 06 - Etiopljani (boja preklop by fantom).cbr")?.title,
            "Etiopljani")
        XCTAssertEqual(Labels.matchNameFirst("Corto Maltese - 07 - U Sibiru.cbz")?.title,
                       "U Sibiru")
    }

    /// A number in the title itself must survive — it is not a size.
    func testNumbersInsideTitlesSurvive() {
        XCTAssertEqual(Labels.matchNameFirst("Corto Maltese - 09 - Blago Samarkanda")?.title,
                       "Blago Samarkanda")
        XCTAssertEqual(Labels.matchNameFirst("Zagor 13 - Tajna 7 zlatnika")?.title,
                       "Tajna 7 zlatnika")
    }

    /// Sub-volumes stay distinct: 3a and 3b are different comics.
    func testSubVolumesRemainSeparate() {
        let a = Labels.matchNameFirst("Corto Maltese - 03a - Karipska svita")
        let b = Labels.matchNameFirst("Corto Maltese - 03b - Pod gusarskom zastavom")
        XCTAssertEqual(a?.number, "03")
        XCTAssertEqual(b?.number, "03")
        XCTAssertNotEqual(a?.title, b?.title, "the two volumes would merge into one row")
    }
}

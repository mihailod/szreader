import XCTest
@testable import SZKit

/// Search has to cover more than titles: publisher, hero, edition, series and
/// issue number all live outside the post body, in the page chrome.
final class PageContextTests: XCTestCase {

    private func page(_ fragment: String) throws -> String? {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path),
              let hit = names.filter({ $0.lowercased().contains(".htm") && $0.contains(fragment) })
                             .sorted(by: { $0.count < $1.count }).first
        else { return nil }
        return try String(contentsOf: dir.appendingPathComponent(hit), encoding: .utf8)
    }

    func testExtractsTopicAndBreadcrumbTrail() throws {
        guard let html = try page("Zagor - ZLATNA") else { throw XCTSkip("fixture missing") }
        let context = Catalog.pageContext(in: html)
        XCTAssertEqual(context.topic, "Zagor - ZLATNA SERIJA - ZS i LMS")
        XCTAssertEqual(context.trail, ["BONELLI", "Zagor Te-Nay", "ZS i LMS"])
        XCTAssertEqual(context.hero, "Zagor Te-Nay")
        XCTAssertEqual(context.publisher, "BONELLI")
    }

    /// The site name and the section every topic sits under are on every page,
    /// so indexing them would match everything and rank nothing.
    func testDropsUniversalCrumbs() throws {
        guard let html = try page("Kolorka -") else { throw XCTSkip("fixture missing") }
        let trail = Catalog.pageContext(in: html).trail
        XCTAssertFalse(trail.contains("Stripzona"))
        XCTAssertFalse(trail.contains("STRIPOVI NA EX-YU JEZICIMA"))
        XCTAssertTrue(trail.contains("Strip Revije"), "\(trail)")
    }

    func testMissingChromeDegradesQuietly() {
        let context = Catalog.pageContext(in: "<html><body>no title, no crumbs</body></html>")
        XCTAssertNil(context.topic)
        XCTAssertTrue(context.trail.isEmpty)
        XCTAssertEqual(context.searchableText, "")
    }
}

final class SearchScopeTests: XCTestCase {

    private func loadedStore() throws -> Store {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path)
        else { throw XCTSkip("fixtures missing") }

        let store = try Store()
        var loaded = 0
        for fragment in ["Zagor - ZLATNA", "Mister No", "Kolorka -", "Alan Ford"] {
            guard let hit = names.filter({ $0.contains(fragment) && $0.lowercased().contains(".htm") })
                                 .sorted(by: { $0.count < $1.count }).first,
                  let html = try? String(contentsOf: dir.appendingPathComponent(hit),
                                         encoding: .utf8) else { continue }
            try store.ingest(html: html, source: fragment)
            loaded += 1
        }
        try XCTSkipIf(loaded < 4, "fixtures incomplete")
        return store
    }

    /// Exactly the queries the app promises in its search placeholder.
    func testFindsByPublisherHeroEditionAndSeries() throws {
        let store = try loadedStore()
        let queries = [
            "bonelli",          // publisher, from the breadcrumb
            "zagor",            // hero
            "zlatna serija",    // edition, from the topic title
            "zs",               // edition abbreviation, from the forum name
            "lms",              // edition abbreviation
            "lunov magnus",     // edition spelled out
            "mister no",        // hero
            "fibra",            // publisher, from the topic title
            "kolorka",          // series
            "alan ford",        // hero
        ]
        for q in queries {
            XCTAssertFalse(try store.search(q).isEmpty, "no results for “\(q)”")
        }
    }

    /// Issue numbers must be searchable, including where the code stores a
    /// zero-padded form ("0151") that a prefix query for "151" would miss.
    ///
    /// The number is taken from the corpus rather than hardcoded — an earlier
    /// version of this test asserted 151, which is not in these pages, so it
    /// failed for a reason that had nothing to do with the feature.
    func testFindsByIssueNumber() throws {
        let store = try loadedStore()
        let sample = try XCTUnwrap(try store.recent(limit: 400).first { $0.number != nil },
                                   "no numbered issues in the corpus")
        let number = try XCTUnwrap(sample.number)
        let hits = try store.search(String(number))
        XCTAssertFalse(hits.isEmpty, "no results for issue number \(number)")
        XCTAssertTrue(hits.contains { $0.number == number },
                      "searching \(number) did not return issue \(number)")
    }

    /// A zero-padded code must still be reachable by the bare number.
    func testZeroPaddedCodeIsReachableByPlainNumber() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>MN_LMS_0151</div><div>http://www.mediafire.com/?FAKEKEY151</div>
            """)
        XCTAssertFalse(try store.search("151").isEmpty, "bare number missed a padded code")
        XCTAssertFalse(try store.search("0151").isEmpty, "padded form missed")
    }

    /// A code like MN_LMS_511 must be reachable by any of its parts.
    func testCodePartsAreIndexedSeparately() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>MN_LMS_511</div><div>http://www.mediafire.com/?FAKEKEY511</div>
            """)
        for q in ["mn", "lms", "511", "MN_LMS_511", "lunov"] {
            XCTAssertFalse(try store.search(q).isEmpty, "no results for “\(q)”")
        }
    }

    /// Narrowing still works: extra words must not widen the result set.
    func testMultipleTokensNarrow() throws {
        let store = try loadedStore()
        let broad = try store.search("zagor").count
        let narrow = try store.search("zagor kuca").count
        XCTAssertGreaterThan(broad, narrow)
        XCTAssertGreaterThan(narrow, 0)
    }

    /// Diacritic folding still applies across the wider index.
    func testFoldingStillApplies() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Kolorka - FIBRA - Vas upload razno - Stripzona</title>
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            """)
        XCTAssertFalse(try store.search("zasto").isEmpty)
        XCTAssertFalse(try store.search("Zašto").isEmpty)
    }

    /// A title recovered from a filename must not wipe the rest of the index.
    func testBackfillPreservesContextInIndex() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>MN_LMS_518</div><div>http://www.mediafire.com/?x0mrij299kyr947</div>
            """)
        let stub = StubTransport { req in
            HTTPResponse(status: 302, headers: [
                "Location": "http://www.mediafire.com/file/x0mrij299kyr947/"
                          + "LMS+518+-+Mister+No+-+Bubnjevi+u+dzungli.cbr/file"])
        }
        let expectation = expectation(description: "backfill")
        Task {
            try await store.backfillTitles(via: stub)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 5)

        XCTAssertEqual(try store.search("bubnjevi").first?.title, "Bubnjevi u dzungli")
        XCTAssertFalse(try store.search("lunov").isEmpty, "context lost when the title was set")
        XCTAssertFalse(try store.search("lms").isEmpty, "code lost when the title was set")
    }
}

final class CoverURLTests: XCTestCase {

    /// stripovi.com 301s http image requests to https, so an http cover URL
    /// costs two round-trips. On a 120-issue page that is 240 requests before
    /// the first cover renders.
    func testCoverURLsAreStoredAsHTTPS() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <img src="http://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg">
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let issue = try XCTUnwrap(try store.search("nasilje").first)
        let cover = try XCTUnwrap(issue.coverURL)
        XCTAssertTrue(cover.hasPrefix("https://"), "cover would pay a redirect: \(cover)")
        XCTAssertTrue(cover.hasSuffix("TN_ZG_ZS_13.jpg"))
    }

    /// An https source must be left alone rather than double-rewritten.
    func testHTTPSCoverIsUnchanged() {
        let covers = Catalog.covers(in:
            #"<img src="https://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_21.jpg">"#)
        XCTAssertEqual(covers[21], "https://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_21.jpg")
    }
}

/// The "Downloaded" filter.
final class DownloadedFilterTests: XCTestCase {

    /// 30 issues, with the only download last. A filter applied to the results
    /// of a capped query would return nothing; applied in SQL it finds it.
    private func populated() throws -> (Store, Int) {
        let store = try Store()
        var html = ""
        for n in 1...30 {
            html += "<div>\(String(format: "%03d", n))-Broj \(n)</div>"
                 +  "<div>http://www.mediafire.com/?FAKEKEY\(String(format: "%03d", n))</div>"
        }
        try store.ingest(html: html)
        let last = try XCTUnwrap(try store.recent(limit: 100).last)
        try store.recordDownload(issueID: last.id, mirrorURL: "http://x/1",
                                 path: URL(fileURLWithPath: "/tmp/x.cbz"), bytes: 10)
        return (store, last.id)
    }

    func testFilterFindsADownloadPastTheRowCap() throws {
        let (store, downloadedID) = try populated()
        let unfiltered = try store.recent(limit: 5)
        XCTAssertFalse(unfiltered.contains { $0.id == downloadedID },
                       "precondition: the download should fall past this cap")

        let filtered = try store.recent(limit: 5, downloadedOnly: true)
        XCTAssertEqual(filtered.map(\.id), [downloadedID])
    }

    func testFilterAppliesToSearchToo() throws {
        let (store, downloadedID) = try populated()
        XCTAssertGreaterThan(try store.search("broj", limit: 100).count, 1)
        let filtered = try store.search("broj", limit: 100, downloadedOnly: true)
        XCTAssertEqual(filtered.map(\.id), [downloadedID])
    }

    func testFilterIsEmptyWhenNothingIsDownloaded() throws {
        let store = try Store()
        try store.ingest(html: "<div>013-Nasilje</div><div>http://www.mediafire.com/?FAKE013</div>")
        XCTAssertTrue(try store.recent(limit: 50, downloadedOnly: true).isEmpty)
        XCTAssertFalse(try store.recent(limit: 50).isEmpty)
    }
}

/// How an issue is labelled on the shelf.
final class ShelfLabelTests: XCTestCase {

    private func issue(hero: String?, edition: String?, number: Int?) -> StoredIssue {
        StoredIssue(id: 1, code: "MN_LMS_511", number: number, title: "Dijamantska klopka",
                    series: nil, hero: hero, edition: edition, publisher: nil, style: .labeledBlock,
                    mirrorCount: 2, coverURL: nil, isDownloaded: false)
    }

    /// Several words become initials.
    func testMultiWordEditionBecomesInitials() {
        XCTAssertEqual(issue(hero: "Mister No", edition: "Lunov Magnus Strip",
                             number: 511).editionCode, "LMS")
        XCTAssertEqual(issue(hero: "Kit Teler", edition: "ZLATNA SERIJA",
                             number: 21).editionCode, "ZS")
        XCTAssertEqual(issue(hero: "Alan Ford", edition: "Super Strip Biblioteka",
                             number: 33).editionCode, "SSB")
    }

    /// A single word is used as it is, not reduced to one letter.
    func testSingleWordEditionIsKept() {
        XCTAssertEqual(issue(hero: "Alan Ford", edition: "Vjesnik", number: 1).editionCode,
                       "Vjesnik")
        XCTAssertEqual(issue(hero: "Kolorka", edition: "FIBRA", number: 3).editionCode, "FIBRA")
    }

    func testShelfMarkReadsAsEditionThenNumber() {
        XCTAssertEqual(issue(hero: "Mister No", edition: "Lunov Magnus Strip",
                             number: 511).shelfMark, "LMS 511")
    }

    /// Missing pieces must not produce "LMS " or a stray separator.
    func testShelfMarkDegradesCleanly() {
        XCTAssertEqual(issue(hero: nil, edition: nil, number: 7).shelfMark, "7")
        XCTAssertEqual(issue(hero: nil, edition: "Zlatna Serija", number: nil).shelfMark, "ZS")
        XCTAssertNil(issue(hero: nil, edition: nil, number: nil).shelfMark)
    }

    func testProvenanceIsHeroThenSeries() {
        XCTAssertEqual(issue(hero: "Mister No", edition: "Lunov Magnus Strip", number: 511)
                        .provenance, "Mister No, Lunov Magnus Strip")
        XCTAssertEqual(issue(hero: "Mister No", edition: nil, number: 1).provenance, "Mister No")
        XCTAssertNil(issue(hero: nil, edition: nil, number: 1).provenance)
    }
}

/// Hero names as readers actually use them.
final class HeroAliasTests: XCTestCase {

    func testZagorLosesItsRegisteredSuffixOnScreen() {
        XCTAssertEqual(PageContext.displayName(forHero: "Zagor Te-Nay"), "Zagor")
        // Folded matching, so punctuation and case cannot miss it.
        XCTAssertEqual(PageContext.displayName(forHero: "ZAGOR TE-NAY"), "Zagor")
        XCTAssertEqual(PageContext.displayName(forHero: "Zagor Te Nay"), "Zagor")
    }

    /// Every other hero passes through untouched.
    func testOtherHeroesAreUnchanged() {
        XCTAssertEqual(PageContext.displayName(forHero: "Mister No"), "Mister No")
        XCTAssertEqual(PageContext.displayName(forHero: "Alan Ford"), "Alan Ford")
        XCTAssertEqual(PageContext.displayName(forHero: "Zagor"), "Zagor")
    }

    /// End to end, on the real page.
    func testZagorPageReportsTheShortName() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let hit = names.first(where: { $0.contains("Zagor - ZLATNA") }),
              let html = try? String(contentsOf: dir.appendingPathComponent(hit),
                                     encoding: .utf8)
        else { throw XCTSkip("fixture missing") }

        let context = Catalog.pageContext(in: html)
        // Stored and indexed as the forum spells it, so searching the full
        // name still finds it...
        XCTAssertEqual(context.hero, "Zagor Te-Nay")
        XCTAssertTrue(context.searchableText.contains("Zagor Te-Nay"))
        XCTAssertEqual(context.publisher, "BONELLI")
        // ...and shortened only where a reader sees it.
        XCTAssertEqual(PageContext.displayName(forHero: context.hero!), "Zagor")
    }
}

/// The shelf must not silently stop partway through the library.
final class ResultLimitTests: XCTestCase {

    private func store(issues: Int) throws -> Store {
        let store = try Store()
        var html = ""
        for n in 1...issues {
            html += "<div>\(String(format: "%04d", n))-Broj \(n)</div>"
                 +  "<div>http://www.mediafire.com/?FAKEKEY\(String(format: "%04d", n))</div>"
        }
        try store.ingest(html: html)
        return store
    }

    func testNilLimitReturnsEverything() throws {
        let store = try store(issues: 250)
        XCTAssertEqual(store.issueCount, 250)
        XCTAssertEqual(try store.recent(limit: nil).count, 250)
        XCTAssertEqual(try store.search("broj", limit: nil).count, 250)
    }

    /// An explicit cap still works, for callers that want one.
    func testExplicitLimitStillApplies() throws {
        let store = try store(issues: 250)
        XCTAssertEqual(try store.recent(limit: 10).count, 10)
        XCTAssertEqual(try store.search("broj", limit: 10).count, 10)
    }

    /// The filter and an absent limit must compose.
    func testNilLimitWithDownloadedFilter() throws {
        let store = try store(issues: 250)
        XCTAssertTrue(try store.recent(limit: nil, downloadedOnly: true).isEmpty)
        XCTAssertEqual(try store.recent(limit: nil, downloadedOnly: false).count, 250)
    }

    /// A library far larger than anything on the forum still comes back whole,
    /// and quickly — this is the claim that removing the cap rests on.
    func testLargeLibraryIsReturnedWhole() throws {
        let store = try store(issues: 5_000)
        let started = Date()
        let all = try store.recent(limit: nil)
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(all.count, 5_000)
        XCTAssertLessThan(elapsed, 2.0, "loading the shelf took \(elapsed)s")
    }
}

/// What the reader's title bar says.
final class ReaderTitleTests: XCTestCase {

    private func issue(edition: String?, hero: String?, title: String?,
                       number: Int? = 511, code: String? = "MN_LMS_511") -> StoredIssue {
        StoredIssue(id: 1, code: code, number: number, title: title, series: nil,
                    hero: hero, edition: edition, publisher: nil, style: .labeledBlock,
                    mirrorCount: 2, coverURL: nil, isDownloaded: true)
    }

    func testFullTitleReadsSeriesNumberHeroThenName() {
        XCTAssertEqual(issue(edition: "Super Strip Biblioteka", hero: "Alan Ford",
                             title: "Grupa TNT", number: 1).readerTitle,
                       "SSB 1 · Alan Ford · Grupa TNT")
        XCTAssertEqual(issue(edition: "Lunov Magnus Strip", hero: "Mister No",
                             title: "Dijamantska klopka").readerTitle,
                       "LMS 511 · Mister No · Dijamantska klopka")
    }

    /// The display alias applies here too.
    func testHeroUsesItsShortName() {
        XCTAssertEqual(issue(edition: "Zlatna Serija", hero: "Zagor Te-Nay",
                             title: "Nasilje u Darkvudu", number: 13).readerTitle,
                       "ZS 13 · Zagor · Nasilje u Darkvudu")
    }

    /// Missing pieces are dropped, not left as dangling separators.
    func testMissingPiecesAreOmitted() {
        XCTAssertEqual(issue(edition: nil, hero: "Alan Ford",
                             title: "Grupa TNT", number: 1).readerTitle,
                       "1 · Alan Ford · Grupa TNT")
        XCTAssertEqual(issue(edition: "Zlatna Serija", hero: nil,
                             title: "Nasilje", number: 13).readerTitle,
                       "ZS 13 · Nasilje")
        XCTAssertEqual(issue(edition: "Zlatna Serija", hero: "Zagor",
                             title: "Nasilje", number: nil).readerTitle,
                       "ZS · Zagor · Nasilje")
    }

    /// With nothing to go on, the code is better than an empty bar.
    func testFallsBackToTheCode() {
        XCTAssertEqual(issue(edition: nil, hero: nil, title: nil, number: nil).readerTitle,
                       "MN_LMS_511")
        XCTAssertEqual(issue(edition: nil, hero: nil, title: nil,
                             number: nil, code: nil).readerTitle, "Comic")
    }
}

/// Editions whose initials are not what readers call them.
final class EditionCodeTests: XCTestCase {

    /// Spelled out rather than abbreviated: it is a fan scanlation exclusive
    /// to the forum, not a printed edition like the others.
    func testStripzonaScanlationIsSpelledOut() {
        XCTAssertEqual(PageContext.code(forEdition: "Stripzona Scanlation"), "SZScanlation")
        // Folded, so the forum's shouted spelling resolves the same way.
        XCTAssertEqual(PageContext.code(forEdition: "STRIPZONA SCANLATION"), "SZScanlation")
    }

    /// Everything else still derives from the words themselves.
    func testOtherEditionsAreUnaffected() {
        XCTAssertEqual(PageContext.code(forEdition: "Lunov Magnus Strip"), "LMS")
        XCTAssertEqual(PageContext.code(forEdition: "ZLATNA SERIJA"), "ZS")
        XCTAssertEqual(PageContext.code(forEdition: "Super Strip Biblioteka"), "SSB")
        XCTAssertEqual(PageContext.code(forEdition: "Vjesnik"), "Vjesnik")
        XCTAssertNil(PageContext.code(forEdition: "   "))
    }

    /// The alias must reach the shelf, not just the parser.
    func testStoredIssueUsesTheAlias() {
        let issue = StoredIssue(id: 1, code: "JD_01", number: 1, title: "Takav je bio Alan Skot",
                                series: nil, hero: "Dzudas", edition: "STRIPZONA SCANLATION", publisher: nil,
                                style: .labeledBlock, mirrorCount: 2, coverURL: nil,
                                isDownloaded: false)
        XCTAssertEqual(issue.editionCode, "SZScanlation")
        XCTAssertEqual(issue.shelfMark, "SZScanlation 1")
        XCTAssertEqual(issue.readerTitle,
                       "SZScanlation 1 · Dzudas · Takav je bio Alan Skot")
    }
}

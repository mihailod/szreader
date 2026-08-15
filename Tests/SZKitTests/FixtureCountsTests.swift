import XCTest
@testable import SZKit

/// Proves the Swift port reproduces the Python spike's measurements exactly.
///
/// Fixtures are read from `spike/pages/` via #filePath rather than copied into
/// the repo — no duplication of the saved pages, and deleting them makes these
/// tests skip with a clear message instead of failing.
final class FixtureCountsTests: XCTestCase {

    private static var pagesDir: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/SZKitTests/<this file>
            .deletingLastPathComponent()          // SZKitTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // package root
            .appendingPathComponent("spike/pages")
    }

    /// (filename fragment, total links, attributed) — measured by survey.py.
    ///
    /// Kosmoplov and Galaksija share three pages of one topic, and the first
    /// leaves 22 links unattributed: notes the posters left between them —
    /// "Fali stranica 37.", "Linkovi za Galaksiju 101" — which read as a
    /// series followed by a number and would otherwise claim the next link.
    ///
    /// Sirius leaves six links unattributed on purpose — collected volumes
    /// covering ranges of issues. Its seven double numbers ("121/122") are
    /// one issue each, and "YU SIRIUS", the special that closes the run, is
    /// an issue with no number at all.
    ///
    /// Johnny Logan came later than the spike and is measured here rather than
    /// by it. Its one unattributed link is a second, "fixed" scan of issue 1
    /// posted on its own line with no label of its own — an extra mirror, not
    /// a missing comic.
    ///
    /// Two entries have moved past the spike, and deliberately: the spike could
    /// not read labels that put the number after a dashed name ("Alef - SF
    /// magazin 01"), so it left most of Alef unattributed. Both pages were
    /// checked issue by issue after the change — Alef parses 1…26 complete,
    /// Martin Mystere 1…78 — with no implausible numbers, so these are links
    /// the spike missed rather than new mis-parses.
    private let expected: [(String, Int, Int)] = [
        ("Alan Ford",        70,   70),
        ("Alef - Ostale",    51,   50),
        ("Alef - pdf",       26,   26),
        ("Kosmoplov - pdf",  24,   24),
        // Re-saved 14 Aug 2026 with more posts unlocked (102 links became
        // 172) and joined by a second topic page: together 1…190.
        ("Galaksija - pdf - Casopisi", 172, 172),
        ("Galaksija - pdf - Page 2",    20,  20),
        ("Asteriks",         20,   20),
        ("Diabolik",          18,   18),
        ("Vjesnik, 1987-1988", 40,   40),
        ("Kriminal",           6,    6),
        ("Satanik",            6,    6),
        ("Dzudas - LUNOV",   22,   22),
        ("Dzudas - STRIPZONA", 33,  33),
        ("Erotski Roman",    186,  184),
        ("Gigant",           79,   79),
        ("Johnny Logan",     22,   21),
        ("Kapetan Miki",     67,   67),
        ("Kosmoplov i Galaksija - obrade - Casopisi", 268, 246),
        ("obrade - Page 2",   63,   63),
        ("obrade - Page 3",   40,   40),
        // Re-saved 13 Aug 2026 with more posts unlocked (37 links became
        // 157), and joined by two further topic pages on 14 Aug. The three
        // read as one run, 85…1102, every issue with a cover.
        ("Komandant Mark - Zlatna Serija - Komandant", 157, 157),
        ("Komandant Mark - Zlatna Serija - Page 2",    120, 120),
        ("Komandant Mark - Zlatna Serija - Page 3",     43,  43),
        // Martin Mystere and Kit Teler's Zlatna Serija page were re-saved on
        // 10 Aug 2026 with more of their content unlocked, so these are larger
        // than the spike measured. The fixtures changed, not the parser — each
        // page was checked for implausible numbers before these were moved.
        ("Ken Parker - FIBRA",    49,   49),
        ("Ken Parker - LIBELLUS", 79,   79),
        ("Ken Parker - SYSTEM",   25,   25),
        // Re-saved 15 Aug 2026 with more posts unlocked (82 links became
        // 137) and joined by two further topic pages: 8…996 as one run.
        ("Kit Teler - LUNOV MAGNUS STRIP - Kit",    137, 137),
        ("Kit Teler - LUNOV MAGNUS STRIP - Page 2", 148, 148),
        ("Kit Teler - LUNOV MAGNUS STRIP - Page 3", 102, 102),
        ("Kit Teler - ZLATNA", 15,  15),
        ("Kolorka -",        144,  144),
        ("Kolorka Specijal",  34,   34),
        ("Korto Malteze",     34,   34),
        ("Martin Mystere",   114,  109),
        ("Maxmagnus",         27,   27),
        ("Mister No",        268,  268),
        ("Orka -",            62,   62),
        ("Orka Specijal",     30,   30),
        ("Roto Biblioteka",  38,   38),
        ("Sirius",           164,  158),
        // Re-saved 13 Aug 2026 with more of its posts unlocked — 107 links
        // became 238 — and joined by two further topic pages. The three
        // read as one run, 128…995; see testVelikiBlekContinuesAcrossPages.
        ("Veliki Blek - Lunov Magnus Strip - Veliki", 238, 238),
        ("Veliki Blek - Lunov Magnus Strip - Page 2", 244, 244),
        ("Veliki Blek - Lunov Magnus Strip - Page 3",  36,  36),
        ("Zagor - LUNOV",     43,   43),
        ("Zagor - ZLATNA SERIJA - ZS", 125, 125),
        ("ZLATNA SERIJA - Page 2",      120, 120),
        ("ZLATNA SERIJA - Page 3",       76,  76),
    ]

    private func html(matching fragment: String) throws -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.pagesDir.path) else { return nil }
        // A fragment matching two saved pages is a trap: the shorter filename
        // wins, so adding a page can quietly point an old expectation at it.
        // "Alef" started meaning "Alef - pdf" the moment that was saved.
        let matching = names.filter { $0.lowercased().contains(".htm") && $0.contains(fragment) }
        XCTAssertLessThan(matching.count, 2,
                          "“\(fragment)” matches \(matching.count) saved pages: \(matching.sorted())")
        // Longest match wins, so "Kolorka -" doesn't shadow "Kolorka Specijal".
        let hit = names
            .filter { $0.lowercased().contains(".htm") && $0.contains(fragment) }
            .sorted { $0.count < $1.count }
            .first
        guard let hit else { return nil }
        return try String(contentsOf: Self.pagesDir.appendingPathComponent(hit), encoding: .utf8)
    }

    func testPerPageCoverageMatchesPythonSpike() throws {
        var checked = 0
        for (fragment, total, attributed) in expected {
            guard let page = try html(matching: fragment) else { continue }
            let cov = Catalog.coverage(Catalog.links(in: page))
            XCTAssertEqual(cov.total, total, "link count for \(fragment)")
            XCTAssertEqual(cov.attributed, attributed, "attributed for \(fragment)")
            checked += 1
        }
        try XCTSkipIf(checked == 0, "no fixtures in spike/pages — nothing to verify")
        XCTAssertEqual(checked, expected.count, "some fixtures are missing")
    }

    func testCorpusTotals() throws {
        var total = 0, attributed = 0, found = 0
        for (fragment, _, _) in expected {
            guard let page = try html(matching: fragment) else { continue }
            let cov = Catalog.coverage(Catalog.links(in: page))
            total += cov.total; attributed += cov.attributed; found += 1
        }
        try XCTSkipIf(found < expected.count, "fixture set incomplete")
        XCTAssertEqual(total, 3905)
        XCTAssertEqual(attributed, 3868)
    }

    /// A long run split across forum pages has to read as one series.
    ///
    /// Each later page is a separate topic page with its own header, so
    /// nothing but the parse ties them to the first: same hero, same edition,
    /// and numbering that carries on rather than restarting. If any of those
    /// drifted, the shelf would show two Zagors, or two issue 561s. The run
    /// hands over at 560/561 and again at 908/909.
    func testZlatnaSerijaContinuesAcrossPages() throws {
        guard let one = try html(matching: "Zagor - ZLATNA SERIJA - ZS"),
              let two = try html(matching: "ZLATNA SERIJA - Page 2"),
              let three = try html(matching: "ZLATNA SERIJA - Page 3")
        else { throw XCTSkip("Zagor fixtures not present") }

        let store = try Store()
        try store.ingest(html: one)
        let afterFirst = try store.recent(limit: nil).count
        try store.ingest(html: two)
        let afterSecond = try store.recent(limit: nil).count
        try store.ingest(html: three)
        let rows = try store.recent(limit: nil)

        XCTAssertEqual(Set(rows.compactMap(\.edition)), ["ZLATNA SERIJA"],
                       "the three pages disagree about the edition")
        XCTAssertEqual(rows.count, 302)
        XCTAssertGreaterThan(afterSecond, afterFirst, "the second page added nothing")
        XCTAssertGreaterThan(rows.count, afterSecond, "the third page added nothing")

        let numbers = rows.compactMap(\.number).sorted()
        XCTAssertEqual(numbers.first, 13)
        XCTAssertEqual(numbers.last, 1101)
        XCTAssertEqual(Set(numbers).count, numbers.count, "an issue number appears twice")

        // Importing the same pages again is not a second copy of the run.
        try store.ingest(html: one)
        try store.ingest(html: two)
        try store.ingest(html: three)
        XCTAssertEqual(try store.recent(limit: nil).count, 302, "re-import duplicated the run")
    }

    /// The same, for a series whose edition is not shouted.
    ///
    /// Zagor survived the forum's pagination by luck: "ZLATNA SERIJA" is in
    /// capitals, so the shouted-part rule reached it before the topic's
    /// trailing "Page 2" could be mistaken for the edition. Veliki Blek's
    /// "Lunov Magnus Strip" is title case and had no such protection — its
    /// three pages arrived as three separate series called "Lunov Magnus
    /// Strip", "Page 2" and "Page 3", a hundred issues each.
    func testVelikiBlekContinuesAcrossPages() throws {
        guard let one = try html(matching: "Veliki Blek - Lunov Magnus Strip - Veliki"),
              let two = try html(matching: "Veliki Blek - Lunov Magnus Strip - Page 2"),
              let three = try html(matching: "Veliki Blek - Lunov Magnus Strip - Page 3")
        else { throw XCTSkip("Veliki Blek fixtures not present") }

        let store = try Store()
        for page in [one, two, three] { try store.ingest(html: page) }
        let rows = try store.recent(limit: nil)

        XCTAssertEqual(Set(rows.compactMap(\.edition)), ["Lunov Magnus Strip"],
                       "the pagination marker leaked into the edition")
        // 258, not 259: the run once carried two rows that were not issues
        // — ")-SZ.cbr", the tail of a filename the URL pattern cut short,
        // and "cijeli strip", a note after a link that displaced LMS 349 —
        // and did not carry 349 itself.
        XCTAssertEqual(rows.count, 258)
        let numbers = rows.compactMap(\.number).sorted()
        XCTAssertEqual(numbers.first, 128)
        XCTAssertEqual(numbers.last, 995)
        XCTAssertEqual(Set(numbers).count, numbers.count, "an issue number appears twice")
    }

    /// Komandant Mark is the other title-case run split over forum pages,
    /// and it arrived after the pagination marker was already handled — so
    /// this is the check that the fix holds for a series it was not written
    /// against.
    func testKomandantMarkContinuesAcrossPages() throws {
        guard let one = try html(matching: "Komandant Mark - Zlatna Serija - Komandant"),
              let two = try html(matching: "Komandant Mark - Zlatna Serija - Page 2"),
              let three = try html(matching: "Komandant Mark - Zlatna Serija - Page 3")
        else { throw XCTSkip("Komandant Mark fixtures not present") }

        let store = try Store()
        for page in [one, two, three] { try store.ingest(html: page) }
        let rows = try store.recent(limit: nil)

        XCTAssertEqual(Set(rows.compactMap(\.edition)), ["Zlatna Serija"])
        XCTAssertEqual(rows.count, 282)
        let numbers = rows.compactMap(\.number).sorted()
        XCTAssertEqual(numbers.first, 85)
        XCTAssertEqual(numbers.last, 1102)
        XCTAssertEqual(Set(numbers).count, numbers.count, "an issue number appears twice")
        // This run is the one page in the corpus where every issue has art.
        XCTAssertEqual(rows.filter { $0.coverURL != nil }.count, 282)
    }

    /// Entity decoding is not optional: IPB writes `http&#58;//...`, and
    /// without unescaping a URL regex finds nothing at all.
    func testEntityDecodingIsApplied() {
        let lines = HTMLText.plainLines("<pre>http&#58;//www.mediafire.com/?abc123</pre>")
        XCTAssertEqual(lines, ["http://www.mediafire.com/?abc123"])
    }

    /// Inline tags must not break a line; block tags must.
    func testInlineMarkupDoesNotShredALine() {
        let lines = HTMLText.plainLines("<div><b>Orka specijal 1</b> - <i>Eternaut</i></div>")
        XCTAssertEqual(lines, ["Orka specijal 1 - Eternaut"])
    }

    /// A tag whose attribute contains '>' must not split mid-tag and leak
    /// attribute soup into the text.
    func testTagWithAngleBracketInAttribute() {
        let lines = HTMLText.plainLines(
            "<img onerror='if(x.indexOf(1)>-1){y}' src='a.jpg'><div>Title</div>")
        XCTAssertEqual(lines, ["Title"])
    }
}

/// Two runs sharing one topic.
final class TwoSeriesInOneTopicTests: XCTestCase {

    /// Kosmoplov ran 1–24 and Galaksija numbers its own from 1, both on the
    /// same page. Neither has a title or a code, so with the series left out
    /// of the natural key they were the same twenty-four rows: the second to
    /// arrive was dropped and its links handed to the first, leaving a run
    /// that appeared to begin at 25.
    func testTwoSeriesKeepTheirOwnNumbering() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Kosmoplov i Galaksija - obrade - Casopisi - Stripzona</title>
            <span itemprop="title">Casopisi</span>
            <div>Kosmoplov 01 (rosko &amp; MickRC)</div>
            <div>https://mega.co.nz/#!FAKEKOS1!FAKEKEY</div>
            <div>Galaksija 01 (stvarni izgled) (drazen23)</div>
            <div>https://mega.co.nz/#!FAKEGAL1!FAKEKEY</div>
            """)
        let rows = try store.recent(limit: nil)
        XCTAssertEqual(rows.count, 2, "one series absorbed the other")
        XCTAssertEqual(Set(rows.compactMap(\.series)), ["Kosmoplov", "Galaksija"])
        // Each keeps its own link rather than one collecting both.
        XCTAssertEqual(rows.map(\.mirrorCount), [1, 1])
    }

    /// Re-importing still must not duplicate anything.
    func testReimportIsStillIdempotent() throws {
        let page = """
            <title>Kosmoplov i Galaksija - obrade - Casopisi - Stripzona</title>
            <span itemprop="title">Casopisi</span>
            <div>Galaksija 01 (stvarni izgled) (drazen23)</div>
            <div>https://mega.co.nz/#!FAKEGAL1!FAKEKEY</div>
            """
        let store = try Store()
        try store.ingest(html: page)
        try store.ingest(html: page)
        XCTAssertEqual(try store.recent(limit: nil).count, 1)
    }
}

/// What a topic gathering two runs is called.
final class CombinedTopicNamingTests: XCTestCase {

    /// "Kosmoplov i Galaksija" is where these were found, not what they are —
    /// and it reduces to "KIG", which names neither. Where the topic names
    /// the series inside itself, the series is the finer answer, so the shelf
    /// and the filters separate them.
    func testTheSeriesNamesTheIssueWhenTheTopicIsACompound() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Kosmoplov i Galaksija - obrade - Casopisi - Stripzona</title>
            <span itemprop="title">Casopisi</span>
            <div>Kosmoplov 01 (rosko &amp; MickRC)</div>
            <div>https://mega.co.nz/#!FAKEKOS1!FAKEKEY</div>
            <div>Galaksija 91 (drazen23)</div>
            <div>https://mega.co.nz/#!FAKEGAL91!FAKEKEY</div>
            """)
        let rows = try store.recent(limit: nil)
        XCTAssertEqual(Set(rows.compactMap(\.edition)), ["Kosmoplov", "Galaksija"])
        XCTAssertEqual(Set(rows.compactMap(\.shelfMark)), ["Kosmoplov 1", "Galaksija 91"])
    }

    /// A topic that does not name the series keeps its own name: Alef's
    /// issues are "Alef 1", not "ASM 1".
    func testAnOrdinaryTopicKeepsItsName() {
        XCTAssertEqual(Store.edition(of: "Alef - SF magazin", under: "Alef"), "Alef")
        XCTAssertEqual(Store.edition(of: "Mister No", under: "LUNOV MAGNUS STRIP"),
                       "LUNOV MAGNUS STRIP")
        // Nothing to prefer when the topic says nothing.
        XCTAssertNil(Store.edition(of: "Corto Maltese", under: nil))
    }
}

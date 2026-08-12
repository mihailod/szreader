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
        ("Alef",             51,   50),
        ("Asteriks",         20,   20),
        ("Dzudas",           33,   33),
        ("Gigant",           79,   79),
        ("Johnny Logan",     22,   21),
        ("Kapetan Miki",     67,   67),
        ("Komandant Mark",   37,   37),
        // Both Kit Teler pages and Martin Mystere were re-saved on 10 Aug 2026
        // with more of their content unlocked, so these are larger than the
        // spike measured. The fixtures changed, not the parser — each page was
        // checked for implausible numbers before these were moved.
        ("Kit Teler - LUNOV", 82,   82),
        ("Kit Teler - ZLATNA", 15,  15),
        ("Kolorka -",        144,  144),
        ("Kolorka Specijal",  34,   34),
        ("Korto Malteze",     34,   34),
        ("Martin Mystere",   114,  109),
        ("Mister No",        268,  268),
        ("Orka -",            62,   62),
        ("Orka Specijal",     30,   30),
        ("Zagor - LUNOV",     43,   43),
        ("Zagor - ZLATNA SERIJA - ZS", 125, 125),
        ("ZLATNA SERIJA - Page 2",      120, 120),
    ]

    private func html(matching fragment: String) throws -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.pagesDir.path) else { return nil }
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
        XCTAssertEqual(total, 1450)
        XCTAssertEqual(attributed, 1443)
    }

    /// A long run split across forum pages has to read as one series.
    ///
    /// The second page is a separate topic page with its own header, so
    /// nothing but the parse ties it to the first: same hero, same edition,
    /// and numbering that carries on rather than restarting. If any of those
    /// drifted, the shelf would show two Zagors, or two issue 561s.
    func testZlatnaSerijaContinuesAcrossPages() throws {
        guard let one = try html(matching: "Zagor - ZLATNA SERIJA - ZS"),
              let two = try html(matching: "ZLATNA SERIJA - Page 2")
        else { throw XCTSkip("Zagor fixtures not present") }

        let store = try Store()
        try store.ingest(html: one)
        let afterFirst = try store.recent(limit: nil).count
        try store.ingest(html: two)
        let rows = try store.recent(limit: nil)

        XCTAssertEqual(Set(rows.compactMap(\.edition)), ["ZLATNA SERIJA"],
                       "the two pages disagree about the edition")
        XCTAssertEqual(rows.count, 240)
        XCTAssertGreaterThan(rows.count, afterFirst, "the second page added nothing")

        let numbers = rows.compactMap(\.number).sorted()
        XCTAssertEqual(numbers.first, 13)
        XCTAssertEqual(numbers.last, 908)
        XCTAssertEqual(Set(numbers).count, numbers.count, "an issue number appears twice")

        // Importing the same pages again is not a second copy of the run.
        try store.ingest(html: one)
        try store.ingest(html: two)
        XCTAssertEqual(try store.recent(limit: nil).count, 240, "re-import duplicated the run")
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

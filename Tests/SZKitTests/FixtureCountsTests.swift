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
    /// Two entries have moved past the spike, and deliberately: the spike could
    /// not read labels that put the number after a dashed name ("Alef - SF
    /// magazin 01"), so it left most of Alef unattributed. Both pages were
    /// checked issue by issue after the change — Alef parses 1…26 complete,
    /// Martin Mystere 1…78 — with no implausible numbers, so these are links
    /// the spike missed rather than new mis-parses.
    private let expected: [(String, Int, Int)] = [
        ("Alan Ford",       70,  70),
        ("Alef",            51,  50),
        ("Asteriks",        20,  20),
        ("Dzudas",          33,  33),
        // Mostly locked (250 hidden blocks) — the like quota ran out. The six
        // visible links still parse, so it stays in the corpus.
        ("Kit Teler - LUNOV", 6,   6),
        ("Kolorka -",      144, 144),
        ("Kolorka Specijal", 34, 34),
        ("Korto Malteze",   34,   0),
        ("Martin Mystere",  84,  79),
        ("Mister No",      268, 268),
        ("Orka -",          62,  62),
        ("Orka Specijal",   30,  30),
        ("Zagor - LUNOV",   43,  43),
        ("Zagor - ZLATNA", 125, 125),
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
        XCTAssertEqual(total, 1004)
        XCTAssertEqual(attributed, 964)
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

import XCTest
@testable import SZKit

/// Phase 1: ingest parsed issues into SQLite and find them again by title.
final class StoreTests: XCTestCase {

    private static var pagesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
    }

    private func page(_ fragment: String) throws -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: Self.pagesDir.path) else { return nil }
        guard let hit = names
            .filter({ $0.lowercased().contains(".htm") && $0.contains(fragment) })
            .sorted(by: { $0.count < $1.count }).first else { return nil }
        return try String(contentsOf: Self.pagesDir.appendingPathComponent(hit), encoding: .utf8)
    }

    // MARK: - Search, the phase 1 acceptance criterion

    /// Typing without diacritics must find a title that has them. This is the
    /// whole reason titles are stored folded as well as verbatim.
    func testSearchIgnoresDiacritics() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            <div>001 (SSB 089/001) - Šuplji zub - https://mega.nz/file/FAKEID#K</div>
            """)

        XCTAssertEqual(try store.search("suplji").first?.title, "Šuplji zub")
        XCTAssertEqual(try store.search("Šuplji").first?.title, "Šuplji zub")
        XCTAssertEqual(try store.search("zasto sam ubio").first?.title, "Zašto sam ubio Pierrea")
    }

    /// Prefixes should match, so results appear while you are still typing.
    func testPrefixSearch() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKE1</div>
            """)
        XCTAssertEqual(try store.search("dark").first?.title, "Nasilje u Darkvudu")
        XCTAssertEqual(try store.search("nas dark").first?.title, "Nasilje u Darkvudu")
        XCTAssertTrue(try store.search("zagor").isEmpty)
    }

    func testMirrorsAreGroupedUnderOneIssue() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>021-Kuca uzasa</div>
            <div>http://www.mediafire.com/?FAKE21A</div>
            <div>https://mega.nz/file/FAKE21B#K</div>
            """)
        let hit = try XCTUnwrap(try store.search("kuca uzasa").first)
        XCTAssertEqual(hit.mirrorCount, 2)
        XCTAssertEqual(try store.mirrors(forIssue: hit.id).map(\.host),
                       ["mediafire.com", "mega.nz"])
        XCTAssertEqual(try store.mirrors(forIssue: hit.id).map(\.ordinal), [0, 1])
    }

    /// Re-importing a page after liking more posts must not duplicate what is
    /// already there — the like quota makes re-imports routine.
    func testReimportIsIdempotent() throws {
        let store = try Store()
        let html = """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKE1</div>
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKE2</div>
            """
        let first = try store.ingest(html: html)
        let second = try store.ingest(html: html)
        XCTAssertEqual(first.issues, 2)
        XCTAssertEqual(first.mirrors, 2)
        XCTAssertEqual(second.issues, 0, "second import added issues")
        XCTAssertEqual(second.mirrors, 0, "second import added mirrors")
        XCTAssertEqual(store.issueCount, 2)
    }

    /// A stale label produces plausible but wrong titles. Those must never
    /// reach the library — a wrong title is worse than a missing one.
    func testSuspectGroupsAreNotStored() throws {
        var html = "<div>013-Some Title</div>"
        for i in 0..<10 { html += "<div>http://www.mediafire.com/?FAKE\(i)</div>" }
        let store = try Store()
        let result = try store.ingest(html: html)
        XCTAssertEqual(result.issues, 0)
        XCTAssertEqual(store.issueCount, 0)
    }

    /// labeledBlock posts carry a code but no title. They must still be stored
    /// and findable by code; their titles arrive in phase 2 from filenames.
    func testCodeOnlyIssuesAreStoredAndFindable() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_511</div><div>http://www.mediafire.com/?FAKEA</div>
            """)
        let hit = try XCTUnwrap(try store.search("mn lms 511").first)
        XCTAssertEqual(hit.code, "MN_LMS_511")
        XCTAssertEqual(hit.number, 511)
        XCTAssertNil(hit.title)
    }

    // MARK: - Against the real corpus

    func testIngestRealPages() throws {
        let store = try Store()
        var pages = 0
        for fragment in ["Zagor - ZLATNA", "Mister No", "Alan Ford", "Kolorka -"] {
            guard let html = try page(fragment) else { continue }
            try store.ingest(html: html, source: fragment)
            pages += 1
        }
        try XCTSkipIf(pages < 4, "fixtures missing")
        print("[store] \(pages) pages -> \(store.issueCount) issues, \(store.mirrorCount) mirrors")
        for q in ["nasilje", "kuca uzasa", "grupa tnt", "zasto sam ubio", "suplji"] {
            let hits = try store.search(q, limit: 3)
            let shown = hits.map { "\($0.title ?? $0.code ?? "?")" }.joined(separator: " | ")
            print("[search] \(q.padding(toLength: 16, withPad: " ", startingAt: 0)) -> \(hits.count): \(shown)")
        }

        // Every stored issue must have at least one mirror to be useful.
        XCTAssertGreaterThan(store.issueCount, 300)
        XCTAssertGreaterThanOrEqual(store.mirrorCount, store.issueCount)

        // Titles that appear inline on those pages are findable without diacritics.
        XCTAssertEqual(try store.search("nasilje u darkvudu").first?.title, "Nasilje u Darkvudu")
        XCTAssertFalse(try store.search("kuca uzasa").isEmpty)
        XCTAssertFalse(try store.search("grupa tnt").isEmpty)

        // Mister No is labeledBlock: codes present, titles absent until phase 2.
        let mn = try XCTUnwrap(try store.search("mn lms 511").first)
        XCTAssertEqual(mn.code, "MN_LMS_511")
        XCTAssertNil(mn.title)
    }

    func testEmptyQueryReturnsNothing() throws {
        let store = try Store()
        try store.ingest(html: "<div>013-Title</div><div>http://www.mediafire.com/?FAKE</div>")
        XCTAssertTrue(try store.search("").isEmpty)
        XCTAssertTrue(try store.search("   ").isEmpty)
        XCTAssertTrue(try store.search("!!!").isEmpty)   // folds away to nothing
    }
}

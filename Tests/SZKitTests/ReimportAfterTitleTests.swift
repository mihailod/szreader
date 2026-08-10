import XCTest
@testable import SZKit

/// Re-importing a page after any row has been modified.
///
/// `changes()` reports the rows touched by the last statement that *modified*
/// something — an `INSERT OR IGNORE` that ignores leaves the previous count
/// standing. So once the backfill has named an issue (an UPDATE, which does
/// modify), the next import reads that 1 and concludes it inserted a new row,
/// then writes a second FTS entry for a rowid that already has one.
final class ReimportAfterTitleTests: XCTestCase {

    private func fileStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Store(path: dir.appendingPathComponent("library.sqlite").path)
    }

    private let page = """
        <div>MN_LMS_511</div><div>http://www.mediafire.com/?FAKEKEY511</div>
        <div>MN_LMS_513</div><div>http://www.mediafire.com/?FAKEKEY513</div>
        <div>MN_LMS_517</div><div>http://www.mediafire.com/?FAKEKEY517</div>
        """

    /// Naming every issue, then re-importing the same page.
    ///
    /// `setTitle` is what the backfill does on success. If it rewrites the
    /// row's identity, the re-imported label no longer matches the row it
    /// created and the import inserts the whole page a second time.
    func testReimportAfterEveryIssueWasNamed() throws {
        let store = try fileStore()
        _ = try store.importPage(html: page, source: "first")
        let before = store.issueCount
        XCTAssertEqual(before, 3, "precondition")

        for issue in try store.recent() {
            try store.setTitle(issueID: issue.id, title: "Naslov \(issue.number ?? 0)")
        }

        XCTAssertNoThrow(try store.importPage(html: page, source: "second"))
        XCTAssertEqual(store.issueCount, before,
                       "re-import duplicated every issue the backfill had named")
    }

    /// The exact sequence from the device: import, resolve a name, import again.
    func testReimportAfterATitleWasResolved() throws {
        let store = try fileStore()
        _ = try store.importPage(html: page, source: "first")
        let issue = try XCTUnwrap(try store.recent().first)

        // What the backfill does when it names an issue.
        try store.setTitle(issueID: issue.id, title: "DIJAMANTSKA KLOPKA")

        // Every issue already exists, so every INSERT OR IGNORE is ignored.
        XCTAssertNoThrow(try store.importPage(html: page, source: "second"))
    }

    /// The index must not gain duplicate rows either — a silently doubled entry
    /// would return the same issue twice from every search.
    func testIndexHasOneRowPerIssue() throws {
        let store = try fileStore()
        _ = try store.importPage(html: page, source: "first")
        let issue = try XCTUnwrap(try store.recent().first)
        try store.setTitle(issueID: issue.id, title: "DIJAMANTSKA KLOPKA")
        _ = try? store.importPage(html: page, source: "second")

        let indexed = try store.db.scalarInt("SELECT COUNT(*) FROM issue_fts")
        XCTAssertEqual(indexed, store.issueCount, "FTS index out of step with the issues")

        let hits = try store.search("dijamantska", limit: 50)
        XCTAssertEqual(hits.count, 1, "duplicate index rows return the issue twice")
    }
}

/// Healing libraries already damaged by the identity bug.
final class DuplicateHealingTests: XCTestCase {

    private func path() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("library.sqlite").path
    }

    /// A duplicate has no mirrors of its own, because `mirror.url` is UNIQUE
    /// and the re-import's inserts were ignored.
    func testMirrorlessDuplicateIsRemovedOnOpen() throws {
        let file = try path()
        let store = try Store(path: file)
        try store.ingest(html:
            "<div>MN_LMS_511</div><div>http://www.mediafire.com/?FAKEKEY511</div>")
        let original = try XCTUnwrap(try store.recent().first)

        // Exactly what the old bug produced: same code and number, no mirrors.
        try store.db.run("""
            INSERT INTO issue (code, number, title, title_folded, style, search_text)
            VALUES ('MN_LMS_511', 511, NULL, 'different folded value', 'labeledBlock', 'x')
            """)
        XCTAssertEqual(store.issueCount, 2, "precondition: duplicate present")

        let reopened = try Store(path: file)
        XCTAssertEqual(reopened.issueCount, 1, "duplicate survived the migration")
        XCTAssertEqual(try reopened.recent().first?.id, original.id, "kept the wrong row")
    }

    /// An entry with no links is not a duplicate and must survive.
    func testLinklessIssueIsNotDeleted() throws {
        let file = try path()
        let store = try Store(path: file)
        try store.db.run("""
            INSERT INTO issue (code, number, title, title_folded, style, search_text)
            VALUES ('SOLO_001', 1, 'Sam', 'sam', 'labeledBlock', 'sam')
            """)
        XCTAssertEqual(try Store(path: file).issueCount, 1, "a link-less entry was deleted")
    }
}

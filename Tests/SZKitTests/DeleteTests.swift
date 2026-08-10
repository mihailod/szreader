import XCTest
@testable import SZKit

final class DeleteTests: XCTestCase {

    private func populated() throws -> Store {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
            <div>021-Kuca uzasa</div>
            <div>http://www.mediafire.com/?FAKEKEY21A</div>
            <div>https://mega.nz/file/FAKEID21B#FAKEKEY</div>
            """)
        return store
    }

    func testDeleteRemovesOnlyThatIssue() throws {
        let store = try populated()
        XCTAssertEqual(store.issueCount, 3)
        let target = try XCTUnwrap(try store.search("klark").first)

        try store.delete(issueID: target.id)

        XCTAssertEqual(store.issueCount, 2)
        XCTAssertFalse(try store.search("nasilje").isEmpty)
        XCTAssertFalse(try store.search("kuca").isEmpty)
    }

    /// FTS is a virtual table with no foreign keys, so a deleted issue stays
    /// searchable unless its index row is removed explicitly — the result is a
    /// library that returns comics it no longer has.
    func testDeleteAlsoClearsTheSearchIndex() throws {
        let store = try populated()
        let target = try XCTUnwrap(try store.search("klark").first)
        try store.delete(issueID: target.id)
        XCTAssertTrue(try store.search("klark").isEmpty, "deleted issue still searchable")
    }

    func testDeleteCascadesToMirrors() throws {
        let store = try populated()
        let target = try XCTUnwrap(try store.search("kuca").first)
        XCTAssertEqual(target.mirrorCount, 2)
        let before = store.mirrorCount

        try store.delete(issueID: target.id)

        XCTAssertEqual(store.mirrorCount, before - 2, "mirrors outlived their issue")
        XCTAssertTrue(try store.mirrors(forIssue: target.id).isEmpty)
    }

    /// The downloaded archive is on disk, which the database cannot cascade to.
    func testDeleteReportsTheDownloadedFile() throws {
        let store = try populated()
        let target = try XCTUnwrap(try store.search("nasilje").first)
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).cbz")
        try store.recordDownload(issueID: target.id, mirrorURL: "http://x/y",
                                 path: path, bytes: 1234)

        let orphan = try store.delete(issueID: target.id)
        XCTAssertEqual(orphan, path, "caller was not told which file to remove")
        XCTAssertEqual(store.downloadedCount, 0)
    }

    func testDeleteAllEmptiesEverything() throws {
        let store = try populated()
        let target = try XCTUnwrap(try store.search("kuca").first)
        try store.recordDownload(issueID: target.id, mirrorURL: "http://x/y",
                                 path: URL(fileURLWithPath: "/tmp/a.cbz"), bytes: 1)

        let files = try store.deleteAll()

        XCTAssertEqual(store.issueCount, 0)
        XCTAssertEqual(store.mirrorCount, 0)
        XCTAssertEqual(store.downloadedCount, 0)
        XCTAssertEqual(files.map(\.lastPathComponent), ["a.cbz"])
        XCTAssertTrue(try store.search("zagor").isEmpty)
        XCTAssertTrue(try store.recent().isEmpty)
    }

    /// Deleting must not poison the store: re-importing has to work after.
    func testLibraryIsUsableAfterDeleteAll() throws {
        let store = try populated()
        try store.deleteAll()
        let added = try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        XCTAssertEqual(added.issues, 1)
        XCTAssertFalse(try store.search("nasilje").isEmpty)
    }

    func testDeletingSomethingThatIsGoneIsHarmless() throws {
        let store = try populated()
        XCTAssertNoThrow(try store.delete(issueID: 9999))
        XCTAssertEqual(store.issueCount, 3)
    }
}

extension DeleteTests {

    /// "Remove All" reclaims disk without touching the catalogue — the point
    /// being that nothing has to be imported again, which costs a Like.
    func testRemoveAllDownloadsKeepsTheCatalogue() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
            """)
        for issue in try store.recent() {
            try store.recordDownload(issueID: issue.id, mirrorURL: "http://x/\(issue.id)",
                                     path: URL(fileURLWithPath: "/tmp/\(issue.id).cbz"), bytes: 10)
        }
        XCTAssertEqual(store.downloadedCount, 2)

        let files = try store.deleteAllDownloads()

        XCTAssertEqual(files.count, 2, "caller was not told which files to remove")
        XCTAssertEqual(store.downloadedCount, 0)
        XCTAssertEqual(store.issueCount, 2, "catalogue was lost")
        XCTAssertFalse(try store.search("nasilje").isEmpty, "still searchable")
        // Covers grey out again because nothing is downloaded any more.
        XCTAssertTrue(try store.recent().allSatisfy { !$0.isDownloaded })
    }

    /// The downloaded flag is what greys the artwork, so it has to track the
    /// download table in both directions.
    func testIsDownloadedReflectsTheDownloadTable() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let issue = try XCTUnwrap(try store.recent().first)
        XCTAssertFalse(issue.isDownloaded)

        try store.recordDownload(issueID: issue.id, mirrorURL: "http://x/y",
                                 path: URL(fileURLWithPath: "/tmp/a.cbz"), bytes: 1)
        XCTAssertTrue(try XCTUnwrap(try store.recent().first).isDownloaded)

        try store.deleteDownload(issueID: issue.id)
        XCTAssertFalse(try XCTUnwrap(try store.recent().first).isDownloaded)
        XCTAssertEqual(store.issueCount, 1, "deleting a download removed the issue")
    }
}

extension DeleteTests {

    private var threeIssuePage: String {
        """
        <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
        <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
        <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
        <div>021-Kuca uzasa</div><div>http://www.mediafire.com/?FAKEKEY021</div>
        """
    }

    /// Re-importing a page after deleting some of it must restore only what is
    /// missing, never duplicate what survived.
    ///
    /// The trap is the mirror table: URLs are UNIQUE, so if a delete left
    /// mirrors behind, the re-inserted issue would silently come back with
    /// zero mirrors and no way to download it.
    func testReimportAfterDeleteRestoresOnlyWhatIsMissing() throws {
        let store = try Store()
        XCTAssertEqual(try store.importPage(html: threeIssuePage).issues, 3)

        let doomed = try XCTUnwrap(try store.search("klark").first)
        try store.delete(issueID: doomed.id)
        XCTAssertEqual(store.issueCount, 2)

        let again = try store.importPage(html: threeIssuePage)
        XCTAssertEqual(again.issues, 1, "should re-add only the deleted issue")
        XCTAssertEqual(again.mirrors, 1, "the restored issue needs its mirror back")
        XCTAssertEqual(store.issueCount, 3, "duplicates crept in")

        let restored = try XCTUnwrap(try store.search("klark").first)
        XCTAssertEqual(restored.mirrorCount, 1, "restored issue has no mirror to download")
    }

    /// Removing a download changes nothing about the catalogue, so a re-import
    /// should be a complete no-op.
    func testReimportAfterRemovingDownloadsAddsNothing() throws {
        let store = try Store()
        try store.importPage(html: threeIssuePage)
        for issue in try store.recent() {
            try store.recordDownload(issueID: issue.id, mirrorURL: "http://x/\(issue.id)",
                                     path: URL(fileURLWithPath: "/tmp/\(issue.id).cbz"), bytes: 5)
        }
        try store.deleteAllDownloads()

        let again = try store.importPage(html: threeIssuePage)
        XCTAssertEqual(again.issues, 0)
        XCTAssertEqual(again.mirrors, 0)
        XCTAssertEqual(store.issueCount, 3)
    }

    /// After a full reset the app is genuinely back to its initial state, and
    /// importing the same page rebuilds it exactly.
    func testReimportAfterFullResetRebuildsEverything() throws {
        let store = try Store()
        let first = try store.importPage(html: threeIssuePage)
        try store.deleteAll()
        XCTAssertEqual(store.issueCount, 0)
        XCTAssertEqual(store.mirrorCount, 0)

        let rebuilt = try store.importPage(html: threeIssuePage)
        XCTAssertEqual(rebuilt.issues, first.issues)
        XCTAssertEqual(rebuilt.mirrors, first.mirrors)
        XCTAssertFalse(try store.search("kuca").isEmpty)
    }
}

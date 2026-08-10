import XCTest
@testable import SZKit

/// "Imported 0 issues" has three very different causes and the user can only
/// act on one of them. These tests pin which message each cause produces.
final class ImportReportTests: XCTestCase {

    func testFullyLockedPageTellsYouToLike() throws {
        let store = try Store()
        let html = """
            <div>MN_LMS_511</div>
            <div>Hidden Content You'll be able to see the hidden content once you like this post.</div>
            <div>MN_LMS_512</div>
            <div>Hidden Content You'll be able to see the hidden content once you like this post.</div>
            """
        let report = try store.importPage(html: html)
        XCTAssertEqual(report.links, 0)
        XCTAssertEqual(report.hiddenBlocks, 2)
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(report.advice?.contains("still hidden"), true, "\(report.advice ?? "nil")")
        XCTAssertEqual(report.advice?.contains("Like the posts"), true)
    }

    /// A forum index has no download blocks at all — a different problem from
    /// a locked topic, and worth saying so.
    func testPageWithNoBlocksAtAllSuggestsWrongPage() throws {
        let store = try Store()
        let report = try store.importPage(html: "<div>Welcome to the forum index</div>")
        XCTAssertEqual(report.hiddenBlocks, 0)
        XCTAssertEqual(report.advice?.contains("topic page"), true, "\(report.advice ?? "nil")")
    }

    /// The common real case: some posts liked, others not.
    func testPartiallyUnlockedPageReportsWhatRemains() throws {
        let store = try Store()
        let html = """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div>
            <div>Hidden Content — like this post.</div>
            """
        let report = try store.importPage(html: html)
        XCTAssertEqual(report.issues, 1)
        XCTAssertEqual(report.hiddenBlocks, 1)
        XCTAssertEqual(report.advice?.contains("still hidden"), true, "\(report.advice ?? "nil")")
    }

    func testCleanImportGivesNoAdvice() throws {
        let store = try Store()
        let html = """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
            """
        let report = try store.importPage(html: html)
        XCTAssertEqual(report.issues, 2)
        XCTAssertEqual(report.mirrors, 2)
        XCTAssertNil(report.advice)
    }

    /// Skipped links are reported rather than silently dropped — they are the
    /// ones a stale label would otherwise have mislabelled.
    func testSkippedLinksAreSurfaced() throws {
        let store = try Store()
        var html = "<div>013-Some Title</div>"
        for i in 0..<10 { html += "<div>http://www.mediafire.com/?FAKE\(i)</div>" }
        let report = try store.importPage(html: html)
        XCTAssertEqual(report.links, 10)
        XCTAssertEqual(report.attributed, 0)
        XCTAssertEqual(report.issues, 0)
        XCTAssertEqual(report.advice?.contains("could not be matched"), true,
                       "\(report.advice ?? "nil")")
    }

    /// Re-importing after liking more posts is the normal workflow, because the
    /// daily like quota unlocks a topic in batches.
    func testReimportAddsOnlyWhatIsNew() throws {
        let store = try Store()
        let first = """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """
        let second = first + """
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
            """
        XCTAssertEqual(try store.importPage(html: first).issues, 1)
        let again = try store.importPage(html: second)
        XCTAssertEqual(again.issues, 1, "should add only the newly unlocked issue")
        XCTAssertEqual(again.mirrors, 1)
        XCTAssertEqual(store.issueCount, 2)
    }
}

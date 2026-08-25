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
        XCTAssertEqual(report.advice?.contains("all download links are hidden"), true,
                       "\(report.advice ?? "nil")")
        XCTAssertEqual(report.advice?.contains("[LIKE THIS]"), true,
                       "the message names the forum's own button")
    }

    /// A forum index has no download blocks at all — a different problem from
    /// a locked topic, and worth saying so.
    func testPageWithNoBlocksAtAllSuggestsWrongPage() throws {
        let store = try Store()
        let report = try store.importPage(html: "<div>Welcome to the forum index</div>")
        XCTAssertEqual(report.hiddenBlocks, 0)
        // Not just "topic page": both messages say that now, and the point of
        // this one is that there is nothing on the page to unlock either.
        XCTAssertEqual(report.advice?.contains("not on a topic page at all"), true,
                       "\(report.advice ?? "nil")")
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

    /// The commonest empty import of all: the same page a second time.
    ///
    /// It used to fall through to no advice at all, which left the message
    /// reading "2 of 2 links matched an issue" — true, and no answer to the
    /// only question being asked, which is why nothing happened.
    func testAnAlreadyImportedPageSaysSo() throws {
        let store = try Store()
        let html = """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
            """
        XCTAssertFalse(try store.importPage(html: html).isEmpty)

        let again = try store.importPage(html: html)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.advice, "Everything on this page is already in your library.")
    }

    /// Already imported, with more still locked — the second half is the part
    /// there is something to do about.
    func testAnAlreadyImportedPageStillPointsAtWhatIsLocked() throws {
        let store = try Store()
        let html = """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div>
            <div>Hidden Content — like this post.</div>
            """
        XCTAssertFalse(try store.importPage(html: html).isEmpty)

        let again = try store.importPage(html: html)
        XCTAssertTrue(again.isEmpty)
        XCTAssertEqual(again.advice?.contains("already in your library"), true,
                       "\(again.advice ?? "nil")")
        XCTAssertEqual(again.advice?.contains("still hidden"), true,
                       "\(again.advice ?? "nil")")
    }

    /// Every empty import has something to say. The popup the shelf shows for
    /// one has nothing else to fall back on.
    func testEveryEmptyImportHasAdvice() throws {
        let store = try Store()
        let pages = [
            "<div>Welcome to the forum index</div>",
            "<div>MN_LMS_511</div><div>Hidden Content — like this post.</div>",
            "<div>013-Some Title</div><div>http://www.mediafire.com/?FAKE0</div>"
                + "<div>http://www.mediafire.com/?FAKE1</div>",
        ]
        for html in pages {
            let report = try store.importPage(html: html)
            guard report.isEmpty else { continue }
            XCTAssertNotNil(report.advice, "no reason given for \(html)")
        }
        // And the same page twice, which is the fourth way to import nothing.
        let twice = "<div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>"
        _ = try store.importPage(html: twice)
        XCTAssertNotNil(try store.importPage(html: twice).advice)
    }
}

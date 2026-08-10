import XCTest
@testable import SZKit

/// Phase 2's payoff: `labeledBlock` issues arrive with a code and no title,
/// and probing their mirrors gives them a name you can search for.
final class BackfillTests: XCTestCase {

    /// Redirect stub keyed by MediaFire file id.
    private func transport(_ filenames: [String: String]) -> StubTransport {
        StubTransport { req in
            guard let key = MediaFireHost.key(from: req.url), let name = filenames[key] else {
                return HTTPResponse(status: 404)
            }
            let encoded = name.addingPercentEncoding(
                withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._ "))) ?? name
            return HTTPResponse(status: 302, headers: [
                "Location": "http://www.mediafire.com/file/\(key)/\(encoded)/file"
            ])
        }
    }

    func testUntitledIssueBecomesSearchableByTitle() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_518</div>
            <div>http://www.mediafire.com/?x0mrij299kyr947</div>
            """)

        // Before: a code, no title, unfindable by name.
        XCTAssertEqual(store.untitledIssueCount, 1)
        XCTAssertTrue(try store.search("bubnjevi").isEmpty)

        let result = try await store.backfillTitles(
            via: transport(["x0mrij299kyr947":
                            "LMS 518 - Mister No - Bubnjevi u dzungli (drzeko).cbr"]))

        XCTAssertEqual(result.probed, 1)
        XCTAssertEqual(result.titled, 1)
        XCTAssertEqual(store.untitledIssueCount, 0)

        let hit = try XCTUnwrap(try store.search("bubnjevi").first)
        XCTAssertEqual(hit.title, "Bubnjevi u dzungli")
        XCTAssertEqual(hit.code, "MN_LMS_518")
        // Scanner credits must not leak into the title.
        XCTAssertFalse(hit.title!.contains("drzeko"))
    }

    /// Diacritic folding has to survive the backfill path too — the title is
    /// re-indexed, so a bug here would only show up after probing.
    func testBackfilledTitleIsSearchableWithoutDiacritics() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_517</div><div>http://www.mediafire.com/?km9noee90qf5smr</div>
            """)
        try await store.backfillTitles(
            via: transport(["km9noee90qf5smr": "LMS 517 - Mister No - U čeljusti jaguara.cbr"]))
        XCTAssertEqual(try store.search("celjusti").first?.title, "U čeljusti jaguara")
    }

    /// Probe results are permanent; a second pass must not re-request them.
    func testProbesAreNotRepeated() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_518</div><div>http://www.mediafire.com/?x0mrij299kyr947</div>
            """)
        let stub = transport(["x0mrij299kyr947": "LMS 518 - Mister No - Bubnjevi u dzungli.cbr"])
        try await store.backfillTitles(via: stub)
        let afterFirst = stub.requests.count
        let second = try await store.backfillTitles(via: stub)
        XCTAssertEqual(second.probed, 0)
        XCTAssertEqual(stub.requests.count, afterFirst, "re-probed an already-known mirror")
    }

    /// The forum label can point at the wrong file — one confirmed case in the
    /// corpus. The file's own metadata wins, the issue is flagged, and the
    /// distrusted title is NOT written.
    func testLabelFileMismatchIsFlaggedNotApplied() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>0413 - ZAGOR - Zagorova pravda</div>
            <div>http://www.mediafire.com/?pTpUzADQ1234567</div>
            """)
        let result = try await store.backfillTitles(
            via: transport(["pTpUzADQ1234567": "ZS 0425 Zagor - Neravna Borba.cbr"]))

        XCTAssertEqual(result.mismatched, 1)
        XCTAssertEqual(result.titled, 0)
        // The inline title survives; it is not silently replaced by the other
        // comic's name, and not blessed as verified either.
        XCTAssertEqual(try store.search("zagorova pravda").first?.title, "Zagorova pravda")
        XCTAssertTrue(try store.search("neravna borba").isEmpty, "distrusted title was applied")
    }

    /// A filename whose number agrees with the label marks the issue verified.
    func testMatchingNumberMarksVerified() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?v9leke6rjs7vcxx</div>
            """)
        let result = try await store.backfillTitles(
            via: transport(["v9leke6rjs7vcxx": "ZS 013 - Zagor - Nasilje u Darkvudu.cbr"]))
        XCTAssertEqual(result.mismatched, 0)
        XCTAssertEqual(result.probed, 1)
    }

    /// A dead mirror must not abort the batch or lose the issue.
    func testDeadMirrorIsCountedAndSkipped() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_999</div><div>http://www.mediafire.com/?deadkey00000000</div>
            <div>MN_LMS_518</div><div>http://www.mediafire.com/?x0mrij299kyr947</div>
            """)
        let result = try await store.backfillTitles(
            via: transport(["x0mrij299kyr947": "LMS 518 - Mister No - Bubnjevi u dzungli.cbr"]))
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.titled, 1)
        XCTAssertEqual(store.issueCount, 2, "a dead link must not remove the issue")
    }

    /// Issues with no title are probed before ones that already have a name —
    /// they are the ones a user currently cannot find.
    func testUntitledIssuesAreProbedFirst() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Has A Title</div><div>http://www.mediafire.com/?titled000000000</div>
            <div>MN_LMS_518</div><div>http://www.mediafire.com/?untitled00000000</div>
            """)
        let stub = transport([:])
        _ = try await store.backfillTitles(via: stub, limit: 1)
        XCTAssertEqual(MediaFireHost.key(from: stub.requests[0].url), "untitled00000000")
    }
}

/// Scoping the backfill to what the user actually sees.
final class UntitledMirrorCountTests: XCTestCase {

    /// Some topics list only a code and a link — no title anywhere on the page.
    private func codeOnlyStore() throws -> Store {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_511</div><div>http://www.mediafire.com/?FAKEKEY511</div>
            <div>MN_LMS_513</div><div>http://www.mediafire.com/?FAKEKEY513</div>
            """)
        return store
    }

    func testUntitledMirrorsAreCounted() throws {
        let store = try codeOnlyStore()
        XCTAssertEqual(store.untitledMirrorCount, 2)
    }

    /// The count must reach zero, or a caller looping on it never stops.
    func testCountFallsToZeroOnceNamed() async throws {
        let store = try codeOnlyStore()
        // MediaFire exposes the name in the download path it redirects to.
        let stub = StubTransport { _ in
            HTTPResponse(status: 302, headers: ["Location":
                "https://download.mediafire.com/x/LMS - 511 - Mister No - Neki Naslov.cbr"])
        }
        _ = try await store.backfillTitles(via: stub, limit: 50)
        XCTAssertEqual(store.untitledMirrorCount, 0, "a caller looping on this would spin")
    }

    /// An issue that already has a title is not what this counts.
    /// The progress readout counts issues, not mirrors: two mirrors on one
    /// issue is one name to resolve, and counting mirrors would show a total
    /// roughly twice the real work.
    func testIssueCountIgnoresTheSecondMirror() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>MN_LMS_511</div>
            <div>http://www.mediafire.com/?FAKEKEY511</div>
            <div>http://www.mediafire.com/?FAKEKEY511B</div>
            """)
        XCTAssertEqual(store.untitledIssueCount, 1)
        XCTAssertGreaterThan(store.untitledMirrorCount, 1)
    }

    func testTitledIssuesAreNotCounted() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        XCTAssertEqual(store.untitledMirrorCount, 0)
    }
}

/// Consistent casing for names recovered from filenames.
final class TitleCaseTests: XCTestCase {

    func testShoutedTitleBecomesSentenceCase() {
        XCTAssertEqual(TitleCleaner.normaliseCase("DIJAMANTSKA KLOPKA"), "Dijamantska klopka")
        XCTAssertEqual(TitleCleaner.normaliseCase("U CELJUSTI JAGUARA"), "U celjusti jaguara")
    }

    /// A title that already carries lowercase is the author's own casing.
    func testMixedCaseIsLeftAlone() {
        XCTAssertEqual(TitleCleaner.normaliseCase("Sablast doline"), "Sablast doline")
        XCTAssertEqual(TitleCleaner.normaliseCase("Zagor Te-Nay"), "Zagor Te-Nay")
        XCTAssertEqual(TitleCleaner.normaliseCase("Grupa TNT"), "Grupa TNT")
    }

    /// Acronyms inside an all-caps title are lowercased along with everything
    /// else. Documented rather than fixed: no rule separates "NLO" and "TNT"
    /// from "PAS", "SAN" and "ZUB", which are ordinary words here.
    func testAcronymsInsideShoutedTitlesAreLowercasedToo() {
        XCTAssertEqual(TitleCleaner.normaliseCase("NAPAD NLO"), "Napad nlo")
    }

    /// The case that actually matters: page labels keep their own casing, so
    /// an acronym in a normally-cased title is never touched.
    func testAcronymInAMixedCaseTitleIsUntouched() {
        XCTAssertEqual(TitleCleaner.normaliseCase("Grupa TNT"), "Grupa TNT")
    }

    func testEmptyAndPunctuationAreSafe() {
        XCTAssertEqual(TitleCleaner.normaliseCase(""), "")
        XCTAssertEqual(TitleCleaner.normaliseCase("123"), "123")
    }

    /// Rows stored before the fix are evened out when the library opens.
    func testStoredTitlesAreNormalisedOnOpen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("library.sqlite").path

        let store = try Store(path: file)
        try store.ingest(html:
            "<div>MN_LMS_511</div><div>http://www.mediafire.com/?FAKEKEY511</div>")
        let id = try XCTUnwrap(try store.recent().first).id
        try store.setTitle(issueID: id, title: "DIJAMANTSKA KLOPKA")

        let reopened = try Store(path: file)
        XCTAssertEqual(try reopened.recent().first?.title, "Dijamantska klopka")
        // The index must follow the title, or search stops finding it.
        XCTAssertEqual(try reopened.search("dijamantska", limit: 10).count, 1)
    }
}

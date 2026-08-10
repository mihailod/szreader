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

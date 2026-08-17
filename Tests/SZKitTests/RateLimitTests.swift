import XCTest
@testable import SZKit

/// Being asked to wait.
///
/// A rate limit is the one failure the reader can do something about, and the
/// only useful thing to tell them is how long — so what these check is that
/// the wait survives from the header to the sentence, and that nothing in the
/// download path quietly asks again in the meantime.
final class RateLimitTests: XCTestCase {

    // MARK: - Reading the header

    /// Both forms the header is defined in. Reading only the number would turn
    /// every date-bearing rate limit into an unexplained failure.
    func testBothFormsOfRetryAfterAreRead() {
        XCTAssertEqual(RetryAfter.seconds("120"), 120)
        XCTAssertEqual(RetryAfter.seconds("  120 "), 120)

        // 1_000_000 epoch seconds is 12 Jan 1970 13:46:40 GMT; five minutes on
        // from there is 13:51:40.
        let now = Date(timeIntervalSince1970: 1_000_000)
        let inFive = "Mon, 12 Jan 1970 13:51:40 GMT"
        XCTAssertEqual(RetryAfter.seconds(inFive, now: now) ?? 0, 300, accuracy: 1)
    }

    /// A wait that has already passed is no wait at all — a clock that is
    /// slightly off must not produce "wait -4 seconds".
    func testAWaitInThePastIsNoWait() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertNil(RetryAfter.seconds("Mon, 12 Jan 1970 13:36:40 GMT", now: now))
        XCTAssertNil(RetryAfter.seconds("0"))
        XCTAssertNil(RetryAfter.seconds("-5"))
        XCTAssertNil(RetryAfter.seconds("soon"))
        XCTAssertNil(RetryAfter.seconds(nil))
        XCTAssertNil(RetryAfter.seconds(""))
    }

    /// Rounded up, never down: a message that says one minute for a 90-second
    /// limit sends the reader back early to the same refusal.
    func testTheWaitIsSaidTheWayAPersonWouldSayIt() {
        XCTAssertEqual(RetryAfter.phrase(1), "1 second")
        XCTAssertEqual(RetryAfter.phrase(30), "30 seconds")
        XCTAssertEqual(RetryAfter.phrase(30.2), "31 seconds")
        XCTAssertEqual(RetryAfter.phrase(90), "2 minutes")
        XCTAssertEqual(RetryAfter.phrase(600), "10 minutes")
        XCTAssertEqual(RetryAfter.phrase(3600), "60 minutes")
        XCTAssertEqual(RetryAfter.phrase(7200), "2 hours")
    }

    /// 429 always counts. A 503 counts only when it names a wait — a bare one
    /// is a server having a moment, which is retried instead.
    func testWhichStatusesCountAsARefusal() {
        XCTAssertTrue(RetryAfter.refusal(status: 429, header: nil, host: "h")?
            .isRateLimited ?? false)
        XCTAssertTrue(RetryAfter.refusal(status: 429, header: "60", host: "h")?
            .isRateLimited ?? false)
        XCTAssertTrue(RetryAfter.refusal(status: 503, header: "60", host: "h")?
            .isRateLimited ?? false)
        XCTAssertNil(RetryAfter.refusal(status: 503, header: nil, host: "h"))
        XCTAssertNil(RetryAfter.refusal(status: 500, header: "60", host: "h"))
        XCTAssertNil(RetryAfter.refusal(status: 404, header: nil, host: "h"))
    }

    /// What the reader actually reads. The host and the wait are the two facts
    /// worth having, and a refusal with no stated wait still has to say
    /// something rather than trail off.
    func testTheMessageNamesTheHostAndTheWait() {
        let stated = DownloadError.rateLimited(host: "archive.org", retryAfter: 300)
        XCTAssertTrue(stated.description.contains("archive.org"), stated.description)
        XCTAssertTrue(stated.description.contains("5 minutes"), stated.description)

        let silent = DownloadError.rateLimited(host: "archive.org", retryAfter: nil)
        XCTAssertTrue(silent.description.contains("a few minutes"), silent.description)
    }

    // MARK: - What the download does about it

    private func library(_ store: Store, root: URL) -> Library {
        Library(store: store, paths: LibraryPaths(root: root),
                transport: StubTransport { _ in .init(status: 500) },
                downloader: URLSessionDownloader(),
                registry: HostRegistry(hosts: [DirectHost(hosts: ["127.0.0.1"])]))
    }

    private func seedOneIssue(into store: Store, base: String) throws -> Int {
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion,
            generated: "2026-01-01", base: base,
            series: [.init(key: "SK", name: "Svet Kompjutera", code: "SK",
                           language: "serbian")],
            issues: [.init(id: "SK_84_10", series: "SK", number: 1,
                           title: "Oktobar 1984", year: 1984, month: 10,
                           zip: "SKH/ZIP/1984_10.zip", cover: nil, thumb: nil,
                           bytes: nil, pages: 48, dead: nil)])
        try store.seed(file)
        return try XCTUnwrap(store.recent(limit: nil).first?.id)
    }

    /// One request, one refusal, and it stops there.
    ///
    /// The retry that carries a transfer through archive.org's 500s must not
    /// touch this one: asking again is precisely what the server said not to
    /// do, and three tries is three strikes against whatever limit is counting.
    func testARefusalIsNotRetried() async throws {
        let server = try TinyHTTPServer(routes: [:], refuseWith: "120")
        defer { server.stop() }

        let store = try Store()
        let issueID = try seedOneIssue(into: store, base: server.base + "/pcsux/")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await library(store, root: root).fetch(issueID: issueID)
            XCTFail("a refusal should not produce a comic")
        } catch let error as DownloadError {
            XCTAssertTrue(error.isRateLimited, "\(error)")
            // Reaches the reader as itself, not wrapped in "every mirror
            // failed" — which would read as a broken link and hide the wait.
            XCTAssertTrue(Library.reason(error).contains("2 minutes"),
                          Library.reason(error))
        }
        XCTAssertEqual(server.requested.count, 1, "the refusal was asked again")
    }

    /// And it stops the whole download, not just this mirror.
    ///
    /// The mirror loop exists to work through alternatives when one link is
    /// bad. A rate limit is not a bad link — it is the host — so moving on to
    /// the next one asks the same server again, immediately, which is both
    /// futile and the surest way to extend the limit.
    func testARefusalStopsTheRemainingMirrorsBeingTried() async throws {
        let server = try TinyHTTPServer(routes: [:], refuseWith: "120")
        defer { server.stop() }

        let store = try Store()
        let issueID = try seedOneIssue(into: store, base: server.base + "/pcsux/")
        try store.db.run("""
            INSERT INTO mirror (issue_id, url, host, ordinal, filename, size)
            VALUES (?, ?, '127.0.0.1', 1, 'second.zip', NULL)
            """, [.int(Int64(issueID)), .text(server.base + "/pcsux/SKH/ZIP/second.zip")])
        XCTAssertEqual(try store.liveMirrors(forIssue: issueID).count, 2)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        _ = try? await library(store, root: root).fetch(issueID: issueID)

        XCTAssertEqual(server.requested.count, 1,
                       "the second mirror was tried on the same refusing host")
        XCTAssertFalse(try store.recent(limit: nil).first?.isDownloaded ?? true)
    }
}

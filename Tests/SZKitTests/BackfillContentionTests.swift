import XCTest
@testable import SZKit

/// Importing while the title backfill runs.
///
/// The earlier concurrency tests used `concurrentPerform`, which is synchronous.
/// The real failure happens between an async backfill (probe, await, write,
/// repeat) and an import on another task, so it is reproduced that way here.
final class BackfillContentionTests: XCTestCase {

    /// A transport that takes its time, like the throttled one in the app.
    private struct SlowTransport: Transport {
        let delay: Duration
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            try await Task.sleep(for: delay)
            return HTTPResponse(status: 302, headers: ["Location":
                "https://download.mediafire.com/x/LMS - 511 - Mister No - Naslov.cbr"])
        }
    }

    private func page(_ range: ClosedRange<Int>) -> String {
        range.map { n in
            "<div>MN_LMS_\(500 + n)</div>"
            + "<div>http://www.mediafire.com/?FAKEKEY\(500 + n)</div>"
        }.joined()
    }

    func testImportSucceedsWhileBackfillIsRunning() async throws {
        let store = try Store()
        try store.ingest(html: page(1...40))

        // Backfill in the background, exactly as the app does it.
        let backfill = Task.detached {
            _ = try? await store.backfillTitles(
                via: SlowTransport(delay: .milliseconds(20)), limit: 40)
        }

        // Import repeatedly while that runs.
        var failures: [String] = []
        for batch in 0..<12 {
            do {
                _ = try store.importPage(html: page((100 + batch * 5)...(104 + batch * 5)),
                                         source: "contention \(batch)")
            } catch {
                failures.append("\(error)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        _ = await backfill.value

        XCTAssertEqual(failures, [], "imports lost while titles were resolving")
    }

    /// The reverse order: backfill writes while an import holds a transaction.
    func testBackfillSucceedsWhileImporting() async throws {
        let store = try Store()
        try store.ingest(html: page(1...30))

        let importer = Task.detached {
            for batch in 0..<10 {
                _ = try? store.importPage(html: self.page((200 + batch * 3)...(202 + batch * 3)),
                                          source: "importer \(batch)")
            }
        }
        let result = try await store.backfillTitles(
            via: SlowTransport(delay: .milliseconds(15)), limit: 30)
        _ = await importer.value

        XCTAssertGreaterThan(result.probed, 0, "backfill made no progress")
        XCTAssertEqual(result.failed, 0, "probe writes failed under contention")
    }
}

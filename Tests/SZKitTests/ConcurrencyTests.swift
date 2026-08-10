import XCTest
@testable import SZKit

/// One sqlite3 connection is shared by the UI and the background title
/// backfill. WAL permits concurrent readers but only one writer, so an import
/// racing a probe write failed with "database is locked" — and the import was
/// lost, not retried.
final class ConcurrentAccessTests: XCTestCase {

    /// Writes from several threads at once must all land.
    func testConcurrentWritesAllSucceed() throws {
        let store = try Store()
        try store.ingest(html: "<div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>")
        let issueID = try XCTUnwrap(try store.recent().first).id

        let writes = 60
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: writes) { i in
            do {
                try store.recordDownload(issueID: issueID,
                                         mirrorURL: "http://x/\(i)",
                                         path: URL(fileURLWithPath: "/tmp/\(i).cbz"),
                                         bytes: Int64(i))
            } catch {
                failures.mutate { $0 += 1 }
            }
        }
        XCTAssertEqual(failures.value, 0, "writes lost to a locked database")
    }

    /// Reads interleaved with writes must neither throw nor tear.
    func testConcurrentReadsAndWritesAreStable() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>
            <div>002-Drugi</div><div>http://www.mediafire.com/?FAKE002</div>
            """)
        let failures = Locked(0)
        DispatchQueue.concurrentPerform(iterations: 60) { i in
            do {
                if i.isMultiple(of: 2) {
                    _ = try store.search("prvi", limit: 20)
                    _ = store.untitledIssueCount
                } else {
                    try store.ingest(html:
                        "<div>\(100 + i)-Naslov \(i)</div>"
                        + "<div>http://www.mediafire.com/?FAKE\(100 + i)</div>")
                }
            } catch {
                failures.mutate { $0 += 1 }
            }
        }
        XCTAssertEqual(failures.value, 0, "reads or writes failed under contention")
        XCTAssertGreaterThan(store.issueCount, 2)
    }

    /// Nested calls happen constantly (`scalarInt` calls `query`; the backfill
    /// writes inside its own loop). A non-reentrant lock would deadlock here.
    func testNestedDatabaseCallsDoNotDeadlock() throws {
        let store = try Store()
        try store.ingest(html: "<div>001-Prvi</div><div>http://www.mediafire.com/?FAKE001</div>")
        let done = expectation(description: "nested calls returned")
        DispatchQueue.global().async {
            _ = store.issueCount
            _ = store.untitledIssueCount
            _ = try? store.recent(limit: 10, downloadedOnly: false)
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
    }
}

/// Minimal thread-safe box, so the tests above do not themselves race.
private final class Locked<T>: @unchecked Sendable {
    private var storage: T
    private let lock = NSLock()
    init(_ value: T) { storage = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return storage }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&storage); lock.unlock() }
}

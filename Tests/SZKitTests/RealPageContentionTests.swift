import XCTest
@testable import SZKit

/// Reproduction attempt against the real Mister No page: 120 code-only entries
/// with two mirrors each, which is what the backfill is actually chewing on
/// when an import fails.
final class RealPageContentionTests: XCTestCase {

    /// File-backed, like the app. An in-memory database does not use WAL, so a
    /// test on one cannot see a WAL-mode failure at all.
    private func fileStore() throws -> Store {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try Store(path: dir.appendingPathComponent("library.sqlite").path)
    }

    private struct SlowTransport: Transport {
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            try await Task.sleep(for: .milliseconds(5))
            return HTTPResponse(status: 302, headers: ["Location":
                "https://download.mediafire.com/x/LMS - 511 - Mister No - Naslov.cbr"])
        }
    }

    private func page() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("spike/pages/"
                + "Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona.html")
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("saved topic page not present")
        }
        return html
    }

    /// Re-importing the same page is the normal case: the like quota means a
    /// page is unlocked in batches, so it gets imported again and again.
    func testReimportWhileBackfillRuns() async throws {
        let html = try page()
        let store = try fileStore()
        _ = try store.importPage(html: html, source: "first")

        let backfill = Task.detached {
            _ = try? await store.backfillTitles(via: SlowTransport(), limit: 200)
        }

        var failures: [String] = []
        for i in 0..<8 {
            do {
                _ = try store.importPage(html: html, source: "reimport \(i)")
            } catch {
                failures.append("\(type(of: error)): \(error)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        _ = await backfill.value

        if !failures.isEmpty { print("REPRO-FAILURES: \(failures.prefix(3))") }
        XCTAssertEqual(failures, [], "re-import failed while titles resolved")
    }

    /// Searching hits the same FTS index the backfill rewrites per title.
    func testSearchWhileBackfillRewritesTheIndex() async throws {
        let html = try page()
        let store = try fileStore()
        _ = try store.importPage(html: html, source: "first")

        let backfill = Task.detached {
            _ = try? await store.backfillTitles(via: SlowTransport(), limit: 200)
        }
        var failures: [String] = []
        for _ in 0..<40 {
            do { _ = try store.search("mister", limit: 50) }
            catch { failures.append("\(type(of: error)): \(error)") }
            try await Task.sleep(for: .milliseconds(5))
        }
        _ = await backfill.value

        if !failures.isEmpty { print("REPRO-FAILURES: \(failures.prefix(3))") }
        XCTAssertEqual(failures, [], "search failed while the index was rewritten")
    }
}

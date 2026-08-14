import XCTest
@testable import SZKit

/// Topics whose labels are nothing but a number.
final class BareNumberIdentityTests: XCTestCase {

    private static let pagesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spike/pages")

    private func page(_ prefix: String) throws -> String {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.pagesDir.path)
        let hit = try XCTUnwrap(names.first { $0.hasPrefix(prefix) }, prefix)
        return try String(contentsOf: Self.pagesDir.appendingPathComponent(hit), encoding: .utf8)
    }

    /// Two bare-number topics in one library must not overwrite each other.
    ///
    /// The natural key is code, number, title and series, and a bare-number
    /// label has none of the three that are not the number — so Ken Parker's
    /// issue 1 and Erotski Roman's issue 1 were the same row. Whichever page
    /// was imported second silently lost every issue the first already
    /// covered: Ken Parker runs to 79, so Erotski Roman arrived starting at
    /// 80, with no error anywhere.
    ///
    /// Both orders, because `INSERT OR IGNORE` hides the loss in whichever
    /// page comes second.
    func testTwoBareNumberTopicsKeepTheirOwnIssues() throws {
        for reversed in [false, true] {
            var pages = ["Ken Parker - LIBELLUS", "Erotski"]
            if reversed { pages.reverse() }

            let store = try Store()
            for p in pages { _ = try store.ingest(html: try page(p)) }
            let rows = try store.recent(limit: nil)

            let ken = rows.filter { $0.edition == "LIBELLUS I FIBRA" }
            let ero = rows.filter { $0.edition == "Erotski Roman" }
            let order = reversed ? "Erotski first" : "Ken Parker first"

            XCTAssertEqual(ken.count, 79, "Ken Parker lost issues — \(order)")
            XCTAssertEqual(ero.count, 184, "Erotski Roman lost issues — \(order)")
            XCTAssertEqual(ken.compactMap(\.number).min(), 1, order)
            XCTAssertEqual(ero.compactMap(\.number).min(), 1, order)
            XCTAssertEqual(rows.count, 263, order)
        }
    }

    /// Re-importing either page is still not a second copy: the topic's name
    /// has to land in the key the same way every time.
    func testReimportDoesNotDuplicate() throws {
        let store = try Store()
        for p in ["Ken Parker - LIBELLUS", "Erotski"] { _ = try store.ingest(html: try page(p)) }
        let first = try store.recent(limit: nil).count
        for p in ["Ken Parker - LIBELLUS", "Erotski"] { _ = try store.ingest(html: try page(p)) }
        XCTAssertEqual(try store.recent(limit: nil).count, first, "re-import duplicated the runs")
    }
}

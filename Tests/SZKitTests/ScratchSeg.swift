import XCTest
@testable import SZKit

final class ScratchSeg: XCTestCase {
    func testMapping() throws {
        let p = "spike/pages/Sirius, SF časopis - Casopisi - Stripzona.html"
        let store = try Store()
        try store.ingest(html: try String(contentsOfFile: p, encoding: .utf8))
        let rows = try store.recent(limit: nil)
        for want in ["Ne ubijte Rulla!", "Euroconski dvoboj", "YU SIRIUS", "Posljednji Winnebago"] {
            guard let issue = rows.first(where: { $0.title == want }) else { continue }
            let seg = try store.segment(forIssue: issue.id)
            print("G \(issue.shelfMark ?? "-") [\(want)] -> \(seg.map { "\($0.first)–\($0.last)" } ?? "none")")
        }
        if let seg = try store.segment(forIssue: rows.first { $0.number == 1 }!.id) {
            let ctx = try store.context(forIssue: rows.first { $0.number == 1 }!.id)!
            print("G set \(seg.first)–\(seg.last) covers \(try store.issues(inSegment: seg, context: ctx).count) issues")
        }
    }
}

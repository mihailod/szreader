import XCTest
@testable import SZKit

/// One edition, however the forum happened to spell it.
///
/// Uploaders type the edition by hand, so the same run arrives as "Lunov
/// magnus strip" on one topic and "Lunov Magnus Strip" on another. Left alone
/// that is two rows in the filter menu, each finding half of a run of several
/// hundred issues, and nothing on screen to say why.
final class EditionCaseTests: XCTestCase {

    /// Two real issues, filed under one edition spelled two ways.
    ///
    /// The spellings are set directly rather than inferred from two topic
    /// titles. `PageContext` only takes a breadcrumb as the edition when the
    /// forum shouts it, so a lower-cased title yields a different edition
    /// entirely and the fixture would not hold what it claims to. What is
    /// under test is what the store does with two spellings once they exist,
    /// so the fixture states them.
    private func library() throws -> Store {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div>Kolorka 3 Prva prica (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEYAAA</div>
            """)
        try store.ingest(html: """
            <title>Veliki Blek - VELIKI BLEK - Veliki Blek - Stripzona</title>
            <div>Kolorka 4 Druga prica (Oliver Ka) (08.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEYBBB</div>
            """)
        try store.db.run("UPDATE issue SET edition = ? WHERE title LIKE '%Prva%'",
                         [.text("Lunov Magnus Strip")])
        try store.db.run("UPDATE issue SET edition = ? WHERE title LIKE '%Druga%'",
                         [.text("Lunov magnus strip")])
        return store
    }

    /// The menu offers the edition once, not once per spelling.
    func testTheMenuListsAnEditionOnce() throws {
        let store = try library()
        let editions = try store.editions()
        let lunov = editions.filter { $0.range(of: "lunov", options: .caseInsensitive) != nil }
        XCTAssertEqual(lunov.count, 1, "listed more than once: \(lunov)")
    }

    /// And picking it finds every issue filed under any casing of it.
    ///
    /// This is the half that matters. Collapsing the menu without matching
    /// case-insensitively would be worse than the duplicate: one tidy row
    /// that silently returns half the run.
    func testPickingItFindsTheWholeRun() throws {
        let store = try library()
        let all = try store.recent(limit: nil)
        XCTAssertEqual(all.count, 2, "the fixture should hold one issue per spelling")

        let chosen = try XCTUnwrap(try store.editions()
            .first { $0.range(of: "lunov", options: .caseInsensitive) != nil })
        let matched = try store.recent(limit: nil, editions: [chosen])
        XCTAssertEqual(matched.count, 2,
                       "picking “\(chosen)” found \(matched.count) of 2 issues")
    }

    /// Search narrows the same way, so a filtered search cannot disagree with
    /// the same filter applied while browsing.
    func testSearchNarrowsCaseInsensitivelyToo() throws {
        let store = try library()
        let chosen = try XCTUnwrap(try store.editions()
            .first { $0.range(of: "lunov", options: .caseInsensitive) != nil })
        XCTAssertEqual(try store.search("prica", limit: nil, editions: [chosen]).count, 2)
    }

    /// Distinct editions are still distinct — the grouping folds case, not
    /// everything that starts alike.
    func testDifferentEditionsAreStillSeparate() throws {
        let store = try library()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - Zagor - Stripzona</title>
            <div>Kolorka 5 Treca prica (Oliver Ka) (09.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEYCCC</div>
            """)
        let editions = try store.editions()
        XCTAssertEqual(editions.count, 2, "\(editions)")
        XCTAssertTrue(editions.contains("ZLATNA SERIJA"), "\(editions)")
    }
}

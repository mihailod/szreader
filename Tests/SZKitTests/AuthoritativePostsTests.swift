import XCTest
@testable import SZKit

/// Topics where one member's posts supersede the rest of the thread.
final class AuthoritativePostsTests: XCTestCase {

    private func page(_ fragment: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let hit = names.first(where: { $0.contains(fragment) }),
              let html = try? String(contentsOf: dir.appendingPathComponent(hit),
                                     encoding: .utf8)
        else { throw XCTSkip("no saved page matching “\(fragment)”") }
        return html
    }

    private func postCount(_ html: String) -> Int {
        html.components(separatedBy: "class='post_block hentry").count - 1
    }

    /// The whole run, from the one member who posted it complete.
    func testAlefYieldsTheCompleteRun() throws {
        let store = try Store()
        _ = try store.importPage(html: try page("Alef"), source: "alef")
        let rows = try store.recent(limit: nil)

        XCTAssertEqual(rows.count, 26, "the edition ran to 26 issues")
        XCTAssertEqual(rows.compactMap(\.number).sorted(), Array(1...26))
        XCTAssertEqual(rows.filter { $0.coverURL != nil }.count, 26, "every issue has cover art")
        XCTAssertTrue(rows.allSatisfy { ($0.mirrorCount) > 0 }, "every issue has a link")
    }

    /// Eleven posts on the page, six of them the ones worth reading.
    func testOnlyTheDesignatedAuthorSurvives() throws {
        let whole = try page("Alef")
        let reduced = Catalog.authoritativeHTML(whole)
        XCTAssertEqual(postCount(whole), 11)
        XCTAssertEqual(postCount(reduced), 6)
        XCTAssertLessThan(reduced.count, whole.count)
    }

    /// The page context comes from the head and breadcrumbs, so those must
    /// survive the reduction — otherwise the series and publisher are lost.
    func testReductionKeepsThePageContext() throws {
        let reduced = Catalog.authoritativeHTML(try page("Alef"))
        let context = Catalog.pageContext(in: reduced)
        XCTAssertEqual(context.edition, "Alef")
        XCTAssertNotNil(context.topic)
    }

    /// Every other topic is read whole.
    func testOtherTopicsAreUntouched() throws {
        for fragment in ["Mister No - LUNOV MAGNUS STRIP", "Zagor - ZLATNA SERIJA", "Orka - FIBRA"] {
            let html = try page(fragment)
            XCTAssertEqual(Catalog.authoritativeHTML(html), html, "\(fragment) was altered")
        }
    }

    /// If the author is not on the page, read it whole rather than return
    /// nothing — a missing member must not empty the topic.
    func testMissingAuthorFallsBackToTheWholePage() {
        let html = """
            <title>Alef - Ostale edicije pisanih romana - Stripzona</title>
            <span itemprop="name">Pisani romani</span>
            <div class='post_block hentry'><span itemprop="name">someone</span>
            <div>Alef - SF magazin 01</div><div>http://www.mediafire.com/?FAKE01</div></div>
            <div class='post_block hentry'><span itemprop="name">another</span>
            <div>Alef - SF magazin 02</div><div>http://www.mediafire.com/?FAKE02</div></div>
            """
        XCTAssertEqual(Catalog.authoritativeHTML(html), html)
    }
}

/// Labels that put the number after the name.
final class NameFirstLabelTests: XCTestCase {

    /// Alef lists issues as "Alef - SF magazin 01 (scanners)". A name that
    /// allows only spaces stops at the hyphen and matches nothing.
    func testNameMayContainADash() {
        let match = Labels.matchNameFirst("Alef - SF magazin 01 (drazen23 & retfala-ri)")
        XCTAssertEqual(match?.number, "01")
        XCTAssertEqual(match?.name, "Alef - SF magazin")
        // Scanner credits are not a title.
        XCTAssertNil(match?.title)
    }

    func testPlainNameFirstStillWorks() {
        XCTAssertEqual(Labels.matchNameFirst("Zagor 13 - Nasilje u Darkvudu")?.number, "13")
        XCTAssertEqual(Labels.matchNameFirst("Alef 07")?.number, "07")
    }

    /// Page furniture must not be read as a label.
    func testFurnitureIsRejected() {
        XCTAssertNil(Labels.matchNameFirst("Strana 2"))
        XCTAssertNil(Labels.matchNameFirst("update 3"))
        XCTAssertNil(Labels.matchNameFirst("https://mega.nz/file/abc123"))
    }
}

/// Cover filenames that end in a number without an underscore.
final class NumberedCoverTests: XCTestCase {

    func testLetterThenDigitsCounts() {
        let covers = Catalog.covers(in: """
            <img src="https://i.postimg.cc/xx/alef-SF01.jpg">
            <img src="https://i.postimg.cc/yy/alef-SF26.jpg">
            """)
        XCTAssertEqual(covers[1], "https://i.postimg.cc/xx/alef-SF01.jpg")
        XCTAssertEqual(covers[26], "https://i.postimg.cc/yy/alef-SF26.jpg")
    }

    /// A member avatar is named "av-68.jpg". Without this it would claim to be
    /// issue 68 and, on a page that has one, take its cover.
    func testAvatarsDoNotClaimAnIssueNumber() {
        XCTAssertFalse(Catalog.isPlausibleCover(
            "https://www.stripzona.com/port/uploads/av-68.jpg"))
        XCTAssertTrue(Catalog.covers(in:
            #"<img src="https://www.stripzona.com/port/uploads/av-68.jpg">"#).isEmpty)
    }

    func testUnderscoreStyleStillWorks() {
        let covers = Catalog.covers(in:
            #"<img src="http://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg">"#)
        XCTAssertEqual(covers[13], "https://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg")
    }
}

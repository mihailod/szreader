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

    /// Photobucket rewrites a cover as "AS_PZAL_1_zps96t63e0n.jpg" — the
    /// number in the middle, followed by a cache-busting suffix. Requiring the
    /// digits to sit immediately before the extension missed every one, which
    /// is why that topic had 20 issues and 4 covers.
    func testCacheBusterAfterTheNumberIsTolerated() {
        let covers = Catalog.covers(in: """
            <img src="https://i.photobucket.com/albums/a602/x/asteriks/AS_PZAL_1_zps96t63e0n.jpg">
            <img src="https://i.photobucket.com/albums/a602/x/asteriks/AS_PZAL_12_zpszlgdlwbu.jpg">
            """)
        XCTAssertEqual(covers[1]?.hasSuffix("AS_PZAL_1_zps96t63e0n.jpg"), true)
        XCTAssertEqual(covers[12]?.hasSuffix("AS_PZAL_12_zpszlgdlwbu.jpg"), true)
    }

    /// The suffix must not swallow the number: a digits-only run after the
    /// separator is still the issue number, not a cache key.
    func testNumberIsTakenFromBeforeTheSuffix() {
        let covers = Catalog.covers(in:
            #"<img src="https://example.com/x/AS_PZAL_7_zpsfbexslad.jpg">"#)
        XCTAssertEqual(covers.keys.sorted(), [7])
    }

    func testUnderscoreStyleStillWorks() {
        let covers = Catalog.covers(in:
            #"<img src="http://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg">"#)
        XCTAssertEqual(covers[13], "https://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg")
    }
}

/// Cover matching by position, for pages whose images carry no number.
final class PositionalCoverTests: XCTestCase {

    /// Korto Malteze hosts its covers on imgur under random ids, so no
    /// filename rule can work — position is the only evidence there is.
    func testRandomIdIsNotReadAsAnIssueNumber() {
        // "wW7QGs8.jpg" ends in s8, which a looser rule read as issue 8 — and
        // that false reading took the slot from the cover actually beside it.
        XCTAssertTrue(Catalog.covers(in:
            #"<img src="https://imgur.com/wW7QGs8.jpg">"#).isEmpty)
        XCTAssertTrue(Catalog.covers(in:
            #"<img src="https://imgur.com/yUH6Hce.jpg">"#).isEmpty)
        XCTAssertTrue(Catalog.covers(in:
            #"<img src="https://imgur.com/1RAEajM.jpg">"#).isEmpty)
    }

    /// The genuine conventions still read, so tightening did not overshoot.
    func testRealNumberedNamesStillRead() {
        XCTAssertEqual(Catalog.covers(in:
            #"<img src="https://x/alef-SF01.jpg">"#)[1], "https://x/alef-SF01.jpg")
        XCTAssertEqual(Catalog.covers(in:
            #"<img src="https://x/Dzudas_07.jpg">"#)[7], "https://x/Dzudas_07.jpg")
        XCTAssertEqual(Catalog.covers(in:
            #"<img src="https://x/AS_PZAL_3_zpsabcd1234.jpg">"#)[3],
            "https://x/AS_PZAL_3_zpsabcd1234.jpg")
    }

    /// A topic that opens with an index of every issue, then lists the entries
    /// with the cover above each title.
    ///
    /// Deciding direction per image goes wrong here: the last index entry sits
    /// waiting, claims the first real cover, and everything after it is off by
    /// one — wrong covers throughout, which is worse than none.
    func testIndexBlockDoesNotShiftTheCovers() {
        let html = """
            <div>Corto Maltese - 01 - Mladost</div>
            <div>Corto Maltese - 02 - Balada</div>
            <div>Corto Maltese - 03 - Karipska</div>
            <div><img src="https://imgur.com/aaaaaaa.jpg"></div>
            <div>Corto Maltese - 01 - Mladost</div>
            <div><img src="https://imgur.com/bbbbbbb.jpg"></div>
            <div>Corto Maltese - 02 - Balada</div>
            <div><img src="https://imgur.com/ccccccc.jpg"></div>
            <div>Corto Maltese - 03 - Karipska</div>
            """
        let covers = Catalog.covers(in: html)
        XCTAssertEqual(covers[1], "https://imgur.com/aaaaaaa.jpg")
        XCTAssertEqual(covers[2], "https://imgur.com/bbbbbbb.jpg")
        XCTAssertEqual(covers[3], "https://imgur.com/ccccccc.jpg")
    }

    /// The other convention — cover below its title — must still work.
    func testCoverBelowTitleStillWorks() {
        let html = """
            <div>Corto Maltese - 01 - Mladost</div>
            <div><img src="https://imgur.com/aaaaaaa.jpg"></div>
            <div>Corto Maltese - 02 - Balada</div>
            <div><img src="https://imgur.com/bbbbbbb.jpg"></div>
            """
        let covers = Catalog.covers(in: html)
        XCTAssertEqual(covers[1], "https://imgur.com/aaaaaaa.jpg")
        XCTAssertEqual(covers[2], "https://imgur.com/bbbbbbb.jpg")
    }

    /// Name-first labels have to count as labels here too, or a topic written
    /// that way has nothing for an image to attach to.
    func testNameFirstLabelsAnchorCovers() {
        let covers = Catalog.covers(in: """
            <div><img src="https://imgur.com/zzzzzzz.jpg"></div>
            <div>Corto Maltese - 09 - Blago Samarkanda</div>
            """)
        XCTAssertEqual(covers[9], "https://imgur.com/zzzzzzz.jpg")
    }
}

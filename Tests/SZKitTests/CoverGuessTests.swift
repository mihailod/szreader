import XCTest
@testable import SZKit

/// Covers the catalogue has but the page did not link.
final class CoverGuessTests: XCTestCase {

    private let vb = "https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_128.jpg"

    /// Veliki Blek links 103 thumbnails and leaves fourteen issues with none,
    /// though the catalogue has them all.
    func testGuessesFromASibling() {
        XCTAssertEqual(CoverGuess.url(likeSibling: vb, number: 128, wanted: 137),
                       "https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_137.jpg")
    }

    /// Only the trailing number is the issue: the others name the series.
    func testTheSeriesNumbersAreLeftAlone() {
        let guessed = CoverGuess.url(likeSibling: vb, number: 128, wanted: 192)
        XCTAssertEqual(guessed,
                       "https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_192.jpg")
    }

    /// A catalogue that pads keeps padding.
    func testPaddingIsCarriedOver() {
        XCTAssertEqual(
            CoverGuess.url(likeSibling: "https://x/TN/TN_ZG_ZS_0013.jpg", number: 13, wanted: 7),
            "https://x/TN/TN_ZG_ZS_0007.jpg")
    }

    /// The sibling has to be named after its own issue, or the pattern says
    /// nothing. This is what keeps the guess away from covers filed under
    /// another series' numbering, like Johnny Logan's.
    func testSiblingNotNamedAfterItsIssueIsRefused() {
        // The file says 173; the issue is 1.
        XCTAssertNil(CoverGuess.url(
            likeSibling: "https://x/TN/TN_JL_SS_173.jpg", number: 1, wanted: 2))
    }

    func testNoGuessForItself() {
        XCTAssertNil(CoverGuess.url(likeSibling: vb, number: 128, wanted: 128))
    }

    /// A number with no cover behind it redirects to a page rather than 404ing,
    /// so "did I get an image" is the only usable question.
    func testOnlyAnImageCounts() {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0])
        XCTAssertTrue(CoverGuess.isImage(status: 200, contentType: "image/jpeg", body: jpeg))
        XCTAssertTrue(CoverGuess.isImage(status: 200, contentType: nil, body: jpeg))
        XCTAssertFalse(CoverGuess.isImage(status: 200, contentType: "text/html",
                                          body: Data("<html>".utf8)))
        XCTAssertFalse(CoverGuess.isImage(status: 301, contentType: "image/jpeg", body: jpeg))
        XCTAssertFalse(CoverGuess.isImage(status: 200, contentType: nil, body: Data("<html>".utf8)))
    }
}

/// Asking the catalogue for the covers a page left out.
final class CoverBackfillTests: XCTestCase {

    /// A page that links most of its covers and misses a few — Veliki Blek's
    /// shape.
    private func partlyCovered() throws -> (Store, [Int]) {
        let store = try Store()
        var page = "<title>Veliki Blek - LUNOV MAGNUS STRIP - Veliki Blek - Stripzona</title>"
        for n in [128, 129, 137] {
            if n != 137 {
                page += "<div><img src=\"https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_\(n).jpg\"></div>"
            }
            page += "<div>LMS \(n) - Naslov \(n) - http://www.mediafire.com/?FAKEKEY\(n)</div>"
        }
        try store.ingest(html: page)
        let rows = try store.recent(limit: nil)
        return (store, rows.filter { $0.coverURL == nil }.compactMap(\.number))
    }

    func testAConfirmedGuessBecomesTheCover() async throws {
        let (store, uncovered) = try partlyCovered()
        XCTAssertEqual(uncovered, [137], "the fixture should leave exactly one gap")

        let jpeg = StubTransport { _ in
            HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg"],
                         body: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        }
        let result = try await store.backfillCovers(via: jpeg)
        XCTAssertEqual(result.asked, 1)
        XCTAssertEqual(result.found, 1)

        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.number == 137 })
        XCTAssertEqual(issue.coverURL,
                       "https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_137.jpg")
    }

    /// The catalogue answers a number it does not have with a redirect to an
    /// HTML page, not a 404. Recording that would leave an empty frame on the
    /// shelf and stop the comic's own first page from ever standing in.
    func testAGuessThatIsNotAnImageIsNotRecorded() async throws {
        let (store, _) = try partlyCovered()
        let html = StubTransport { _ in
            HTTPResponse(status: 301, headers: ["Content-Type": "text/html"],
                         body: Data("<html>".utf8))
        }
        let outcome = try await store.backfillCovers(via: html)
        XCTAssertEqual(outcome.found, 0)
        let issue = try XCTUnwrap(store.recent(limit: nil).first { $0.number == 137 })
        XCTAssertNil(issue.coverURL, "a page was recorded as artwork")
    }

    /// Asked once. Without that the same miss comes back on every pass and
    /// the catalogue is hit for it forever.
    func testAMissIsNotAskedTwice() async throws {
        let (store, _) = try partlyCovered()
        let missing = StubTransport { _ in HTTPResponse(status: 301) }
        let first = try await store.backfillCovers(via: missing)
        XCTAssertEqual(first.asked, 1)
        let second = try await store.backfillCovers(via: missing)
        XCTAssertEqual(second.asked, 0, "the same miss was asked again")
    }
}

/// One edition carries several series, and they are catalogued separately.
final class CoverSiblingTests: XCTestCase {

    /// LUNOV MAGNUS STRIP runs Mister No, Zagor, Kit Teler and more. A
    /// coverless Veliki Blek issue must not be offered Mister No's cover —
    /// the guessed number exists in that directory too, so the mistake would
    /// be a plausible-looking wrong cover rather than a visible failure.
    func testASiblingFromAnotherSeriesIsNotUsed() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Mister No - LUNOV MAGNUS STRIP - Mister No - Stripzona</title>
            <div><img src="https://www.stripovi.com/naslovnice/MisterNo/TN/TN_MN_LMS_137.jpg"></div>
            <div>137-Neki naslov</div><div>http://www.mediafire.com/?FAKEKEY137</div>
            """)
        try store.ingest(html: """
            <title>Veliki Blek - LUNOV MAGNUS STRIP - Veliki Blek - Stripzona</title>
            <div>140-Zov bubnjeva</div><div>http://www.mediafire.com/?FAKEKEY140</div>
            """)

        let pending = try store.pendingCovers(limit: 100)
        let blek = pending.filter { $0.number == 140 }
        XCTAssertTrue(blek.isEmpty || blek.allSatisfy { !$0.sibling.contains("MisterNo") },
                      "a Veliki Blek issue was offered a Mister No cover")
    }

    /// Within one series it still works.
    func testASiblingFromTheSameSeriesIsUsed() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Veliki Blek - LUNOV MAGNUS STRIP - Veliki Blek - Stripzona</title>
            <div><img src="https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_128.jpg"></div>
            <div>128-Veliki Blek</div><div>http://www.mediafire.com/?FAKEKEY128</div>
            <div>140-Zov bubnjeva</div><div>http://www.mediafire.com/?FAKEKEY140</div>
            """)
        let pending = try store.pendingCovers(limit: 100).filter { $0.number == 140 }
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(CoverGuess.url(likeSibling: try XCTUnwrap(pending.first).sibling,
                                      number: try XCTUnwrap(pending.first).siblingNumber,
                                      wanted: 140),
                       "https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_140.jpg")
    }
}

/// Neighbours that disagree about where the covers live.
extension CoverSiblingTests {

    /// One topic, two catalogue directories — a page that hotlinks a cover
    /// from the wrong series alongside its own. Which one names the pattern
    /// is then a coin toss, and the wrong answer is a plausible-looking cover
    /// rather than a visible failure, so nothing is guessed.
    func testNeighboursDisagreeingOnADirectoryGuessNothing() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Veliki Blek - LUNOV MAGNUS STRIP - Veliki Blek - Stripzona</title>
            <div><img src="https://www.stripovi.com/naslovnice/VelikiBlek/TN/TN_VB_LMS_128.jpg"></div>
            <div>128-Veliki Blek</div><div>http://www.mediafire.com/?FAKEKEY128</div>
            <div><img src="https://www.stripovi.com/naslovnice/MisterNo/TN/TN_MN_LMS_129.jpg"></div>
            <div>129-Sinovi sume</div><div>http://www.mediafire.com/?FAKEKEY129</div>
            <div>140-Zov bubnjeva</div><div>http://www.mediafire.com/?FAKEKEY140</div>
            """)

        let covered = try store.recent(limit: nil).filter { $0.coverURL != nil }
        XCTAssertEqual(covered.count, 2, "the fixture needs two disagreeing neighbours")
        XCTAssertTrue(try store.pendingCovers(limit: 100).allSatisfy { $0.number != 140 },
                      "a pattern was read from neighbours that disagree")
    }
}

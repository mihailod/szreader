import XCTest
@testable import SZKit

/// Reading a page address off the site, which is what a download falls back to
/// when the shipped rule stops being true.
final class StripoviPageTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/stripovi")

    private func page(_ name: String) throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent(name), encoding: .utf8)
    }

    // MARK: - A real page

    func testItReadsThePageImage() throws {
        let html = try page("comic-6-page-10.html")
        XCTAssertEqual(StripoviPage.pageImage(html),
                       "webcomics/MartinaMjesec/mm0110.jpg")
    }

    func testItReadsThePageCount() throws {
        XCTAssertEqual(StripoviPage.pageCount(try page("comic-6-page-10.html")), 20)
    }

    /// What the fallback is *for*: the address read off the site is the same
    /// one the shipped rule builds, so switching between them is invisible.
    func testTheSiteAgreesWithTheShippedRule() throws {
        let comic = try XCTUnwrap(try StripoviCatalog.shipped().comics.first { $0.id == 6 })
        XCTAssertEqual(StripoviPage.pageImage(try page("comic-6-page-10.html")),
                       comic.pageImage(10))
    }

    // MARK: - What it must not pick up

    /// The page carries a masthead, a header illustration and two book covers
    /// in the sidebar. A parser that took the first image on the page would
    /// download the site's furniture in reading order.
    func testItIgnoresEveryOtherImageOnThePage() {
        let html = """
        <html><body>
        <img src="/images/layout/masthead.png">
        <div class="photo"><img src="/images/headerimages/Dylan026.jpg"></div>
        <div id="comic-container">
        <a href="index.asp?page=online-comics-single&ComicID=6&PageCount=11">\
        <img src="webcomics/MartinaMjesec/mm0110.jpg" alt="Snijeg u kolovozu"/></a>
        </div>
        <img src="https://www.stripovi.com/naslovnice/Albumi/something.jpg">
        </body></html>
        """
        XCTAssertEqual(StripoviPage.pageImage(html), "webcomics/MartinaMjesec/mm0110.jpg")
    }

    func testAPageWithNoComicOnItReadsAsNone() {
        XCTAssertNil(StripoviPage.pageImage("<html><body>the front page</body></html>"))
        XCTAssertNil(StripoviPage.pageCount("<html><body>the front page</body></html>"))
    }

    // MARK: - Encoding

    /// These pages state no charset, so it has to be known rather than read.
    /// Decoded as UTF-8 a real page is not merely mis-accented — it is nil,
    /// because the high bytes are not valid UTF-8 — so getting this wrong
    /// turns every page of every comic into "no page at all".
    func testTheSitesOwnEncodingIsUnderstood() throws {
        let croatian = "Treća liga, Čukarički"
        let data = try XCTUnwrap(croatian.data(using: .windowsCP1250))
        XCTAssertNil(String(data: data, encoding: .utf8),
                     "if this ever decodes as UTF-8 the fallback below is untested")
        XCTAssertEqual(StripoviPage.decode(data), croatian)
    }

    func testUTF8StillDecodes() throws {
        let data = try XCTUnwrap("Šahist".data(using: .utf8))
        XCTAssertEqual(StripoviPage.decode(data), "Šahist")
    }
}

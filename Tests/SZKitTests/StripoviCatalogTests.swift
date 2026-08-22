import XCTest
@testable import SZKit

/// The shipped index of Stripovi.com, and the rule its page addresses follow.
///
/// Every expected address below was read off the live site before it was
/// written here — page one and the last page of each comic, plus a middle page
/// used to check the rule rather than to build it. They are assertions about
/// the real site, not about the generator.
final class StripoviCatalogTests: XCTestCase {

    private func catalogue() throws -> StripoviCatalog {
        try StripoviCatalog.shipped()
    }

    private func comic(_ id: Int) throws -> StripoviCatalog.Comic {
        try XCTUnwrap(try catalogue().comics.first { $0.id == id })
    }

    // MARK: - What ships

    func testTheWholeIndexIsThere() throws {
        let file = try catalogue()
        XCTAssertEqual(file.version, StripoviCatalog.currentVersion)
        XCTAssertEqual(file.comics.count, 31)
        XCTAssertEqual(file.comics.reduce(0) { $0 + $1.pages }, 1442)
    }

    /// These comics have no covers of their own — the site drew a tile for
    /// each, and it is the only artwork there is. A row without one is a grey
    /// rectangle on the shelf for ever.
    func testEveryComicHasArtwork() throws {
        let without = try catalogue().comics.filter { ($0.cover ?? "").isEmpty }
        XCTAssertEqual(without.map(\.id), [])
    }

    func testEveryComicSaysWhoMadeIt() throws {
        let without = try catalogue().comics.filter { ($0.creators ?? "").isEmpty }
        XCTAssertEqual(without.map(\.id), [])
    }

    // MARK: - The page rule

    /// Two digits of padding, which is 27 of the 31.
    func testAPageAddressIsBuiltFromTheRule() throws {
        let snijeg = try comic(6)
        XCTAssertEqual(snijeg.pages, 20)
        XCTAssertEqual(snijeg.pageImage(1), "webcomics/MartinaMjesec/mm0101.jpg")
        XCTAssertEqual(snijeg.pageImage(9), "webcomics/MartinaMjesec/mm0109.jpg")
        XCTAssertEqual(snijeg.pageImage(20), "webcomics/MartinaMjesec/mm0120.jpg")
    }

    /// The four comics that run past 99 pages pad to three, and getting this
    /// wrong is invisible until page 100.
    func testTheLongComicsPadToThree() throws {
        let strumfovi = try comic(12)
        XCTAssertEqual(strumfovi.pages, 126)
        XCTAssertEqual(strumfovi.pageImage(1), "webcomics/Strumfovi/Strumfovi1001.jpg")
        XCTAssertEqual(strumfovi.pageImage(99), "webcomics/Strumfovi/Strumfovi1099.jpg")
        XCTAssertEqual(strumfovi.pageImage(126), "webcomics/Strumfovi/Strumfovi1126.jpg")

        XCTAssertEqual(try comic(21).pageImage(152), "webcomics/Svinje/Svinje1152.jpg")
        XCTAssertEqual(try comic(18).pageImage(106), "webcomics/VatraSNeba/VSN1106.jpg")
        XCTAssertEqual(try comic(16).pageImage(133),
                       "webcomics/BojeMogaGrada/BojeMogaGrada1133.jpg")
    }

    /// The width cannot be read off the early pages: `Cukaricki101` parses
    /// equally well as a prefix of `Cukaricki10` with one digit, and every
    /// single-digit page fits both readings. Only a page past nine tells them
    /// apart — which is why the rule was checked against one.
    func testTheWidthIsTheOneAPageBeyondNineAgreesWith() throws {
        let cukaricki = try comic(24)
        XCTAssertEqual(cukaricki.pageImage(1), "webcomics/Cukaricki/Cukaricki101.jpg")
        XCTAssertEqual(cukaricki.pageImage(29), "webcomics/Cukaricki/Cukaricki129.jpg")
        XCTAssertEqual(cukaricki.pageImage(57), "webcomics/Cukaricki/Cukaricki157.jpg")
    }

    /// A comic short enough that the ambiguity never surfaces still has to be
    /// right for the pages it does have.
    func testAShortComicIsStillAddressedCorrectly() throws {
        let winter = try comic(15)
        XCTAssertEqual(winter.pages, 8)
        XCTAssertEqual(winter.pageImage(1), "webcomics/WinterSong/winter101.jpg")
        XCTAssertEqual(winter.pageImage(8), "webcomics/WinterSong/winter108.jpg")
    }

    func testEveryComicYieldsExactlyItsPages() throws {
        for comic in try catalogue().comics {
            XCTAssertEqual(comic.pageImages.count, comic.pages, "comic \(comic.id)")
        }
    }

    /// A page outside the run is nil rather than a plausible-looking address
    /// for something that is not there.
    func testAPageOutsideTheRunHasNoAddress() throws {
        let snijeg = try comic(6)
        XCTAssertNil(snijeg.pageImage(0))
        XCTAssertNil(snijeg.pageImage(21))
    }

    // MARK: - Addresses that survive being a URL

    /// One of these directories is `webcomics/lumen&kremen`. A raw `&` is the
    /// kind of character that survives one URL parser and not the next.
    func testAnAwkwardPathStillMakesAURL() throws {
        let file = try catalogue()
        let lumen = try comic(2)
        let path = try XCTUnwrap(lumen.pageImage(1))
        XCTAssertTrue(path.contains("&"), "the fixture that makes this test worth having")

        let absolute = file.url(path)
        let url = try XCTUnwrap(URL(string: absolute))
        XCTAssertEqual(url.host, "www.stripovi.com")
        // The ampersand belongs to the path and must not start a query.
        XCTAssertNil(url.query)
    }

    func testEveryPageOfEveryComicMakesAURL() throws {
        let file = try catalogue()
        for comic in file.comics {
            for path in comic.pageImages {
                XCTAssertNotNil(URL(string: file.url(path)), "comic \(comic.id): \(path)")
            }
        }
    }

    // MARK: - Series

    /// Five of the thirty-one are episodes of one run. The site titles them
    /// "Martina Mjesec 1: Snijeg u kolovozu"; the shelf wants those as a
    /// series, a number and a title rather than one string.
    func testTheOneSeriesIsSplitIntoItsParts() throws {
        let episodes = try catalogue().comics
            .filter { $0.series == "Martina Mjesec" }
            .sorted { $0.number < $1.number }
        XCTAssertEqual(episodes.map(\.id), [6, 7, 8, 9, 10])
        XCTAssertEqual(episodes.map(\.number), [1, 2, 3, 4, 5])
        XCTAssertEqual(episodes.first?.title, "Snijeg u kolovozu")
        XCTAssertEqual(episodes.last?.title, "Odiseja")
        // The run's name must not be left in the episode's own title.
        for episode in episodes {
            XCTAssertFalse(episode.title.contains("Martina Mjesec"), episode.title)
        }
    }

    /// Everything else stands alone, and says so rather than inventing a run
    /// of one.
    func testAComicThatStandsAloneHasNoSeries() throws {
        XCTAssertNil(try comic(24).series)
        XCTAssertEqual(try catalogue().comics.filter { $0.series != nil }.count, 5)
    }

    // MARK: - Addresses on the site

    func testTheReaderAddressUsesThePagingParameter() {
        // `PageNum` is the parameter every link on the site carries and it
        // does nothing; `PageCount` is the one that turns a page.
        let url = Stripovi.readerURL(comic: 6, page: 12)
        XCTAssertTrue(url.contains("ComicID=6"))
        XCTAssertTrue(url.contains("PageCount=12"))
        XCTAssertFalse(url.contains("PageNum"))
    }
}

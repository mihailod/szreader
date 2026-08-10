import XCTest
@testable import SZKit

/// Cover art for StripZona's own scanlations, which are not catalogued on
/// stripovi.com and so carry no issue number in the filename.
final class ScanlationCoverTests: XCTestCase {

    /// Art above the title.
    func testCoverAboveItsTitle() {
        let html = """
            <div><img src="https://www.stripzona.com/uploads/judas_01.jpg"></div>
            <div>1 - Prvi deo</div>
            <div>https://www.mediafire.com/?FAKEKEY001</div>
            <div><img src="https://www.stripzona.com/uploads/judas_02.jpg"></div>
            <div>2 - Drugi deo</div>
            <div>https://www.mediafire.com/?FAKEKEY002</div>
            """
        let covers = Catalog.covers(in: html)
        XCTAssertEqual(covers[1], "https://www.stripzona.com/uploads/judas_01.jpg")
        XCTAssertEqual(covers[2], "https://www.stripzona.com/uploads/judas_02.jpg")
    }

    /// Art below the title — equally common, so neither layout may be assumed.
    func testCoverBelowItsTitle() {
        let html = """
            <div>1 - Prvi deo</div>
            <div><img src="https://www.stripzona.com/uploads/judas_01.jpg"></div>
            <div>2 - Drugi deo</div>
            <div><img src="https://www.stripzona.com/uploads/judas_02.jpg"></div>
            """
        let covers = Catalog.covers(in: html)
        XCTAssertEqual(covers[1], "https://www.stripzona.com/uploads/judas_01.jpg")
        XCTAssertEqual(covers[2], "https://www.stripzona.com/uploads/judas_02.jpg")
    }

    /// Forum furniture outnumbers real covers on a busy topic; without the
    /// filter the first thing every issue gets is an emoticon.
    func testFurnitureIsNotMistakenForCoverArt() {
        let html = """
            <img src="https://www.stripzona.com/public/style_emoticons/default/smile.gif">
            <img src="https://www.stripzona.com/public/style_images/avatar.gif">
            <div>7 - Sedmi deo</div>
            """
        XCTAssertNil(Catalog.covers(in: html)[7])
        XCTAssertFalse(Catalog.isPlausibleCover(
            "https://www.stripzona.com/public/style_emoticons/default/smile.gif"))
        XCTAssertTrue(Catalog.isPlausibleCover(
            "https://www.stripzona.com/uploads/judas_01.jpg"))
    }

    /// The stripovi.com filename names its issue outright, so it must win over
    /// whatever happens to sit nearby in the post.
    func testNumberedCoverBeatsPosition() {
        let html = """
            <div><img src="https://www.stripzona.com/uploads/wrong_art.jpg"></div>
            <div>13 - Nasilje u Darkvudu</div>
            <div><img src="http://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg"></div>
            """
        XCTAssertEqual(Catalog.covers(in: html)[13],
                       "https://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_13.jpg")
    }

    /// An image with no title anywhere near it belongs to no issue.
    func testDistantImageIsNotClaimed() {
        let html = """
            <div><img src="https://www.stripzona.com/uploads/header.jpg"></div>
            <div>filler</div><div>filler</div><div>filler</div>
            <div>filler</div><div>filler</div><div>filler</div>
            <div>9 - Deveti deo</div>
            """
        XCTAssertNil(Catalog.covers(in: html)[9])
    }

    /// Positional matching must not disturb the ordinary stripovi.com path.
    func testNumberedCoversStillWork() {
        let html = """
            <img src="http://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_21.jpg">
            <img src="http://www.stripovi.com/naslovnice/Zagor/TN/TN_ZG_ZS_22.jpg">
            """
        let covers = Catalog.covers(in: html)
        XCTAssertEqual(covers.count, 2)
        XCTAssertTrue(covers[21]!.hasPrefix("https://"))
    }
}

/// Mega hands back an http:// storage node. App Transport Security refuses it
/// outright (NSURLErrorDomain -1022) and the request never leaves the device,
/// so every mega.nz download failed while the error looked like a dead mirror.
final class MegaSecureNodeTests: XCTestCase {

    func testStorageNodeIsForcedToTLS() throws {
        let url = try XCTUnwrap(MegaHost.secureNode(
            "http://gfs302n518.userstorage.mega.co.nz/dl/abc123"))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "gfs302n518.userstorage.mega.co.nz")
        XCTAssertEqual(url.path, "/dl/abc123")
    }

    func testAlreadySecureNodeIsUnchanged() throws {
        let url = try XCTUnwrap(MegaHost.secureNode(
            "https://gfs302n518.userstorage.mega.co.nz/dl/abc123"))
        XCTAssertEqual(url.absoluteString,
                       "https://gfs302n518.userstorage.mega.co.nz/dl/abc123")
    }
}

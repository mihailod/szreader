import XCTest
@testable import SZKit

/// The fence around each in-app browser.
///
/// Small enough to read in a minute and worth testing exhaustively anyway: it
/// is the whole of the difference between "a view of one site" and "a web
/// browser embedded in a comics reader", and every one of the near misses below
/// is a domain anyone could register this afternoon.
final class HostFenceTests: XCTestCase {

    private func admits(_ fence: HostFence, _ address: String) -> Bool {
        guard let url = URL(string: address) else {
            XCTFail("not a URL: \(address)")
            return false
        }
        return fence.admits(url)
    }

    /// The site itself, its subdomains, and the item servers a download lands
    /// on — which are subdomains too, and change from year to year.
    func testItAdmitsTheSiteAndEverythingUnderIt() {
        for address in ["https://archive.org/search",
                        "https://archive.org/details/amiga-bilten-1",
                        "http://archive.org/details/amiga-bilten-1",
                        "https://web.archive.org/web/2020/http://example.com/",
                        "https://ia601403.us.archive.org/BookReader/BookReaderImages.php?id=x",
                        "https://dn720001.ca.archive.org/0/items/x/__ia_thumb.jpg",
                        // Host names are case-insensitive, and a link may be
                        // written in any of them.
                        "https://ARCHIVE.ORG/details/x",
                        "https://Web.Archive.Org/"] {
            XCTAssertTrue(admits(.archive, address), address)
        }

        for address in ["https://www.stripzona.com/port/index.php",
                        "http://stripzona.com/port/index.php",
                        "https://stripzona.com/"] {
            XCTAssertTrue(admits(.stripzona, address), address)
        }
    }

    /// The near misses, which are the only ones that matter.
    ///
    /// `notarchive.org` and `archive.org.example.com` both pass a `contains`
    /// test and the second passes a naive `hasSuffix` on the bare name too.
    /// Matching on a leading dot is what separates a subdomain from a domain
    /// that merely ends in the same letters.
    func testItRefusesEverythingThatMerelyLooksLikeTheSite() {
        for address in ["https://notarchive.org/details/x",
                        "https://archive.org.example.com/details/x",
                        "https://archive.orgx/details/x",
                        "https://example.com/archive.org/details/x",
                        "https://myarchive.org/",
                        "https://example.com/?next=https://archive.org/",
                        "https://mediafire.com/file/abc",
                        "https://stripzona.com.evil.example/port/"] {
            XCTAssertFalse(admits(.archive, address), address)
        }

        // And each fence admits only its own site: the two browsers are two
        // fences, not one shared list.
        XCTAssertFalse(admits(.stripzona, "https://archive.org/details/x"))
        XCTAssertFalse(admits(.archive, "https://www.stripzona.com/port/index.php"))
    }

    /// A way out of the fence that never touches a host name.
    ///
    /// `mailto:` and `tel:` hand the navigation to another app, and
    /// `itms-apps:` opens the App Store — none of which is somewhere a fenced
    /// browser should be able to send anyone. `file:` would read the device.
    func testItRefusesEverySchemeButTheWeb() {
        for address in ["mailto:someone@example.com",
                        "tel:+15551234",
                        "sms:+15551234",
                        "itms-apps://apps.apple.com/app/id6801719481",
                        "file:///etc/passwd",
                        "ftp://archive.org/pub/x",
                        "javascript:alert(1)"] {
            XCTAssertFalse(admits(.archive, address), address)
        }
    }

    /// WebKit loads `about:blank` itself, between pages and on its own
    /// account. Refusing it fences the browser off from its own machinery.
    func testItAdmitsWebKitsOwnBlankPage() {
        XCTAssertTrue(admits(.archive, "about:blank"))
        XCTAssertTrue(admits(.stripzona, "about:blank"))
    }

    /// A URL with no host at all is not somewhere; it is a malformed link, and
    /// the answer to those is no.
    func testAHostlessURLIsRefused() {
        XCTAssertFalse(admits(.archive, "https:///details/x"))
        XCTAssertFalse(admits(.archive, "/details/amiga-bilten-1"))
    }

    /// The fence the archive.org browser uses is the same host the rest of the
    /// app builds its addresses from, rather than a second copy of the string.
    func testTheArchiveFenceIsBuiltFromTheSameHostAsItsURLs() {
        XCTAssertEqual(HostFence.archive.hosts, [ArchiveOrg.host])
        XCTAssertTrue(ArchiveOrg.base.hasPrefix("https://\(ArchiveOrg.host)/"))
        XCTAssertTrue(ArchiveOrg.searchURL.hasPrefix("https://\(ArchiveOrg.host)/"))
    }
}

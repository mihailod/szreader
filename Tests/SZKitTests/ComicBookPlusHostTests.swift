import XCTest
@testable import SZKit

/// Turning a book page into a download.
///
/// The signed-out fixture is a real `?dlid=` page; the signed-in one is that
/// same page with the download cell put back, because the only difference the
/// site makes for a member is what sits in that one cell. The link's shape is
/// taken from a real one with its session token replaced.
final class ComicBookPlusHostTests: XCTestCase {

    private static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/comicbookplus")

    private func signedOutPage() throws -> String {
        try String(contentsOf: Self.fixtures.appendingPathComponent("book-jesse-james-24.html"),
                   encoding: .utf8)
    }

    /// The same page as a member sees it: the register prompt replaced by the
    /// link the site actually serves, `&amp;`-escaped exactly as it writes it.
    private func signedInPage() throws -> String {
        try signedOutPage().replacingOccurrences(
            of: "To download files please",
            with: #"<a href="https://box01.comicbookplus.com/dload/?f=1fb7fbddfbe79e7c3f2acd58b3db0acd&amp;t=cbr&amp;n=Jesse_James_024&amp;sess=SESSIONTOKEN">Download</a> was"#)
    }

    private func host(cookies: String? = nil) -> ComicBookPlusHost {
        ComicBookPlusHost(cookies: { cookies })
    }

    private var bookURL: URL { URL(string: "https://comicbookplus.com/?dlid=102317")! }

    // MARK: - What it claims

    /// Book pages only. The resolved `/dload/` address is on the same domain
    /// and must not be claimed: `directLink` hands it back for the downloader
    /// to fetch, and a host that claimed it too would try to read a comic as
    /// an HTML page.
    func testItClaimsBookPagesAndNotDownloads() {
        let h = host()
        XCTAssertTrue(h.canHandle(bookURL))
        XCTAssertTrue(h.canHandle(URL(string: "https://comicbookplus.com/?dlid=1")!))
        XCTAssertFalse(h.canHandle(
            URL(string: "https://box01.comicbookplus.com/dload/?f=abc&t=cbr&sess=x")!))
        XCTAssertFalse(h.canHandle(URL(string: "https://comicbookplus.com/?cid=1751")!))
        XCTAssertFalse(h.canHandle(URL(string: "https://archive.org/download/x/y.pdf")!))
    }

    // MARK: - Probe

    /// Filename and size are public: only the link to the file is not. So a
    /// shelf can say what a download will cost before anyone has signed in.
    func testItProbesWithoutASession() async throws {
        let page = try signedOutPage()
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(page.utf8)) }
        let meta = try await host().probe(bookURL, via: transport)

        XCTAssertEqual(meta.filename,
                       "Jesse_James_024__Avon_1955.09_10__c2c___Willie_Williams.cbz")
        // "21.61mb" as the page states it, rounded to bytes.
        XCTAssertEqual(meta.size, Int(21.61 * 1_048_576))
        XCTAssertNil(transport.requests.last?.headers["Cookie"],
                     "a probe should not spend the reader's session")
    }

    // MARK: - Resolving

    func testItReadsTheDownloadLinkOffTheSignedInPage() async throws {
        let page = try signedInPage()
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(page.utf8)) }
        let link = try await host(cookies: "SMFCookie350=x; PHPSESSID=y")
            .directLink(bookURL, via: transport)

        XCTAssertEqual(link.url.host, "box01.comicbookplus.com")
        // `URL.path` drops the trailing slash the site writes.
        XCTAssertEqual(link.url.path, "/dload")
        XCTAssertEqual(transport.requests.last?.headers["Cookie"],
                       "SMFCookie350=x; PHPSESSID=y")
    }

    /// The page writes `&amp;` between query parameters. A URL carrying those
    /// literally fetches nothing at all.
    func testTheLinksEntitiesAreDecoded() async throws {
        let page = try signedInPage()
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(page.utf8)) }
        let link = try await host(cookies: "PHPSESSID=y").directLink(bookURL, via: transport)

        XCTAssertFalse(link.url.absoluteString.contains("&amp;"), link.url.absoluteString)
        let items = URLComponents(url: link.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "t" }?.value, "cbr")
        XCTAssertEqual(items.first { $0.name == "sess" }?.value, "SESSIONTOKEN")
    }

    /// The site refuses images without one, and its own pages send it.
    func testItSendsARefererWithTheDownload() async throws {
        let page = try signedInPage()
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(page.utf8)) }
        let link = try await host(cookies: "PHPSESSID=y").directLink(bookURL, via: transport)
        XCTAssertEqual(link.headers["Referer"], bookURL.absoluteString)
    }

    /// Signed out, the site puts a register prompt where the link would be.
    /// The reader can fix that, so the message says how rather than naming a
    /// status code.
    func testSignedOutItSaysToSignIn() async throws {
        let page = try signedOutPage()
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(page.utf8)) }
        do {
            _ = try await host().directLink(bookURL, via: transport)
            XCTFail("resolved a download from a page that offers none")
        } catch {
            let reason = Library.reason(error).lowercased()
            XCTAssertTrue(reason.contains("sign in"), reason)
        }
    }

    /// The download is a PHP script that streams without a `Content-Length`,
    /// so nothing downstream can learn a total from the response. The page
    /// states one, and this is what carries it there — without it the reader
    /// watches a bar at zero and the free-space check has nothing to weigh.
    func testItCarriesTheSizeTheServerWillNotDeclare() async throws {
        let page = try signedInPage()
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(page.utf8)) }
        let link = try await host(cookies: "PHPSESSID=y").directLink(bookURL, via: transport)

        // "21.61mb" as the page states it.
        XCTAssertEqual(link.expectedBytes, Int64(21.61 * 1_048_576))
    }

    func testAMissingBookIsADeadLink() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 404) }
        do {
            _ = try await host().probe(bookURL, via: transport)
            XCTFail("a 404 resolved")
        } catch HostError.notFound {
            // The dead-mirror path, which is what marks the row rather than
            // reporting a mystery to the reader.
        }
    }
}

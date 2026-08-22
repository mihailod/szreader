import XCTest
@testable import SZKit

/// Fetching a Stripovi comic, and what happens when the shipped page-address
/// rule stops being true.
///
/// The rule is an inference about a site that never promised it, so the
/// behaviour that matters here is the demotion: the first address that does
/// not work must make the rest of the download read its addresses off the
/// site, exactly as if no rule had ever shipped.
final class StripoviFetcherTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("stripovi-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixture

    /// Three pages, so a break at page two has something on either side of it.
    private func catalogue(pages: Int = 3) throws -> StripoviCatalog {
        let json = """
        {"version": 1, "generated": "2026-01-01", "base": "https://www.stripovi.com/",
         "comics": [{"id": 99, "title": "Proba", "series": null, "number": 1,
                     "pages": \(pages), "cover": "images/TN_proba.jpg",
                     "creators": "Netko (crtež)", "date": null, "lead": null,
                     "dir": "webcomics/Proba", "prefix": "proba1",
                     "width": 2, "ext": ".jpg"}]}
        """
        return try StripoviCatalog.decode(Data(json.utf8))
    }

    private func comic(_ file: StripoviCatalog) throws -> StripoviCatalog.Comic {
        try XCTUnwrap(file.comics.first)
    }

    private var jpeg: Data { Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x20, count: 32) }

    /// The address the rule builds for a page, and the reader page it would
    /// fall back to.
    private func ruleAddress(_ page: Int) -> String {
        "https://www.stripovi.com/webcomics/Proba/proba1\(String(format: "%02d", page)).jpg"
    }
    private func resolvedAddress(_ page: Int) -> String {
        "https://www.stripovi.com/webcomics/Proba/elsewhere-\(page).jpg"
    }
    private func readerPage(_ page: Int) -> String {
        "<html><body><div id=\"comic-container\"><img src=\"webcomics/Proba/elsewhere-\(page).jpg\"></div></body></html>"
    }

    private func fetch(_ transport: StubTransport, pages: Int = 3)
        async throws -> StripoviFetchResult {
        let file = try catalogue(pages: pages)
        return try await StripoviFetcher(transport: transport, interval: .zero)
            .fetch(comic: try comic(file), in: file, into: directory)
    }

    // MARK: - The rule works

    func testItFetchesEveryPageFromTheRule() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: self.jpeg) }
        let result = try await fetch(transport)

        XCTAssertEqual(result.pages, 3)
        XCTAssertFalse(result.resolvedFromSite)
        XCTAssertEqual(transport.requests.count, 3, "one request per page and no more")
        XCTAssertEqual(transport.requests.map(\.url.absoluteString),
                       (1...3).map(ruleAddress))
    }

    /// The finished directory is a comic, which is the whole point.
    func testAFinishedFetchIsReadable() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: self.jpeg) }
        _ = try await fetch(transport)
        XCTAssertEqual(try ComicDocument(unpackedAt: directory).pageCount, 3)
    }

    // MARK: - The rule stops being true

    /// A stub whose rule addresses stop working from `breaksAt` onward, and
    /// which answers the reader page with somewhere else entirely.
    private func breakingTransport(at breaksAt: Int) -> StubTransport {
        StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("index.asp") {
                let page = Int(url.split(separator: "=").last ?? "") ?? 0
                return HTTPResponse(status: 200,
                                    body: Data(self.readerPage(page).utf8))
            }
            if url.contains("elsewhere-") {
                return HTTPResponse(status: 200, body: self.jpeg)
            }
            let page = Int(url.suffix(6).prefix(2)) ?? 0
            return page >= breaksAt ? HTTPResponse(status: 404)
                                    : HTTPResponse(status: 200, body: self.jpeg)
        }
    }

    func testABrokenAddressDemotesTheRestOfTheDownload() async throws {
        let transport = breakingTransport(at: 2)
        let result = try await fetch(transport)

        XCTAssertTrue(result.resolvedFromSite, "the download must report it worked around the rule")
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(try ComicDocument(unpackedAt: directory).pageCount, 3,
                       "the comic must still be complete")
    }

    /// Once demoted it stays demoted — the rule is not retried on later pages,
    /// which is what "behave as though there were no page list" means.
    func testItDoesNotGoBackToTheRuleAfterDemoting() async throws {
        let transport = breakingTransport(at: 2)
        _ = try await fetch(transport)

        let addresses = transport.requests.map(\.url.absoluteString)
        XCTAssertTrue(addresses.contains(ruleAddress(1)), "page one used the rule")
        XCTAssertFalse(addresses.contains(ruleAddress(3)),
                       "page three asked the rule again after it had already failed")
        XCTAssertTrue(addresses.contains(resolvedAddress(3)))
    }

    /// A page of HTML served with a 200 is what a site returns when an address
    /// stops existing. It must demote rather than be written as a page.
    func testSomethingThatIsNotAnImageAlsoDemotes() async throws {
        let transport = StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("index.asp") {
                let page = Int(url.split(separator: "=").last ?? "") ?? 0
                return HTTPResponse(status: 200, body: Data(self.readerPage(page).utf8))
            }
            if url.contains("elsewhere-") { return HTTPResponse(status: 200, body: self.jpeg) }
            // 200, with a page of markup where a picture should be.
            return HTTPResponse(status: 200, body: Data("<!doctype html><html>".utf8))
        }
        let result = try await fetch(transport)
        XCTAssertTrue(result.resolvedFromSite)
        XCTAssertEqual(try ComicDocument(unpackedAt: directory).pageCount, 3)
    }

    // MARK: - Pages the site does not have

    /// The site's page menu counts a page, its markup links it, and the file
    /// is not on the server. Real: Šahist counts 25 pages and `Sahist_125.jpg`
    /// 404s; Snijeg u kolovozu counts 20 and `mm0118.jpg` 404s while 19 and 20
    /// are served normally.
    private func holeAt(_ gone: Int) -> StubTransport {
        StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("index.asp") {
                let page = Int(url.split(separator: "=").last ?? "") ?? 0
                // The site names exactly the address the rule built — it
                // agrees with us, and the file is simply not there.
                let path = "webcomics/Proba/proba1\(String(format: "%02d", page)).jpg"
                return HTTPResponse(status: 200, body: Data(
                    "<div id=\"comic-container\"><img src=\"\(path)\"></div>".utf8))
            }
            let page = Int(url.suffix(6).prefix(2)) ?? 0
            return page == gone ? HTTPResponse(status: 404)
                                : HTTPResponse(status: 200, body: self.jpeg)
        }
    }

    /// A hole in the source costs that page and nothing else. Refusing to
    /// finish would mean the comic could never be read at all.
    func testAPageTheSiteDoesNotHaveIsSkipped() async throws {
        let result = try await fetch(holeAt(2))
        XCTAssertEqual(result.missingFromSource, [2])
        XCTAssertEqual(result.pages, 2, "three pages counted, one of them gone")
        XCTAssertEqual(try ComicDocument(unpackedAt: directory).pageCount, 2)
    }

    /// It is a hole, not a stale rule. Demoting would spend a second request
    /// on every remaining page to be told the same thing.
    func testAHoleDoesNotDemoteTheRestOfTheDownload() async throws {
        let transport = holeAt(2)
        let result = try await fetch(transport)
        XCTAssertFalse(result.resolvedFromSite)

        // Page 3 went straight to the rule rather than asking the site again.
        let asked = transport.requests.filter { $0.url.absoluteString.contains("index.asp") }
        XCTAssertEqual(asked.count, 1, "the site was asked about more than the missing page")
        XCTAssertTrue(transport.requests.map(\.url.absoluteString).contains(ruleAddress(3)))
    }

    /// Every page gone is not a short comic, it is no comic — and a marker
    /// written over an empty directory would claim otherwise.
    func testAComicWithNoPagesLeftIsNotFinished() async throws {
        let transport = StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("index.asp") {
                let page = Int(url.split(separator: "=").last ?? "") ?? 0
                let path = "webcomics/Proba/proba1\(String(format: "%02d", page)).jpg"
                return HTTPResponse(status: 200, body: Data(
                    "<div id=\"comic-container\"><img src=\"\(path)\"></div>".utf8))
            }
            return HTTPResponse(status: 404)
        }
        do {
            _ = try await fetch(transport)
            XCTFail("a comic with every page missing must not be marked complete")
        } catch let error as PageFetchError {
            XCTAssertEqual(error, .noPages)
        }
        XCTAssertThrowsError(try ComicDocument(unpackedAt: directory))
    }

    /// A 404 whose page the site says lives *somewhere else* is the rule going
    /// stale, and must still demote rather than be written off as a hole.
    func testA404TheSiteDisagreesWithStillDemotes() async throws {
        let result = try await fetch(breakingTransport(at: 2))
        XCTAssertTrue(result.resolvedFromSite)
        XCTAssertEqual(result.missingFromSource, [])
        XCTAssertEqual(result.pages, 3)
    }

    // MARK: - Redirects

    /// The site stores some files under a lowercased path and answers the
    /// mixed-case one with a 301 — per *file*, not per comic. Refusing to
    /// follow that turned an ordinary redirect into a comic that could not be
    /// downloaded at all.
    func testARedirectIsFollowed() async throws {
        let transport = StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("/Proba/") {
                return HTTPResponse(status: 301, headers: [
                    "Location": url.replacingOccurrences(of: "/Proba/", with: "/proba/")])
            }
            return HTTPResponse(status: 200, body: self.jpeg)
        }
        let result = try await fetch(transport)
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(try ComicDocument(unpackedAt: directory).pageCount, 3)
    }

    /// Following a redirect is not the rule going stale: the address named a
    /// real page and the server said where it keeps it. Demoting would spend
    /// an extra request per page on something one hop settles.
    func testARedirectDoesNotDemote() async throws {
        let transport = StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("/Proba/") {
                return HTTPResponse(status: 301, headers: [
                    "Location": url.replacingOccurrences(of: "/Proba/", with: "/proba/")])
            }
            return HTTPResponse(status: 200, body: self.jpeg)
        }
        let result = try await fetch(transport)
        XCTAssertFalse(result.resolvedFromSite)
        XCTAssertFalse(transport.requests.contains { $0.url.absoluteString.contains("index.asp") })
    }

    /// A server redirecting to itself must not spin the download for ever.
    func testARedirectLoopGivesUp() async throws {
        let transport = StubTransport { request in
            HTTPResponse(status: 301, headers: ["Location": request.url.absoluteString])
        }
        do {
            _ = try await fetch(transport)
            XCTFail("a redirect loop must not run for ever")
        } catch let error as PageFetchError {
            XCTAssertTrue("\(error)".contains("too many redirects"), "\(error)")
        }
    }

    /// A redirect off the site is a page fetched from somewhere nobody chose.
    func testARedirectOffTheSiteIsRefused() async throws {
        let transport = StubTransport { _ in
            HTTPResponse(status: 302, headers: ["Location": "https://example.com/page.jpg"])
        }
        do {
            _ = try await fetch(transport)
            XCTFail("a redirect off the site must be refused")
        } catch let error as PageFetchError {
            XCTAssertTrue("\(error)".contains("off the site"), "\(error)")
        }
    }

    /// A relative `Location` is resolved against the address it came from.
    func testARelativeRedirectIsResolved() async throws {
        let transport = StubTransport { request in
            let url = request.url.absoluteString
            if url.contains("/Proba/") {
                return HTTPResponse(status: 301, headers: ["Location": "/webcomics/proba/x.jpg"])
            }
            return HTTPResponse(status: 200, body: self.jpeg)
        }
        _ = try await fetch(transport)
        XCTAssertTrue(transport.requests.contains {
            $0.url.absoluteString == "https://www.stripovi.com/webcomics/proba/x.jpg"
        }, transport.requests.map(\.url.absoluteString).description)
    }

    // MARK: - A refusal is not a broken rule

    /// The one failure that must *not* demote. Resolving answers a server
    /// asking to be left alone with two requests per page instead of one.
    func testARefusalStopsTheDownloadInsteadOfResolving() async throws {
        let transport = StubTransport { _ in
            HTTPResponse(status: 429, headers: ["Retry-After": "120"])
        }
        do {
            _ = try await fetch(transport)
            XCTFail("a refusal must stop the download")
        } catch let refusal as DownloadError {
            XCTAssertTrue(refusal.isRateLimited)
        }
        XCTAssertFalse(transport.requests.contains { $0.url.absoluteString.contains("index.asp") },
                       "it asked the site for addresses after being told to stop")
    }

    // MARK: - Resume

    func testPagesAlreadyOnDiskAreNotFetchedAgain() async throws {
        let first = StubTransport { _ in HTTPResponse(status: 200, body: self.jpeg) }
        _ = try await fetch(first)

        let second = StubTransport { _ in HTTPResponse(status: 200, body: self.jpeg) }
        let result = try await fetch(second)
        XCTAssertEqual(second.requests.count, 0, "everything was already here")
        XCTAssertEqual(result.pages, 3)
    }

    // MARK: - Requests the site would recognise

    /// Zero is the default and means "do not read the body", which here would
    /// write a comic of empty pages.
    func testTheBodyIsActuallyRead() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: self.jpeg) }
        _ = try await fetch(transport)
        for request in transport.requests {
            XCTAssertGreaterThan(request.maxBodyBytes, 0)
        }
    }

    func testEachPageIsAskedForAsAPictureOfItsComic() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: self.jpeg) }
        _ = try await fetch(transport)
        let referers = Set(transport.requests.compactMap { $0.headers["Referer"] })
        XCTAssertEqual(referers, [Stripovi.comicURL(id: 99)])
    }
}

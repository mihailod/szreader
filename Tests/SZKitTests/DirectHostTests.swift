import XCTest
@testable import SZKit

/// Downloading a plain file off a web server.
final class DirectHostTests: XCTestCase {

    private let host = DirectHost()

    // MARK: - What it claims

    /// Scoped to the archive the catalogue points at, and nothing else.
    ///
    /// A catch-all here would swallow every unrecognised link on a forum page.
    /// Those fail today as `noHostFor`, which names the host so it can be
    /// added; as a "direct" download they would instead fetch whatever HTML
    /// the server returned and be diagnosed several steps later as bytes that
    /// match neither zip nor rar.
    func testItClaimsOnlyItsOwnArchive() throws {
        XCTAssertTrue(host.canHandle(
            URL(string: "https://retrospec.elite.org/pcsux/SKH/ZIP/1984_10.zip")!))
        XCTAssertTrue(host.canHandle(
            URL(string: "http://RetroSpec.Elite.ORG/pcsux/x.zip")!), "host is case-insensitive")

        for other in ["http://www.mediafire.com/?x0mrij299kyr947",
                      "https://mega.nz/file/FAKEID#K",
                      "https://pixeldrain.com/u/abc123",
                      "https://example.com/some/file.zip",
                      // Not the same host: a subdomain is a different server.
                      "https://cdn.retrospec.elite.org/x.zip"] {
            XCTAssertFalse(host.canHandle(URL(string: other)!), other)
        }
        // Nothing but the web.
        XCTAssertFalse(host.canHandle(URL(string: "ftp://retrospec.elite.org/x.zip")!))
        XCTAssertFalse(host.canHandle(URL(string: "file:///tmp/x.zip")!))
    }

    /// The registry routes each URL to exactly one host, with no contest.
    func testTheRegistryRoutesEachURLOnce() throws {
        let registry = HostRegistry()
        let expected = [
            "https://retrospec.elite.org/pcsux/SKH/ZIP/1984_10.zip": "direct",
            "http://www.mediafire.com/?x0mrij299kyr947": "mediafire",
            "https://mega.nz/file/FAKEID#K": "mega",
            "https://pixeldrain.com/u/abc123": "pixeldrain",
        ]
        for (url, name) in expected {
            let claimants = registry.hosts.filter { $0.canHandle(URL(string: url)!) }
            XCTAssertEqual(claimants.count, 1, "\(url) claimed by \(claimants.map(\.name))")
            XCTAssertEqual(claimants.first?.name, name, url)
        }
        // And an unknown host is still nobody's, so it fails by name rather
        // than being fetched blind.
        XCTAssertNil(registry.host(for: URL(string: "https://example.com/x.zip")!))
    }

    // MARK: - What it answers

    /// The filename is in the URL, so no request is made to learn it.
    func testProbeCostsNothing() async throws {
        let transport = StubTransport { _ in
            XCTFail("a static file server should not be asked anything")
            return .init(status: 500)
        }
        let meta = try await host.probe(
            URL(string: "https://retrospec.elite.org/pcsux/SKH/ZIP/1984_10.zip")!,
            via: transport)
        XCTAssertEqual(meta.filename, "1984_10.zip")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testTheLinkIsTheURLItself() async throws {
        let transport = StubTransport { _ in .init(status: 500) }
        let url = URL(string: "https://retrospec.elite.org/pcsux/SKH/ZIP/1984_10.zip")!
        let link = try await host.directLink(url, via: transport)
        XCTAssertEqual(link.url, url)
        XCTAssertNil(link.postProcess, "nothing to decrypt")
        XCTAssertTrue(link.headers.isEmpty)
    }

    // MARK: - End to end, against a real socket

    private func zipOfOnePage(named name: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A 1x1 PNG is enough: the reader only has to find one page.
        let png = Data(base64Encoded: """
            iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmM\
            IQAAAABJRU5ErkJggg==
            """)!
        try png.write(to: dir.appendingPathComponent(name))

        let archive = dir.appendingPathComponent("out.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-X", archive.path, name]
        p.currentDirectoryURL = dir
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("zip unavailable") }
        return try Data(contentsOf: archive)
    }

    /// The whole path, with nothing stubbed between the catalogue row and a
    /// readable comic: a seeded issue, its URL resolved by `DirectHost`,
    /// fetched over a socket by the real downloader, sniffed as a zip and
    /// recorded as downloaded.
    func testASeededIssueDownloadsFromAServer() async throws {
        let body = try zipOfOnePage(named: "sk19841001.png")
        let server = try TinyHTTPServer(routes: ["/pcsux/SKH/ZIP/1984_10.zip": body])
        defer { server.stop() }

        let store = try Store()
        let issueID = try seedOneIssue(into: store, base: server.base + "/pcsux/")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in .init(status: 500) },
                              downloader: URLSessionDownloader(),
                              registry: HostRegistry(hosts: [DirectHost(hosts: ["127.0.0.1"])]))

        let outcome = try await library.fetch(issueID: issueID)

        XCTAssertEqual(outcome.kind, .zip)
        XCTAssertEqual(outcome.bytes, Int64(body.count))
        // Named from the URL rather than "\(id).bin", because the seed
        // recorded the filename.
        XCTAssertEqual(outcome.path.lastPathComponent, "1984_10.zip")
        XCTAssertEqual(server.requested, ["/pcsux/SKH/ZIP/1984_10.zip"],
                       "one request, no probe")

        // The library agrees it is here, and it opens.
        XCTAssertTrue(try store.recent(limit: nil).first?.isDownloaded ?? false)
        let document = try library.document(forIssue: issueID)
        XCTAssertEqual(document.pageCount, 1)
    }

    /// A server having a moment is asked again, rather than reported to the
    /// reader as a download that failed.
    ///
    /// This is archive.org, measured: the same URL answered 500 to three of
    /// eight requests and served the file on the other five. An issue there
    /// has one mirror and nothing to fall back to, so without this a third of
    /// downloads ended in "every mirror failed: HTTP 500".
    func testAServerErrorIsRetried() async throws {
        let body = try zipOfOnePage(named: "sk19841001.png")
        let server = try TinyHTTPServer(routes: ["/pcsux/SKH/ZIP/1984_10.zip": body],
                                        failFirst: 2)
        defer { server.stop() }

        let store = try Store()
        let issueID = try seedOneIssue(into: store, base: server.base + "/pcsux/")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in .init(status: 500) },
                              downloader: URLSessionDownloader(),
                              registry: HostRegistry(hosts: [DirectHost(hosts: ["127.0.0.1"])]))

        let outcome = try await library.fetch(issueID: issueID)
        XCTAssertEqual(outcome.bytes, Int64(body.count))
        XCTAssertEqual(server.requested.count, 3, "the two 500s should have been retried")
    }

    /// A missing archive fails by saying so, and the issue is marked rather
    /// than silently looking untouched.
    ///
    /// This is what the eight dead RetroSpec links do. Nothing marks them
    /// dead in advance: the site may restore them, so the answer is found out
    /// each time rather than frozen at build time.
    func testAMissingArchiveFailsWithItsStatus() async throws {
        let server = try TinyHTTPServer(routes: [:])
        defer { server.stop() }

        let store = try Store()
        let issueID = try seedOneIssue(into: store, base: server.base + "/pcsux/")
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in .init(status: 500) },
                              downloader: URLSessionDownloader(),
                              registry: HostRegistry(hosts: [DirectHost(hosts: ["127.0.0.1"])]))

        do {
            _ = try await library.fetch(issueID: issueID)
            XCTFail("a 404 should not produce a comic")
        } catch let error as DownloadError {
            XCTAssertTrue(Library.reason(error).contains("404"), Library.reason(error))
        }
        XCTAssertFalse(try store.recent(limit: nil).first?.isDownloaded ?? true)
    }

    /// One issue from a catalogue pointed at the test server.
    private func seedOneIssue(into store: Store, base: String) throws -> Int {
        let file = ShippedCatalog(
            version: ShippedCatalog.currentVersion,
            generated: "2026-01-01", base: base,
            series: [.init(key: "SK", name: "Svet Kompjutera", code: "SK",
                           language: "serbian")],
            issues: [.init(id: "SK_84_10", series: "SK", number: 1,
                           title: "Oktobar 1984", year: 1984, month: 10,
                           zip: "SKH/ZIP/1984_10.zip",
                           cover: "SKH/Covers/SK8410-00.jpg",
                           thumb: "SKH/SK8410-00.jpg",
                           bytes: nil, pages: 48, dead: nil)])
        try store.seed(file)
        return try XCTUnwrap(store.recent(limit: nil).first?.id)
    }
}

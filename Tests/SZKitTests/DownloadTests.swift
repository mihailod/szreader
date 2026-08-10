import XCTest
@testable import SZKit

/// Writes canned bytes instead of hitting the network.
final class StubDownloader: FileDownloader, @unchecked Sendable {
    private let bodies: [String: Data]      // keyed by direct-link host
    private(set) var fetched: [URL] = []
    var failWith: Error?

    init(bodies: [String: Data]) { self.bodies = bodies }

    func download(_ link: DirectLink, to destination: URL,
                  progress: (@Sendable (DownloadProgress) -> Void)?) async throws {
        if let failWith { throw failWith }
        fetched.append(link.url)
        let data = bodies[link.url.host ?? ""] ?? Data()
        guard !data.isEmpty else { throw DownloadError.emptyFile }
        try data.write(to: destination)
        progress?(DownloadProgress(received: Int64(data.count), expected: Int64(data.count)))
    }
}

private let zipBytes = Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: UInt8(0x41), count: 200))
private let rarBytes = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07] + Array(repeating: UInt8(0x42), count: 200))

final class ArchiveSniffTests: XCTestCase {

    /// A large share of scene `.cbr` files are really zips, so the extension
    /// proves nothing and the magic bytes decide.
    func testSniffIgnoresExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let liar = dir.appendingPathComponent("actually-a-zip.cbr")
        try zipBytes.write(to: liar)
        XCTAssertEqual(ArchiveKind.sniff(liar), .zip)

        let rar = dir.appendingPathComponent("actually-a-rar.cbz")
        try rarBytes.write(to: rar)
        XCTAssertEqual(ArchiveKind.sniff(rar), .rar)

        let junk = dir.appendingPathComponent("noise.cbr")
        try Data(repeating: 0x00, count: 64).write(to: junk)
        XCTAssertEqual(ArchiveKind.sniff(junk), .unknown)
    }
}

final class CTRDecryptionTests: XCTestCase {

    // Vector produced by `openssl enc -aes-128-ctr`, so the primitive is
    // checked against an authoritative implementation, not just itself.
    private let key = Data([0x55, 0x87, 0xe2, 0x86, 0xca, 0xf6, 0xf7, 0x0d,
                            0x58, 0x6d, 0x64, 0x6c, 0xdf, 0xaf, 0x60, 0x8e])
    private let nonce = Data([0x55, 0x97, 0x61, 0x96, 0x9b, 0x71, 0xd7, 0x9f])
    private var plain: Data { Data((0..<300).map { UInt8(($0 * 7 + 13) % 256) }) }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMatchesOpenSSLVector() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let cipher = Data([0x51, 0xd7, 0x8b, 0x7d, 0xfa, 0x75, 0x74, 0x84,
                           0x80, 0x29, 0x15, 0xfc, 0x3e, 0x17, 0x78, 0x49])
        let src = dir.appendingPathComponent("head.bin")
        let dst = dir.appendingPathComponent("head.out")
        try cipher.write(to: src)
        try AES.decryptCTR(source: src, destination: dst, key: key, nonce: nonce)
        XCTAssertEqual(try Data(contentsOf: dst), plain.prefix(16))
    }

    /// Streaming must produce byte-identical output regardless of chunk size —
    /// a counter that resets per chunk would corrupt everything after block 1
    /// and only show up on files larger than the buffer.
    func testChunkBoundariesDoNotCorruptOutput() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("full.bin")

        // Encrypt by decrypting: CTR is symmetric.
        let plainSrc = dir.appendingPathComponent("plain.bin")
        try plain.write(to: plainSrc)
        try AES.decryptCTR(source: plainSrc, destination: src, key: key, nonce: nonce)

        for chunk in [16, 17, 64, 256, 1 << 20] {
            let out = dir.appendingPathComponent("out-\(chunk).bin")
            try AES.decryptCTR(source: src, destination: out,
                               key: key, nonce: nonce, chunkSize: chunk)
            XCTAssertEqual(try Data(contentsOf: out), plain, "chunk size \(chunk)")
        }
    }
}

final class LibraryTests: XCTestCase {

    private func makeLibrary(store: Store, downloader: FileDownloader,
                             transport: Transport) throws -> (Library, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let lib = Library(store: store, paths: LibraryPaths(root: root),
                          transport: transport, downloader: downloader)
        return (lib, root)
    }

    /// MediaFire direct-link page, then the file itself.
    private func mediafireTransport() -> StubTransport {
        StubTransport { req in
            let html = "<a href=\"https://download937.mediafire.com/tok/key/comic.cbr\">go</a>"
            return HTTPResponse(status: 200, body: Data(html.utf8))
        }
    }

    func testDownloadsAndSniffsArchive() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?aaaaaaaaaaaaaaa</div>
            """)
        let issue = try XCTUnwrap(try store.search("nasilje").first)
        let downloader = StubDownloader(bodies: ["download937.mediafire.com": zipBytes])
        let (lib, root) = try makeLibrary(store: store, downloader: downloader,
                                          transport: mediafireTransport())
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try await lib.fetch(issueID: issue.id)
        XCTAssertEqual(outcome.kind, .zip)
        XCTAssertEqual(outcome.bytes, Int64(zipBytes.count))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outcome.path.path))
        // No .part left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(
            atPath: outcome.path.deletingLastPathComponent().path)
        XCTAssertFalse(leftovers.contains { $0.hasSuffix(".part") })
    }

    /// The whole point of `drugi sken`: a dead primary must cost the user
    /// nothing, and must be remembered so it is not retried first next time.
    func testFallsBackToSecondMirrorAndRemembersTheDeadOne() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>021-Kuca uzasa</div>
            <div>http://www.mediafire.com/?deadaaaaaaaaaaa</div>
            <div>https://pixeldrain.com/u/AbCd1234</div>
            """)
        let issue = try XCTUnwrap(try store.search("kuca").first)
        XCTAssertEqual(issue.mirrorCount, 2)

        let transport = StubTransport { req in
            if req.url.host?.contains("mediafire") == true { return HTTPResponse(status: 404) }
            return HTTPResponse(status: 200, body: Data(#"{"name":"c.cbz","size":204}"#.utf8))
        }
        let downloader = StubDownloader(bodies: ["pixeldrain.com": zipBytes])
        let (lib, root) = try makeLibrary(store: store, downloader: downloader,
                                          transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try await lib.fetch(issueID: issue.id)
        XCTAssertTrue(outcome.mirrorURL.contains("pixeldrain"))

        // The dead MediaFire mirror now sorts last.
        let ordered = try store.liveMirrors(forIssue: issue.id)
        XCTAssertTrue(ordered.last!.url.contains("mediafire"))
    }

    func testAllMirrorsDeadReportsEveryReason() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>030-Nema nista</div><div>http://www.mediafire.com/?deadaaaaaaaaaaa</div>
            """)
        let issue = try XCTUnwrap(try store.search("nema").first)
        let transport = StubTransport { _ in HTTPResponse(status: 404) }
        let (lib, root) = try makeLibrary(store: store,
                                          downloader: StubDownloader(bodies: [:]),
                                          transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await lib.fetch(issueID: issue.id)
            XCTFail("expected allMirrorsFailed")
        } catch let error as DownloadError {
            XCTAssertTrue("\(error)".contains("every mirror failed"))
        }
    }

    /// Bytes that decrypt to noise, or a truncated mirror, must not be filed
    /// away as a comic — the magic-byte check is the guard.
    func testNonArchiveIsRejectedAndRemoved() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>040-Smece</div><div>http://www.mediafire.com/?aaaaaaaaaaaaaaa</div>
            """)
        let issue = try XCTUnwrap(try store.search("smece").first)
        let junk = Data(repeating: 0x7F, count: 128)
        let downloader = StubDownloader(bodies: ["download937.mediafire.com": junk])
        let (lib, root) = try makeLibrary(store: store, downloader: downloader,
                                          transport: mediafireTransport())
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            _ = try await lib.fetch(issueID: issue.id)
            XCTFail("expected notAnArchive")
        } catch let error as DownloadError {
            XCTAssertTrue("\(error)".contains("not a CBZ/CBR"))
        }
        XCTAssertEqual(store.downloadedCount, 0)
    }

    /// Tapping READ twice must not download twice.
    func testSecondFetchReturnsCachedFile() async throws {
        let store = try Store()
        try store.ingest(html: """
            <div>050-Opet</div><div>http://www.mediafire.com/?aaaaaaaaaaaaaaa</div>
            """)
        let issue = try XCTUnwrap(try store.search("opet").first)
        let downloader = StubDownloader(bodies: ["download937.mediafire.com": zipBytes])
        let (lib, root) = try makeLibrary(store: store, downloader: downloader,
                                          transport: mediafireTransport())
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try await lib.fetch(issueID: issue.id)
        let second = try await lib.fetch(issueID: issue.id)
        XCTAssertEqual(first.path, second.path)
        XCTAssertEqual(downloader.fetched.count, 1, "downloaded twice")
    }

    /// Mega's bytes arrive encrypted; the CTR pass runs after the transfer so a
    /// background URLSession can do the fetching.
    func testMegaDownloadIsDecryptedAfterTransfer() async throws {
        let store = try Store()
        let fragment = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789-_ABCDEFGH"
        try store.ingest(html: """
            <div>060-Sifrovano</div><div>https://mega.nz/file/dMoiVBZY#\(fragment)</div>
            """)
        let issue = try XCTUnwrap(try store.search("sifrovano").first)

        // Pre-encrypt a zip with the same key material the host will derive.
        let (key, nonce) = try MegaHost.derive(fragment: fragment)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plainURL = dir.appendingPathComponent("p.bin")
        let cipherURL = dir.appendingPathComponent("c.bin")
        try zipBytes.write(to: plainURL)
        try AES.decryptCTR(source: plainURL, destination: cipherURL, key: key, nonce: nonce)

        let transport = StubTransport { _ in
            HTTPResponse(status: 200,
                         body: Data(#"[{"g":"https://gfs1.userstorage.mega.co.nz/dl/a","s":204}]"#.utf8))
        }
        let downloader = StubDownloader(
            bodies: ["gfs1.userstorage.mega.co.nz": try Data(contentsOf: cipherURL)])
        let (lib, root) = try makeLibrary(store: store, downloader: downloader,
                                          transport: transport)
        defer { try? FileManager.default.removeItem(at: root) }

        let outcome = try await lib.fetch(issueID: issue.id)
        XCTAssertEqual(outcome.kind, .zip, "decryption produced non-archive bytes")
        XCTAssertEqual(try Data(contentsOf: outcome.path), zipBytes)
    }
}

import XCTest
@testable import SZKit

// Fixtures from libarchive's BSD-licensed test suite: one RAR4 archive
// (magic 52 61 72 21 1a 07 00) and one RAR5 (… 1a 07 01). The corpus spans
// 2009-2026 uploads, so both format generations have to work.
let rarFixtureBase64 = """
    UmFyIRoHAM+QcwAADQAAAAAAAACEUnQgkDIAFAAAABQAAAADQqLIvrd22j4UMAgApIEAAHRlc3Qu\
    dHh0gAi3dto+t3baPnRlc3QgdGV4dCBkb2N1bWVudA0KnS90IJAyAAgAAAAIAAAAA3tEybbRTNg+\
    FDAIAP+hAAB0ZXN0bGlua8AI0UzYPlBf2j50ZXN0LnR4dM3gdCCQOgAUAAAAFAAAAANCosi+Y3fa\
    PhQwEACkgQAAdGVzdGRpclx0ZXN0LnR4dMDMY3faPmN32j50ZXN0IHRleHQgZG9jdW1lbnQNCqHI\
    dOCQMQAAAAAAAAAAAAMAAAAAY3faPhQwBwDtQQAAdGVzdGRpcsDMY3faPmR32j7m53TgkDYAAAAA\
    AAAAAAADAAAAAJ2r1T4UMAwA7UEAAHRlc3RlbXB0eWRpcoDMnavVPsVd2j7EPXsAQAcA
    """

private let rar5Base64 = """
    UmFyIRoHAQAzkrXlCgEFBgAFAQGAgAA4MAZjLAIDC50ABJ0ApIMCtEOglYAAAQ5oZWxsb3dvcmxk\
    LnR4dAoDE34Oq1tW6Q4aaGVsbG8gbGliYXJjaGl2ZSB0ZXN0IHN1aXRlIQodd1ZRAwUEAA==
    """

final class RarReaderTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func write(_ base64: String, as name: String) throws -> URL {
        let data = try XCTUnwrap(Data(base64Encoded: base64
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: " ", with: "")))
        let url = scratch.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: - RAR4

    func testListsRar4EntriesWithoutUnpacking() throws {
        let url = try write(rarFixtureBase64, as: "v4.rar")
        let names = try RarReader.list(archiveAt: url)
        XCTAssertTrue(names.contains("test.txt"), "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("test.txt") && $0 != "test.txt" },
                      "expected a nested entry too: \(names)")
        // Directory entries are excluded by the shim.
        XCTAssertFalse(names.contains("testemptydir"))
    }

    func testExtractsRar4Content() throws {
        let url = try write(rarFixtureBase64, as: "v4.rar")
        let reader = try RarReader(url: url, workDirectory: scratch.appendingPathComponent("out4"))
        let entries = try reader.entries()
        XCTAssertTrue(entries.contains("test.txt"), "\(entries)")

        let data = try reader.data(for: "test.txt")
        XCTAssertEqual(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                       "test text document")
    }

    /// Nested paths must survive extraction, since comics are often one
    /// directory deep inside the archive.
    func testPreservesNestedPaths() throws {
        let url = try write(rarFixtureBase64, as: "v4.rar")
        let reader = try RarReader(url: url, workDirectory: scratch.appendingPathComponent("nested"))
        let nested = try XCTUnwrap(try reader.entries().first { $0.contains("/") })
        XCTAssertTrue(nested.hasSuffix("test.txt"))
        XCTAssertFalse(try reader.data(for: nested).isEmpty)
    }

    // MARK: - RAR5

    /// RAR5 is a different container generation; older readers reject it.
    func testExtractsRar5Content() throws {
        let url = try write(rar5Base64, as: "v5.rar")
        let reader = try RarReader(url: url, workDirectory: scratch.appendingPathComponent("out5"))
        XCTAssertEqual(try reader.entries(), ["helloworld.txt"])
        XCTAssertEqual(String(decoding: try reader.data(for: "helloworld.txt"), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       "hello libarchive test suite!")
    }

    // MARK: - Routing and failure

    /// The opener dispatches on magic bytes, so a `.cbz` that is really a RAR
    /// still opens — mislabelled files are common in the corpus.
    func testOpenerRoutesRarByMagicBytesNotExtension() throws {
        let url = try write(rar5Base64, as: "mislabelled.cbz")
        let reader = try ArchiveOpener.open(url, workDirectory: scratch.appendingPathComponent("o"))
        XCTAssertEqual(try reader.entries(), ["helloworld.txt"])
    }

    func testCorruptArchiveReportsAReadableError() throws {
        var bytes = try XCTUnwrap(Data(base64Encoded: rar5Base64
            .replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: " ", with: "")))
        bytes.replaceSubrange(40..<bytes.count, with: Data(repeating: 0xFF, count: bytes.count - 40))
        let url = scratch.appendingPathComponent("broken.rar")
        try bytes.write(to: url)

        XCTAssertThrowsError(try RarReader(url: url,
                                           workDirectory: scratch.appendingPathComponent("b"))) { error in
            // Must name the problem, not surface a bare integer.
            let text = "\(error)"
            XCTAssertTrue(text.hasPrefix("rar: "), text)
            XCTAssertFalse(text.contains("unrecognised unrar error"), text)
        }
    }

    func testMissingEntryIsReported() throws {
        let url = try write(rar5Base64, as: "v5.rar")
        let reader = try RarReader(url: url, workDirectory: scratch.appendingPathComponent("m"))
        XCTAssertThrowsError(try reader.data(for: "nope.jpg"))
    }

    /// unrar reports success for a bare signature with no headers, so without
    /// an explicit guard a truncated download becomes a silent 0-page comic.
    func testEmptyOrTruncatedArchiveIsRejected() throws {
        let url = scratch.appendingPathComponent("truncated.rar")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0x00]).write(to: url)

        // unrar itself sees nothing wrong ...
        XCTAssertEqual(try RarReader.list(archiveAt: url), [])
        // ... so the reader has to be the one that refuses it.
        XCTAssertThrowsError(try RarReader(url: url,
                                           workDirectory: scratch.appendingPathComponent("t"))) { error in
            XCTAssertTrue("\(error)".contains("no files"), "\(error)")
        }
    }

    /// Opening and filtering a RAR work end to end.
    ///
    /// The fixture holds .txt files, so there is nothing to read. That used to
    /// produce a document with zero pages, which the reader rendered as an
    /// empty frame and a spinner that never resolved; it now fails with a
    /// message naming what the archive does contain.
    func testComicDocumentOverRarWithoutPages() throws {
        let url = try write(rarFixtureBase64, as: "pages.cbr")
        XCTAssertThrowsError(try ComicDocument(
            fileURL: url, workDirectory: scratch.appendingPathComponent("doc"))) { error in
            let message = "\(error)"
            XCTAssertTrue(message.contains("no readable pages"), message)
            XCTAssertTrue(message.contains(".txt"), "error names nothing concrete: \(message)")
        }
        // The RAR itself still opens and lists its members.
        let archive = try ArchiveOpener.open(
            url, workDirectory: scratch.appendingPathComponent("raw"))
        XCTAssertFalse(try archive.entries().isEmpty)
    }
}

/// Unpacking is done once, not on every open.
///
/// `szunrar_extract_all` used to run each time a comic was opened — 90 MB
/// re-extracted to read pages already sitting on disk, which was most of the
/// delay between tapping a cover and seeing one.
final class RarUnpackCacheTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: scratch) }

    private func archive() throws -> URL {
        let url = scratch.appendingPathComponent("pages.cbr")
        try XCTUnwrap(Data(base64Encoded: rarFixtureBase64, options: .ignoreUnknownCharacters))
            .write(to: url)
        return url
    }

    /// Deleting an extracted file and reopening proves it: if extraction ran
    /// again the file would be back. Timing would only prove the machine was
    /// busy.
    func testSecondOpenDoesNotExtractAgain() throws {
        let url = try archive()
        let work = scratch.appendingPathComponent("work")

        let first = try RarReader(url: url, workDirectory: work)
        let entry = try XCTUnwrap(first.entries().first)
        let victim = work.appendingPathComponent(entry)
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        try FileManager.default.removeItem(at: victim)

        _ = try RarReader(url: url, workDirectory: work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path),
                       "the archive was extracted a second time")
    }

    /// A directory left behind by an interrupted unpack has no marker, so it
    /// must be extracted rather than trusted.
    func testUnfinishedUnpackIsRedone() throws {
        let url = try archive()
        let work = scratch.appendingPathComponent("work")

        let first = try RarReader(url: url, workDirectory: work)
        let entry = try XCTUnwrap(first.entries().first)
        try FileManager.default.removeItem(at: work.appendingPathComponent(entry))
        // Drop the marker: this is what a half-finished extraction looks like.
        try FileManager.default.removeItem(at: work.appendingPathComponent(".szunpacked"))

        let second = try RarReader(url: url, workDirectory: work)
        XCTAssertTrue(try second.entries().contains(entry),
                      "an interrupted unpack was trusted")
    }

    /// The marker is bookkeeping, not a page.
    func testMarkerIsNotListedAsAnEntry() throws {
        let reader = try RarReader(url: try archive(),
                                   workDirectory: scratch.appendingPathComponent("work"))
        XCTAssertFalse(try reader.entries().contains { $0.contains(".szunpacked") })
    }
}

/// Unpacking at download time, so the first open is not the one that pays.
final class PrepareForReadingTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Downloads a RAR through the normal path, then checks it arrived unpacked.
    func testDownloadLeavesTheComicUnpacked() async throws {
        let rar = try XCTUnwrap(Data(base64Encoded: rarFixtureBase64,
                                     options: .ignoreUnknownCharacters))
        let store = try Store()
        try store.ingest(html:
            "<div>013-Nasilje</div><div>http://www.mediafire.com/?FAKE013</div>")
        let issue = try XCTUnwrap(try store.recent().first)

        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in
                                  HTTPResponse(status: 200, headers: ["location":
                                      "https://download.mediafire.com/x/c.cbr"])
                              },
                              downloader: StubDownloader(bodies: ["www.mediafire.com": rar,
                                                                  "download.mediafire.com": rar]),
                              registry: HostRegistry(hosts: [PassThroughHost()]))
        _ = try await library.fetch(issueID: issue.id)
        // The fixture holds .txt files, so opening it rightly reports no
        // readable pages. Extraction still runs first, and that is what is
        // being checked: the unpacking happened at download time.
        _ = try? library.prepareForReading(issueID: issue.id)

        // The marker is only written after a successful extraction, so its
        // presence means the work was done before any reading began.
        let unpacked = FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .contains { $0.lastPathComponent == ".szunpacked" } ?? false
        XCTAssertTrue(unpacked, "the comic was left packed for the first open to deal with")
    }

    /// Priming twice must be harmless — a re-download runs it again.
    func testPreparingTwiceIsFine() async throws {
        let zip = Data([0x50, 0x4B, 0x03, 0x04] + Array(repeating: UInt8(0x41), count: 200))
        let store = try Store()
        try store.ingest(html:
            "<div>014-Drugi</div><div>http://www.mediafire.com/?FAKE014</div>")
        let issue = try XCTUnwrap(try store.recent().first)
        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in HTTPResponse(status: 200) },
                              downloader: StubDownloader(bodies: ["www.mediafire.com": zip]),
                              registry: HostRegistry(hosts: [PassThroughHost()]))
        _ = try? await library.fetch(issueID: issue.id)
        // Not a real archive, so this throws — the point is that it throws the
        // same way both times rather than leaving anything half-made.
        let first = (try? library.prepareForReading(issueID: issue.id)) != nil
        let second = (try? library.prepareForReading(issueID: issue.id)) != nil
        XCTAssertEqual(first, second)
    }
}

/// Resolves without touching the network.
private struct PassThroughHost: FileHost {
    let name = "test"
    func canHandle(_ url: URL) -> Bool { true }
    func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
        FileMeta(filename: "c.cbr")
    }
    func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
        DirectLink(url: URL(string: "https://www.mediafire.com/c.cbr")!)
    }
}

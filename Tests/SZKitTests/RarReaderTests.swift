import XCTest
@testable import SZKit

// Fixtures from libarchive's BSD-licensed test suite: one RAR4 archive
// (magic 52 61 72 21 1a 07 00) and one RAR5 (… 1a 07 01). The corpus spans
// 2009-2026 uploads, so both format generations have to work.
private let rar4Base64 = """
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
        let url = try write(rar4Base64, as: "v4.rar")
        let names = try RarReader.list(archiveAt: url)
        XCTAssertTrue(names.contains("test.txt"), "\(names)")
        XCTAssertTrue(names.contains { $0.hasSuffix("test.txt") && $0 != "test.txt" },
                      "expected a nested entry too: \(names)")
        // Directory entries are excluded by the shim.
        XCTAssertFalse(names.contains("testemptydir"))
    }

    func testExtractsRar4Content() throws {
        let url = try write(rar4Base64, as: "v4.rar")
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
        let url = try write(rar4Base64, as: "v4.rar")
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
        let url = try write(rar4Base64, as: "pages.cbr")
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

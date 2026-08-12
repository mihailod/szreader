import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SZKit

/// Reading `.7z`, which the forum uses for some split archives.
final class SevenZipTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG(_ url: URL, size: Int = 24) throws {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw XCTSkip("cannot synthesise a PNG here") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("PNG write failed") }
    }

    /// bsdtar writes 7z, so the fixture is built rather than checked in.
    @discardableResult
    private func makeArchive(pages: Int, at name: String = "comic.7z") throws -> URL {
        let build = root.appendingPathComponent("build", isDirectory: true)
        let inner = build.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for i in 1...pages {
            try writePNG(inner.appendingPathComponent(String(format: "p%03d.png", i)))
        }
        let archive = root.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cf", archive.path, "--format", "7zip", "pages"]
        p.currentDirectoryURL = build
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0,
              FileManager.default.fileExists(atPath: archive.path)
        else { throw XCTSkip("no 7z writer available here") }
        return archive
    }

    /// The signature is six bytes, which is why the sniff reads eight.
    func testSignatureIsRecognised() throws {
        let archive = try makeArchive(pages: 2)
        XCTAssertEqual(ArchiveKind.sniff(archive), .sevenZip)
        XCTAssertEqual(ArchiveKind.sniff(Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C, 0x00, 0x03])),
                       .sevenZip)
        // Not confused with the others.
        XCTAssertEqual(ArchiveKind.sniff(Data([0x50, 0x4B, 0x03, 0x04])), .zip)
        XCTAssertEqual(ArchiveKind.sniff(Data([0x52, 0x61, 0x72, 0x21])), .rar)
    }

    func testEntriesAndBytesComeBack() throws {
        let archive = try makeArchive(pages: 3)
        let reader = try SevenZipReader(url: archive,
                                        workDirectory: root.appendingPathComponent("w"))
        let entries = try reader.entries()
        XCTAssertEqual(entries.count, 3, "\(entries)")
        XCTAssertTrue(entries.allSatisfy { $0.hasSuffix(".png") })

        let first = try XCTUnwrap(entries.sorted().first)
        let bytes = try reader.data(for: first)
        XCTAssertTrue(bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]), "not the PNG that went in")
    }

    /// The opener has to pick the reader from the bytes, not the extension —
    /// these arrive named .7z, .cbr and anything else the scanner chose.
    func testOpenerPicksTheSevenZipReader() throws {
        let archive = try makeArchive(pages: 2, at: "mislabelled.cbr")
        let reader = try ArchiveOpener.open(archive,
                                            workDirectory: root.appendingPathComponent("w2"))
        XCTAssertTrue(reader is SevenZipReader, "opened as \(type(of: reader))")
    }

    /// End to end: a 7z of images is a readable comic.
    func testComicDocumentOpensA7z() throws {
        let archive = try makeArchive(pages: 4)
        let document = try ComicDocument(fileURL: archive,
                                         workDirectory: root.appendingPathComponent("w3"))
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertNotNil(try document.page(0, maxPixelSize: 64))
    }

    /// Unpacked once, like RAR: deleting an extracted file and reopening proves
    /// it, where timing would only prove the machine was busy.
    func testSecondOpenDoesNotExtractAgain() throws {
        let archive = try makeArchive(pages: 2)
        let work = root.appendingPathComponent("w4")
        let first = try SevenZipReader(url: archive, workDirectory: work)
        let victim = work.appendingPathComponent(try XCTUnwrap(first.entries().first))
        try FileManager.default.removeItem(at: victim)

        _ = try SevenZipReader(url: archive, workDirectory: work)
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path),
                       "the archive was extracted a second time")
    }

    /// A truncated download opens as an archive with nothing in it, which must
    /// fail rather than present as a comic with no pages.
    func testEmptyArchiveIsRejected() throws {
        let build = root.appendingPathComponent("empty", isDirectory: true)
        try FileManager.default.createDirectory(at: build.appendingPathComponent("pages"),
                                                withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("empty.7z")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cf", archive.path, "--format", "7zip", "pages"]
        p.currentDirectoryURL = build
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("no 7z writer available here") }

        XCTAssertThrowsError(try SevenZipReader(url: archive,
                                                workDirectory: root.appendingPathComponent("w5")))
    }
}

/// Comics posted as two complete archives, half the pages in each.
///
/// Not the same as a split archive: those are volumes of one file that unrar
/// joins, and opening volume one gives the whole comic. These each open on
/// their own and simply stop halfway.
final class MultiArchiveComicTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func writePNG(_ url: URL) throws {
        let cs = CGColorSpaceCreateDeviceGray()
        guard let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                  bytesPerRow: 16, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let image = ctx.makeImage(),
              let dest = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw XCTSkip("cannot synthesise a PNG here") }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("PNG write failed") }
    }

    /// Builds one archive holding `pages` images, named after the real corpus.
    private func makeHalf(named name: String, pages: ClosedRange<Int>) throws -> URL {
        let build = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inner = build.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for i in pages {
            try writePNG(inner.appendingPathComponent(String(format: "p%03d.png", i)))
        }
        let archive = root.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cf", archive.path, "--format", "7zip", "pages"]
        p.currentDirectoryURL = build
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("no 7z writer available here") }
        return archive
    }

    /// The Martin Mystere #4 shape: "…_1_deo.7z" and "…_2_deo.7z".
    func testBothHalvesBecomeOneComic() throws {
        let first = try makeHalf(named: "MM_004_Prokleto_Pleme_1_deo.7z", pages: 1...4)
        _ = try makeHalf(named: "MM_004_Prokleto_Pleme_2_deo.7z", pages: 5...9)

        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w"))
        XCTAssertEqual(document.pageCount, 9, "the second half was not joined on")
        XCTAssertNotNil(try document.page(0, maxPixelSize: 32))
        // A page from the far half has to be readable, not just counted.
        XCTAssertNotNil(try document.page(8, maxPixelSize: 32))
    }

    /// Order matters: half one first, then half two.
    func testPagesKeepTheirOrderAcrossArchives() throws {
        let first = try makeHalf(named: "comic.part1.7z", pages: 1...2)
        _ = try makeHalf(named: "comic.part2.7z", pages: 3...4)
        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w2"))
        XCTAssertEqual(document.pages.count, 4)
        XCTAssertTrue(document.pages[0].contains("p001"), document.pages[0])
        XCTAssertTrue(document.pages[3].contains("p004"), document.pages[3])
    }

    /// A lone archive must not go looking for company.
    func testSingleArchiveIsUnaffected() throws {
        let only = try makeHalf(named: "whole.7z", pages: 1...3)
        let document = try ComicDocument(fileURL: only,
                                         workDirectory: root.appendingPathComponent("w3"))
        XCTAssertEqual(document.pageCount, 3)
    }

    /// A sibling that is not a readable archive is a fragment of a split file —
    /// already joined into volume one — and must be ignored rather than
    /// counted or thrown.
    func testUnreadableSiblingIsIgnored() throws {
        let first = try makeHalf(named: "vol.part1.7z", pages: 1...3)
        try Data("not an archive".utf8)
            .write(to: root.appendingPathComponent("vol.part2.7z"))

        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w4"))
        XCTAssertEqual(document.pageCount, 3)
    }

    /// The RAR-volume shape, which the filenames cannot be told apart from.
    ///
    /// If a later volume does open, it lists the pages volume one has already
    /// produced — unrar joined them — and joining it on would show the comic
    /// twice.
    func testCompanionRepeatingTheSamePagesIsDropped() throws {
        let first = try makeHalf(named: "joined.part1.7z", pages: 1...5)

        // Same entry names as volume one: an already-joined volume seen twice.
        let copy = root.appendingPathComponent("joined.part2.7z")
        try FileManager.default.copyItem(at: first, to: copy)

        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w6"))
        XCTAssertEqual(document.pageCount, 5, "the comic was joined to itself")
    }

    /// …but a companion that repeats only *some* names is still carrying
    /// pages of its own and must be joined.
    func testPartlyOverlappingCompanionIsStillJoined() throws {
        let first = try makeHalf(named: "olap.part1.7z", pages: 1...4)
        _ = try makeHalf(named: "olap.part2.7z", pages: 3...8)
        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w7"))
        XCTAssertEqual(document.pageCount, 10)
    }

    /// Opening the same comic twice must give the same comic.
    ///
    /// The second half used to unpack *inside* the first half's directory, so
    /// every open after the first found those pages already sitting there,
    /// counted them as volume one's, and then joined volume two on top: the
    /// comic grew by half each time it was opened.
    func testReopeningDoesNotGrowTheComic() throws {
        let first = try makeHalf(named: "MM_004_1_deo.7z", pages: 1...4)
        _ = try makeHalf(named: "MM_004_2_deo.7z", pages: 5...9)
        let work = root.appendingPathComponent("w8")

        let firstOpen = try ComicDocument(fileURL: first, workDirectory: work)
        XCTAssertEqual(firstOpen.pageCount, 9)
        let reopened = try ComicDocument(fileURL: first, workDirectory: work)
        XCTAssertEqual(reopened.pageCount, 9, "the comic grew on reopening")
        let thirdOpen = try ComicDocument(fileURL: first, workDirectory: work)
        XCTAssertEqual(thirdOpen.pageCount, 9)
    }

    /// A comic unpacked by the layout that gave volume one the whole
    /// directory must correct itself, and reclaim the space that layout left
    /// behind.
    func testComicUnpackedByTheOldLayoutIsCorrected() throws {
        let first = try makeHalf(named: "old_1_deo.7z", pages: 1...4)
        _ = try makeHalf(named: "old_2_deo.7z", pages: 5...9)
        let work = root.appendingPathComponent("w9")
        let fm = FileManager.default

        // What that layout left: volume one loose in the root, volume two in
        // a subdirectory of it.
        let loose = work.appendingPathComponent("pages", isDirectory: true)
        try fm.createDirectory(at: loose, withIntermediateDirectories: true)
        for i in 1...4 { try writePNG(loose.appendingPathComponent("p00\(i).png")) }
        fm.createFile(atPath: work.appendingPathComponent(".szunpacked").path, contents: nil)
        let nested = work.appendingPathComponent("volume-2/pages", isDirectory: true)
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        for i in 5...9 { try writePNG(nested.appendingPathComponent("p00\(i).png")) }

        let document = try ComicDocument(fileURL: first, workDirectory: work)
        XCTAssertEqual(document.pageCount, 9, "stale pages were counted")
        XCTAssertFalse(fm.fileExists(atPath: loose.path),
                       "the old copy of every page was left on disk")
    }

    /// Unpacked directories sit beside the archives and share their names;
    /// only a file can be a second archive.
    func testUnpackedDirectoryIsNotMistakenForACompanion() throws {
        let first = try makeHalf(named: "dir_1_deo.7z", pages: 1...3)
        let decoy = root.appendingPathComponent("dir_2_deo", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w10"))
        XCTAssertEqual(document.pageCount, 3)
    }

    /// Pieces of a different comic sitting in the same directory must not be
    /// pulled in.
    func testUnrelatedArchivesAreNotJoined() throws {
        let first = try makeHalf(named: "MM_004.part1.7z", pages: 1...2)
        _ = try makeHalf(named: "MM_009.part2.7z", pages: 1...5)
        let document = try ComicDocument(fileURL: first,
                                         workDirectory: root.appendingPathComponent("w5"))
        XCTAssertEqual(document.pageCount, 2, "a different comic's pages were joined on")
    }
}

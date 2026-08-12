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

    /// A repeat is not just dropped from the page list — its unpacked copy
    /// has to go too.
    ///
    /// This is what a RAR volume set looks like: unrar joins the volumes when
    /// the first is opened, so volume one already holds the whole comic and
    /// unpacking the second leaves a second copy of it on disk. Silent, and
    /// it doubles what the comic costs.
    func testARepeatedVolumeDoesNotKeepItsUnpackedCopy() throws {
        let first = try makeHalf(named: "vol.part1.7z", pages: 1...5)
        let copy = root.appendingPathComponent("vol.part2.7z")
        try FileManager.default.copyItem(at: first, to: copy)
        let work = root.appendingPathComponent("w11")

        let document = try ComicDocument(fileURL: first, workDirectory: work)
        XCTAssertEqual(document.pageCount, 5)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("volume-2").path),
            "the redundant volume is still unpacked on disk")
    }

    /// A fragment that will not open must not leave a part-unpacked directory
    /// behind either.
    func testAnUnreadableCompanionLeavesNothingUnpacked() throws {
        let first = try makeHalf(named: "frag.part1.7z", pages: 1...3)
        try Data("not an archive".utf8)
            .write(to: root.appendingPathComponent("frag.part2.7z"))
        let work = root.appendingPathComponent("w12")

        _ = try ComicDocument(fileURL: first, workDirectory: work)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("volume-2").path))
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

/// The archive is a second copy of the comic once its pages are out.
final class ArchiveReclaimTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// Builds an issue that is already downloaded, and returns its library.
    private func downloaded(_ archives: [String: ClosedRange<Int>]) throws -> (Library, Int, URL) {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let id = try XCTUnwrap(store.recent(limit: nil).first).id

        let comics = root.appendingPathComponent("comics", isDirectory: true)
        let paths = LibraryPaths(root: comics)
        let issue = paths.directory(forIssue: id)
        try FileManager.default.createDirectory(at: issue, withIntermediateDirectories: true)

        var first: URL?
        for (name, pages) in archives.sorted(by: { $0.key < $1.key }) {
            let built = try SevenZipFixture.make(named: name, pages: pages, in: root, at: issue)
            if first == nil { first = built }
        }
        try store.recordDownload(issueID: id, mirrorURL: "planted",
                                 path: try XCTUnwrap(first), bytes: 1)

        let library = Library(store: store, paths: paths,
                              transport: StubTransport { _ in HTTPResponse(status: 404) },
                              downloader: StubDownloader(bodies: [:]))
        return (library, id, issue)
    }

    private func archivesLeft(in issue: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: issue.path)) ?? [])
            .filter { $0.hasSuffix(".7z") }.sorted()
    }

    /// A single archive: its pages land beside it, so the rule for what to
    /// delete has to be tight enough to leave them alone.
    func testSingleArchiveIsDroppedButItsPagesSurvive() throws {
        let (library, id, issue) = try downloaded(["comic.7z": 1...5])

        let document = try library.document(forIssue: id)
        XCTAssertEqual(document.pageCount, 5)
        XCTAssertTrue(archivesLeft(in: issue).isEmpty, "the archive was kept")

        // And it still opens, from the pages alone.
        XCTAssertEqual(try library.document(forIssue: id).pageCount, 5)
        XCTAssertNotNil(try library.document(forIssue: id).page(4, maxPixelSize: 32))
    }

    /// Every archive of a split set goes, not just the recorded one.
    func testBothHalvesOfASplitAreDropped() throws {
        let (library, id, issue) = try downloaded([
            "comic.part1.7z": 1...4,
            "comic.part2.7z": 5...9,
        ])

        XCTAssertEqual(try library.document(forIssue: id).pageCount, 9)
        XCTAssertTrue(archivesLeft(in: issue).isEmpty, "a half was left behind")
        XCTAssertEqual(try library.document(forIssue: id).pageCount, 9)
    }

    /// An archive belonging to something else in the same folder is not ours
    /// to delete.
    func testAnUnrelatedArchiveIsLeftAlone() throws {
        let (library, id, issue) = try downloaded([
            "comic.7z": 1...4,
            "somethingelse.7z": 1...2,
        ])
        _ = try library.document(forIssue: id)
        XCTAssertEqual(archivesLeft(in: issue), ["somethingelse.7z"])
    }
}

/// Builds small 7z archives for tests that need real ones.
enum SevenZipFixture {
    static func make(named name: String, pages: ClosedRange<Int>,
                     in scratch: URL, at destination: URL) throws -> URL {
        let build = scratch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let inner = build.appendingPathComponent("pages", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)

        let cs = CGColorSpaceCreateDeviceGray()
        for i in pages {
            guard let ctx = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
                                      bytesPerRow: 16, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let image = ctx.makeImage(),
                  let dest = CGImageDestinationCreateWithURL(
                    inner.appendingPathComponent(String(format: "p%03d.png", i)) as CFURL,
                    UTType.png.identifier as CFString, 1, nil)
            else { throw XCTSkip("cannot synthesise a PNG here") }
            CGImageDestinationAddImage(dest, image, nil)
            guard CGImageDestinationFinalize(dest) else { throw XCTSkip("PNG write failed") }
        }

        let archive = destination.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cf", archive.path, "--format", "7zip", "pages"]
        p.currentDirectoryURL = build
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("no 7z writer available here") }
        return archive
    }
}

/// Volumes left behind by an earlier build, and the safety rule for deleting
/// an archive.
final class StaleVolumeTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A redundant volume used to be cleared only while opening from the
    /// archive. Once the archives are deleted that path never runs again, so
    /// the second copy sat there for good — a comic costing twice its size,
    /// with nothing left that would ever come back for it.
    func testARedundantVolumeIsClearedWhenOpeningFromPages() throws {
        let work = root.appendingPathComponent("w", isDirectory: true)
        let first = try SevenZipFixture.make(named: "c.7z", pages: 1...6, in: root, at: root)
        _ = try ComicDocument(fileURL: first, workDirectory: work.appendingPathComponent("volume-1"))
        try FileManager.default.copyItem(at: work.appendingPathComponent("volume-1"),
                                         to: work.appendingPathComponent("volume-2"))

        let document = try ComicDocument(unpackedAt: work)
        XCTAssertEqual(document.pageCount, 6, "the copy was counted")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("volume-2").path),
            "the second copy is still on disk")
    }

    /// A volume carrying pages of its own is the rest of the comic, not a
    /// copy, and must survive.
    func testAVolumeWithItsOwnPagesIsKept() throws {
        let work = root.appendingPathComponent("w2", isDirectory: true)
        let a = try SevenZipFixture.make(named: "a.7z", pages: 1...4, in: root, at: root)
        let b = try SevenZipFixture.make(named: "b.7z", pages: 5...9, in: root, at: root)
        _ = try ComicDocument(fileURL: a, workDirectory: work.appendingPathComponent("volume-1"))
        _ = try ComicDocument(fileURL: b, workDirectory: work.appendingPathComponent("volume-2"))

        XCTAssertEqual(try ComicDocument(unpackedAt: work).pageCount, 9)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: work.appendingPathComponent("volume-2").path))
    }

    /// The pages must decode before the archive they came from is destroyed.
    /// An extraction can finish and still leave files that cannot be read,
    /// and deleting the archive then loses the download for good.
    func testArchivesSurviveWhenThePagesDoNotDecode() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let id = try XCTUnwrap(store.recent(limit: nil).first).id
        let paths = LibraryPaths(root: root.appendingPathComponent("comics", isDirectory: true))
        let issue = paths.directory(forIssue: id)
        let fm = FileManager.default
        try fm.createDirectory(at: issue, withIntermediateDirectories: true)

        let archive = try SevenZipFixture.make(named: "c.7z", pages: 1...4, in: root, at: issue)
        try store.recordDownload(issueID: id, mirrorURL: "planted", path: archive, bytes: 1)

        // An extraction that finished — marker and all — and left pages that
        // are not images.
        let pages = issue.appendingPathComponent("pages", isDirectory: true)
        try fm.createDirectory(at: pages, withIntermediateDirectories: true)
        for i in 1...4 {
            try Data("truncated".utf8)
                .write(to: pages.appendingPathComponent(String(format: "p%03d.png", i)))
        }
        fm.createFile(atPath: issue.appendingPathComponent(".szunpacked").path, contents: nil)

        let library = Library(store: store, paths: paths,
                              transport: StubTransport { _ in HTTPResponse(status: 404) },
                              downloader: StubDownloader(bodies: [:]))
        _ = try? library.document(forIssue: id)

        XCTAssertTrue(fm.fileExists(atPath: archive.path),
                      "the archive was destroyed although its pages do not decode")
    }
}

/// Comics posted as an archive inside an archive.
///
/// Gigant is the case: a RAR volume set whose volumes join into a single
/// `.cbr`, which is itself an archive of the pages. Unwrapping that leaves
/// three copies of the comic on the device — the inner archive as extracted,
/// the copy written out to be opened, and the pages — and only the pages are
/// ever read.
final class UnwrappedComicTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// An outer archive whose only member is an inner archive of the pages.
    private func nestedArchive(pages: ClosedRange<Int>) throws -> URL {
        let inner = try SevenZipFixture.make(named: "comic.cbr", pages: pages,
                                             in: root, at: root)
        let wrap = root.appendingPathComponent("wrap", isDirectory: true)
        try FileManager.default.createDirectory(at: wrap, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: inner, to: wrap.appendingPathComponent("comic.cbr"))

        let outer = root.appendingPathComponent("outer.7z")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        p.arguments = ["-cf", outer.path, "--format", "7zip", "comic.cbr"]
        p.currentDirectoryURL = wrap
        try p.run(); p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "no 7z writer available here")
        return outer
    }

    /// The pages end up under "nested-…-work", not in the volume directories,
    /// which hold the inner archive. Looking only at the volumes finds a comic
    /// with nothing in it — and with the download deleted, nothing to reopen.
    func testPagesAreFoundAfterUnwrapping() throws {
        let outer = try nestedArchive(pages: 1...5)
        let work = root.appendingPathComponent("w", isDirectory: true)
        XCTAssertEqual(try ComicDocument(fileURL: outer, workDirectory: work).pageCount, 5)

        let reopened = try ComicDocument(unpackedAt: work)
        XCTAssertEqual(reopened.pageCount, 5, "the unwrapped pages were not found")
        XCTAssertNotNil(try reopened.page(4, maxPixelSize: 32))
    }

    /// A zip is read in place — no extraction, no pages on disk — so the
    /// archive *is* the comic and deleting it destroys the download.
    ///
    /// The check that stops this has to be "does it open without the
    /// archives", not "did the document I am holding read back": that
    /// document was built from the archive and reads back perfectly, right up
    /// until the file is gone.
    func testAZipComicKeepsItsArchive() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Bob Moran</div><div>http://www.mediafire.com/?FAKEKEY001</div>
            """)
        let id = try XCTUnwrap(store.recent(limit: nil).first).id
        let paths = LibraryPaths(root: root.appendingPathComponent("comics", isDirectory: true))
        let issue = paths.directory(forIssue: id)
        try FileManager.default.createDirectory(at: issue, withIntermediateDirectories: true)

        // Pages zipped straight in, the way a .cbz arrives.
        let inner = try SevenZipFixture.make(named: "src.7z", pages: 1...4, in: root, at: root)
        let staging = root.appendingPathComponent("z", isDirectory: true)
        _ = try ComicDocument(fileURL: inner, workDirectory: staging)
        let cbz = issue.appendingPathComponent("comic.cbz")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-q", "-r", "-0", cbz.path, "."]
        zip.currentDirectoryURL = staging
        try zip.run(); zip.waitUntilExit()
        try XCTSkipIf(zip.terminationStatus != 0, "no zip here")
        try store.recordDownload(issueID: id, mirrorURL: "planted", path: cbz, bytes: 1)

        let library = Library(store: store, paths: paths,
                              transport: StubTransport { _ in HTTPResponse(status: 404) },
                              downloader: StubDownloader(bodies: [:]))
        XCTAssertEqual(try library.document(forIssue: id).pageCount, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cbz.path),
                      "the comic's only copy was deleted")
        XCTAssertEqual(try library.document(forIssue: id).pageCount, 4, "it no longer opens")
    }

    /// Once the pages exist, the inner archive and the copy of it are dead
    /// weight — on a real comic, twice its size again.
    func testIntermediateCopiesAreDropped() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Bob Moran</div><div>http://www.mediafire.com/?FAKEKEY001</div>
            """)
        let id = try XCTUnwrap(store.recent(limit: nil).first).id
        let paths = LibraryPaths(root: root.appendingPathComponent("comics", isDirectory: true))
        let issue = paths.directory(forIssue: id)
        try FileManager.default.createDirectory(at: issue, withIntermediateDirectories: true)

        let outer = try nestedArchive(pages: 1...5)
        let placed = issue.appendingPathComponent("comic.part1")
        try FileManager.default.moveItem(at: outer, to: placed)
        try store.recordDownload(issueID: id, mirrorURL: "planted", path: placed, bytes: 1)

        let library = Library(store: store, paths: paths,
                              transport: StubTransport { _ in HTTPResponse(status: 404) },
                              downloader: StubDownloader(bodies: [:]))
        XCTAssertEqual(try library.document(forIssue: id).pageCount, 5)

        let left = ((try? FileManager.default.contentsOfDirectory(atPath: issue.path)) ?? []).sorted()
        XCTAssertEqual(left, ["nested-0-work"],
                       "the archives and the unwrapped copies are still there")

        // And it still opens, from the pages alone.
        XCTAssertEqual(try library.document(forIssue: id).pageCount, 5)
    }
}

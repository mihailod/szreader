import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SZKit

/// Comics packaged inside another archive.
///
/// Both failing downloads turned out to be wrappers: Judas arrived as a zip
/// whose only entry was "01 …cbz", Mister No as a rar whose only entry was a
/// cbr. The pages sit one level down, so the page filter saw an archive and no
/// images and reported a comic with zero pages — which the reader rendered as
/// an empty frame and a spinner that never resolved.
final class NestedArchiveTests: XCTestCase {

    /// An archive whose content is a PDF rather than pages.
    ///
    /// The other nesting convention. A scanlation is a zip inside a zip, which
    /// this suite already covers; bombjack packages most of its books as a zip
    /// whose single entry is the whole thing as a PDF. Neither the page list
    /// nor the nested-archive list sees a PDF, so the document came out empty
    /// and the reader reported the archive corrupt — on 60% of that source.
    func testAZipHoldingOnlyAPDFOpensAsThatPDF() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("zipped-pdf-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        // Written here rather than shipped as a fixture, so the test cannot
        // quietly skip itself for want of one — a skipped test proves nothing.
        let inner = scratch.appendingPathComponent("Book.pdf")
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)
        guard let context = CGContext(inner as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("cannot write a PDF here")
        }
        for page in 0..<3 {
            context.beginPage(mediaBox: &box)
            context.setFillColor(gray: 0, alpha: 1)
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 20 + CGFloat(page) * 10))
            context.endPage()
        }
        context.closePDF()

        let archive = scratch.appendingPathComponent("Book.zip")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.arguments = ["-j", "-q", archive.path, inner.path]
        try zip.run(); zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw XCTSkip("zip unavailable") }

        let document = try ComicDocument(fileURL: archive,
                                         workDirectory: scratch.appendingPathComponent("work"))
        XCTAssertEqual(document.pageCount, 3,
                       "a zip holding a PDF read back as an empty comic")
    }


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

    @discardableResult
    private func zip(_ contents: [String], in directory: URL, to archive: URL) throws -> URL {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q", "-X", archive.path] + contents
        p.currentDirectoryURL = directory
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("zip unavailable") }
        return archive
    }

    /// A cbz inside a zip: the shape Judas actually downloads as.
    func testComicWrappedInAnotherArchiveOpens() throws {
        let inner = root.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for i in 1...3 { try writePNG(inner.appendingPathComponent("p\(i).png")) }
        let cbz = try zip(["p1.png", "p2.png", "p3.png"], in: inner,
                          to: root.appendingPathComponent("01 Naslov.cbz"))
        let outer = try zip([cbz.lastPathComponent], in: root,
                            to: root.appendingPathComponent("download.zip"))

        let document = try ComicDocument(fileURL: outer,
                                         workDirectory: root.appendingPathComponent("w"))
        XCTAssertEqual(document.pageCount, 3, "pages one level down were not found")
        XCTAssertNotNil(try document.page(0, maxPixelSize: 64))
    }

    /// The ordinary case must not regress: pages directly in the archive.
    func testFlatArchiveStillOpens() throws {
        let inner = root.appendingPathComponent("flat", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        for i in 1...2 { try writePNG(inner.appendingPathComponent("p\(i).png")) }
        let cbz = try zip(["p1.png", "p2.png"], in: inner,
                          to: root.appendingPathComponent("flat.cbz"))
        XCTAssertEqual(try ComicDocument(fileURL: cbz,
                                         workDirectory: root.appendingPathComponent("w2")).pageCount, 2)
    }

    /// An archive with nothing readable must say so rather than open empty —
    /// zero pages is what left the reader spinning.
    func testArchiveWithNoPagesThrowsSomethingLegible() throws {
        let inner = root.appendingPathComponent("junk", isDirectory: true)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        try "notes".write(to: inner.appendingPathComponent("readme.txt"),
                          atomically: true, encoding: .utf8)
        let cbz = try zip(["readme.txt"], in: inner, to: root.appendingPathComponent("empty.cbz"))

        XCTAssertThrowsError(try ComicDocument(fileURL: cbz,
                                               workDirectory: root.appendingPathComponent("w3"))) {
            let message = "\($0)"
            XCTAssertTrue(message.contains("no readable pages"), "unhelpful error: \(message)")
            XCTAssertTrue(message.contains("readme.txt"), "error names nothing concrete: \(message)")
        }
    }

    func testNestedArchiveDetection() {
        let entries = ["01 Naslov.cbz", "cover.jpg", "__MACOSX/._x.cbz", "notes.txt"]
        XCTAssertEqual(PageManifest.nestedArchives(in: entries), ["01 Naslov.cbz"])
    }
}

import CoreGraphics
import PDFKit
import XCTest
@testable import SZKit

/// Drawing a PDF page that does not sit square in its own file.
///
/// Two things a scanner leaves behind that a naive render gets wrong, both
/// found in one magazine: Transactor for the Amiga is 88 landscape pages of
/// 792×590, every one of them carrying `/Rotate 90` or `/Rotate 270`. Sized
/// from the box, each page came out with its masthead cut off and a white band
/// down the side.
///
/// The PDFs below are written by hand, a few hundred bytes each, because that
/// is the only way to state `/Rotate` — `CGContext`'s PDF writer has no way to
/// set it, and the real magazine is 15 MB.
final class PDFRotationTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pdf-rotation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// A one-page PDF whose only content is a black rectangle covering the
    /// whole of its box, so anything left white in the render is page that was
    /// not drawn where it should have been.
    private func write(mediaBox: CGRect, rotate: Int, name: String) throws -> URL {
        let content = """
        0 0 0 rg
        \(mediaBox.origin.x) \(mediaBox.origin.y) \(mediaBox.width) \(mediaBox.height) re
        f
        """
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            """
            << /Type /Page /Parent 2 0 R \
            /MediaBox [\(mediaBox.minX) \(mediaBox.minY) \(mediaBox.maxX) \(mediaBox.maxY)] \
            /Rotate \(rotate) /Contents 4 0 R >>
            """,
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
        ]

        var pdf = "%PDF-1.4\n"
        var offsets: [Int] = []
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets {
            pdf += String(format: "%010d 00000 n \n", offset)
        }
        pdf += """
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xref)
        %%EOF
        """

        let url = scratch.appendingPathComponent(name)
        try Data(pdf.utf8).write(to: url)
        return url
    }

    /// Every pixel, or the first one that is not near-black.
    private func firstUnpaintedPixel(_ image: CGImage) -> (x: Int, y: Int)? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return (0, 0) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] > 40 {
                return (x, y)
            }
        }
        return nil
    }

    /// The bug, stated as the shape it produced.
    ///
    /// A landscape box turned a quarter is a portrait page. Rendering it into
    /// a landscape frame is what cut the tops off 88 pages of Transactor.
    func testAQuarterTurnedPageIsRenderedTurned() throws {
        for rotation in [90, 270] {
            let url = try write(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 100),
                                rotate: rotation, name: "turned-\(rotation).pdf")
            let comic = try XCTUnwrap(PDFComic(fileURL: url))
            let page = try XCTUnwrap(comic.image(0, maxPixelSize: 400))

            XCTAssertEqual(page.width, 200, "\(rotation)° should present portrait")
            XCTAssertEqual(page.height, 400, "\(rotation)° should present portrait")
            XCTAssertNil(firstUnpaintedPixel(page),
                         "\(rotation)°: the page does not cover its own frame")
        }
    }

    /// A half turn presents the same shape, so the frame must not change —
    /// only what is drawn in it.
    func testAHalfTurnedPageKeepsItsShape() throws {
        let url = try write(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 100),
                            rotate: 180, name: "half.pdf")
        let page = try XCTUnwrap(PDFComic(fileURL: url)?.image(0, maxPixelSize: 400))
        XCTAssertEqual(page.width, 400)
        XCTAssertEqual(page.height, 200)
        XCTAssertNil(firstUnpaintedPixel(page))
    }

    /// An unturned page is the case that always worked, and has to keep
    /// working: this is the shape of every other PDF in the library.
    func testAnUnturnedPageIsUnchanged() throws {
        let url = try write(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 100),
                            rotate: 0, name: "plain.pdf")
        let page = try XCTUnwrap(PDFComic(fileURL: url)?.image(0, maxPixelSize: 400))
        XCTAssertEqual(page.width, 400)
        XCTAssertEqual(page.height, 200)
        XCTAssertNil(firstUnpaintedPixel(page))
    }

    /// A box that does not start at the origin.
    ///
    /// The old code subtracted the box's origin by hand *and* let
    /// `draw(with:to:)` do it, which shifts the page by that much again. It
    /// went unnoticed because a scanner's box almost always starts at zero.
    func testABoxAwayFromTheOriginIsNotShiftedTwice() throws {
        let url = try write(mediaBox: CGRect(x: 50, y: 20, width: 200, height: 100),
                            rotate: 0, name: "offset.pdf")
        let page = try XCTUnwrap(PDFComic(fileURL: url)?.image(0, maxPixelSize: 400))
        XCTAssertEqual(page.width, 400)
        XCTAssertEqual(page.height, 200)
        XCTAssertNil(firstUnpaintedPixel(page), "the page was drawn off its own frame")
    }

    /// The size a page presents at, which is what the frame is built from.
    func testShownSizeSwapsOnlyForAQuarterTurn() throws {
        let cases: [(Int, CGSize)] = [
            (0,   CGSize(width: 200, height: 100)),
            (90,  CGSize(width: 100, height: 200)),
            (180, CGSize(width: 200, height: 100)),
            (270, CGSize(width: 100, height: 200)),
            // Whatever the file happens to say.
            (360, CGSize(width: 200, height: 100)),
            (-90, CGSize(width: 100, height: 200)),
        ]
        for (rotation, expected) in cases {
            let url = try write(mediaBox: CGRect(x: 0, y: 0, width: 200, height: 100),
                                rotate: rotation, name: "size-\(rotation).pdf")
            let document = try XCTUnwrap(PDFDocument(url: url))
            let page = try XCTUnwrap(document.page(at: 0))
            XCTAssertEqual(PDFComic.shownSize(of: page), expected, "\(rotation)°")
        }
    }
}

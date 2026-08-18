import CoreGraphics
import Foundation
import PDFKit

/// A comic that arrived as a PDF rather than a folder of scans.
///
/// Sirius is the case that brought this in: every individual download on its
/// page is long dead, and the only surviving copies are three collected
/// archives holding one PDF per issue. A PDF page is drawn rather than
/// decoded, so nothing about it fits the archive path — but the reader only
/// ever asks a comic for a page as an image, which is a question a PDF can
/// answer just as well.
struct PDFComic {

    private let document: PDFDocument

    init?(fileURL: URL) {
        guard let document = PDFDocument(url: fileURL) else { return nil }
        self.document = document
    }

    var pageCount: Int { document.pageCount }

    /// One page, drawn at the size it will be shown.
    ///
    /// Scans are 2000-3000px on the long edge and a PDF page is resolution
    /// independent, so the scale is chosen the same way the image path
    /// chooses its downsample: whatever the panel can actually show. Drawing
    /// a 146-page magazine at full size instead is how an iPad runs out of
    /// memory.
    func image(_ index: Int, maxPixelSize: Int) -> CGImage? {
        guard index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return nil }

        let shown = Self.shownSize(of: page)
        guard shown.width > 0, shown.height > 0, maxPixelSize > 0 else { return nil }

        let scale = CGFloat(maxPixelSize) / max(shown.width, shown.height)
        let width = Int((shown.width * scale).rounded())
        let height = Int((shown.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }

        // White, not transparent: a scanned page is paper, and anything it
        // leaves unpainted should read as paper too rather than as a hole.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.scaleBy(x: scale, y: scale)
        // Nothing is translated for the box's origin, and nothing rotates the
        // context: `draw(with:to:)` maps the box — turned, and wherever in
        // page space it sits — onto the context's own origin. Doing either by
        // hand applies it twice.
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }

    /// The size a page is actually presented at.
    ///
    /// Not its box. A PDF page carries a `/Rotate` telling every reader to
    /// turn it a quarter or a half before showing it, and `bounds(for:)`
    /// answers with the box as it sits in the file — untouched by that.
    /// `draw(with:to:)` *does* apply it, so on a quarter-turned page the two
    /// disagree, and a context sized from the box gets a portrait page drawn
    /// into a landscape frame: clipped along one edge, blank along another.
    ///
    /// Transactor for the Amiga is scanned that way throughout — every page a
    /// landscape 792×590 box with `/Rotate 90` or `270` — so all 88 pages of
    /// it came out with their mastheads cut off.
    static func shownSize(of page: PDFPage) -> CGSize {
        let box = page.bounds(for: .mediaBox)
        // Rotation is a multiple of 90; a half turn presents the same shape,
        // a quarter turn swaps it. Normalised because the value in a file is
        // whatever its writer put there, negatives included.
        let quarterTurns = ((page.rotation % 360) + 360) % 360
        return quarterTurns == 90 || quarterTurns == 270
            ? CGSize(width: box.height, height: box.width)
            : CGSize(width: box.width, height: box.height)
    }
}

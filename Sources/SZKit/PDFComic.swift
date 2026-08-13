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

        let box = page.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0, maxPixelSize > 0 else { return nil }

        let scale = CGFloat(maxPixelSize) / max(box.width, box.height)
        let width = Int((box.width * scale).rounded())
        let height = Int((box.height * scale).rounded())
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
        context.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

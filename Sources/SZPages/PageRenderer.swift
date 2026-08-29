import CoreGraphics
import Foundation
import ImageIO

/// Decodes comic pages at the size they will actually be shown.
///
/// Scans are commonly 2000-3000px on the long edge. A 2500x3500 page decodes to
/// roughly 35 MB in memory, so holding a handful of full-resolution pages is
/// enough to get an app jetsammed on a base-model iPad. ImageIO's thumbnail
/// path decodes straight to the target size instead of decoding full and then
/// scaling down.
public enum PageRenderer {

    /// Pixel dimensions without decoding the image.
    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    /// Writes a JPEG, for the one image this app keeps rather than decodes:
    /// a cover taken from a comic's own first page.
    @discardableResult
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.jpeg" as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    /// Decodes at most `maxPixelSize` on the long edge, preserving aspect.
    ///
    /// Pass the screen's long edge in *pixels* (points x scale). Anything more
    /// is memory spent on detail the panel cannot show.
    public static func downsample(data: Data, maxPixelSize: Int) -> CGImage? {
        guard maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF rotation
            kCGImageSourceShouldCacheImmediately: true,         // decode now, not at draw time
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Whether the bytes decode as an image at all — a page that fails this is
    /// a corrupt entry rather than a page.
    /// What a scanned page can plausibly be shaped like, as height ÷ width.
    ///
    /// Wide enough for a double-page spread at one end and a tall album page
    /// at the other.
    public static let pageShapes: ClosedRange<Double> = 0.4...2.5

    /// Whether an image is shaped like a page of the comic rather than
    /// something else the scanner put in the archive.
    ///
    /// Scans are not only pages. The fourth image in Alan Ford's "Grupa TNT"
    /// is the book's spine: 69 by 2107, thirty times taller than it is wide.
    /// The landscape reader sizes every slot in its strip from the first page
    /// it decodes, and taking that one made each of the hundred and thirty-five
    /// slots forty-two thousand points tall — the page then drew as a band
    /// near the top of one and the reader was left looking at the empty rest
    /// of it. A black screen, with a correct page number and working
    /// scrubbers, which read as a comic that had failed to load rather than a
    /// layout that had gone wrong.
    public static func isPageShaped(width: Int, height: Int) -> Bool {
        guard width > 0, height > 0 else { return false }
        return pageShapes.contains(Double(height) / Double(width))
    }

    public static func isDecodable(_ data: Data) -> Bool {
        pixelSize(of: data) != nil
    }
}

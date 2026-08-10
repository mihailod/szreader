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
    public static func isDecodable(_ data: Data) -> Bool {
        pixelSize(of: data) != nil
    }
}

/// A comic that has been downloaded and opened.
///
/// Pages are pulled from the archive on demand. Extracting all of them up front
/// would cost a second copy of a 90 MB file on disk for no benefit, since the
/// reader only ever shows a handful at a time.
public final class ComicDocument {

    public let archive: ArchiveReader
    public let pages: [String]

    public init(archive: ArchiveReader) throws {
        self.archive = archive
        self.pages = try archive.pageNames()
    }

    public convenience init(fileURL: URL, workDirectory: URL? = nil) throws {
        try self.init(archive: try ArchiveOpener.open(fileURL, workDirectory: workDirectory))
    }

    public var pageCount: Int { pages.count }

    public func pageData(_ index: Int) throws -> Data {
        guard pages.indices.contains(index) else {
            throw ArchiveError.entryNotFound("page \(index)")
        }
        return try archive.data(for: pages[index])
    }

    /// Decoded page, sized for the target screen.
    public func page(_ index: Int, maxPixelSize: Int) throws -> CGImage? {
        PageRenderer.downsample(data: try pageData(index), maxPixelSize: maxPixelSize)
    }

    /// Indices worth decoding ahead of `current`.
    ///
    /// Prefetching both directions keeps a back-flip as smooth as a forward
    /// one; the window is small on purpose, because each cached page costs
    /// real memory.
    public func prefetchWindow(around current: Int, radius: Int = 2) -> [Int] {
        let lower = max(0, current - radius)
        let upper = min(pageCount - 1, current + radius)
        guard lower <= upper else { return [] }
        return (lower...upper).filter { $0 != current }
    }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Putting one PopBoks page back together.
///
/// The archive stores no page images. Each page is a pyramid of 256-pixel
/// tiles — the technique a map server uses, so a browser can pan around a huge
/// picture while fetching only the part on screen. Three levels exist:
///
///     level 0   2 x 2 grid     300 x 387
///     level 1   3 x 4 grid     600 x 774
///     level 2   5 x N grid    1200 x ~1550   <- the scan
///
/// Level 2 is the only one worth reading: 1200 pixels across is about 150 dpi
/// on a magazine page, and level 1 at 600 is too coarse for body text. So a
/// page costs one request per tile, and a page is the unit this app deals in.
///
/// **The grid is measured, never assumed.** The tiles' own dimensions are what
/// decide the finished page, because the archive's bottom row is a partial
/// strip whose height differs from issue to issue — anything from 13 pixels to
/// a full 256. Reading that from the pixels means the one thing that varies
/// cannot be got wrong, and nothing here has to agree with a table.
///
/// **This reassembles more of the page than the archive's own viewer shows.**
/// Its reader loops over a fixed seven rows. Two Ritam issues are eight rows
/// tall, so on that site the bottom strip of every page in them is simply
/// never requested and never drawn. The tiles are there; only the loop is
/// short. Discovering the row count instead of hard-coding it is what recovers
/// them — see `PopBoksCatalog.Issue.rows`.
public enum PopBoksPage {

    /// The zoom level that holds the scan. Levels 0 and 1 are the same page
    /// at a quarter and a half of the width, for panning; there is no level 3.
    public static let level = 2

    /// Every tile of one page, in the order they are fetched.
    ///
    /// Row-major and top-left first, which is the order they are drawn in and
    /// the order a partial fetch should stop in — a page that fails half way
    /// has its top half, which is the half worth having if it is ever shown.
    public static func grid(columns: Int, rows: Int) -> [(column: Int, row: Int)] {
        guard columns > 0, rows > 0 else { return [] }
        return (0..<rows).flatMap { row in (0..<columns).map { (column: $0, row: row) } }
    }

    /// `LocalizedError` as well as `CustomStringConvertible`, because only the
    /// former is what `Library.reason` — and so the message a reader is shown
    /// — actually reads. Without it every one of these arrives as "The
    /// operation couldn't be completed. (StitchError error 2.)", which names
    /// nothing and cost an afternoon once.
    public enum StitchError: Error, CustomStringConvertible, LocalizedError {
        case missingTile(column: Int, row: Int)
        case undecodableTile(column: Int, row: Int)
        case ragged(String)
        case couldNotDraw
        case couldNotEncode

        public var errorDescription: String? { description }

        public var description: String {
            switch self {
            case .missingTile(let c, let r):     return "tile \(c),\(r) did not arrive"
            case .undecodableTile(let c, let r): return "tile \(c),\(r) is not an image"
            case .ragged(let why):               return why
            case .couldNotDraw:                  return "the page could not be drawn"
            case .couldNotEncode:                return "the page could not be encoded"
            }
        }
    }

    /// A finished page, and what it cost to finish it.
    public struct Stitched: Sendable {
        public let data: Data
        /// Positions the archive does not hold, drawn blank.
        ///
        /// Reported rather than swallowed. It is a real defect in the scan —
        /// a corner of the page that nobody can recover — and the only place
        /// anyone would find out is the download that met it.
        public let blanks: [Tile]
    }

    /// Assembles one page from its tiles and returns it as a JPEG.
    ///
    /// - Parameter tiles: keyed by column and row, zero-based, row 0 at the
    ///   top.
    ///
    ///   A position may be absent, and then it is drawn blank — but only
    ///   because of what the caller has already established about it.
    ///   `PopBoksFetcher` omits a tile only when the archive answered `403`
    ///   for it, which is a statement that the file is not there rather than a
    ///   failure to fetch it; every other failure throws long before this.
    ///   The archive does have such holes: Džuboks 88's page 35 is a complete
    ///   page but for its top-right corner, and refusing it outright would
    ///   make that whole issue undownloadable for ever over one missing tile.
    ///
    ///   What is *not* tolerated is a row or column with nothing in it at all,
    ///   because then there is no way to know how tall or wide it should be —
    ///   and a guess there moves every tile below or beside it.
    ///
    /// - Parameter quality: 0.9 rather than the 0.8 used for captured covers.
    ///   These tiles are already JPEG, so this is a second generation of lossy
    ///   encoding over the same pixels, and the artefacts land on scanned text.
    public static func stitch(tiles: [Tile: Data],
                              columns: Int, rows: Int,
                              quality: Double = 0.9) throws -> Stitched {
        guard columns > 0, rows > 0 else { throw StitchError.ragged("empty grid") }

        // Decode first, so a bad tile is found before a large context is
        // allocated for a page that cannot be finished.
        var images: [Tile: CGImage] = [:]
        var blanks: [Tile] = []
        for row in 0..<rows {
            for column in 0..<columns {
                let key = Tile(column: column, row: row)
                guard let data = tiles[key] else {
                    blanks.append(key)
                    continue
                }
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw StitchError.undecodableTile(column: column, row: row)
                }
                images[key] = image
            }
        }

        // The page's shape, read off whichever tiles arrived.
        //
        // Measured from any tile in the column or row rather than from the top
        // row and left column, which is what this used to do. Those edges are
        // not privileged — Džuboks 88's page 35 is missing a tile *in* the top
        // row — and a hole there left the width of that whole column unknown.
        func width(ofColumn column: Int) throws -> Int {
            for row in 0..<rows {
                if let image = images[Tile(column: column, row: row)] { return image.width }
            }
            throw StitchError.ragged("column \(column) is entirely missing")
        }
        func height(ofRow row: Int) throws -> Int {
            for column in 0..<columns {
                if let image = images[Tile(column: column, row: row)] { return image.height }
            }
            throw StitchError.ragged("row \(row) is entirely missing")
        }
        let widths = try (0..<columns).map(width(ofColumn:))
        let heights = try (0..<rows).map(height(ofRow:))

        // A tile that disagrees with its own row or column means the grid is
        // not the rectangle it was asked for, and pasting it anyway would
        // shear the page. Checked rather than trusted: it costs nothing and it
        // is the failure that would be hardest to recognise on the shelf.
        for (key, image) in images {
            guard image.width == widths[key.column], image.height == heights[key.row] else {
                throw StitchError.ragged(
                    "tile \(key.column),\(key.row) is \(image.width)x\(image.height), "
                  + "not \(widths[key.column])x\(heights[key.row])")
            }
        }

        let totalWidth = widths.reduce(0, +)
        let totalHeight = heights.reduce(0, +)

        // Scans are grey or colour but never transparent, and an opaque
        // context is both smaller and faster to draw into.
        guard let context = CGContext(
            data: nil, width: totalWidth, height: totalHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw StitchError.couldNotDraw
        }
        // Anything not covered by a tile would otherwise be whatever the
        // allocation happened to contain.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: totalWidth, height: totalHeight))

        // Core Graphics counts y upwards from the bottom; the grid counts rows
        // downwards from the top. Getting this backwards produces a page whose
        // rows are in reverse order — which still looks like a page, which is
        // why it is worth saying out loud here.
        var top = 0
        for row in 0..<rows {
            var left = 0
            for column in 0..<columns {
                // A position with no tile keeps the white already filled in
                // above, which is what a missing corner of a scan should look
                // like: blank paper rather than whatever was in memory.
                if let image = images[Tile(column: column, row: row)] {
                    context.draw(image, in: CGRect(
                        x: left,
                        y: totalHeight - top - heights[row],
                        width: widths[column],
                        height: heights[row]))
                }
                left += widths[column]
            }
            top += heights[row]
        }

        guard let page = context.makeImage() else { throw StitchError.couldNotDraw }
        return Stitched(data: try encodeJPEG(page, quality: quality),
                        blanks: blanks.sorted { ($0.row, $0.column) < ($1.row, $1.column) })
    }

    /// One position in the grid.
    public struct Tile: Hashable, Sendable {
        public let column: Int
        public let row: Int
        public init(column: Int, row: Int) {
            self.column = column; self.row = row
        }
    }

    /// A JPEG in memory.
    ///
    /// `PageRenderer.writeJPEG` writes to a URL, which is right for a captured
    /// cover and wrong here: `PageDownload.write` wants the bytes so it can
    /// check them and rename a temporary file into place, and a page written
    /// straight out would skip both.
    static func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw StitchError.couldNotEncode
        }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: quality,
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw StitchError.couldNotEncode
        }
        return out as Data
    }
}

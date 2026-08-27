import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SZKit

/// Putting a page back together from its tiles.
///
/// Synthetic tiles rather than saved ones, deliberately: what is being tested
/// is geometry — which tile goes where, and what the finished page measures —
/// and a tile of a known flat colour answers that far more sharply than a
/// scan of a magazine page would. Every tile here is a different colour, so a
/// page assembled wrongly is not merely a failed assertion but a readable
/// description of what moved where.
final class PopBoksPageTests: XCTestCase {

    // MARK: - Making tiles

    /// A solid PNG. PNG rather than JPEG so the colour that goes in is exactly
    /// the colour that comes out, and the tolerance below can be about the
    /// *output* encoding alone.
    private func solid(width: Int, height: Int,
                       red: Int, green: Int, blue: Int) throws -> Data {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                                     blue: CGFloat(blue) / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            out as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return out as Data
    }

    /// A tile's colour, chosen so that every position in the grid is distinct
    /// and so that a swapped row and a swapped column cannot collide.
    private func colour(column: Int, row: Int) -> (Int, Int, Int) {
        (40 + column * 40, 40 + row * 25, 200)
    }

    /// A full grid of tiles, sized the way the archive sizes them: 256 square,
    /// with a narrow last column and a short last row.
    private func tiles(columns: Int, rows: Int,
                       lastColumnWidth: Int = 176,
                       lastRowHeight: Int = 13) throws -> [PopBoksPage.Tile: Data] {
        var out: [PopBoksPage.Tile: Data] = [:]
        for row in 0..<rows {
            for column in 0..<columns {
                let (r, g, b) = colour(column: column, row: row)
                out[PopBoksPage.Tile(column: column, row: row)] = try solid(
                    width: column == columns - 1 ? lastColumnWidth : 256,
                    height: row == rows - 1 ? lastRowHeight : 256,
                    red: r, green: g, blue: b)
            }
        }
        return out
    }

    // MARK: - Reading the result back

    private func decode(_ data: Data) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    /// One pixel, in the coordinates a person reads a page in: y downwards
    /// from the top.
    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: 1, height: 1,
                      bitsPerComponent: 8, bytesPerRow: 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        })
        // Draw the whole page offset so that the wanted pixel lands in the
        // single-pixel context.
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y),
                                       width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func assertColour(_ got: (Int, Int, Int), _ want: (Int, Int, Int),
                              _ what: String, tolerance: Int = 24,
                              file: StaticString = #filePath, line: UInt = #line) {
        let close = abs(got.0 - want.0) <= tolerance
            && abs(got.1 - want.1) <= tolerance
            && abs(got.2 - want.2) <= tolerance
        XCTAssertTrue(close, "\(what): got \(got), wanted about \(want)",
                      file: file, line: line)
    }

    /// A position that holds a tile rather than the blank the fill leaves.
    ///
    /// Deliberately weaker than naming the colour: which tile it is has been
    /// established elsewhere, and what matters here is that something was
    /// drawn at all.
    private func assertDrawn(_ got: (Int, Int, Int), _ what: String,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(got.0 > 240 && got.1 > 240 && got.2 > 240,
                       "\(what): nothing was drawn here, it is blank",
                       file: file, line: line)
    }

    /// Where each tile's middle falls on the finished page.
    private func centres(columns: Int, rows: Int,
                         lastColumnWidth: Int = 176,
                         lastRowHeight: Int = 13) -> [[(x: Int, y: Int)]] {
        var ys: [Int] = []
        var top = 0
        for row in 0..<rows {
            let height = row == rows - 1 ? lastRowHeight : 256
            ys.append(top + height / 2)
            top += height
        }
        var xs: [Int] = []
        var left = 0
        for column in 0..<columns {
            let width = column == columns - 1 ? lastColumnWidth : 256
            xs.append(left + width / 2)
            left += width
        }
        return ys.map { y in xs.map { (x: $0, y: y) } }
    }

    /// The colour at the middle of every tile, as a grid.
    ///
    /// Sampled rather than compared against the colours that went in, because
    /// the round trip through PNG, a drawing context and JPEG shifts every
    /// channel by up to about 25 — consistently, but by enough that an
    /// absolute match would be asserting something about colour management
    /// rather than about where the tiles went.
    ///
    /// What placement actually needs is *order*: red rises to the right and
    /// green downwards, so a page that is flipped, mirrored or transposed
    /// fails and a page that is merely a slightly different blue does not.
    private func sampled(_ page: PopBoksPage.Stitched,
                         columns: Int, rows: Int) throws -> [[(Int, Int, Int)]] {
        let image = try decode(page.data)
        return try centres(columns: columns, rows: rows).map { row in
            try row.map { try pixel(image, x: $0.x, y: $0.y) }
        }
    }

    // MARK: - Size

    /// The archive's usual page: five columns and seven rows, 1200x1549.
    func testAFullPageMeasuresWhatTheTilesAddUpTo() throws {
        let page = try PopBoksPage.stitch(tiles: try tiles(columns: 5, rows: 7),
                                          columns: 5, rows: 7)
        let image = try decode(page.data)
        XCTAssertEqual(image.width, 4 * 256 + 176)      // 1200
        XCTAssertEqual(image.height, 6 * 256 + 13)      // 1549
    }

    /// The two Ritam issues the archive's own reader crops: eight rows, with a
    /// full-height seventh and a short eighth.
    func testAnEightRowPageKeepsItsLastStrip() throws {
        let page = try PopBoksPage.stitch(
            tiles: try tiles(columns: 5, rows: 8, lastRowHeight: 76),
            columns: 5, rows: 8)
        let image = try decode(page.data)
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 7 * 256 + 76)      // 1868
    }

    /// A page with fewer rows than the usual seven.
    ///
    /// No page in either magazine has turned out to be one — two looked like
    /// it and were full pages missing a single tile — so this covers the
    /// guard rather than a case in the archive. It is kept because the guard
    /// is what the download leans on the day a re-scan does produce one.
    func testAShortPageIsAWholePage() throws {
        let page = try PopBoksPage.stitch(
            tiles: try tiles(columns: 5, rows: 3, lastRowHeight: 200),
            columns: 5, rows: 3)
        let image = try decode(page.data)
        XCTAssertEqual(image.height, 2 * 256 + 200)
    }

    // MARK: - Placement

    /// **The test this file exists for.**
    ///
    /// Core Graphics counts y upwards from the bottom and the tile grid counts
    /// rows downwards from the top, so a page assembled without flipping is a
    /// page whose rows are in reverse order — which is still a page-shaped
    /// image of the right size, and would sail past every assertion above.
    func testRowsAreNotUpsideDown() throws {
        let page = try PopBoksPage.stitch(tiles: try tiles(columns: 5, rows: 7),
                                          columns: 5, rows: 7)
        let grid = try sampled(page, columns: 5, rows: 7)

        // Green rises with the row number, so reading down any column must
        // find it rising. Reversed rows would find it falling.
        for column in 0..<5 {
            let greens = (0..<7).map { grid[$0][column].1 }
            XCTAssertEqual(greens, greens.sorted(),
                           "column \(column) runs bottom to top: \(greens)")
            XCTAssertEqual(Set(greens).count, 7,
                           "column \(column) repeats a row: \(greens)")
        }
    }

    /// Columns in the order they are fetched, so a page is not mirrored.
    func testColumnsRunLeftToRight() throws {
        let page = try PopBoksPage.stitch(tiles: try tiles(columns: 5, rows: 7),
                                          columns: 5, rows: 7)
        let grid = try sampled(page, columns: 5, rows: 7)

        // Red rises with the column number.
        for row in 0..<7 {
            let reds = grid[row].map(\.0)
            XCTAssertEqual(reds, reds.sorted(), "row \(row) is mirrored: \(reds)")
            XCTAssertEqual(Set(reds).count, 5, "row \(row) repeats a column: \(reds)")
        }
    }

    /// Every tile distinct and in its own place. Catches a transposed grid,
    /// which neither of the checks above would on its own.
    func testEveryTileLandsWhereItBelongs() throws {
        let columns = 5, rows = 7
        let page = try PopBoksPage.stitch(tiles: try tiles(columns: columns, rows: rows),
                                          columns: columns, rows: rows)
        let grid = try sampled(page, columns: columns, rows: rows)

        // Thirty-five positions, thirty-five different colours: no tile was
        // drawn twice and none was left out.
        let all = grid.flatMap { $0 }.map { "\($0.0),\($0.1),\($0.2)" }
        XCTAssertEqual(Set(all).count, columns * rows, "a tile was drawn twice")

        // A transpose swaps the two gradients, so requiring both directions at
        // once is what rules it out.
        for row in 0..<rows {
            XCTAssertEqual(grid[row].map(\.0), grid[row].map(\.0).sorted(), "row \(row)")
        }
        for column in 0..<columns {
            let greens = (0..<rows).map { grid[$0][column].1 }
            XCTAssertEqual(greens, greens.sorted(), "column \(column)")
        }
    }

    // MARK: - Refusals

    /// A tile the archive does not hold is drawn blank and reported.
    ///
    /// The caller only ever omits a tile the archive answered `403` for, so
    /// this is a fact about the scan rather than a fetch that went wrong.
    /// Refusing instead would make Džuboks 88 undownloadable for ever over one
    /// missing corner.
    func testAMissingTileIsDrawnBlankAndReported() throws {
        var grid = try tiles(columns: 5, rows: 7)
        grid[PopBoksPage.Tile(column: 2, row: 3)] = nil

        let page = try PopBoksPage.stitch(tiles: grid, columns: 5, rows: 7)
        XCTAssertEqual(page.blanks, [PopBoksPage.Tile(column: 2, row: 3)])

        let image = try decode(page.data)
        // The page keeps its full size — the hole does not close up.
        XCTAssertEqual(image.width, 1200)
        XCTAssertEqual(image.height, 1549)
        // The hole is white, and its neighbours are untouched.
        assertColour(try pixel(image, x: 2 * 256 + 20, y: 3 * 256 + 20),
                     (255, 255, 255), "the hole")
        assertDrawn(try pixel(image, x: 256 + 20, y: 3 * 256 + 20), "left of the hole")
        assertDrawn(try pixel(image, x: 2 * 256 + 20, y: 4 * 256 + 20), "below the hole")
    }

    /// Džuboks 88's page 35, exactly: a whole page but for the tile at 4,0 —
    /// which is in the very row a naive stitcher measures column widths from.
    ///
    /// The width of column 4 has to come from some other row, or the page
    /// comes out the wrong size and every tile in that column lands wrong.
    func testAHoleInTheTopRowStillMeasuresItsColumn() throws {
        var grid = try tiles(columns: 5, rows: 7)
        grid[PopBoksPage.Tile(column: 4, row: 0)] = nil

        let page = try PopBoksPage.stitch(tiles: grid, columns: 5, rows: 7)
        let image = try decode(page.data)
        // 176 wide, read off the other six tiles in that column — not 256, and
        // not missing.
        XCTAssertEqual(image.width, 4 * 256 + 176)
        XCTAssertEqual(image.height, 1549)
        assertColour(try pixel(image, x: 1100, y: 20), (255, 255, 255), "the hole")
        // Drawn, not blanked. Its exact colour is not the point and would only
        // be asserting how the round trip handles colour.
        assertDrawn(try pixel(image, x: 1100, y: 300), "the tile below the hole")
    }

    /// A row or column with nothing in it at all has no knowable size, and
    /// guessing one moves every tile past it. Refused.
    func testAnEntirelyMissingRowIsRefused() throws {
        var grid = try tiles(columns: 5, rows: 7)
        for column in 0..<5 { grid[PopBoksPage.Tile(column: column, row: 3)] = nil }
        XCTAssertThrowsError(try PopBoksPage.stitch(tiles: grid, columns: 5, rows: 7)) {
            guard case PopBoksPage.StitchError.ragged(let why) = $0 else {
                return XCTFail("wrong error: \($0)")
            }
            XCTAssertTrue(why.contains("row 3"), why)
        }
    }

    func testAnEntirelyMissingColumnIsRefused() throws {
        var grid = try tiles(columns: 5, rows: 7)
        for row in 0..<7 { grid[PopBoksPage.Tile(column: 2, row: row)] = nil }
        XCTAssertThrowsError(try PopBoksPage.stitch(tiles: grid, columns: 5, rows: 7)) {
            guard case PopBoksPage.StitchError.ragged(let why) = $0 else {
                return XCTFail("wrong error: \($0)")
            }
            XCTAssertTrue(why.contains("column 2"), why)
        }
    }

    /// Nothing missing means nothing reported, so a caller can trust `blanks`
    /// as the whole story.
    func testACompletePageReportsNoBlanks() throws {
        let page = try PopBoksPage.stitch(tiles: try tiles(columns: 5, rows: 7),
                                          columns: 5, rows: 7)
        XCTAssertTrue(page.blanks.isEmpty)
    }

    /// A tile that disagrees with its row or column would shear the page.
    func testATileOfTheWrongSizeIsRefused() throws {
        var grid = try tiles(columns: 5, rows: 7)
        grid[PopBoksPage.Tile(column: 1, row: 1)] = try solid(
            width: 200, height: 256, red: 0, green: 0, blue: 0)
        XCTAssertThrowsError(try PopBoksPage.stitch(tiles: grid, columns: 5, rows: 7)) {
            guard case PopBoksPage.StitchError.ragged = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    /// Bytes that are not an image at all — which is what a server sends when
    /// it would rather show an error page than a tile.
    func testRubbishIsRefused() throws {
        var grid = try tiles(columns: 5, rows: 7)
        grid[PopBoksPage.Tile(column: 0, row: 0)] = Data("<html>nope</html>".utf8)
        XCTAssertThrowsError(try PopBoksPage.stitch(tiles: grid, columns: 5, rows: 7)) {
            guard case PopBoksPage.StitchError.undecodableTile = $0 else {
                return XCTFail("wrong error: \($0)")
            }
        }
    }

    // MARK: - The grid

    func testTheGridIsRowMajorFromTheTopLeft() {
        let grid = PopBoksPage.grid(columns: 3, rows: 2)
        XCTAssertEqual(grid.count, 6)
        XCTAssertEqual(grid.first.map { [$0.column, $0.row] }, [0, 0])
        XCTAssertEqual(grid.map(\.row), [0, 0, 0, 1, 1, 1])
        XCTAssertEqual(grid.map(\.column), [0, 1, 2, 0, 1, 2])
    }

    func testAnEmptyGridIsEmpty() {
        XCTAssertTrue(PopBoksPage.grid(columns: 0, rows: 5).isEmpty)
        XCTAssertTrue(PopBoksPage.grid(columns: 5, rows: 0).isEmpty)
    }
}

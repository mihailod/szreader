import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import SZKit

/// Fetching one PopBoks issue, against a stand-in archive.
///
/// Offline, with a transport that serves tiles of the sizes the real archive
/// serves. That is what lets the assembly be tested at all: the thing worth
/// checking is that thirty-five separately fetched tiles arrive at the
/// stitcher as thirty-five *different* tiles, and a test that needed the
/// network would be too slow and too flaky to say so.
///
/// **Run these with `swift test -c release` as well as plainly.** The bug they
/// were written for only appears optimised: with the collector's fix reverted,
/// `swift test` passes all nine and `swift test -c release` fails seven. The
/// app ships optimised, so debug alone is the configuration that does not
/// matter here — and a green debug run is exactly what made the fault look
/// like something else for an hour.
final class PopBoksFetcherTests: XCTestCase {

    // MARK: - A stand-in archive

    /// Serves a tile for any address inside the grid it is given, and 403 for
    /// anything outside it — which is what the real archive answers for a file
    /// it does not have, rather than 404.
    private final class FakeArchive: Transport, @unchecked Sendable {
        let columns: Int
        let rows: Int
        /// Positions to answer 403 for even though they are inside the grid,
        /// the way the real archive has holes in otherwise complete pages.
        var holes: Set<PopBoksPage.Tile>
        /// Pages to answer 403 for entirely.
        var absentPages: Set<Int>
        private let lock = NSLock()
        private(set) var asked: [String] = []

        init(columns: Int = 5, rows: Int = 7,
             holes: Set<PopBoksPage.Tile> = [], absentPages: Set<Int> = []) {
            self.columns = columns; self.rows = rows
            self.holes = holes; self.absentPages = absentPages
        }

        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            let path = request.url.lastPathComponent
            lock.lock(); asked.append(request.url.path); lock.unlock()

            // ".../{issue}/{page}/2_{column}_{row}.jpg"
            let parts = request.url.pathComponents
            let page = Int(parts[parts.count - 2]) ?? 0
            let name = path.replacingOccurrences(of: ".jpg", with: "")
            let numbers = name.split(separator: "_").compactMap { Int($0) }
            guard numbers.count == 3 else { return HTTPResponse(status: 403) }
            let (column, row) = (numbers[1], numbers[2])

            if absentPages.contains(page) { return HTTPResponse(status: 403) }
            guard column < columns, row < rows else { return HTTPResponse(status: 403) }
            if holes.contains(PopBoksPage.Tile(column: column, row: row)) {
                return HTTPResponse(status: 403)
            }
            // The real archive's shape: a narrow last column, a short last row.
            let width = column == columns - 1 ? 176 : 256
            let height = row == rows - 1 ? 13 : 256
            return HTTPResponse(status: 200,
                                body: Self.tile(width: width, height: height,
                                                column: column, row: row))
        }

        /// A tile whose colour identifies where it came from, so a page
        /// assembled out of the wrong tiles is not merely the wrong size.
        static func tile(width: Int, height: Int, column: Int, row: Int) -> Data {
            let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            context.setFillColor(CGColor(red: CGFloat(30 + column * 40) / 255,
                                         green: CGFloat(30 + row * 30) / 255,
                                         blue: 0.7, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let image = context.makeImage()!
            let out = NSMutableData()
            let destination = CGImageDestinationCreateWithData(
                out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
            return out as Data
        }
    }

    private func issue(id: Int = 1, firstPage: Int = 1, pages: Int = 1,
                       columns: Int = 5, rows: Int = 7) -> PopBoksCatalog.Issue {
        PopBoksCatalog.Issue(id: id, number: id, label: "\(id)", title: "Džuboks \(id)",
                             year: 1974, month: nil, firstPage: firstPage, pages: pages,
                             columns: columns, rows: rows)
    }

    private func catalogue(_ issue: PopBoksCatalog.Issue) -> PopBoksCatalog {
        PopBoksCatalog(version: 1, generated: "test", base: PopBoks.base,
                       magazine: "dzuboks", issues: [issue])
    }

    private func directory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("popboks-tests/\(UUID().uuidString)")
        return url
    }

    private func size(of url: URL) throws -> (width: Int, height: Int) {
        let data = try Data(contentsOf: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (try XCTUnwrap(props[kCGImagePropertyPixelWidth] as? Int),
                try XCTUnwrap(props[kCGImagePropertyPixelHeight] as? Int))
    }

    /// No pause between pages: the courtesy interval is right against a real
    /// archive and is dead time in a test.
    private func fetcher(_ transport: Transport) -> PopBoksFetcher {
        PopBoksFetcher(transport: transport, interval: .zero)
    }

    // MARK: - The whole page

    /// **The regression this file exists for.**
    ///
    /// Thirty-five tiles are fetched concurrently and have to arrive at the
    /// stitcher as thirty-five *different* tiles. They once did not: every
    /// result came back carrying the same position — 0,0 — while the requests
    /// themselves went to the right thirty-five addresses and every one
    /// answered 200. The page collapsed into a single tile and the download
    /// failed with "column 1 is entirely missing", which named the symptom and
    /// nothing else.
    ///
    /// A finished page of the right size is the shortest statement that all
    /// thirty-five got through, because the width comes from five different
    /// columns and the height from seven different rows.
    func testAPageIsAssembledFromEveryTile() async throws {
        let archive = FakeArchive()
        let one = issue()
        let into = directory()

        let result = try await fetcher(archive).fetch(
            issue: one, in: catalogue(one), into: into)

        XCTAssertEqual(result.pages, 1)
        XCTAssertEqual(result.blankTiles, 0)
        XCTAssertTrue(result.missingFromSource.isEmpty)

        let page = into.appendingPathComponent("0001.jpg")
        let (width, height) = try size(of: page)
        XCTAssertEqual(width, 4 * 256 + 176, "the five columns did not all arrive")
        XCTAssertEqual(height, 6 * 256 + 13, "the seven rows did not all arrive")
    }

    /// Every tile asked for exactly once, and nothing outside the page except
    /// the two edge checks.
    func testItAsksForEachTileOnce() async throws {
        let archive = FakeArchive()
        let one = issue()
        _ = try await fetcher(archive).fetch(issue: one, in: catalogue(one),
                                             into: directory())

        let tiles = archive.asked.filter { $0.contains("/1/1/") }
        XCTAssertEqual(Set(tiles).count, tiles.count, "a tile was asked for twice")
        // 35 tiles, plus one row past the bottom and one column past the edge.
        XCTAssertEqual(tiles.count, 37)
    }

    /// The marker is what tells the rest of the app this is a whole issue, and
    /// it must be written last.
    func testAFinishedIssueIsMarkedUnpacked() async throws {
        let archive = FakeArchive()
        let one = issue(pages: 3)
        let into = directory()
        _ = try await fetcher(archive).fetch(issue: one, in: catalogue(one), into: into)

        for page in 1...3 {
            let file = into.appendingPathComponent(String(format: "%04d.jpg", page))
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "page \(page)")
        }
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: into.appendingPathComponent(UnpackMarker.name).path))
    }

    // MARK: - What the archive is missing

    /// A hole in an otherwise complete page is drawn blank and reported,
    /// rather than failing the issue — Džuboks 88's page 35 is exactly this,
    /// and refusing would make that issue undownloadable for ever.
    func testAHoleIsFilledAndReported() async throws {
        let archive = FakeArchive(holes: [PopBoksPage.Tile(column: 4, row: 0)])
        let one = issue()
        let into = directory()

        let result = try await fetcher(archive).fetch(
            issue: one, in: catalogue(one), into: into)

        XCTAssertEqual(result.blankTiles, 1)
        // The page keeps its full size: the missing corner does not close up,
        // and its column's width is read off the rest of that column.
        let (width, height) = try size(of: into.appendingPathComponent("0001.jpg"))
        XCTAssertEqual(width, 1200)
        XCTAssertEqual(height, 1549)
    }

    /// A page the archive does not hold at all is skipped and named, and the
    /// issue still finishes — Džuboks 15's last page is one.
    func testAnAbsentPageIsSkippedNotFatal() async throws {
        let archive = FakeArchive(absentPages: [2])
        let one = issue(pages: 3)
        let into = directory()

        let result = try await fetcher(archive).fetch(
            issue: one, in: catalogue(one), into: into)

        XCTAssertEqual(result.missingFromSource, [2])
        XCTAssertEqual(result.pages, 2)
        // Finished despite the hole, which is the point: two thirds of an
        // issue is worth having and nothing at all is not.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: into.appendingPathComponent(UnpackMarker.name).path))
    }

    // MARK: - A catalogue that has gone stale

    /// A page taller than the index records is refused loudly rather than
    /// stitched short. Cropping is the one failure that would look like a
    /// page and ship.
    func testAPageTallerThanRecordedIsRefused() async throws {
        // The archive has eight rows; the catalogue says seven.
        let archive = FakeArchive(rows: 8)
        let one = issue(rows: 7)

        do {
            _ = try await fetcher(archive).fetch(issue: one, in: catalogue(one),
                                                 into: directory())
            XCTFail("a taller page was accepted")
        } catch let error as PageFetchError {
            XCTAssertTrue("\(error)".contains("more of this page"), "\(error)")
        }
    }

    /// And wider, which is the same failure sideways.
    func testAPageWiderThanRecordedIsRefused() async throws {
        let archive = FakeArchive(columns: 6)
        let one = issue(columns: 5)

        do {
            _ = try await fetcher(archive).fetch(issue: one, in: catalogue(one),
                                                 into: directory())
            XCTFail("a wider page was accepted")
        } catch let error as PageFetchError {
            XCTAssertTrue("\(error)".contains("more of this page"), "\(error)")
        }
    }

    // MARK: - Where a page really is

    /// Reading position one is the scan's own first page, which for one Ritam
    /// issue is page 3.
    func testItFetchesFromTheScansOwnFirstPage() async throws {
        let archive = FakeArchive()
        let one = issue(id: 142, firstPage: 3, pages: 2)
        _ = try await fetcher(archive).fetch(issue: one, in: catalogue(one),
                                             into: directory())

        XCTAssertTrue(archive.asked.contains { $0.contains("/142/3/") })
        XCTAssertTrue(archive.asked.contains { $0.contains("/142/4/") })
        XCTAssertFalse(archive.asked.contains { $0.contains("/142/1/") },
                       "asked for a page before the scan starts")
    }

    // MARK: - Resuming

    /// An interrupted issue must not pay for its finished pages twice. On this
    /// source that is worth thousands of requests.
    func testPagesAlreadyOnDiskAreNotFetchedAgain() async throws {
        let one = issue(pages: 2)
        let into = directory()

        let first = FakeArchive()
        _ = try await fetcher(first).fetch(issue: one, in: catalogue(one), into: into)
        let asked = first.asked.count

        let second = FakeArchive()
        _ = try await fetcher(second).fetch(issue: one, in: catalogue(one), into: into)
        XCTAssertEqual(second.asked.count, 0,
                       "re-fetched \(second.asked.count) of \(asked) tiles")
    }
}

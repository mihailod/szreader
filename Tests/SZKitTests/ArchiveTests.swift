import CoreGraphics
import ImageIO
import XCTest
@testable import SZKit

/// A zip built by Python's zipfile: mixed stored/deflated entries, deliberately
/// out of natural order, with the junk real archives actually contain.
private let fixtureZipBase64 = """
    UEsDBBQAAAAIAAAAIQCpiJ6IBQAAAAMAAAAQAAAAY29taWMvcGFnZTEwLmpwZwtx9QMAUEsDBBQA\
    AAAAAAAAIQDsyG2HAwAAAAMAAAAPAAAAY29taWMvcGFnZTIuanBnVFdPUEsDBBQAAAAIAAAAIQB7\
    xMvsBQAAAAMAAAAPAAAAY29taWMvcGFnZTEuanBn8/dzBQBQSwMEFAAAAAAAAAAhADmc+wYEAAAA\
    BAAAABQAAABfX01BQ09TWC8uX3BhZ2UxLmpwZ2p1bmtQSwMEFAAAAAAAAAAhADmc+wYEAAAABAAA\
    AAkAAABUaHVtYnMuZGJqdW5rUEsDBBQAAAAAAAAAIQAv3bLHDAAAAAwAAAAQAAAAY29taWMvcmVh\
    ZG1lLnR4dG5vdCBhbiBpbWFnZVBLAwQUAAAAAAAAACEAOZz7BgQAAAAEAAAACQAAAC5EU19TdG9y\
    ZWp1bmtQSwECFAMUAAAACAAAACEAqYieiAUAAAADAAAAEAAAAAAAAAAAAAAAgAEAAAAAY29taWMv\
    cGFnZTEwLmpwZ1BLAQIUAxQAAAAAAAAAIQDsyG2HAwAAAAMAAAAPAAAAAAAAAAAAAACAATMAAABj\
    b21pYy9wYWdlMi5qcGdQSwECFAMUAAAACAAAACEAe8TL7AUAAAADAAAADwAAAAAAAAAAAAAAgAFj\
    AAAAY29taWMvcGFnZTEuanBnUEsBAhQDFAAAAAAAAAAhADmc+wYEAAAABAAAABQAAAAAAAAAAAAA\
    AIABlQAAAF9fTUFDT1NYLy5fcGFnZTEuanBnUEsBAhQDFAAAAAAAAAAhADmc+wYEAAAABAAAAAkA\
    AAAAAAAAAAAAAIABywAAAFRodW1icy5kYlBLAQIUAxQAAAAAAAAAIQAv3bLHDAAAAAwAAAAQAAAA\
    AAAAAAAAAACAAfYAAABjb21pYy9yZWFkbWUudHh0UEsBAhQDFAAAAAAAAAAhADmc+wYEAAAABAAA\
    AAkAAAAAAAAAAAAAAIABMAEAAC5EU19TdG9yZVBLBQYAAAAABwAHAKYBAABbAQAAAAA=
    """

private func fixtureZip() throws -> Data {
    try XCTUnwrap(Data(base64Encoded: fixtureZipBase64.replacingOccurrences(of: "\n", with: "")
        .replacingOccurrences(of: " ", with: "")))
}

final class PageManifestTests: XCTestCase {

    /// Lexicographic sorting puts page10 between page1 and page2, silently
    /// shuffling the comic. This is the single most damaging ordering bug.
    func testNaturalSortOrdersPagesLikeAHuman() {
        let shuffled = ["p10.jpg", "p2.jpg", "p1.jpg", "p21.jpg", "p3.jpg"]
        XCTAssertEqual(PageManifest.pages(from: shuffled),
                       ["p1.jpg", "p2.jpg", "p3.jpg", "p10.jpg", "p21.jpg"])
    }

    func testLeadingZerosAndMixedWidthsCompareNumerically() {
        XCTAssertEqual(PageManifest.pages(from: ["009.png", "10.png", "0008.png"]),
                       ["0008.png", "009.png", "10.png"])
    }

    func testJunkIsExcluded() {
        let entries = ["__MACOSX/._p1.jpg", "Thumbs.db", ".DS_Store", "desktop.ini",
                       "comic/", "readme.txt", "cover.jpg"]
        XCTAssertEqual(PageManifest.pages(from: entries), ["cover.jpg"])
    }

    func testNonImagesAreExcludedEvenWhenNotJunk() {
        XCTAssertEqual(PageManifest.pages(from: ["notes.txt", "info.nfo", "a.jpg"]), ["a.jpg"])
    }

    func testSubdirectoriesAreKeptAndSortedTogether() {
        let entries = ["ch2/p1.jpg", "ch1/p2.jpg", "ch1/p10.jpg", "ch1/p1.jpg"]
        XCTAssertEqual(PageManifest.pages(from: entries),
                       ["ch1/p1.jpg", "ch1/p2.jpg", "ch1/p10.jpg", "ch2/p1.jpg"])
    }
}

final class ZipReaderTests: XCTestCase {

    func testListsEveryEntry() throws {
        let reader = try ZipReader(data: try fixtureZip())
        XCTAssertEqual(try reader.entries().count, 7)
    }

    /// Both compression methods a CBZ uses in practice.
    func testReadsStoredAndDeflatedEntries() throws {
        let reader = try ZipReader(data: try fixtureZip())
        XCTAssertEqual(try reader.data(for: "comic/page2.jpg"), Data("TWO".utf8))   // stored
        XCTAssertEqual(try reader.data(for: "comic/page1.jpg"), Data("ONE".utf8))   // deflated
        XCTAssertEqual(try reader.data(for: "comic/page10.jpg"), Data("TEN".utf8))  // deflated
    }

    func testPageNamesFilterAndSort() throws {
        let reader = try ZipReader(data: try fixtureZip())
        XCTAssertEqual(try reader.pageNames(),
                       ["comic/page1.jpg", "comic/page2.jpg", "comic/page10.jpg"])
    }

    func testMissingEntryIsReported() throws {
        let reader = try ZipReader(data: try fixtureZip())
        XCTAssertThrowsError(try reader.data(for: "nope.jpg"))
    }

    func testGarbageIsRejectedRatherThanCrashing() {
        XCTAssertThrowsError(try ZipReader(data: Data(repeating: 0x41, count: 500)))
        XCTAssertThrowsError(try ZipReader(data: Data()))
    }

    /// A `.cbr` that is really a zip must open as a zip; the extension is not
    /// evidence, and a large share of scene files are mislabelled.
    func testOpenerDispatchesOnMagicBytesNotExtension() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let liar = dir.appendingPathComponent("mislabelled.cbr")
        try fixtureZip().write(to: liar)
        let reader = try ArchiveOpener.open(liar)
        XCTAssertEqual(try reader.pageNames().count, 3)

        // A truncated RAR routes to the RAR reader and is rejected there.
        let rar = dir.appendingPathComponent("truncated.cbr")
        try Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00, 0x00]).write(to: rar)
        XCTAssertThrowsError(try ArchiveOpener.open(rar, workDirectory: dir.appendingPathComponent("w")))
    }
}

final class ComicDocumentTests: XCTestCase {

    func testPagesAreOrderedAndAddressable() throws {
        let doc = try ComicDocument(archive: try ZipReader(data: try fixtureZip()))
        XCTAssertEqual(doc.pageCount, 3)
        XCTAssertEqual(try doc.pageData(0), Data("ONE".utf8))
        XCTAssertEqual(try doc.pageData(2), Data("TEN".utf8))
        XCTAssertThrowsError(try doc.pageData(3))
    }

    /// Prefetching both directions keeps a back-flip as smooth as a forward one.
    func testPrefetchWindowClampsAtBothEnds() throws {
        let doc = try ComicDocument(archive: try ZipReader(data: try fixtureZip()))
        XCTAssertEqual(doc.prefetchWindow(around: 0), [1, 2])
        XCTAssertEqual(doc.prefetchWindow(around: 1), [0, 2])
        XCTAssertEqual(doc.prefetchWindow(around: 2), [0, 1])
    }
}

final class PageRendererTests: XCTestCase {

    /// A page-sized JPEG, built in process so the test needs no binary fixture.
    private func syntheticPage(width: Int, height: Int) throws -> Data {
        let space = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: space,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())

        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            out, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    func testReadsPixelSizeWithoutDecoding() throws {
        let data = try syntheticPage(width: 1600, height: 2400)
        let size = try XCTUnwrap(PageRenderer.pixelSize(of: data))
        XCTAssertEqual(size.width, 1600)
        XCTAssertEqual(size.height, 2400)
    }

    /// The point of the whole exercise: a 2500x3500 scan must not be decoded at
    /// full size just to fill a 2732px panel.
    func testDownsampleCapsTheLongEdge() throws {
        let data = try syntheticPage(width: 2500, height: 3500)
        let image = try XCTUnwrap(PageRenderer.downsample(data: data, maxPixelSize: 1024))
        XCTAssertEqual(max(image.width, image.height), 1024)
        // Aspect preserved: 2500/3500 of 1024 is 731.
        XCTAssertEqual(image.width, 731, accuracy: 2)
    }

    func testDownsampleDoesNotUpscaleBeyondSource() throws {
        let data = try syntheticPage(width: 400, height: 600)
        let image = try XCTUnwrap(PageRenderer.downsample(data: data, maxPixelSize: 4096))
        XCTAssertLessThanOrEqual(max(image.width, image.height), 600)
    }

    func testUndecodableBytesAreRejected() {
        XCTAssertFalse(PageRenderer.isDecodable(Data("not an image".utf8)))
        XCTAssertNil(PageRenderer.downsample(data: Data(), maxPixelSize: 512))
    }
}

private func XCTAssertEqual(_ a: Int, _ b: Int, accuracy: Int,
                            file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertTrue(abs(a - b) <= accuracy, "\(a) not within \(accuracy) of \(b)",
                  file: file, line: line)
}

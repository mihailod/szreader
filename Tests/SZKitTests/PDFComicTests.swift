import CoreGraphics
import XCTest
@testable import SZKit

/// Comics that arrive as a PDF rather than a folder of scans.
///
/// Sirius is the case: every individual download on its page is dead, and the
/// only surviving copies are collected archives holding one PDF per issue.
final class PDFComicTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A magazine-shaped PDF with a distinct mark on each page.
    private func makePDF(named name: String, pages: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 420, height: 595)      // A5, like Sirius
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw XCTSkip("cannot write a PDF here")
        }
        for page in 0..<pages {
            context.beginPage(mediaBox: &box)
            context.setFillColor(gray: 0, alpha: 1)
            // A bar whose height encodes the page, so pages are told apart.
            context.fill(CGRect(x: 20, y: 20, width: 100, height: 20 + CGFloat(page) * 10))
            context.endPage()
        }
        context.closePDF()
        return url
    }

    func testPagesAreDrawnAtTheSizeAsked() throws {
        let doc = try ComicDocument(pdfAt: try makePDF(named: "comic.pdf", pages: 6))
        XCTAssertEqual(doc.pageCount, 6)
        XCTAssertTrue(doc.isPDF)

        let image = try XCTUnwrap(doc.page(0, maxPixelSize: 1200))
        XCTAssertEqual(max(image.width, image.height), 1200)
        // A5 is taller than wide, and that has to survive the rendering.
        XCTAssertGreaterThan(image.height, image.width)
    }

    /// Pages must not all be the same page.
    func testEachPageIsItsOwn() throws {
        let doc = try ComicDocument(pdfAt: try makePDF(named: "comic.pdf", pages: 4))
        let inks = try (0..<4).map { index -> Int in
            let image = try XCTUnwrap(doc.page(index, maxPixelSize: 200))
            return Self.darkPixels(image)
        }
        XCTAssertEqual(inks, inks.sorted(), "later pages carry more ink; these are out of order")
        XCTAssertEqual(Set(inks).count, 4, "some pages rendered identically")
    }

    /// Unpainted areas are paper, not a hole — a transparent page reads as
    /// black once it is drawn on the reader's background.
    func testUnpaintedAreasArePaper() throws {
        let doc = try ComicDocument(pdfAt: try makePDF(named: "comic.pdf", pages: 1))
        let image = try XCTUnwrap(doc.page(0, maxPixelSize: 200))
        XCTAssertLessThan(Self.darkPixels(image), image.width * image.height / 2,
                          "the page came out mostly dark")
    }

    /// A PDF downloaded on its own opens through the ordinary path.
    func testADownloadedPDFIsRecognised() throws {
        let url = try makePDF(named: "comic.pdf", pages: 3)
        XCTAssertEqual(ArchiveKind.sniff(url), .pdf)
        XCTAssertEqual(try ComicDocument(fileURL: url).pageCount, 3)
    }

    func testSomethingThatIsNotAPDFIsRefused() throws {
        let url = root.appendingPathComponent("nope.pdf")
        try Data("not a pdf".utf8).write(to: url)
        XCTAssertThrowsError(try ComicDocument(pdfAt: url))
    }

    private static func darkPixels(_ image: CGImage) -> Int {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(data: &bytes, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return 0 }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return bytes.filter { $0 < 128 }.count
    }
}

/// Runs of issues published as a single download.
final class IssueSegmentTests: XCTestCase {

    private let page = """
        <title>Sirius, SF časopis - Casopisi - Stripzona</title>
        <span itemprop="title">Casopisi</span>
        <div>http://www.mediafire.com/?FAKESET001 - Sirius 001-116 (pdf)</div>
        <div>http://www.mediafire.com/?FAKESET143 - Sirius 143-164+YU (pdf)</div>
        <div>http://www.mediafire.com/?FAKE001 - Sirius 001 - Ne ubijte Rulla</div>
        <div>http://www.mediafire.com/?FAKE099 - Sirius 099 - 900 Baka</div>
        <div>http://www.mediafire.com/?FAKE163 - Sirius 163/164 - Posljednji Winnebago</div>
        <div>http://www.mediafire.com/?FAKE121 - Sirius 121-122 - Euroconski dvoboj</div>
        <div>http://www.mediafire.com/?FAKEYU - YU SIRIUS</div>
        """

    func testASpanIsASetRatherThanAnIssue() {
        let sets = Catalog.segments(in: page)
        XCTAssertEqual(sets.map(\.first), [1, 143])
        XCTAssertEqual(sets.map(\.last), [116, 164])
    }

    /// A title beginning with a number is not a span — issue 99 is "900 Baka".
    func testATitleStartingWithANumberIsNotASet() {
        XCTAssertFalse(Catalog.segments(in: page).contains { $0.first == 99 })
    }

    /// Two consecutive numbers are a double issue — one magazine — however
    /// the topic joins them. Written with a dash it looks exactly like a
    /// span, and reading it as a set of two would put a whole download behind
    /// a single comic.
    func testADoubleIssueIsNotASet() {
        let sets = Catalog.segments(in: page)
        XCTAssertFalse(sets.contains { $0.first == 163 })
        XCTAssertFalse(sets.contains { $0.first == 121 }, "a double issue was read as a set")
    }

    func testIssuesFindTheirSet() throws {
        let store = try Store()
        try store.ingest(html: page)
        let rows = try store.recent(limit: nil)

        let first = try XCTUnwrap(rows.first { $0.number == 1 })
        XCTAssertEqual(try store.segment(forIssue: first.id)?.last, 116)

        // The special has no number, and says so only in the set's own label.
        let special = try XCTUnwrap(rows.first { $0.title == "YU SIRIUS" })
        XCTAssertEqual(try store.segment(forIssue: special.id)?.first, 143)

        let double = try XCTUnwrap(rows.first { $0.numberTo == 164 })
        XCTAssertEqual(try store.segment(forIssue: double.id)?.first, 143)
    }

    /// Which file inside the archive belongs to which issue.
    func testMembersAreMatchedToIssues() {
        let entries = [
            "Sirius 143-164+YU/Sirius 143.pdf",
            "Sirius 143-164+YU/Sirius 155-156.pdf",
            "Sirius 143-164+YU/Sirius 163-164.pdf",
            "Sirius 143-164+YU/YU Sirius.pdf",
        ]
        XCTAssertEqual(IssueSegment.member(entries, number: 143, numberTo: nil, title: "X"),
                       "Sirius 143-164+YU/Sirius 143.pdf")
        // A double must take its own file, not the one it is half of.
        XCTAssertEqual(IssueSegment.member(entries, number: 155, numberTo: 156, title: "X"),
                       "Sirius 143-164+YU/Sirius 155-156.pdf")
        XCTAssertEqual(IssueSegment.member(entries, number: nil, numberTo: nil,
                                           title: "YU SIRIUS"),
                       "Sirius 143-164+YU/YU Sirius.pdf")
        XCTAssertNil(IssueSegment.member(entries, number: 999, numberTo: nil, title: nil))
    }

    /// The warning names the run, because a size alone does not explain why
    /// one tap moves a hundred comics.
    func testTheWarningNamesTheRun() {
        let set = IssueSegment(url: "u", label: "Sirius 001-116 (pdf)", first: 1, last: 116)
        XCTAssertTrue(set.downloadWarning.contains("1–116"))
        XCTAssertTrue(set.removalWarning.contains("1–116"))
        // Read them as sentences, not as a verb dropped into a slot.
        XCTAssertTrue(set.downloadWarning.hasSuffix("fetch all of them."))
        XCTAssertTrue(set.removalWarning.hasSuffix("removes all of them."))
    }
}

/// What a set costs on disk.
final class SegmentDiskUsageTests: XCTestCase {

    /// Every issue in a set points into one shared directory. Charging each
    /// of them for it reported 16.68 GB for 144 MB of files.
    func testASharedSetIsCountedOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let shared = root.appendingPathComponent("set-1/contents", isDirectory: true)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)

        let store = try Store()
        var html = "<title>Sirius, SF časopis - Casopisi - Stripzona</title>"
        for n in 1...5 {
            html += "<div>http://www.mediafire.com/?FAKE\(n) - Sirius 00\(n) - Naslov \(n)</div>"
        }
        try store.ingest(html: html)

        // One megabyte of files, five issues reading out of them.
        for n in 1...5 {
            try Data(repeating: 0x41, count: 200_000)
                .write(to: shared.appendingPathComponent("Sirius 00\(n).pdf"))
        }
        for (n, issue) in try store.recent(limit: nil).sorted(by: { ($0.number ?? 0) < ($1.number ?? 0) })
            .enumerated() {
            try store.recordDownload(issueID: issue.id, mirrorURL: "set",
                                     path: shared.appendingPathComponent("Sirius 00\(n + 1).pdf"),
                                     bytes: 200_000)
        }

        let onDisk = Store.sizeOnDisk(shared)
        XCTAssertEqual(store.totalDownloadedBytes, onDisk,
                       "the shared set was counted once per issue")
        XCTAssertLessThan(store.totalDownloadedBytes, onDisk * 2)
    }
}

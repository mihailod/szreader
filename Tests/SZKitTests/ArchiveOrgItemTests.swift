import XCTest
@testable import SZKit

/// Reading archive.org's metadata, which is what the shipped catalogue is
/// built out of.
///
/// The fixture below is a real response with the fields nothing uses removed —
/// OCR confidence, torrents, which servers hold the item. What is left is
/// exactly what `archive-build` reads.
final class ArchiveOrgItemTests: XCTestCase {

    private let biltenJSON = """
    {
      "created": 1786981457,
      "metadata": {
        "identifier": "amiga-bilten-1",
        "title": "Amiga Bilten 1",
        "creator": "Almir Mulabećirović & Elmir Husetović",
        "date": "1988-09",
        "language": "bos",
        "mediatype": "texts"
      },
      "files": [
        {"name": "Amiga Bilten 1.pdf", "format": "Image Container PDF", "size": "7174738"},
        {"name": "Amiga Bilten 1_text.pdf", "format": "Additional Text PDF", "size": "2673983"},
        {"name": "Amiga Bilten 1_jp2.zip", "format": "Single Page Processed JP2 ZIP",
         "size": "38570760"},
        {"name": "Amiga Bilten 1_page_numbers.json", "format": "Page Numbers JSON",
         "size": "3179"},
        {"name": "Amiga Bilten 1_scandata.xml", "format": "Scandata", "size": "6388"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "16306"},
        {"name": "amiga-bilten-1_files.xml", "format": "Metadata"}
      ]
    }
    """.data(using: .utf8)!

    func testItReadsWhatTheCatalogueNeeds() throws {
        let item = try XCTUnwrap(try ArchiveOrgItem.decode(biltenJSON))
        XCTAssertEqual(item.identifier, "amiga-bilten-1")
        XCTAssertEqual(item.title, "Amiga Bilten 1")
        XCTAssertEqual(item.year, 1988)
        XCTAssertEqual(item.month, 9)
    }

    /// The uploaded scan, not one of the derivatives made from it. Picking by
    /// extension would take whichever `.pdf` came first, and the OCR copy is a
    /// third of the size and visibly worse.
    func testTheScanIsTheUploadedPDF() throws {
        let item = try XCTUnwrap(try ArchiveOrgItem.decode(biltenJSON))
        XCTAssertEqual(item.scan?.name, "Amiga Bilten 1.pdf")
        XCTAssertEqual(item.scan?.bytes, 7_174_738)
    }

    /// The page count comes from the scanner's record, not from the page-number
    /// derivative that sits beside it under a more inviting name.
    func testThePageCountComesFromScandata() throws {
        let item = try XCTUnwrap(try ArchiveOrgItem.decode(biltenJSON))
        XCTAssertEqual(item.scandata?.name, "Amiga Bilten 1_scandata.xml")
    }

    /// The count the scan states, and — when a file somehow omits it — the
    /// pages it actually holds.
    func testScandataIsCounted() {
        let xml = """
            <book><bookData><leafCount>18</leafCount></bookData>
            <pageData><page leafNum="0"><pageType>Normal</pageType></page>
            <page leafNum="1"><pageType>Normal</pageType></page></pageData></book>
            """
        XCTAssertEqual(ArchiveOrg.pageCount(inScandata: xml), 18)

        let noCount = "<book><pageData><page leafNum=\"0\"/><page leafNum=\"1\"/>"
                    + "<page leafNum=\"2\"/></pageData></book>"
        XCTAssertEqual(ArchiveOrg.pageCount(inScandata: noCount), 3)
        XCTAssertNil(ArchiveOrg.pageCount(inScandata: "<book></book>"))
    }

    /// A file with no size at all still decodes — the metadata omits it for
    /// the derived XML — rather than failing the whole item.
    func testAFileWithNoSizeIsStillListed() throws {
        let item = try XCTUnwrap(try ArchiveOrgItem.decode(biltenJSON))
        let xml = try XCTUnwrap(item.files.first { $0.name.hasSuffix("_files.xml") })
        XCTAssertNil(xml.bytes)
    }

    /// An identifier that does not exist answers `{}` with HTTP 200, so "no
    /// metadata" is the only signal there is.
    func testAMissingItemIsNil() throws {
        XCTAssertNil(try ArchiveOrgItem.decode("{}".data(using: .utf8)!))
    }

    /// Items are dated to whatever precision their uploader had.
    func testDatesAreReadAtEveryPrecisionTheArchiveUses() {
        XCTAssertEqual(ArchiveOrgItem.dateComponents(of: "1988-09").month, 9)
        XCTAssertEqual(ArchiveOrgItem.dateComponents(of: "1988-09-01").month, 9)
        XCTAssertEqual(ArchiveOrgItem.dateComponents(of: "1988").year, 1988)
        XCTAssertNil(ArchiveOrgItem.dateComponents(of: "1988").month)
        XCTAssertNil(ArchiveOrgItem.dateComponents(of: "undated").year)
        XCTAssertNil(ArchiveOrgItem.dateComponents(of: nil).year)
        // A month out of range is no month rather than a wrong one.
        XCTAssertNil(ArchiveOrgItem.dateComponents(of: "1988-13").month)
    }

    // MARK: - Addresses

    /// The scans are named as their uploader typed them, spaces and all, so
    /// every path the catalogue records has to survive `URL(string:)`.
    func testPathsAreEscaped() throws {
        let path = ArchiveOrg.path(item: "amiga-bilten-1", file: "Amiga Bilten 1.pdf")
        XCTAssertEqual(path, "amiga-bilten-1/Amiga%20Bilten%201.pdf")
        XCTAssertNotNil(URL(string: ArchiveOrg.base + path))
        // A "/" inside a name would otherwise invent a directory.
        XCTAssertEqual(ArchiveOrg.encode("a/b"), "a%2Fb")
    }

    func testTheCoverIsTheFirstPage() {
        XCTAssertEqual(ArchiveOrg.firstPagePath(item: "amiga-bilten-1"),
                       "amiga-bilten-1/page/n0_w1024.jpg")
    }
}

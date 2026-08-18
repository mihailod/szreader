import XCTest
@testable import SZKit

/// Importing an arbitrary item off archive.org, rather than the four the app
/// ships a catalogue for.
///
/// The fixtures are real responses, cut down to the fields that are read. They
/// are the items the feature was built against:
///
///  * `zagor-137-…` — a CBR upload with the archive's full derivative set
///    beside it, which is the common shape.
///  * `vc-op-zagor-007-…` — uploaded as a PDF, whose OCR derivative differs
///    from it *by one letter of case* in the filename and by 240 MB in size.
///  * `vc-lms-na-bis-003-…` — one PNG, a torrent and nothing else: an item
///    that looks importable from the outside and is not.
final class ArchiveOrgBrowseTests: XCTestCase {

    // MARK: - Fixtures

    /// A CBR upload, with everything archive.org derives from one.
    private let comicBookItem = """
    {
      "metadata": {
        "identifier": "zagor-137-dharma-la-strega-daim-press-1976-12",
        "title": "Zagor 137 Dharma La Strega ( Daim Press 1976 12)",
        "mediatype": "texts",
        "collection": ["comics_inbox", "comics", "folkscanomy"],
        "subject": ["zagor", "daim press"]
      },
      "files": [
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12).cbr",
         "format": "Comic Book RAR", "size": "38194644",
         "source": "original"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12).epub",
         "format": "EPUB", "size": "65685066", "source": "derivative"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12).pdf",
         "format": "Text PDF", "size": "8224620",
         "source": "derivative"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_djvu.txt",
         "format": "DjVuTXT", "size": "35188", "source": "derivative"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_hocr.html",
         "format": "hOCR", "size": "1332643", "source": "derivative"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_jp2.zip",
         "format": "Single Page Processed JP2 ZIP", "size": "63921139",
         "source": "derivative"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_scandata.xml",
         "format": "Scandata", "size": "32229", "source": "derivative"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "26795",
         "source": "original"},
        {"name": "zagor-137-dharma-la-strega-daim-press-1976-12_archive.torrent",
         "format": "Archive BitTorrent", "size": "11313",
         "source": "metadata"},
        {"name": "zagor-137-dharma-la-strega-daim-press-1976-12_files.xml",
         "format": "Metadata", "source": "original"}
      ]
    }
    """.data(using: .utf8)!

    /// Uploaded as a PDF. Note the two PDFs: ".PDF" is the 264 MB scan and
    /// ".pdf" is the 23 MB OCR derivative, and only the format tells them
    /// apart.
    private let scannedPDFItem = """
    {
      "metadata": {
        "identifier": "vc-op-zagor-007-povratak-vampira",
        "title": "VC OP Zagor 007 POVRATAK VAMPIRA",
        "mediatype": "texts",
        "subject": "VC Z OP"
      },
      "files": [
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA.PDF",
         "format": "Image Container PDF", "size": "263568337",
         "source": "original"},
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA.pdf",
         "format": "Text PDF", "size": "23295680",
         "source": "derivative"},
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA_jp2.zip",
         "format": "Single Page Processed JP2 ZIP", "size": "193200889",
         "source": "derivative"},
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA_page_numbers.json",
         "format": "Page Numbers JSON", "size": "50656",
         "source": "derivative"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "29877",
         "source": "original"},
        {"name": "vc-op-zagor-007-povratak-vampira_archive.torrent",
         "format": "Archive BitTorrent", "size": "22696",
         "source": "metadata"}
      ]
    }
    """.data(using: .utf8)!

    /// One cover scan uploaded on its own. Every item has a torrent, so this
    /// one is not "torrent only" — it simply holds nothing to read.
    private let singleImageItem = """
    {
      "metadata": {
        "identifier": "vc-lms-na-bis-003-teks-viler-indijanski-agent",
        "title": "VC LMS Na Bis 003 Teks Viler INDIJANSKI AGENT",
        "mediatype": "image",
        "collection": "opensource_image"
      },
      "files": [
        {"name": "VC - LMS na Bis - 003 - Teks Viler.png", "format": "PNG",
         "size": "5071563", "source": "original"},
        {"name": "VC - LMS na Bis - 003 - Teks Viler_thumb.jpg",
         "format": "JPEG Thumb", "size": "14285", "source": "derivative"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "28168",
         "source": "original"},
        {"name": "vc-lms-na-bis-003-teks-viler-indijanski-agent_archive.torrent",
         "format": "Archive BitTorrent", "size": "2803",
         "source": "metadata"}
      ]
    }
    """.data(using: .utf8)!

    /// Byte, September 1986 — scanned by the archive itself rather than
    /// uploaded as a comic, so its derivative set is a different one and its
    /// *upload* is the PDF.
    ///
    /// The item that found two bugs at once. `_daisy.zip` is a DAISY
    /// accessibility package — navigation XML, no pages — and it was offered
    /// as "ZIP, as uploaded, 1.1 MB" beside a 330 MB PDF described as
    /// "smaller".
    private let scannedMagazineItem = """
    {
      "metadata": {
        "identifier": "byte-magazine-1986-09",
        "title": "Byte Magazine Volume 11 Number 09 - The 68000 Family",
        "mediatype": "texts",
        "date": "1986-09",
        "subject": ["byte", "software"]
      },
      "files": [
        {"name": "1986_09_BYTE_11-09.pdf", "format": "Text PDF",
         "size": "330720249", "source": "original"},
        {"name": "1986_09_BYTE_11-09_daisy.zip", "format": "Daisy",
         "size": "1102497", "source": "derivative"},
        {"name": "1986_09_BYTE_11-09.djvu", "format": "DjVu",
         "size": "26774099", "source": "derivative"},
        {"name": "1986_09_BYTE_11-09.epub", "format": "EPUB",
         "size": "49329804", "source": "derivative"},
        {"name": "1986_09_BYTE_11-09.gif", "format": "Animated GIF",
         "size": "243930", "source": "derivative"},
        {"name": "1986_09_BYTE_11-09_abbyy.gz", "format": "Abbyy GZ",
         "size": "28337260", "source": "derivative"},
        {"name": "1986_09_BYTE_11-09_jp2.zip", "format": "Single Page Processed JP2 ZIP",
         "size": "374979001", "source": "derivative"},
        {"name": "1986_09_BYTE_11-09.pdf_meta.txt", "format": "Metadata",
         "size": "583", "source": "original"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile",
         "size": "23344", "source": "original"},
        {"name": "byte-magazine-1986-09_archive.torrent", "format": "Archive BitTorrent",
         "size": "35443", "source": "metadata"}
      ]
    }
    """.data(using: .utf8)!

    /// A "magazine pack": one archive.org item holding a whole run.
    ///
    /// Thirteen issues of Transactor, one PDF each, and the archive ran its
    /// page pipeline over the first only. Treating the item as the issue
    /// offered thirteen identical-looking "PDF · as uploaded" rows and wrote
    /// them all to one library row, each import replacing the last.
    private let packItem = """
    {
      "metadata": {
        "identifier": "transactor-for-the-amiga",
        "title": "Transactor For The Amiga",
        "mediatype": "texts",
        "date": "1988-01-01"
      },
      "files": [
        {"name": "Transactor_for_the_Amiga_Vol_01_01_1988_Apr[ocr].pdf",
         "format": "Text PDF", "size": "15659468", "source": "original"},
        {"name": "Transactor_for_the_Amiga_Vol_01_01_1988_Apr[ocr]_jp2.zip",
         "format": "Single Page Processed JP2 ZIP", "size": "222917474",
         "source": "derivative"},
        {"name": "Transactor_for_the_Amiga_Vol_01_01_1988_Apr[ocr]_scandata.xml",
         "format": "Scandata", "size": "28426", "source": "derivative"},
        {"name": "Transactor_for_the_Amiga_Vol_01_02_1988_Jun[ocr].pdf",
         "format": "Text PDF", "size": "14518557", "source": "original"},
        {"name": "Transactor_for_the_Amiga_Vol_03_01_1989_Oct[ocr].pdf",
         "format": "Text PDF", "size": "16014940", "source": "original"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "23147",
         "source": "original"},
        {"name": "transactor-for-the-amiga_archive.torrent",
         "format": "Archive BitTorrent", "size": "23813", "source": "metadata"}
      ]
    }
    """.data(using: .utf8)!

    private func item(_ data: Data) throws -> ArchiveOrgItem {
        try XCTUnwrap(try ArchiveOrgItem.decode(data))
    }

    // MARK: - Which page is an item

    /// One item is a dozen addresses. All of them name it, and nothing else
    /// does.
    func testTheItemIsReadOffTheAddress() throws {
        let itemPages = [
            "https://archive.org/details/amiga-bilten-1",
            "https://archive.org/details/amiga-bilten-1/page/n0/mode/2up",
            "https://archive.org/details/amiga-bilten-1?sort=-publicdate",
            "https://archive.org/download/amiga-bilten-1/Amiga%20Bilten%201.pdf",
            "https://archive.org/metadata/amiga-bilten-1",
            "https://archive.org/stream/amiga-bilten-1",
            "https://ARCHIVE.ORG/details/amiga-bilten-1",
        ]
        for page in itemPages {
            XCTAssertEqual(ArchiveOrg.identifier(inURL: URL(string: page)!),
                           "amiga-bilten-1", page)
        }

        let notItems = [
            // Where the browser opens, and where Import must stay dark.
            "https://archive.org/search",
            "https://archive.org/search?query=zagor&sin=TXT",
            "https://archive.org/",
            "https://archive.org/details",
            "https://archive.org/about/",
            // A member's profile sits at the same shape as an item.
            "https://archive.org/details/@some_uploader",
            // The Wayback Machine is a subdomain, and its paths are not items.
            "https://web.archive.org/web/2020/http://example.com/",
            // The item servers serve page images, not item pages.
            "https://ia601403.us.archive.org/BookReader/BookReaderImages.php?id=x",
            // Somewhere else entirely, wearing the same path.
            "https://example.com/details/amiga-bilten-1",
        ]
        for page in notItems {
            XCTAssertNil(ArchiveOrg.identifier(inURL: URL(string: page)!), page)
        }
    }

    // MARK: - Which files are readable

    /// The CBR the scanner uploaded, and the PDF the archive derived — in that
    /// order, and nothing else out of the ten files beside them.
    func testOnlyTheFilesTheReaderCanOpenAreOffered() throws {
        let files = try item(comicBookItem).readableFiles
        XCTAssertEqual(files.map(\.name), [
            "Zagor 137 Dharma la strega (Daim Press 1976-12).cbr",
            "Zagor 137 Dharma la strega (Daim Press 1976-12).pdf",
        ])
        XCTAssertEqual(files.map(\.kind), [.comicBook, .text])
        XCTAssertEqual(files.map(\.label), ["CBR", "PDF"])
        XCTAssertEqual(files.first?.bytes, 38_194_644)
    }

    /// JPEG 2000 is the biggest file in most items and iOS cannot decode it at
    /// all, so offering it would mean downloading 64 MB to render blank pages.
    ///
    /// The torrent is excluded for a different reason and it matters which:
    /// every item on archive.org has one, generated whether or not anyone
    /// wanted it, so its presence says nothing about an item — there is simply
    /// no BitTorrent client here.
    func testTheDerivativesThisAppCannotUseAreNotOffered() throws {
        let offered = Set(try item(comicBookItem).readableFiles.map(\.name))
        for excluded in ["Zagor 137 Dharma la strega (Daim Press 1976-12)_jp2.zip",
                         "Zagor 137 Dharma la strega (Daim Press 1976-12).epub",
                         "Zagor 137 Dharma la strega (Daim Press 1976-12)_djvu.txt",
                         "Zagor 137 Dharma la strega (Daim Press 1976-12)_hocr.html",
                         "Zagor 137 Dharma la strega (Daim Press 1976-12)_scandata.xml",
                         "zagor-137-dharma-la-strega-daim-press-1976-12_archive.torrent",
                         "zagor-137-dharma-la-strega-daim-press-1976-12_files.xml",
                         "__ia_thumb.jpg"] {
            XCTAssertFalse(offered.contains(excluded), excluded)
        }
    }

    /// A `_jp2.zip` whose format the archive never recorded would otherwise
    /// read as a plain zip — 190 MB of pages nothing here can decode.
    func testAJP2ZipIsRefusedEvenWithNoFormatToGoOn() {
        let unlabelled = ArchiveOrgItem.File(name: "Some Comic_jp2.zip",
                                             format: nil, bytes: 190_000_000)
        XCTAssertNil(ArchiveOrgItem.kind(of: unlabelled))
        // While a plain zip upload beside it is exactly what this app reads.
        let real = ArchiveOrgItem.File(name: "Some Comic.zip", format: nil, bytes: 40_000_000)
        XCTAssertEqual(ArchiveOrgItem.kind(of: real), .container)
    }

    /// Two files one letter of case apart, 240 MB and quite different things.
    /// Only the archive's own word for them tells which is the scan.
    func testTheUploadedScanIsToldFromItsOCRDerivative() throws {
        let files = try item(scannedPDFItem).readableFiles
        XCTAssertEqual(files.map(\.kind), [.scan, .text])
        XCTAssertEqual(files.first?.name, "VC OP - Zagor - 007 - POVRATAK VAMPIRA.PDF")
        XCTAssertEqual(files.first?.bytes, 263_568_337)
        XCTAssertEqual(files.last?.bytes, 23_295_680)
    }

    /// A DAISY package is a bundle of navigation XML for print-disabled
    /// readers, holding no pages at all — and nothing about the name "Daisy"
    /// or the extension ".zip" says so.
    ///
    /// `source` does, in one word, which is why derivatives are now judged by
    /// an allow-list instead of by their extension. This item offers exactly
    /// one file: the PDF somebody uploaded.
    func testAnArchiveGeneratedPackageIsNotOfferedAsAnUpload() throws {
        let files = try item(scannedMagazineItem).readableFiles
        XCTAssertEqual(files.map(\.name), ["1986_09_BYTE_11-09.pdf"])
        XCTAssertEqual(files.first?.bytes, 330_720_249)
        // And it is the upload, whatever the archive calls its format.
        XCTAssertTrue(files.first?.isOriginal == true)
        XCTAssertEqual(files.first?.detail, "as uploaded")
    }

    /// The size beside a file is measured; the words beside it must not
    /// contradict it.
    ///
    /// "searchable text, smaller" was true of most items and wrong by two
    /// orders of magnitude on the first one anybody tried: 330 MB described as
    /// smaller than a 1 MB package. Nothing here guesses at a size any more.
    func testNoFileClaimsASizeItDoesNotHave() throws {
        for fixture in [comicBookItem, scannedPDFItem, scannedMagazineItem] {
            for file in try item(fixture).readableFiles {
                XCTAssertFalse(file.detail.contains("small"), "\(file.name): \(file.detail)")
                XCTAssertFalse(file.detail.contains("larg"), "\(file.name): \(file.detail)")
            }
        }
        // What it says instead, on the item that has one of each.
        let both = try item(scannedPDFItem).readableFiles
        XCTAssertEqual(both.map(\.detail), ["as uploaded", "searchable text"])
    }

    /// A game's upload is two plain zips, marked `original`, and nothing about
    /// a zip says whether it holds scanned pages or Apple II disk images.
    ///
    /// The item does: `mediatype: software`. Without that check this offered
    /// "ZIP · as uploaded · 13.1 MB", which downloads, unpacks, and yields an
    /// issue with no pages in it.
    func testAnItemThatIsNotSomethingToReadOffersNothing() throws {
        let game = """
        {"metadata": {"identifier": "wozaday_In_Search_of_the_Most_Amazing_Thing",
                      "title": "In Search of the Most Amazing Thing",
                      "mediatype": "software"},
         "files": [
           {"name": "In Search of the Most Amazing Thing.zip", "format": "ZIP",
            "size": "127483", "source": "original"},
           {"name": "In Search of the Most Amazing Thing extras.zip", "format": "ZIP",
            "size": "13766958", "source": "original"},
           {"name": "00playable.woz", "format": "Unknown", "size": "234804",
            "source": "original"}]}
        """.data(using: .utf8)!
        XCTAssertTrue(try item(game).readableFiles.isEmpty)

        // Same file list, same everything, filed as a magazine: readable. The
        // mediatype is the only thing that differs, which is the point.
        let asTexts = String(data: game, encoding: .utf8)!
            .replacingOccurrences(of: "\"mediatype\": \"software\"",
                                  with: "\"mediatype\": \"texts\"")
        XCTAssertEqual(try item(asTexts.data(using: .utf8)!).readableFiles.count, 2)
    }

    /// Every kind that is never a scanned issue, refused whatever it holds.
    func testRecordingsAndFilmsAreRefusedWhateverTheyHold() throws {
        for kind in ["audio", "movies", "etree", "software"] {
            let json = """
            {"metadata": {"identifier": "x", "title": "X", "mediatype": "\(kind)"},
             "files": [{"name": "x.cbz", "format": "Comic Book ZIP", "size": "900",
                        "source": "original"}]}
            """.data(using: .utf8)!
            XCTAssertTrue(try item(json).readableFiles.isEmpty, kind)
        }
        // And the kinds people really do file scans under are left alone: the
        // mediatype is a menu choice on an upload form, not a fact.
        for kind in ["texts", "image", "data"] {
            let json = """
            {"metadata": {"identifier": "x", "title": "X", "mediatype": "\(kind)"},
             "files": [{"name": "x.cbz", "format": "Comic Book ZIP", "size": "900",
                        "source": "original"}]}
            """.data(using: .utf8)!
            XCTAssertEqual(try item(json).readableFiles.count, 1, kind)
        }
    }

    /// A format the archive invents next year is refused until somebody looks
    /// at it, rather than being let through by its extension.
    func testAnUnknownDerivativeIsRefused() {
        let invented = ArchiveOrgItem.File(name: "Something_newthing.zip",
                                           format: "Newfangled ZIP",
                                           bytes: 5_000_000, source: .derivative)
        XCTAssertNil(ArchiveOrgItem.kind(of: invented))
        // While the same file as an upload is judged on what it is.
        let uploaded = ArchiveOrgItem.File(name: "Something.zip", format: "ZIP",
                                           bytes: 5_000_000, source: .original)
        XCTAssertEqual(ArchiveOrgItem.kind(of: uploaded), .container)
    }

    /// The one that greys out Import. An item of one PNG is a cover somebody
    /// uploaded on its own, and there is nothing here to read.
    func testAnItemWithNothingReadableOffersNothing() throws {
        XCTAssertTrue(try item(singleImageItem).readableFiles.isEmpty)
        XCTAssertEqual(try item(singleImageItem).mediatype, "image")
    }

    /// A file the upload lost is not a file.
    func testAZeroByteFileIsNotOffered() {
        XCTAssertNil(ArchiveOrgItem.kind(
            of: ArchiveOrgItem.File(name: "empty.cbz", format: "Comic Book ZIP", bytes: 0)))
    }

    // MARK: - One item, several issues

    /// Two formats of one issue, against two issues in one item — the same
    /// "several readable files", and an extension cannot tell them apart.
    /// The filename can: one stem is one issue.
    func testFormatsOfOneIssueAreNotMistakenForSeveralIssues() throws {
        // A CBR and the PDF derived from it: one issue, two ways to read it.
        let comic = try item(comicBookItem).readableIssues
        XCTAssertEqual(comic.count, 1)
        XCTAssertEqual(comic.first?.files.count, 2)
        XCTAssertEqual(comic.first?.stem, "Zagor 137 Dharma la strega (Daim Press 1976-12)")

        // Two PDFs one letter of case apart — still one issue.
        XCTAssertEqual(try item(scannedPDFItem).readableIssues.count, 1)

        // And a run of a magazine: three issues, one file each.
        let pack = try item(packItem).readableIssues
        XCTAssertEqual(pack.count, 3)
        XCTAssertEqual(pack.map(\.files.count), [1, 1, 1])
        XCTAssertEqual(pack.map(\.best.bytes), [15_659_468, 14_518_557, 16_014_940])
    }

    /// The bug this was all for: importing two issues of a pack used to write
    /// one row twice, the second replacing the first.
    func testEachIssueOfAPackIsItsOwnShelfEntry() throws {
        let store = try Store()
        let pack = try item(packItem)
        let issues = pack.readableIssues

        for issue in issues { try store.importArchiveItem(pack, file: issue.best) }

        let rows = try store.recent(sites: [.archive])
        XCTAssertEqual(rows.count, 3, "three issues, three rows")
        XCTAssertEqual(Set(rows.compactMap(\.code)).count, 3, "and three distinct keys")
        // Each points at its own file, not at whichever was imported last.
        for row in rows {
            let mirrors = try store.mirrors(forIssue: row.id)
            XCTAssertEqual(mirrors.count, 1)
            XCTAssertTrue(mirrors[0].url.contains(row.title?.replacingOccurrences(
                of: " ", with: "_") ?? "!"), "\(row.title ?? "") -> \(mirrors[0].url)")
        }

        // Re-importing one of them is still an edit of that one.
        try store.importArchiveItem(pack, file: issues[0].best)
        XCTAssertEqual(try store.recent(sites: [.archive]).count, 3)
    }

    /// A pack's issues are all called "Transactor For The Amiga" by the item,
    /// so the filename is the only thing that tells them apart — and it is
    /// what names them on the shelf.
    func testAPacksIssuesAreNamedByTheirFile() throws {
        let store = try Store()
        let pack = try item(packItem)
        let issue = pack.readableIssues[1]
        let done = try store.importArchiveItem(pack, file: issue.best)

        XCTAssertEqual(done.title, "Transactor for the Amiga Vol 01 02 1988 Jun")
        // The picker says the magazine once in its heading, so the rows drop
        // the part it already said.
        XCTAssertEqual(pack.shortName(for: issue), "Vol 01 02 1988 Jun")
        // And it is findable by the item's name as well as its own.
        XCTAssertEqual(try store.search("transactor", sites: [.archive]).count, 1)
        XCTAssertEqual(try store.search("1988 jun", sites: [.archive]).first?.id, done.issueID)
    }

    /// An item that holds one issue keeps the identifier as its key, so a
    /// reader who browses to a shipped item still finds the copy they have.
    func testASingleIssueItemIsStillKeyedOnItsIdentifier() throws {
        let single = try item(comicBookItem)
        let issue = single.readableIssues[0]
        XCTAssertEqual(single.code(for: issue), "zagor-137-dharma-la-strega-daim-press-1976-12")

        let pack = try item(packItem)
        XCTAssertEqual(pack.code(for: pack.readableIssues[0]),
                       "transactor-for-the-amiga/Transactor_for_the_Amiga_Vol_01_01_1988_Apr[ocr]")
    }

    // MARK: - Covers

    /// The item's own first page, which the archive serves out of the same
    /// derivatives it makes its reader from — so an item that has them gets a
    /// real cover, and one that does not falls back to its square tile rather
    /// than to a URL that 404s.
    func testTheCoverIsTheFirstPageWhereTheArchiveCanRenderOne() throws {
        let comic = try item(comicBookItem)
        XCTAssertEqual(comic.coverPath(for: comic.readableIssues[0]),
                       "zagor-137-dharma-la-strega-daim-press-1976-12/page/n0_w1024.jpg")

        let bare = ArchiveOrgItem(
            identifier: "plain-upload", title: "Plain Upload", year: nil, month: nil,
            files: [.init(name: "Plain Upload.cbz", format: "Comic Book ZIP", bytes: 1000),
                    .init(name: "__ia_thumb.jpg", format: "Item Tile", bytes: 100)])
        XCTAssertEqual(bare.coverPath(for: bare.readableIssues[0]),
                       "plain-upload/__ia_thumb.jpg")

        let nothing = ArchiveOrgItem(
            identifier: "no-art", title: "No Art", year: nil, month: nil,
            files: [.init(name: "No Art.cbz", format: "Comic Book ZIP", bytes: 1000)])
        XCTAssertNil(nothing.coverPath(for: nothing.readableIssues[0]))
    }

    /// On a pack the archive scanned the first volume and left the rest as
    /// plain PDFs, so the item answers `/page/n0` with volume one's cover —
    /// the right cover for exactly one of the thirteen.
    ///
    /// The others get none rather than a copy of it: the item's square tile is
    /// the item's, and a shelf of identical wrong covers is worse than a shelf
    /// of placeholders that fill themselves in on download.
    func testOnlyTheScannedIssueOfAPackTakesTheItemsCover() throws {
        let pack = try item(packItem)
        let issues = pack.readableIssues
        XCTAssertEqual(pack.coverPath(for: issues[0]),
                       "transactor-for-the-amiga/page/n0_w1024.jpg")
        XCTAssertNil(pack.coverPath(for: issues[1]))
        XCTAssertNil(pack.coverPath(for: issues[2]))
    }

    /// The archive's reader says which file it has open, so the app can import
    /// what is on screen instead of asking again which of thirteen it was.
    func testTheAddressNamesTheOpenFileOfAPack() {
        let url = URL(string: "https://archive.org/details/transactor-for-the-amiga/"
                      + "Transactor_for_the_Amiga_Vol_01_01_1988_Apr%5Bocr%5D/")!
        XCTAssertEqual(ArchiveOrg.identifier(inURL: url), "transactor-for-the-amiga")
        XCTAssertEqual(ArchiveOrg.fileStem(inURL: url),
                       "Transactor_for_the_Amiga_Vol_01_01_1988_Apr[ocr]")

        // A place in the book is not a file in the item.
        let reading = URL(string: "https://archive.org/details/amiga-bilten-1/page/n4/mode/2up")!
        XCTAssertEqual(ArchiveOrg.identifier(inURL: reading), "amiga-bilten-1")
        XCTAssertNil(ArchiveOrg.fileStem(inURL: reading))
        // Nor is an item page with nothing after it.
        XCTAssertNil(ArchiveOrg.fileStem(
            inURL: URL(string: "https://archive.org/details/amiga-bilten-1")!))
    }

    // MARK: - Metadata that arrives in whatever shape

    /// Items browsed to were filled in by whoever uploaded them, and a strict
    /// decoder loses a whole item over one field in an unexpected shape.
    func testWonkyMetadataStillDecodes() throws {
        let awkward = """
        {"metadata": {"identifier": "odd-one", "title": ["First", "Second"],
                      "subject": "one tag", "date": ["1979-04"]},
         "files": [{"name": "a.cbz", "format": "Comic Book ZIP", "size": "10"}]}
        """.data(using: .utf8)!
        let decoded = try item(awkward)
        XCTAssertEqual(decoded.title, "First")
        XCTAssertEqual(decoded.subjects, ["one tag"])
        XCTAssertEqual(decoded.year, 1979)

        // No title at all: the identifier is the only name it has, and an
        // empty one would fold to an empty search key and be unfindable.
        let untitled = """
        {"metadata": {"identifier": "no-title-at-all"}, "files": []}
        """.data(using: .utf8)!
        XCTAssertEqual(try item(untitled).title, "no-title-at-all")
    }

    // MARK: - Asking the archive

    private func client(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse)
        -> ArchiveOrgClient {
        ArchiveOrgClient(transport: StubTransport(handler))
    }

    func testTheClientAsksTheMetadataAPI() async throws {
        let body = comicBookItem
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: body) }
        let fetched = try await ArchiveOrgClient(transport: transport)
            .item("zagor-137-dharma-la-strega-daim-press-1976-12")
        XCTAssertEqual(fetched?.identifier, "zagor-137-dharma-la-strega-daim-press-1976-12")
        XCTAssertEqual(transport.requests.first?.url.absoluteString,
                       "https://archive.org/metadata/zagor-137-dharma-la-strega-daim-press-1976-12")
        // The body has to actually be read, which a probe-shaped request does
        // not do.
        XCTAssertGreaterThan(transport.requests.first?.maxBodyBytes ?? 0, 0)
    }

    /// A missing identifier is answered with `{}` and HTTP 200, so "no
    /// metadata object" is the only way to be told an item does not exist.
    func testAnItemThatDoesNotExistIsNilRatherThanAnError() async throws {
        let empty = try await client { _ in
            HTTPResponse(status: 200, body: "{}".data(using: .utf8)!)
        }.item("nothing-here")
        XCTAssertNil(empty)
    }

    /// A 404 is the archive's final word and is reported; a 500 is the archive
    /// having a moment, which it does often enough that `archive-build` already
    /// allows for it.
    func testA404IsReportedAndA500IsRetried() async throws {
        do {
            _ = try await client { _ in HTTPResponse(status: 404) }.item("gone")
            XCTFail("a 404 should be reported")
        } catch let error as TransportError {
            XCTAssertEqual(error.description, "HTTP 404")
        }

        let attempts = Counter()
        let body = comicBookItem
        let flaky = StubTransport { _ in
            attempts.increment() == 1
                ? HTTPResponse(status: 503)
                : HTTPResponse(status: 200, body: body)
        }
        let recovered = try await ArchiveOrgClient(transport: flaky).item("zagor")
        XCTAssertNotNil(recovered)
        XCTAssertEqual(attempts.value, 2)
    }

    /// Counts calls from the transport's own thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        @discardableResult func increment() -> Int {
            lock.lock(); defer { lock.unlock() }; count += 1; return count
        }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    // MARK: - What lands in the library

    private func imported(_ data: Data, pick: Int = 0) throws -> (Store, ArchiveOrgItem, Int) {
        let store = try Store()
        let source = try item(data)
        let done = try store.importArchiveItem(source, file: source.readableFiles[pick])
        return (store, source, done.issueID)
    }

    /// One row, one file, and "Archive.org" in the column the reader filters
    /// on — which is the whole of what an imported item can honestly claim.
    func testAnImportedItemLandsAsOneIssueWithOneFile() throws {
        let (store, item, id) = try imported(comicBookItem)
        let row = try XCTUnwrap(try store.recent(sites: [.archive]).first)
        XCTAssertEqual(row.id, id)
        XCTAssertEqual(row.site, .archive)
        XCTAssertEqual(row.code, item.identifier)
        XCTAssertEqual(row.publisher, "Archive.org")
        XCTAssertFalse(row.isDownloaded, "importing downloads nothing")
        // No series and no hero: an archive.org identifier is whatever its
        // uploader typed, and a wrong series is a row in the filter menu that
        // nobody can correct.
        XCTAssertNil(row.series)
        XCTAssertNil(row.hero)
        XCTAssertNil(row.edition)

        // Spaces escaped, brackets left alone: they are legal in a path, and
        // the address above is the one the archive answers 200 to.
        let mirrors = try store.mirrors(forIssue: id)
        XCTAssertEqual(mirrors.count, 1)
        XCTAssertEqual(mirrors.first?.url,
                       "https://archive.org/download/"
                       + "zagor-137-dharma-la-strega-daim-press-1976-12/"
                       + "Zagor%20137%20Dharma%20la%20strega%20(Daim%20Press%201976-12).cbr")
        XCTAssertEqual(mirrors.first?.host, "archive.org")
        XCTAssertNotNil(URL(string: mirrors.first?.url ?? ""), "and it survives URL(string:)")
        // The name the file lands under on disk, with the escaping undone.
        XCTAssertEqual(try store.filename(forMirrorAt: mirrors.first?.url ?? ""),
                       "Zagor 137 Dharma la strega (Daim Press 1976-12).cbr")
        // The size the archive states, which is what lets a download too large
        // for the device be refused before a byte of it moves.
        XCTAssertEqual(try store.knownSize(forIssue: id), 38_194_644)
    }

    /// The title archive.org generates is the uploaded filename with its
    /// spacing mangled. `TitleCleaner` was written against exactly that shape.
    func testTheShelfTitleIsCleanedUpAndNumbered() throws {
        let (store, _, id) = try imported(comicBookItem)
        let row = try XCTUnwrap(try store.recent(sites: [.archive]).first { $0.id == id })
        XCTAssertEqual(row.title, "Dharma La Strega")
        XCTAssertEqual(row.number, 137)

        // And an item it cannot read keeps its title untouched rather than
        // being mangled by a guess.
        let plain = ArchiveOrgItem(
            identifier: "some-fanzine", title: "Some Fanzine", year: nil, month: nil,
            files: [.init(name: "a.cbz", format: "Comic Book ZIP", bytes: 10)])
        XCTAssertEqual(Store.archiveLabel(for: plain.title).title, "Some Fanzine")
        XCTAssertNil(Store.archiveLabel(for: plain.title).number)
    }

    /// Cleaning a title throws words away, so everything the item said about
    /// itself goes into the search index instead — the archive.org title, the
    /// identifier and the uploader's tags.
    func testItIsFoundByEverythingTheItemSaidAboutItself() throws {
        let (store, _, id) = try imported(comicBookItem)
        for query in [
            "dharma",           // the cleaned title, which is what the shelf shows
            "daim press",       // only in the archive.org title it was cut from
            "zagor 137",        // likewise: the hero and number, before cleaning
            "strega",           // and in the identifier
            "archive.org",      // the source, so the whole lot is findable at once
        ] {
            XCTAssertEqual(try store.search(query, sites: [.archive]).first?.id, id, query)
        }
    }

    /// Re-importing the same item is an edit, never a second row — which is
    /// what lets the browser offer to change the file an issue points at.
    func testReimportingSwapsTheFileRatherThanAddingAnother() throws {
        let (store, item, id) = try imported(comicBookItem)
        let cbr = try store.mirrors(forIssue: id).first?.url

        let same = try store.importArchiveItem(item, file: item.readableFiles[0])
        XCTAssertEqual(same.issueID, id)
        XCTAssertTrue(same.existed)
        XCTAssertFalse(same.fileChanged, "the same file again changes nothing")

        let swapped = try store.importArchiveItem(item, file: item.readableFiles[1])
        XCTAssertEqual(swapped.issueID, id, "still one issue")
        XCTAssertTrue(swapped.fileChanged)
        XCTAssertEqual(store.issueCount, 1)

        // One file per issue: two mirrors under one issue mean alternates to
        // fall back through, or halves of a split archive, and two formats of
        // one scan are neither.
        let mirrors = try store.mirrors(forIssue: id)
        XCTAssertEqual(mirrors.count, 1)
        XCTAssertNotEqual(mirrors.first?.url, cbr)
        XCTAssertTrue(mirrors.first?.url.hasSuffix(".pdf") == true)
        XCTAssertEqual(try store.knownSize(forIssue: id), 8_224_620)
    }

    /// What the reader has done with an issue survives changing which file it
    /// downloads. A swapped format must not mark a half-read magazine unread.
    func testReimportingLeavesTheReaderTheirPlace() throws {
        let (store, item, id) = try imported(comicBookItem)
        try store.setLastPage(42, issueID: id)
        try store.setRead(true, issueID: id)

        _ = try store.importArchiveItem(item, file: item.readableFiles[1])

        let row = try XCTUnwrap(try store.recent(sites: [.archive]).first { $0.id == id })
        XCTAssertTrue(row.isRead)
        // setRead clears the place by design; what matters here is that the
        // re-import did not disturb the state it left.
        XCTAssertEqual(row.readState, .read)
    }

    /// A reader can browse to A-Profy, which the app already ships a
    /// catalogue for. That is the same item, so it is the same row — and the
    /// catalogue's own title, "Septembar 1988", is a better shelf entry than
    /// the item's "Amiga Bilten 1", so importing must not overwrite it.
    func testBrowsingToAShippedItemDoesNotUndoItsCatalogueEntry() throws {
        let store = try Store()
        let url = try XCTUnwrap(Bundle.module.url(forResource: "archive-catalog",
                                                  withExtension: "json"))
        try store.seed(try ShippedCatalog.decode(try Data(contentsOf: url)), site: .archive)
        let before = try XCTUnwrap(try store.recent(sites: [.archive])
            .first { $0.code == "amiga-bilten-1" })

        let browsed = ArchiveOrgItem(
            identifier: "amiga-bilten-1", title: "Amiga Bilten 1",
            year: 1988, month: 9,
            files: [.init(name: "Amiga Bilten 1.pdf",
                          format: "Image Container PDF", bytes: 7_174_738)])
        let done = try store.importArchiveItem(browsed, file: browsed.readableFiles[0])

        XCTAssertEqual(done.issueID, before.id, "the same item is the same row")
        let after = try XCTUnwrap(try store.recent(sites: [.archive])
            .first { $0.id == before.id })
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.series, before.series)
        XCTAssertEqual(after.pageCount, before.pageCount)
    }
}

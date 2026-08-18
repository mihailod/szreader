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
         "format": "Comic Book RAR", "size": "38194644"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12).epub",
         "format": "EPUB", "size": "65685066"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12).pdf",
         "format": "Text PDF", "size": "8224620"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_djvu.txt",
         "format": "DjVuTXT", "size": "35188"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_hocr.html",
         "format": "hOCR", "size": "1332643"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_jp2.zip",
         "format": "Single Page Processed JP2 ZIP", "size": "63921139"},
        {"name": "Zagor 137 Dharma la strega (Daim Press 1976-12)_scandata.xml",
         "format": "Scandata", "size": "32229"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "26795"},
        {"name": "zagor-137-dharma-la-strega-daim-press-1976-12_archive.torrent",
         "format": "Archive BitTorrent", "size": "11313"},
        {"name": "zagor-137-dharma-la-strega-daim-press-1976-12_files.xml",
         "format": "Metadata"}
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
         "format": "Image Container PDF", "size": "263568337"},
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA.pdf",
         "format": "Text PDF", "size": "23295680"},
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA_jp2.zip",
         "format": "Single Page Processed JP2 ZIP", "size": "193200889"},
        {"name": "VC OP - Zagor - 007 - POVRATAK VAMPIRA_page_numbers.json",
         "format": "Page Numbers JSON", "size": "50656"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "29877"},
        {"name": "vc-op-zagor-007-povratak-vampira_archive.torrent",
         "format": "Archive BitTorrent", "size": "22696"}
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
         "size": "5071563"},
        {"name": "VC - LMS na Bis - 003 - Teks Viler_thumb.jpg",
         "format": "JPEG Thumb", "size": "14285"},
        {"name": "__ia_thumb.jpg", "format": "Item Tile", "size": "28168"},
        {"name": "vc-lms-na-bis-003-teks-viler-indijanski-agent_archive.torrent",
         "format": "Archive BitTorrent", "size": "2803"}
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

    // MARK: - Covers

    /// The item's own first page, which the archive serves out of the same
    /// derivatives it makes its reader from — so an item that has them gets a
    /// real cover, and one that does not falls back to its square tile rather
    /// than to a URL that 404s.
    func testTheCoverIsTheFirstPageWhereTheArchiveCanRenderOne() throws {
        XCTAssertEqual(try item(comicBookItem).coverPath,
                       "zagor-137-dharma-la-strega-daim-press-1976-12/page/n0_w1024.jpg")

        let bare = ArchiveOrgItem(
            identifier: "plain-upload", title: "Plain Upload", year: nil, month: nil,
            files: [.init(name: "Plain Upload.cbz", format: "Comic Book ZIP", bytes: 1000),
                    .init(name: "__ia_thumb.jpg", format: "Item Tile", bytes: 100)])
        XCTAssertEqual(bare.coverPath, "plain-upload/__ia_thumb.jpg")

        let nothing = ArchiveOrgItem(
            identifier: "no-art", title: "No Art", year: nil, month: nil,
            files: [.init(name: "No Art.cbz", format: "Comic Book ZIP", bytes: 1000)])
        XCTAssertNil(nothing.coverPath)
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

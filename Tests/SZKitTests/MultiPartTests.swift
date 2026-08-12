import XCTest
@testable import SZKit

/// Archives split across two downloads.
final class MultiPartDetectionTests: XCTestCase {

    private let one = "LMS_VB_001_Djil_-_Marti_Misterija__rescan___ex-YU_.part1.rar"
    private let two = "LMS_VB_001_Djil_-_Marti_Misterija__rescan___ex-YU_.part2.rar"

    func testVolumeNumberIsRead() {
        XCTAssertEqual(MultiPartArchive.partNumber(in: one), 1)
        XCTAssertEqual(MultiPartArchive.partNumber(in: two), 2)
        XCTAssertEqual(MultiPartArchive.partNumber(in: "x.PART10.RAR"), 10)
    }

    /// What the host actually reports, which is the only name available before
    /// downloading: MediaFire answers "….part1" for a file that lands as
    /// "….part1.rar".
    func testExtensionIsOptional() {
        let reported = "LMS_VB_001_Djil_-_Marti_Misterija__rescan___ex-YU_.part1"
        XCTAssertEqual(MultiPartArchive.partNumber(in: reported), 1)

        let pair = MultiPartArchive.parts([
            (source: "a", filename: "LMS_VB_001.part1"),
            (source: "b", filename: "LMS_VB_001.part2"),
        ])
        XCTAssertEqual(pair?.map(\.part), [1, 2])
    }

    /// A set reported one way and one the other must still group.
    func testMixedReportingStillGroups() {
        let pair = MultiPartArchive.parts([
            (source: "a", filename: "LMS_VB_001.part1"),
            (source: "b", filename: "LMS_VB_001.part2.rar"),
        ])
        XCTAssertEqual(pair?.map(\.part), [1, 2])
    }

    /// An ordinary archive declares no volume, and must not be mistaken for
    /// one — that would turn a working single download into a failed set.
    func testWholeArchivesDeclareNoVolume() {
        XCTAssertNil(MultiPartArchive.partNumber(in: "Mister No 511.cbr"))
        XCTAssertNil(MultiPartArchive.partNumber(in: "comic.rar"))
        XCTAssertNil(MultiPartArchive.partNumber(in: "01 Takav je bio Alan Skot.cbz"))
        // "part" in the title itself is not a volume marker.
        XCTAssertNil(MultiPartArchive.partNumber(in: "Second part of the story.cbr"))
    }

    /// All three conventions appear on one page, so all three have to work.
    func testEveryConventionOnTheMartinMysterePage() {
        let sets = [
            ["LMS_VB_001_MickRC_BUCKO-BDS_.part1", "LMS_VB_001_MickRC_BUCKO-BDS_.part2"],
            ["MM_004_-_Prokleto_Pleme_1_deo.7z", "MM_004_-_Prokleto_Pleme_2_deo.7z"],
            ["MM_015_Kula_Artura__madwolf-SZ__part_1",
             "MM_015_Kula_Artura__madwolf-SZ__part_2"],
            ["MM_016_Tajna_Stounehenga.part1.rar", "MM_016_Tajna_Stounehenga.part2.rar"],
        ]
        for names in sets {
            let parts = MultiPartArchive.parts(names.map { (source: $0, filename: $0) })
            XCTAssertEqual(parts?.map(\.part), [1, 2], "not recognised: \(names)")
        }
    }

    /// The two on that page that are genuinely alternatives must stay that
    /// way — downloading both would waste a transfer, and pairing them as
    /// volumes would produce an archive that cannot open.
    func testRealAlternativesAreNotSplit() {
        XCTAssertNil(MultiPartArchive.parts([
            (source: "a", filename: "MM_LMS_025a"),
            (source: "b", filename: "MM_LMS_025b"),
            (source: "c", filename: "Povratak iz mrtvih (rescan)"),
        ]))
        XCTAssertNil(MultiPartArchive.parts([
            (source: "a", filename: "MM_030_papaya_i_bora81__SF_i_SZ_"),
            (source: "b", filename: "MM_030 (papaya&markoboss SF)"),
        ]))
    }

    func testPiecesAreGroupedInOrder() {
        let parts = MultiPartArchive.parts([(source: "b", filename: two),
                                            (source: "a", filename: one)])
        XCTAssertEqual(parts?.map(\.part), [1, 2])
        XCTAssertEqual(parts?.map(\.source), ["a", "b"])
    }

    /// Two links to the same comic under different names are alternatives, not
    /// pieces. Treating them as pieces would download both for nothing.
    func testAlternativeMirrorsAreNotPieces() {
        XCTAssertNil(MultiPartArchive.parts([
            (source: "a", filename: "Marti Misterija 001.cbr"),
            (source: "b", filename: "MM_001_alternative_scan.cbr"),
        ]))
    }

    /// A lone volume one is not a set: something is missing, and guessing that
    /// a second exists would fail every time.
    func testSingleVolumeIsNotASet() {
        XCTAssertNil(MultiPartArchive.parts([(source: "a", filename: one)]))
    }

    /// Two files claiming the same volume cannot be one archive.
    func testRepeatedVolumeIsRejected() {
        XCTAssertNil(MultiPartArchive.parts([(source: "a", filename: one),
                                             (source: "b", filename: one)]))
    }

    /// Pieces of different archives must not be joined.
    func testDifferentStemsDoNotGroup() {
        XCTAssertNil(MultiPartArchive.parts([
            (source: "a", filename: "Marti_001.part1.rar"),
            (source: "b", filename: "Marti_002.part2.rar"),
        ]))
    }

    func testStemDropsTheVolumeMarker() {
        XCTAssertEqual(MultiPartArchive.stem(of: one), MultiPartArchive.stem(of: two))
        XCTAssertFalse(MultiPartArchive.stem(of: one).contains("part"))
    }
}

/// Downloading every volume of a split archive.
final class MultiPartDownloadTests: XCTestCase {

    /// Serves a distinct body per URL, so the two volumes are distinguishable
    /// on disk.
    private struct VolumeDownloader: FileDownloader {
        func download(_ link: DirectLink, to destination: URL,
                      progress: (@Sendable (DownloadProgress) -> Void)?,
                      check: (@Sendable (Int64) throws -> Void)?) async throws {
            let rar = Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x00])
            let tail = Data(link.url.absoluteString.utf8)
            try check?(Int64(rar.count + tail.count))
            try (rar + tail).write(to: destination)
            progress?(DownloadProgress(received: 1, expected: 1))
        }
    }

    private struct DirectHost: FileHost {
        let name = "test"
        func canHandle(_ url: URL) -> Bool { true }
        func probe(_ url: URL, via transport: Transport) async throws -> FileMeta {
            FileMeta(filename: url.lastPathComponent)
        }
        func directLink(_ url: URL, via transport: Transport) async throws -> DirectLink {
            DirectLink(url: url)
        }
    }

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func fixture() throws -> (Library, Store, Int) {
        let store = try Store()
        try store.ingest(html: """
            <div>001-Marti Misterija</div>
            <div>http://www.mediafire.com/comic.part1.rar</div>
            <div>http://www.mediafire.com/comic.part2.rar</div>
            """)
        let issue = try XCTUnwrap(try store.recent().first)
        let library = Library(store: store, paths: LibraryPaths(root: root),
                              transport: StubTransport { _ in HTTPResponse(status: 200) },
                              downloader: VolumeDownloader(),
                              registry: HostRegistry(hosts: [DirectHost()]),
                              availableSpace: { 10_000_000_000 })
        return (library, store, issue.id)
    }

    /// Both volumes land in one directory under their real names — the only
    /// arrangement unrar will join.
    func testBothVolumesAreDownloaded() async throws {
        let (library, _, issueID) = try fixture()
        let outcome = try await library.fetch(issueID: issueID)

        let directory = outcome.path.deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains("comic.part1.rar"), "\(files)")
        XCTAssertTrue(files.contains("comic.part2.rar"), "\(files)")
    }

    /// The reader opens volume one, so that is what gets recorded.
    func testTheFirstVolumeIsWhatIsRecorded() async throws {
        let (library, store, issueID) = try fixture()
        _ = try await library.fetch(issueID: issueID)

        let recorded = try XCTUnwrap(store.downloadedFile(issueID: issueID))
        XCTAssertEqual(recorded.path.lastPathComponent, "comic.part1.rar")
        XCTAssertTrue(try XCTUnwrap(store.recent().first).isDownloaded)
    }

    /// Volume two is a fragment. Judged on its own it is not an archive, and
    /// insisting it be one would fail every split download.
    func testLaterVolumesAreNotJudgedAsWholeArchives() async throws {
        let (library, _, issueID) = try fixture()
        do {
            _ = try await library.fetch(issueID: issueID)
        } catch {
            XCTFail("a split download was rejected: \(error)")
        }
    }
}

/// Gigant 01 and 02, whose two links are halves of one archive.
///
/// The filenames were read from the live mirrors. Splitting the issue in two
/// left each half as a lone mirror of its own comic, and a single mirror is
/// never examined for parts — so the app downloaded half an archive and could
/// not open it. The names themselves were always sufficient.
final class GigantSplitTests: XCTestCase {

    private let names = [
        "Gigant 01 (rescan)(Mikos & folpi).part1",
        "Gigant 01 (rescan)(Mikos & folpi).part2",
    ]

    func testHalvesAreRecognisedAsOneArchive() throws {
        let parts = try XCTUnwrap(MultiPartArchive.parts(
            names.map { (source: $0, filename: $0) }))
        XCTAssertEqual(parts.map(\.part), [1, 2])
        XCTAssertEqual(parts.first?.filename, names[0])
    }

    /// No extension, and the credits carry a bracketed group before the part
    /// marker — neither may stop the stem from matching.
    func testBothHalvesShareAStem() {
        XCTAssertEqual(MultiPartArchive.stem(of: names[0]),
                       MultiPartArchive.stem(of: names[1]))
        XCTAssertEqual(MultiPartArchive.partNumber(in: names[1]), 2)
    }

    /// The other Gigant issues are single files and must not look split.
    func testASingleFileIsNotASplitArchive() {
        XCTAssertNil(MultiPartArchive.parts([
            (source: "a", filename: "Gigant 03 (rescan)(Mikos & folpi)"),
        ]))
    }
}

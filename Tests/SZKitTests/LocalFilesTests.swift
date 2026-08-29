import XCTest
@testable import SZKit

/// The folder the reader fills themselves.
///
/// Every other source is a page or a catalogue the app reads and turns into
/// rows. This one is a directory that changes while the app is not running,
/// so what is tested here is the reconciliation: the shelf has to agree with
/// the folder after a drag in, after a delete in the Finder, and after the
/// same name comes back holding different bytes.
final class LocalFilesTests: XCTestCase {

    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    @discardableResult
    private func write(_ name: String, bytes: Int = 8) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    // MARK: - Where an arriving file came from

    /// The bug this whole function exists for.
    ///
    /// iOS names the container two ways — `FileManager` says "/var/mobile/…"
    /// and the URL handed over by AirDrop or the share sheet says
    /// "/private/var/mobile/…" — and `/var` is a symlink to `/private/var`.
    /// A `hasPrefix` on those two strings is false for every file it is asked
    /// about, so every Inbox delivery was copied instead of moved and the
    /// original stayed in a folder nothing empties.
    ///
    /// Reproduced here with a symlink of the test's own, because the real
    /// pair only exists on the device.
    func testInboxIsRecognisedThroughASymlink() throws {
        let fm = FileManager.default
        let inbox = folder.appendingPathComponent("Inbox", isDirectory: true)
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let file = inbox.appendingPathComponent("Zagor 137.cbr")
        try Data([0x41]).write(to: file)

        // The same folder reached by another name, as the device reaches it.
        let alias = fm.temporaryDirectory
            .appendingPathComponent("alias-\(UUID().uuidString)")
        try fm.createSymbolicLink(at: alias, withDestinationURL: folder)
        defer { try? fm.removeItem(at: alias) }
        let viaAlias = alias.appendingPathComponent("Inbox/Zagor 137.cbr")

        XCTAssertTrue(LocalFiles.isInInbox(file, of: folder))
        XCTAssertTrue(LocalFiles.isInInbox(viaAlias, of: folder),
                      "a file reached through a symlink to the folder is still in its Inbox")
    }

    /// A file dragged in over the cable sits in the folder itself, not in the
    /// Inbox, and moving it would be moving it from where it already belongs.
    func testFilesOutsideTheInboxAreNotClaimed() throws {
        let dragged = try write("Alan Ford 1.cbz")
        XCTAssertFalse(LocalFiles.isInInbox(dragged, of: folder))

        // The sibling trap: a prefix test on strings holds "Inbox-old" to be
        // inside "Inbox".
        let fm = FileManager.default
        let decoy = folder.appendingPathComponent("Inbox-old", isDirectory: true)
        try fm.createDirectory(at: decoy, withIntermediateDirectories: true)
        let inDecoy = decoy.appendingPathComponent("Zagor 1.cbr")
        try Data([0x41]).write(to: inDecoy)
        XCTAssertFalse(LocalFiles.isInInbox(inDecoy, of: folder))

        // The Inbox itself is not a file in the Inbox.
        XCTAssertFalse(LocalFiles.isInInbox(folder.appendingPathComponent("Inbox"),
                                            of: folder))
    }

    // MARK: - What counts as an issue

    func testOnlyReadableFilesAreOffered() {
        for name in ["A.cbr", "b.CBZ", "c.cb7", "d.pdf", "e.zip", "f.rar", "g.7z"] {
            XCTAssertTrue(LocalFiles.isReadable(name), "\(name) should be readable")
        }
        for name in ["notes.txt", "cover.jpg", "archive.tar.gz", "no-extension"] {
            XCTAssertFalse(LocalFiles.isReadable(name), "\(name) should be passed over")
        }
    }

    /// The Finder writes `.DS_Store` into the folder the first time it is
    /// opened, and copies from some volumes leave `._name` beside the file.
    /// Neither is the reader's, and a shelf row for one is a row that cannot
    /// be opened and cannot be explained.
    func testDotfilesAreNeverOffered() {
        XCTAssertFalse(LocalFiles.isReadable(".DS_Store"))
        XCTAssertFalse(LocalFiles.isReadable("._029 Brodeckov izvjestaj.cbr"))
    }

    func testScanIsFlatAndSkipsDirectories() throws {
        try write("001 Potocici.cbr")
        try write("notes.txt")
        try write(".DS_Store")
        let nested = folder.appendingPathComponent("More", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([0x41]).write(to: nested.appendingPathComponent("Hidden.cbz"))
        // A folder named like an archive is still a folder.
        let decoy = folder.appendingPathComponent("Set.cbz", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)

        let found = LocalFiles.scan(folder)

        XCTAssertEqual(found.map(\.name), ["001 Potocici.cbr"])
    }

    func testScanReportsTheSizeOnDisk() throws {
        try write("Evropa.cbr", bytes: 4096)
        let file = try XCTUnwrap(LocalFiles.scan(folder).first)
        XCTAssertEqual(file.bytes, 4096)
    }

    /// The reader's own name for a file is the last word on what it is
    /// called. The cleaner is tuned for the scene filenames the forum's
    /// downloads arrive under, and when it cannot make a title of a name the
    /// name itself is still the thing the reader will recognise in the
    /// Finder.
    func testAnUnparseableNameKeepsItsOwnStem() {
        let described = LocalFiles.describe("scan_2019_final.cbz")
        XCTAssertNotNil(described.title)
        XCTAssertFalse(described.title?.isEmpty ?? true)
    }

    func testTheExtensionNeverSurvivesIntoTheTitle() {
        for name in ["001 Potocici.cbr", "Evropa.cbr", "043 Sam Pezzo.cbz",
                     "Bosanske basne.cbr", "x.pdf"] {
            let title = LocalFiles.describe(name).title ?? ""
            XCTAssertFalse(title.lowercased().hasSuffix(".cbr"), "\(name) -> \(title)")
            XCTAssertFalse(title.lowercased().hasSuffix(".cbz"), "\(name) -> \(title)")
            XCTAssertFalse(title.lowercased().hasSuffix(".pdf"), "\(name) -> \(title)")
        }
    }

    /// The same issue AirDropped twice is the ordinary case. Overwriting
    /// would replace a file the reader may be part way through.
    func testAnArrivingDuplicateGetsItsOwnName() throws {
        try write("Evropa.cbr")
        XCTAssertEqual(LocalFiles.vacantName(for: "Evropa.cbr", in: folder), "Evropa 2.cbr")
        try write("Evropa 2.cbr")
        XCTAssertEqual(LocalFiles.vacantName(for: "Evropa.cbr", in: folder), "Evropa 3.cbr")
        XCTAssertEqual(LocalFiles.vacantName(for: "Nova.cbr", in: folder), "Nova.cbr")
    }

    // MARK: - Reconciling

    func testAFileDraggedInBecomesAnIssue() throws {
        let store = try Store()
        try write("029 Brodeckov izvjestaj.cbr", bytes: 1234)

        let report = try store.reconcileLocalFiles(LocalFiles.scan(folder))

        XCTAssertEqual(report.added, 1)
        let issue = try XCTUnwrap(try store.search("brodeckov").first)
        XCTAssertEqual(issue.site, .local)
        XCTAssertTrue(issue.isDownloaded, "the file is on the device already")
        XCTAssertFalse(issue.isCatalogued, "nothing shipped this")
        XCTAssertEqual(try store.downloadedFile(issueID: issue.id)?.bytes, 1234)
    }

    /// The scan runs at every launch and every return to the foreground, so
    /// the second pass over an unchanged folder is the common case by a long
    /// way. It has to be a no-op — a second row for the same file would be a
    /// duplicate the reader cannot explain or get rid of.
    func testASecondScanOfTheSameFolderChangesNothing() throws {
        let store = try Store()
        try write("001 Potocici.cbr")
        try write("Evropa.cbr")
        try store.reconcileLocalFiles(LocalFiles.scan(folder))

        let report = try store.reconcileLocalFiles(LocalFiles.scan(folder))

        XCTAssertTrue(report.isEmpty, "an unchanged folder rewrote the shelf")
        XCTAssertEqual(store.issueCount, 2)
    }

    func testDeletingInTheFinderTakesTheRowWithIt() throws {
        let store = try Store()
        try write("001 Potocici.cbr")
        try write("Evropa.cbr")
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let doomed = try XCTUnwrap(try store.search("potocici").first)

        try FileManager.default.removeItem(at: folder.appendingPathComponent("001 Potocici.cbr"))
        let report = try store.reconcileLocalFiles(LocalFiles.scan(folder))

        XCTAssertEqual(report.removed, [doomed.id])
        XCTAssertEqual(store.issueCount, 1)
        XCTAssertTrue(try store.search("potocici").isEmpty, "the row outlived its file")
    }

    /// Same name, different bytes: the reader replaced the file with a better
    /// scan. The row is theirs and stays, but whatever was unpacked from the
    /// old file is now the wrong issue and the caller is told so.
    func testAReplacedFileKeepsItsRowAndReportsItself() throws {
        let store = try Store()
        try write("Evropa.cbr", bytes: 100)
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let issue = try XCTUnwrap(try store.search("evropa").first)

        try write("Evropa.cbr", bytes: 200)
        let report = try store.reconcileLocalFiles(LocalFiles.scan(folder))

        XCTAssertEqual(report.replaced, [issue.id])
        XCTAssertEqual(report.added, 0)
        XCTAssertTrue(report.removed.isEmpty)
        XCTAssertEqual(try store.downloadedFile(issueID: issue.id)?.bytes, 200)
    }

    /// The container's absolute path changes on reinstall. The row is keyed
    /// on the filename for that reason, and the path is rewritten from the
    /// scan so the file is still found afterwards.
    func testAMovedFolderIsHealedByTheNextScan() throws {
        let store = try Store()
        try write("Evropa.cbr", bytes: 64)
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let issue = try XCTUnwrap(try store.search("evropa").first)

        let moved = folder.deletingLastPathComponent()
            .appendingPathComponent("moved-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        folder = moved
        let report = try store.reconcileLocalFiles(LocalFiles.scan(folder))

        XCTAssertTrue(report.isEmpty, "the same file at a new path was treated as a new issue")
        // Resolved on both sides: the scan reads the directory back through
        // the OS, which hands over "/private/var/…" where the test built
        // "/var/…". The same file, spelled the way the filesystem spells it.
        XCTAssertEqual(try store.downloadedFile(issueID: issue.id)?.path.resolvingSymlinksInPath(),
                       moved.appendingPathComponent("Evropa.cbr").resolvingSymlinksInPath())
    }

    // MARK: - Files still arriving

    /// The folder is watched now, so a scan runs while a copy is in progress
    /// rather than only after one. A 300 MB issue's directory entry appears
    /// at the start of its copy, and the first thing a scan sees of it is a
    /// few megabytes — which as a shelf row is an issue that will not open.
    func testAFileStillBeingWrittenIsNotReadyYet() {
        let now = Date()
        let arriving = LocalFile(name: "Big.cbr", url: folder.appendingPathComponent("Big.cbr"),
                                 bytes: 5_000_000, modified: now)
        let (ready, waiting) = LocalFiles.settled([arriving], against: [:], now: now)
        XCTAssertTrue(ready.isEmpty)
        XCTAssertEqual(waiting.map(\.name), ["Big.cbr"])
    }

    /// Everything already in the folder at launch, whatever it was doing
    /// yesterday. Without this the shelf would come up empty and fill in two
    /// seconds later, on every single launch.
    func testAFileThatHasSatThereIsReadyAtOnce() {
        let now = Date()
        let old = LocalFile(name: "Evropa.cbr", url: folder.appendingPathComponent("Evropa.cbr"),
                            bytes: 1234, modified: now.addingTimeInterval(-3600))
        let (ready, waiting) = LocalFiles.settled([old], against: [:], now: now)
        XCTAssertEqual(ready.map(\.name), ["Evropa.cbr"])
        XCTAssertTrue(waiting.isEmpty)
    }

    /// The copy finishes while the app watches: the size stops moving, and
    /// the scan after that is what puts it on the shelf. Without this half a
    /// rule, a file that arrived seconds ago would wait for its mtime to age
    /// out even though nothing was writing to it any more.
    func testASizeThatStoppedMovingIsReady() {
        let now = Date()
        let done = LocalFile(name: "Big.cbr", url: folder.appendingPathComponent("Big.cbr"),
                             bytes: 300_000_000, modified: now)
        let (ready, _) = LocalFiles.settled([done], against: ["Big.cbr": 300_000_000], now: now)
        XCTAssertEqual(ready.map(\.name), ["Big.cbr"])
    }

    /// A file being copied over one already on the shelf is not a file that
    /// has gone. Computing removals from the settled list alone would delete
    /// the row mid-copy, and with it everything the reader had read.
    func testReplacingAFileInPlaceDoesNotRemoveItsRowMidCopy() throws {
        let store = try Store()
        try write("Evropa.cbr", bytes: 100)
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let issue = try XCTUnwrap(try store.search("evropa").first)

        // The scan that catches it half-written: nothing is ready, but the
        // name is still in the folder.
        let report = try store.reconcileLocalFiles([], present: ["Evropa.cbr"])

        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(store.issueCount, 1)
        XCTAssertNotNil(try store.downloadedFile(issueID: issue.id))
    }

    // MARK: - What the bulk deletes may take

    /// Remove All Downloads reclaims what can be fetched again. Nothing can
    /// fetch these again: they came off a computer over a cable.
    func testRemoveAllDownloadsPassesOverLocalFiles() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let downloaded = try XCTUnwrap(try store.search("nasilje").first)
        try store.recordDownload(issueID: downloaded.id, mirrorURL: "http://x/y",
                                 path: folder.appendingPathComponent("x.cbz"), bytes: 10)
        try write("Evropa.cbr")
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let local = try XCTUnwrap(try store.search("evropa").first)

        let removed = try store.deleteAllDownloads()

        XCTAssertEqual(removed.count, 1, "a local file was reported as a freed download")
        XCTAssertNotNil(try store.downloadedFile(issueID: local.id),
                        "the local file stopped being downloaded")
        XCTAssertNil(try store.downloadedFile(issueID: downloaded.id))
    }

    /// Delete Library empties the library of everything an Import could bring
    /// back. It leaves these, and the app asks about them separately.
    func testDeleteLibraryPassesOverLocalFiles() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        try write("Evropa.cbr")
        try store.reconcileLocalFiles(LocalFiles.scan(folder))

        try store.deleteImported()

        XCTAssertEqual(store.issueCount, 1)
        XCTAssertFalse(try store.search("evropa").isEmpty, "Delete Library took a local file")
        XCTAssertTrue(try store.search("nasilje").isEmpty)
    }

    func testDeletingLocalFilesReportsThemForRemoval() throws {
        let store = try Store()
        let url = try write("Evropa.cbr", bytes: 300)
        try write("001 Potocici.cbr", bytes: 700)
        try store.reconcileLocalFiles(LocalFiles.scan(folder))

        XCTAssertEqual(store.localFileTotals.count, 2)
        XCTAssertEqual(store.localFileTotals.bytes, 1000)

        let files = try store.deleteLocalIssues()

        XCTAssertEqual(files.count, 2)
        XCTAssertTrue(files.map { $0.file.resolvingSymlinksInPath() }
                        .contains(url.resolvingSymlinksInPath()))
        XCTAssertEqual(store.issueCount, 0)
        XCTAssertEqual(store.localFileTotals.count, 0)
    }

    // MARK: - Whose file is it

    /// The one that matters most, and the reason `LibraryPaths.owns` exists.
    ///
    /// Opening a downloaded issue deletes the archive once its pages are out:
    /// the pages are the comic, and the archive is a second copy of it. Run
    /// against a local file that rule deletes the reader's own file out of
    /// the folder they dropped it into — and, because it also sweeps
    /// siblings sharing a stem, potentially the issue next to it as well.
    ///
    /// `ArchiveReclaimTests` is the other half of this pair: it proves the
    /// archive under the comics root really is deleted, which is what stops
    /// this test passing for the wrong reason.
    func testOpeningALocalFileNeverDeletesIt() throws {
        let store = try Store()
        let comics = folder.appendingPathComponent("comics", isDirectory: true)
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)

        // The reader's own folder, which is not under the comics root.
        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let scratch = folder.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let archive = try SevenZipFixture.make(named: "Evropa.cbz", pages: 1...4,
                                               in: scratch, at: documents)

        let paths = LibraryPaths(root: comics)
        let library = Library(store: store, paths: paths,
                              transport: StubTransport { _ in HTTPResponse(status: 404) },
                              downloader: StubDownloader(bodies: [:]))
        try store.reconcileLocalFiles(LocalFiles.scan(documents))
        let issue = try XCTUnwrap(try store.search("evropa").first)

        let document = try library.document(forIssue: issue.id)
        XCTAssertEqual(document.pageCount, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path),
                      "opening a local file deleted it out of the reader's folder")

        // And it still reads on the next open, which is the state the deleted
        // archive would have been standing in for.
        XCTAssertEqual(try library.document(forIssue: issue.id).pageCount, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }


    /// The rule that keeps the unpacker and the shelf's delete off the
    /// reader's own files. Both used to assume every path they held named
    /// something under the comics root.
    func testTheLibraryKnowsWhichFilesAreItsOwn() {
        let paths = LibraryPaths(root: URL(fileURLWithPath: "/var/app/Support/SZReader/comics"))
        XCTAssertTrue(paths.owns(URL(fileURLWithPath:
            "/var/app/Support/SZReader/comics/12/Zagor.cbr")))
        XCTAssertFalse(paths.owns(URL(fileURLWithPath: "/var/app/Documents/Evropa.cbr")))
        // A sibling directory whose name merely starts the same way.
        XCTAssertFalse(paths.owns(URL(fileURLWithPath:
            "/var/app/Support/SZReader/comics-old/12/Zagor.cbr")))
        // The root itself is not something inside the root.
        XCTAssertFalse(paths.owns(URL(fileURLWithPath: "/var/app/Support/SZReader/comics")))
    }

    // MARK: - Telling the reader's own files from the app's

    /// One library holding all three kinds of row: an issue the app fetched,
    /// one it has only catalogued, and a file the reader dropped in.
    private func mixedLibrary() throws -> (store: Store, local: LocalFile) {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
            """)
        let fetched = try XCTUnwrap(try store.search("nasilje").first)
        try store.recordDownload(issueID: fetched.id, mirrorURL: "http://x/1",
                                 path: URL(fileURLWithPath: "/tmp/1.cbz"), bytes: 10)

        let url = try write("Evropa 001.cbz", bytes: 64)
        let file = LocalFile(name: url.lastPathComponent, url: url, bytes: 64)
        try store.reconcileLocalFiles([file])
        return (store, file)
    }

    /// The reader's own files answered the Downloaded filter, which is not
    /// what anyone means by it.
    ///
    /// Every local row is written as downloaded the moment it exists — the
    /// file is on the device, so it is — and the effect was that narrowing to
    /// Downloaded emptied the shelf of catalogued issues and filled it with
    /// the folder instead.
    func testDownloadedDoesNotShowLocalFiles() throws {
        let (store, _) = try mixedLibrary()
        let shelf = try store.recent(limit: nil, downloadedOnly: true)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf.first?.site, .stripzona)
        XCTAssertFalse(shelf.contains { $0.site == .local },
                       "the reader's own files answered the Downloaded filter")
    }

    /// And the switch that does ask for them shows them, and nothing else.
    func testLocalFilesFilterShowsOnlyTheReadersOwn() throws {
        let (store, file) = try mixedLibrary()
        let shelf = try store.recent(limit: nil, localOnly: true)
        XCTAssertEqual(shelf.count, 1)
        XCTAssertEqual(shelf.first?.code, file.name)
    }

    /// Two switches over one question, so they OR.
    ///
    /// The alternative is a shelf that cannot hold anything: "fetched and not
    /// a local file" AND "a local file" is satisfied by no row in any library,
    /// and ticking a second filter that widens what is shown would empty the
    /// screen.
    func testDownloadedAndLocalFilesTogetherShowBoth() throws {
        let (store, _) = try mixedLibrary()
        let shelf = try store.recent(limit: nil, downloadedOnly: true, localOnly: true)
        XCTAssertEqual(Set(shelf.map(\.site)), [.stripzona, .local])
        XCTAssertEqual(shelf.count, 2, "the undownloaded catalogue row leaked in")
    }

    /// The count behind "you have not downloaded anything yet", which has to
    /// mean the same thing the filter does.
    ///
    /// Otherwise a reader whose only files are their own ticks Downloaded,
    /// gets an empty shelf, and is told the generic "nothing matches" rather
    /// than the one sentence that would explain it.
    func testDownloadedCountIgnoresLocalFiles() throws {
        let store = try Store()
        let url = try write("Evropa 002.cbz", bytes: 32)
        try store.reconcileLocalFiles([LocalFile(name: url.lastPathComponent,
                                                 url: url, bytes: 32)])
        XCTAssertEqual(store.localFileTotals.count, 1, "the file never became a row")
        XCTAssertEqual(store.downloadedCount, 0)
    }

    // MARK: - Files that are not issues

    /// The reader's folder is theirs, and `isReadable` looks at the extension
    /// alone — so a renamed picture, a truncated download or a text file
    /// called `.cbz` becomes a row exactly like a real scan does. Nothing can
    /// be drawn from it, and without a mark the tile promises artwork for ever
    /// and the sweep opens the file again after every scan.
    func testAFileThatCannotBeDrawnIsMarkedRatherThanRetriedForEver() throws {
        let store = try Store()
        let url = try write("Not really a scan.cbz", bytes: 40)
        try store.reconcileLocalFiles([LocalFile(name: url.lastPathComponent,
                                                 url: url, bytes: 40)])
        let issue = try XCTUnwrap(try store.recent().first)
        XCTAssertFalse(issue.coverFailed, "marked before anything was tried")
        XCTAssertEqual(try store.downloadedIssuesLackingCover(), [issue.id],
                       "the sweep never offered to draw it")

        try store.markCoverCaptureFailed(issueID: issue.id)

        XCTAssertTrue(try XCTUnwrap(try store.recent().first).coverFailed)
        XCTAssertTrue(try store.downloadedIssuesLackingCover().isEmpty,
                      "the same unreadable file is opened again on every scan")
    }

    /// The mark is a verdict on the bytes, and the row outlives them.
    ///
    /// Local rows are matched by name, so replacing a corrupt file with a good
    /// one under the same name keeps the row. Keeping the verdict with it
    /// would leave the shelf calling a perfectly good scan unreadable, with
    /// nothing ever looking again to find out otherwise.
    func testReplacingTheFileClearsTheVerdictOnTheOldOne() throws {
        let store = try Store()
        let url = try write("Evropa 003.cbz", bytes: 40)
        try store.reconcileLocalFiles([LocalFile(name: url.lastPathComponent,
                                                 url: url, bytes: 40)])
        let issue = try XCTUnwrap(try store.recent().first)
        try store.markCoverCaptureFailed(issueID: issue.id)

        // The reader drops a good file in over the bad one: same name, and
        // the different size is what the scan notices.
        try FileManager.default.removeItem(at: url)
        let replacement = try write("Evropa 003.cbz", bytes: 900)
        let report = try store.reconcileLocalFiles(
            [LocalFile(name: replacement.lastPathComponent, url: replacement, bytes: 900)])
        XCTAssertEqual(report.replaced, [issue.id], "the replacement went unnoticed")

        // What the app does for every id in `replaced`.
        try store.clearCoverCaptureFailed(issueID: issue.id)

        XCTAssertFalse(try XCTUnwrap(try store.recent().first).coverFailed)
        XCTAssertEqual(try store.downloadedIssuesLackingCover(), [issue.id],
                       "the new file is never offered to the drawing")
    }

    /// And artwork arriving settles it, whichever way it arrived.
    func testGivingAnIssueACoverForgetsThatItHadNone() throws {
        let store = try Store()
        let url = try write("Evropa 004.cbz", bytes: 40)
        try store.reconcileLocalFiles([LocalFile(name: url.lastPathComponent,
                                                 url: url, bytes: 40)])
        let issue = try XCTUnwrap(try store.recent().first)
        try store.markCoverCaptureFailed(issueID: issue.id)

        try store.setCoverURL("szpage:\(issue.id)", issueID: issue.id)

        XCTAssertFalse(try XCTUnwrap(try store.recent().first).coverFailed,
                       "a row with artwork still says nothing could be drawn for it")
    }

    /// The link the mark actually hangs on: a file that is not an archive
    /// makes the drawing throw, rather than quietly producing something.
    ///
    /// Worth its own test because the mark is only ever set from a failure
    /// here. If `captureCover` came back with a picture for a renamed JPEG —
    /// or threw for a scan that is merely slow to open — the shelf would
    /// label the wrong files, and every test above it would still pass
    /// because they set the mark by hand.
    func testDrawingACoverThrowsForAFileThatIsNotAnArchive() throws {
        let store = try Store()
        let comics = folder.appendingPathComponent("comics", isDirectory: true)
        try FileManager.default.createDirectory(at: comics, withIntermediateDirectories: true)
        let documents = folder.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)

        // A JPEG the reader renamed, which is the everyday version of this:
        // the extension says issue and the bytes say picture.
        let bogus = documents.appendingPathComponent("Holiday.cbz")
        try Data([0xFF, 0xD8, 0xFF, 0xE0] + Array(repeating: 0x00, count: 512)).write(to: bogus)

        let library = Library(store: store, paths: LibraryPaths(root: comics),
                              transport: StubTransport { _ in HTTPResponse(status: 404) },
                              downloader: StubDownloader(bodies: [:]))
        try store.reconcileLocalFiles(LocalFiles.scan(documents))
        let issue = try XCTUnwrap(try store.recent().first)
        XCTAssertEqual(issue.site, .local, "the file never became a local row")

        XCTAssertThrowsError(try library.captureCover(issueID: issue.id),
                             "a renamed picture was accepted as an issue")

        // And a real one in the same folder still draws, so the test above is
        // not passing because nothing here can draw anything.
        let scratch = folder.appendingPathComponent("build", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        _ = try SevenZipFixture.make(named: "Evropa.cbz", pages: 1...2,
                                     in: scratch, at: documents)
        try store.reconcileLocalFiles(LocalFiles.scan(documents))
        let good = try XCTUnwrap(try store.search("evropa").first)
        XCTAssertNoThrow(try library.captureCover(issueID: good.id))
    }
}

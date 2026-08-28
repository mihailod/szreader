import XCTest
@testable import SZKit

/// The download table against the device.
///
/// "Downloaded" on the shelf is the presence of a `download` row and nothing
/// else, and there is one ordinary way for that row to outlive its file: the
/// comics root is excluded from backup and the database recording it is not,
/// so an iCloud restore brings every row back onto a device holding none of
/// the files. These pin both halves — that the sweep forgets those rows, and
/// that it forgets nothing else, which is the half that would cost a reader
/// their library.
final class ReconcileDownloadsTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func library(_ store: Store) -> Library {
        Library(store: store, paths: LibraryPaths(root: root),
                transport: StubTransport { _ in HTTPResponse(status: 200) },
                downloader: StubDownloader(bodies: [:]))
    }

    private func populated() throws -> (Store, Library, Int) {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let library = self.library(store)
        let issue = try XCTUnwrap(try store.recent().first)
        return (store, library, issue.id)
    }

    /// Records a download whose file really is written, so the row and the
    /// disk start out agreeing.
    @discardableResult
    private func downloadArrives(_ store: Store, issueID: Int) throws -> URL {
        let directory = root.appendingPathComponent("\(issueID)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("comic.cbz")
        try Data(repeating: 0x41, count: 64).write(to: file)
        try store.recordDownload(issueID: issueID, mirrorURL: "http://www.mediafire.com/?FAKEKEY013",
                                 path: file, bytes: 64)
        return file
    }

    private func isDownloaded(_ store: Store, _ issueID: Int) throws -> Bool {
        try XCTUnwrap(try store.recent().first { $0.id == issueID }).isDownloaded
    }

    // MARK: - What it forgets

    /// The restore: the database arrives, the comics root does not.
    func testForgetsADownloadWhoseFileAndFolderAreBothGone() throws {
        let (store, library, id) = try populated()
        try downloadArrives(store, issueID: id)
        XCTAssertTrue(try isDownloaded(store, id))

        // What a restore leaves behind: the root exists — the app recreates it
        // on launch — and holds nothing.
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(id)"))

        XCTAssertEqual(try library.reconcileDownloads(), [id])
        XCTAssertFalse(try isDownloaded(store, id),
                       "the shelf still calls an issue downloaded with nothing on the device")
    }

    /// The issue itself survives: the mirrors are still good links and the
    /// read state is still true. Only the file stopped being here.
    func testForgettingADownloadKeepsTheIssueAndItsMirrors() throws {
        let (store, library, id) = try populated()
        try downloadArrives(store, issueID: id)
        try store.setRead(true, issueID: id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(id)"))

        try library.reconcileDownloads()

        let issue = try XCTUnwrap(try store.recent().first { $0.id == id })
        XCTAssertEqual(issue.mirrorCount, 1, "the link to fetch it again went with the file")
        XCTAssertTrue(issue.isRead, "read state is not a fact about the file")
        XCTAssertFalse(try store.mirrors(forIssue: id).isEmpty)
    }

    /// Artwork captured from the comic's own first page lives under the same
    /// excluded root, so it goes wherever the download went. Left pointing at
    /// it, the issue is coverless for good — nothing asks again.
    func testForgetsACapturedCoverThatWentWithTheDownload() throws {
        let (store, library, id) = try populated()
        try downloadArrives(store, issueID: id)
        try store.setCoverURL(Library.coverReference(issueID: id), issueID: id)
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(id)"))

        try library.reconcileDownloads()

        XCTAssertNil(try store.coverURL(forIssue: id),
                     "the issue still points at artwork that is not on the device")
    }

    /// A captured cover whose file is still here is artwork the shelf can
    /// draw, whatever happened to the download.
    func testKeepsACapturedCoverThatIsStillOnTheDevice() throws {
        let (store, library, id) = try populated()
        try downloadArrives(store, issueID: id)
        let reference = Library.coverReference(issueID: id)
        try store.setCoverURL(reference, issueID: id)
        // Written before the download is removed: `coverFile` is deliberately
        // outside the issue's folder so it survives a removed download.
        try Data(repeating: 0x42, count: 16)
            .write(to: LibraryPaths(root: root).coverFile(forIssue: id))
        try FileManager.default.removeItem(at: root.appendingPathComponent("\(id)"))

        try library.reconcileDownloads()

        XCTAssertEqual(try store.coverURL(forIssue: id), reference)
    }

    // MARK: - What it must not forget

    /// The case that would cost a reader their library. An archive is deleted
    /// the moment its pages are out, so for every issue ever opened the
    /// recorded file is *expected* to be missing and the pages beside it are
    /// the comic.
    func testKeepsADownloadThatWasUnpackedAndHadItsArchiveDeleted() throws {
        let (store, library, id) = try populated()
        let file = try downloadArrives(store, issueID: id)

        // Exactly what `discardArchives` leaves: the folder and its pages,
        // without the archive they came out of.
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x43, count: 16)
            .write(to: root.appendingPathComponent("\(id)/0001.jpg"))

        XCTAssertEqual(try library.reconcileDownloads(), [])
        XCTAssertTrue(try isDownloaded(store, id),
                      "an unpacked issue was forgotten because its archive is gone")
    }

    /// A set is one archive shared by a run of issues: the recorded file sits
    /// under `set-<id>/`, and the issue's own folder does not exist until it
    /// is first opened.
    func testKeepsASetMemberWhoseFileLivesOutsideTheIssueFolder() throws {
        let (store, library, id) = try populated()
        let contents = root.appendingPathComponent("set-7/contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let member = contents.appendingPathComponent("013.pdf")
        try Data(repeating: 0x44, count: 32).write(to: member)
        try store.recordDownload(issueID: id, mirrorURL: "http://x/set.zip",
                                 path: member, bytes: 32)

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("\(id)").path),
            "the premise: a set member has no folder of its own until it is opened")
        XCTAssertEqual(try library.reconcileDownloads(), [])
        XCTAssertTrue(try isDownloaded(store, id))
    }

    /// The reader's own files answer to `reconcileLocalFiles`, which applies a
    /// harsher rule than this one — a local file that is gone takes its whole
    /// issue with it. Two mechanisms deleting the same rows to two rules is
    /// how they come to disagree.
    func testLeavesLocalFilesToTheirOwnReconciliation() throws {
        let store = try Store()
        let folder = root.appendingPathComponent("documents", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("029 Brodeckov izvjestaj.cbr")
        try Data(repeating: 0x45, count: 48).write(to: file)
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let id = try XCTUnwrap(try store.recent().first).id

        // Gone from the folder, and nowhere near the comics root — which is
        // what makes this the row the sweep would wrongly claim.
        try FileManager.default.removeItem(at: file)

        XCTAssertEqual(try library(store).reconcileDownloads(), [],
                       "a local file was reconciled by the wrong mechanism")
        XCTAssertTrue(try isDownloaded(store, id))
    }

    /// A root that is not there answers "missing" for every file under it. If
    /// that counted, one failed `createDirectory` would forget the whole
    /// library on the launch least able to afford it.
    func testForgetsNothingWhenTheRootItselfIsMissing() throws {
        let (store, library, id) = try populated()
        try downloadArrives(store, issueID: id)
        try FileManager.default.removeItem(at: root)

        XCTAssertEqual(try library.reconcileDownloads(), [])
        XCTAssertTrue(try isDownloaded(store, id))
    }

    /// Nothing to do is the normal launch, on every device that was never
    /// restored.
    func testForgetsNothingWhenEveryFileIsWhereItShouldBe() throws {
        let (store, library, id) = try populated()
        try downloadArrives(store, issueID: id)
        XCTAssertEqual(try library.reconcileDownloads(), [])
        XCTAssertTrue(try isDownloaded(store, id))
    }

    // MARK: - The one-off, asked when a reader opens an issue

    func testIsOnDeviceFollowsTheFileAndThenTheFolder() throws {
        let (store, library, id) = try populated()
        XCTAssertFalse(library.isOnDevice(issueID: id), "no download recorded at all")

        let file = try downloadArrives(store, issueID: id)
        XCTAssertTrue(library.isOnDevice(issueID: id))

        try FileManager.default.removeItem(at: file)
        XCTAssertTrue(library.isOnDevice(issueID: id), "the unpacked folder is still the comic")

        try FileManager.default.removeItem(at: root.appendingPathComponent("\(id)"))
        XCTAssertFalse(library.isOnDevice(issueID: id))
    }

    func testForgetDownloadReportsWhetherThereWasOneToForget() throws {
        let (store, library, id) = try populated()
        XCTAssertFalse(try library.forgetDownload(issueID: id))

        try downloadArrives(store, issueID: id)
        XCTAssertTrue(try library.forgetDownload(issueID: id))
        XCTAssertFalse(try isDownloaded(store, id))
    }
}

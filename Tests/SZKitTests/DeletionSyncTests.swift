import XCTest
@testable import SZKit

/// Deleting an issue, and having it stay deleted.
///
/// Union is the right rule for the first merge and exactly wrong afterwards:
/// an issue deleted here is, to a merge that only ever adds, an issue the
/// other device has and this one lacks. So it comes back. The reader deletes
/// it again, and it comes back again.
final class DeletionSyncTests: XCTestCase {

    private static let padPage = """
        <title>Zagor - ZLATNA SERIJA - Stripzona</title>
        <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
        <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
        """

    private func device(_ cloud: FakeLibraryCloud, page: String? = DeletionSyncTests.padPage)
        throws -> (LibrarySync, Store) {
        let store = try Store()
        if let page { try store.ingest(html: page) }
        return (LibrarySync(store: store, cloud: cloud), store)
    }

    private func titles(_ store: Store) throws -> [String] {
        try store.recent(limit: nil).compactMap(\.title).sorted()
    }

    // MARK: - Writing the deletion down

    /// A deletion has to be recorded while the row still exists — afterwards
    /// there is nothing left to derive its name in the account from.
    func testDeletingAnIssueRecordsIt() throws {
        let store = try Store()
        try store.ingest(html: Self.padPage)
        let target = try XCTUnwrap(try store.recent(limit: nil).first)

        try store.delete(issueID: target.id)

        XCTAssertEqual(try store.pendingDeletions().count, 1)
    }

    /// A catalogue row is rebuilt from the app bundle and was never sent, so
    /// deleting it here must not tell another device to throw anything away.
    func testDeletingACatalogueRowRecordsNothing() throws {
        let store = try Store()
        try store.seedCatalogue(for: .retrospec)
        let target = try XCTUnwrap(try store.recent(limit: nil).first)

        try store.delete(issueID: target.id)

        XCTAssertEqual(try store.pendingDeletions(), [])
    }

    /// The reader's own file is the folder on this device, and deleting the
    /// row is between them and the folder.
    func testDeletingALocalFileRecordsNothing() throws {
        let store = try Store()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 0x41, count: 32)
            .write(to: folder.appendingPathComponent("029 Brodeckov.cbr"))
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        let target = try XCTUnwrap(try store.recent(limit: nil).first)

        try store.delete(issueID: target.id)

        XCTAssertEqual(try store.pendingDeletions(), [])
    }

    /// The bulk deletes go through the same door. "Delete Library" on a synced
    /// device that quietly meant "on this one" would be a shelf that empties
    /// and then fills itself back up on the next sync.
    func testDeletingTheWholeLibraryRecordsEveryExportableIssue() throws {
        let store = try Store()
        try store.ingest(html: Self.padPage)
        try store.seedCatalogue(for: .retrospec)

        try store.deleteAll()

        XCTAssertEqual(try store.pendingDeletions().count, 2,
                       "only the issues the account actually holds")
    }

    // MARK: - Carrying it between devices

    /// The whole point: an issue deleted on one device goes from the other.
    func testAnIssueDeletedOnOneDeviceIsRemovedFromTheOther() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud)
        let (phone, phoneStore) = try device(cloud, page: nil)
        try await pad.run()
        try await phone.run()
        XCTAssertEqual(try titles(phoneStore).count, 2, "the premise: both have both")

        let doomed = try XCTUnwrap(try padStore.recent(limit: nil)
            .first { $0.title == "Klark siti" })
        try padStore.delete(issueID: doomed.id)
        try await pad.run()

        let outcome = try await phone.run()

        XCTAssertEqual(outcome.removed, 1)
        XCTAssertEqual(try titles(phoneStore), ["Nasilje u Darkvudu"])
    }

    /// And it stays gone. This is the failure union produces: the deletion
    /// works, and the next sync quietly undoes it.
    func testADeletedIssueDoesNotComeBackOnTheNextSync() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud)
        let (phone, phoneStore) = try device(cloud, page: nil)
        try await pad.run()
        try await phone.run()

        let doomed = try XCTUnwrap(try padStore.recent(limit: nil).first)
        try padStore.delete(issueID: doomed.id)
        try await pad.run()
        try await phone.run()

        for _ in 1...3 {
            try await pad.run()
            try await phone.run()
        }

        XCTAssertEqual(padStore.issueCount, 1, "the issue came back to the device that deleted it")
        XCTAssertEqual(phoneStore.issueCount, 1, "the issue came back to the other device")
    }

    /// Applying a deletion that arrived must not record a deletion of our own,
    /// or two devices tell each other about the same removal for ever.
    func testApplyingADeletionDoesNotEchoItBack() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud)
        let (phone, phoneStore) = try device(cloud, page: nil)
        try await pad.run()
        try await phone.run()

        let doomed = try XCTUnwrap(try padStore.recent(limit: nil).first)
        try padStore.delete(issueID: doomed.id)
        try await pad.run()
        XCTAssertEqual(cloud.deleteCalls, 1, "the premise: the iPad sent one removal")

        try await phone.run()

        // Counted at the account rather than read from the phone's own
        // pending list: a run pushes deletions *and clears them*, so an echo
        // and a silence leave that list looking exactly the same.
        XCTAssertEqual(cloud.deleteCalls, 1,
                       "the phone told the account about a deletion it was told about")
        XCTAssertEqual(try phoneStore.pendingDeletions(), [])
    }

    /// Once the account has a deletion it carries it to everyone else, so
    /// holding on to a second copy of that fact would grow for ever.
    func testADeletionIsForgottenOnceSent() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud)
        try await pad.run()

        let doomed = try XCTUnwrap(try padStore.recent(limit: nil).first)
        try padStore.delete(issueID: doomed.id)
        XCTAssertEqual(try padStore.pendingDeletions().count, 1)

        try await pad.run()

        XCTAssertEqual(try padStore.pendingDeletions(), [])
    }

    /// A deletion for something this device never had is not an error.
    func testADeletionForAnUnknownIssueDoesNothing() throws {
        let store = try Store()
        try store.ingest(html: Self.padPage)

        XCTAssertEqual(try store.applyDeletions(["not-a-real-record-name"]), [])
        XCTAssertEqual(store.issueCount, 2)
    }

    // MARK: - A library that has moved to a different account

    /// Shipping is the case this exists for: a development build and a release
    /// build talk to two separate CloudKit databases, and the marks kept here
    /// know nothing about the difference. Without this the first App Store
    /// build would believe it had already sent everything, send nothing, and
    /// sync in perfect silence for ever.
    func testAFullReadOfAnEmptyAccountMakesTheDeviceSendAgain() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud)
        try await pad.run()
        XCTAssertEqual(cloud.recordNames.count, 2)

        // A different account: nothing there, and this device's cursor means
        // nothing to it.
        let fresh = FakeLibraryCloud()
        try padStore.setSyncCursor(nil)
        let moved = LibrarySync(store: padStore, cloud: fresh)

        let outcome = try await moved.run()

        XCTAssertEqual(outcome.pushed, 2, "the library was never uploaded to the new account")
        XCTAssertEqual(fresh.recordNames.count, 2)
    }

    /// And the ordinary "nothing has changed" — which is almost every sync —
    /// must never be mistaken for that.
    func testAnOrdinaryQuietSyncDoesNotResendEverything() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, _) = try device(cloud)
        try await pad.run()
        let saves = cloud.saves

        for _ in 1...3 { try await pad.run() }

        XCTAssertEqual(cloud.saves, saves, "a quiet sync re-sent the whole library")
    }
}

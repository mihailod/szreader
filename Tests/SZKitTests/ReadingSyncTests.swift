import XCTest
@testable import SZKit

/// Where the reader got to, carried between their devices.
///
/// The rule is one blob, newest wins. Not field by field — three of the four
/// values are monotonic, so per-field maxima look safe and are not, for one
/// reason that this file exists to pin.
final class ReadingSyncTests: XCTestCase {

    private static let page = """
        <title>Zagor - ZLATNA SERIJA - Stripzona</title>
        <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
        <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
        """

    private func library() throws -> (Store, Int) {
        let store = try Store()
        try store.ingest(html: Self.page)
        let id = try XCTUnwrap(try store.recent(limit: nil)
            .first { $0.title == "Nasilje u Darkvudu" }?.id)
        return (store, id)
    }

    private func state(_ store: Store, _ id: Int) throws -> StoredIssue {
        try XCTUnwrap(try store.recent(limit: nil).first { $0.id == id })
    }

    // MARK: - What is worth sending

    /// An issue nobody has touched has nothing to say, and a record per issue
    /// in the library would be tens of thousands of them for no information.
    func testAnUntouchedLibraryExportsNothing() throws {
        let (store, _) = try library()
        XCTAssertEqual(try store.exportableReading().count, 0)
    }

    func testMarkingReadIsWorthSending() throws {
        let (store, id) = try library()
        try store.setRead(true, issueID: id)

        let exported = try store.exportableReading()

        XCTAssertEqual(exported.count, 1)
        XCTAssertNotNil(exported.first?.readAt)
    }

    /// Opening an issue and putting it down again is reading state too — it is
    /// what the default sort is built on.
    func testOpeningAnIssueIsWorthSending() throws {
        let (store, id) = try library()
        try store.markOpened(issueID: id)
        XCTAssertEqual(try store.exportableReading().count, 1)
    }

    func testAPositionIsWorthSending() throws {
        let (store, id) = try library()
        try store.setLastPage(12, issueID: id)

        let exported = try XCTUnwrap(try store.exportableReading().first)

        XCTAssertEqual(exported.lastPage, 12)
        XCTAssertNotNil(exported.startedAt, "past the cover is started")
    }

    /// Only what has moved since the account was last told. Reading moves on
    /// issues that are years old, so the mark is a time and not a rowid.
    func testOnlyWhatHasMovedSinceIsExported() throws {
        let (store, id) = try library()
        try store.setRead(true, issueID: id)
        let mark = try XCTUnwrap(try store.latestReadingChange())

        XCTAssertEqual(try store.exportableReading(since: mark).count, 0)

        let other = try XCTUnwrap(try store.recent(limit: nil)
            .first { $0.title == "Klark siti" }?.id)
        try store.setLastPage(3, issueID: other)

        XCTAssertEqual(try store.exportableReading(since: mark).count, 1)
    }

    // MARK: - Merging

    func testAPositionFromAnotherDeviceIsApplied() throws {
        let (pad, padID) = try library()
        let (phone, phoneID) = try library()
        try phone.setLastPage(40, issueID: phoneID)

        XCTAssertEqual(try pad.mergeReading(try phone.exportableReading()), 1)

        XCTAssertEqual(try state(pad, padID).lastPage, 40)
        XCTAssertEqual(try state(pad, padID).readState, .reading)
    }

    /// **The case per-field maxima would get wrong.** Unmarking clears both
    /// `read_at` and `started_at`; if the merge took the maximum of each
    /// field, the other device's older values would put them straight back and
    /// an issue could never be unmarked while a second device existed.
    func testUnmarkingReadTravelsAndIsNotUndone() throws {
        let (pad, padID) = try library()
        let (phone, phoneID) = try library()

        // Both devices agree it is read.
        try phone.setRead(true, issueID: phoneID)
        try pad.mergeReading(try phone.exportableReading())
        XCTAssertTrue(try state(pad, padID).isRead)

        // The phone changes its mind, later.
        Thread.sleep(forTimeInterval: 0.01)
        try phone.setRead(false, issueID: phoneID)

        try pad.mergeReading(try phone.exportableReading())

        XCTAssertFalse(try state(pad, padID).isRead, "unmarking did not travel")
        XCTAssertEqual(try state(pad, padID).readState, .unread)
    }

    /// And the older answer loses, whichever direction it arrives from. A
    /// device that has been away for a month must not undo the month.
    func testAnOlderStateDoesNotOverwriteANewerOne() throws {
        let (pad, padID) = try library()
        let (stale, staleID) = try library()

        try stale.setLastPage(5, issueID: staleID)
        let old = try stale.exportableReading()

        Thread.sleep(forTimeInterval: 0.01)
        try pad.setLastPage(90, issueID: padID)

        let applied = try pad.mergeReading(old)

        XCTAssertEqual(applied, 0, "a stale device rolled the reader back")
        XCTAssertEqual(try state(pad, padID).lastPage, 90)
    }

    /// Reading state applies to catalogue rows, which is most of the library
    /// and exactly the issues somebody is part-way through. The row is rebuilt
    /// on the other device by its switch; only the position travels.
    func testACataloguedIssuesPositionTravelsWithoutTheRow() throws {
        let pad = try Store()
        try pad.seedCatalogue(for: .retrospec)
        let phone = try Store()
        try phone.seedCatalogue(for: .retrospec)

        let target = try XCTUnwrap(try phone.recent(limit: nil).first)
        try phone.setLastPage(7, issueID: target.id)
        let exported = try phone.exportableReading()
        XCTAssertEqual(exported.count, 1)
        // Nothing about the row itself is offered for sync.
        XCTAssertEqual(try phone.exportableIssues().count, 0)

        XCTAssertEqual(try pad.mergeReading(exported), 1)

        let here = try XCTUnwrap(try pad.recent(limit: nil)
            .first { $0.title == target.title && $0.number == target.number })
        XCTAssertEqual(here.lastPage, 7)
    }

    /// A position for an issue this device has never heard of is skipped, not
    /// invented. The pointer arrives on its own account, or the catalogue
    /// rebuilds it; the position is applied whenever the row turns up.
    func testAPositionForAnUnknownIssueIsSkipped() throws {
        let (store, _) = try library()
        let orphan = SyncedReading(
            identity: IssueIdentity(site: .stripzona, code: "NOPE", number: 999,
                                    titleFolded: "nothing here", series: nil),
            readAt: Date(), startedAt: nil, openedAt: nil, lastPage: 3,
            modifiedAt: Date())

        XCTAssertEqual(try store.mergeReading([orphan]), 0)
        XCTAssertEqual(store.issueCount, 2, "an orphan position invented a row")
    }

    /// Merging the same state twice does nothing the second time — this runs
    /// on every foreground.
    func testMergingTheSameStateTwiceIsIdempotent() throws {
        let (pad, _) = try library()
        let (phone, phoneID) = try library()
        try phone.setRead(true, issueID: phoneID)
        let arriving = try phone.exportableReading()

        XCTAssertEqual(try pad.mergeReading(arriving), 1)
        XCTAssertEqual(try pad.mergeReading(arriving), 0)
    }

    // MARK: - Through the engine

    func testReadingCrossesBetweenDevicesThroughTheAccount() async throws {
        let cloud = FakeLibraryCloud()
        let padStore = try Store()
        try padStore.ingest(html: Self.page)
        let phoneStore = try Store()
        try phoneStore.ingest(html: Self.page)

        let pad = LibrarySync(store: padStore, cloud: cloud)
        let phone = LibrarySync(store: phoneStore, cloud: cloud)

        let padID = try XCTUnwrap(try padStore.recent(limit: nil).first).id
        try padStore.setLastPage(33, issueID: padID)
        try await pad.run()

        let outcome = try await phone.run()

        XCTAssertGreaterThan(outcome.readingApplied, 0)
        let here = try XCTUnwrap(try phoneStore.recent(limit: nil)
            .first { $0.lastPage == 33 })
        XCTAssertEqual(here.lastPage, 33)
    }

    /// And an unchanged position is not re-sent on every foreground.
    func testAnUnchangedPositionIsSentOnce() async throws {
        let cloud = FakeLibraryCloud()
        let store = try Store()
        try store.ingest(html: Self.page)
        let sync = LibrarySync(store: store, cloud: cloud)
        let id = try XCTUnwrap(try store.recent(limit: nil).first).id
        try store.setLastPage(10, issueID: id)

        let first = try await sync.run()
        let second = try await sync.run()

        XCTAssertEqual(first.readingPushed, 1)
        XCTAssertEqual(second.readingPushed, 0)
    }
}

/// Reading state that predates the column recording when it changed.
///
/// Every library in existence when syncing arrived was in this state: issues
/// read, positions kept, and no stamp on any of it. Without the backfill the
/// export — which asks for rows whose stamp is set — finds nothing, and a
/// reader syncs their shelf to find every issue unread on the other device
/// with no way to mend it short of opening each one again.
final class ReadingStateBackfillTests: XCTestCase {

    /// Builds a library in the shape an older build left behind: reading
    /// state written straight into the columns, with no stamp.
    private func legacyLibrary() throws -> (Store, Int) {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let id = try XCTUnwrap(try store.recent(limit: nil).first).id
        try store.setRead(true, issueID: id)
        // Wind it back to how an older build would have left it: the state
        // there, the stamp and the migration marker gone.
        try store.rawRun("UPDATE issue SET read_state_at = NULL")
        try store.rawRun("DELETE FROM meta WHERE key = 'read-state-stamped-from-history'")
        return (store, id)
    }

    func testTheBackfillIsNeeded() throws {
        let (store, _) = try legacyLibrary()
        XCTAssertEqual(try store.exportableReading().count, 0,
                       "the premise: unstamped reading state is invisible to sync")
    }

    func testReadingStateFromBeforeTheColumnBecomesExportable() throws {
        let (store, _) = try legacyLibrary()
        try store.runReadStateBackfill()

        let exported = try store.exportableReading()

        XCTAssertEqual(exported.count, 1, "reading state from an older build never syncs")
        XCTAssertNotNil(exported.first?.readAt)
    }

    /// A row carrying only a page number and no timestamp at all still has to
    /// come out stamped, or the floor is doing nothing.
    func testAPositionWithNoTimestampsIsStillStamped() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let id = try XCTUnwrap(try store.recent(limit: nil).first).id
        try store.rawRun("UPDATE issue SET last_page = 8, read_state_at = NULL WHERE id = \(id)")
        try store.rawRun("DELETE FROM meta WHERE key = 'read-state-stamped-from-history'")

        try store.runReadStateBackfill()

        XCTAssertEqual(try store.exportableReading().first?.lastPage, 8)
    }

    /// Stamped as old, so any genuine change made afterwards on any device
    /// wins — the right answer when two devices disagree about state neither
    /// of them can date.
    func testBackfilledStateLosesToARealChange() throws {
        let (pad, _) = try legacyLibrary()
        try pad.runReadStateBackfill()

        let (phone, phoneID) = try legacyLibrary()
        try phone.runReadStateBackfill()
        try phone.setRead(false, issueID: phoneID)

        try pad.mergeReading(try phone.exportableReading())

        let here = try XCTUnwrap(try pad.recent(limit: nil).first)
        XCTAssertFalse(here.isRead, "a deliberate change lost to undated history")
    }

    /// An untouched library gains nothing: the backfill must not invent
    /// reading state for issues nobody has opened.
    func testTheBackfillLeavesUntouchedIssuesAlone() throws {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        try store.rawRun("DELETE FROM meta WHERE key = 'read-state-stamped-from-history'")

        try store.runReadStateBackfill()

        XCTAssertEqual(try store.exportableReading().count, 0)
    }
}

/// A push that fails must not be recorded as having happened.
///
/// The failure this guards against is the quiet one: the transport reports
/// success, the mark advances past work that never landed, and the position is
/// never offered again. That is precisely how reading state came to stop
/// syncing with nothing anywhere saying so — CloudKit refuses records one at a
/// time inside a result the caller has to actually read.
final class ReadingPushFailureTests: XCTestCase {

    /// Accepts pointers, refuses positions until told otherwise.
    private final class RefusingCloud: LibraryCloud, @unchecked Sendable {
        let lock = NSLock()
        var refuse = true
        private var stored: [SyncedReading] = []

        var readingCount: Int { lock.lock(); defer { lock.unlock() }; return stored.count }

        func changes(since cursor: SyncCursor?) async throws -> CloudChanges {
            CloudChanges(issues: [], cursor: nil)
        }
        func save(_ issues: [SyncedIssue]) async throws {}
        func saveReading(_ states: [SyncedReading]) async throws {
            lock.lock(); defer { lock.unlock() }
            if refuse { throw CocoaError(.fileWriteUnknown) }
            stored.append(contentsOf: states)
        }
        func delete(_ recordNames: [String]) async throws {}
    }

    private func library() throws -> (Store, Int) {
        let store = try Store()
        try store.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        return (store, try XCTUnwrap(try store.recent(limit: nil).first).id)
    }

    func testAFailedReadingPushIsRetriedNextTime() async throws {
        let cloud = RefusingCloud()
        let (store, id) = try library()
        try store.setLastPage(21, issueID: id)
        let sync = LibrarySync(store: store, cloud: cloud)

        do {
            _ = try await sync.run()
            XCTFail("the refusal was swallowed")
        } catch {
            // Expected: the transport said no, and said so.
        }
        XCTAssertEqual(cloud.readingCount, 0)

        cloud.refuse = false
        let outcome = try await sync.run()

        XCTAssertEqual(outcome.readingPushed, 1, "the position was recorded as sent and lost")
        XCTAssertEqual(cloud.readingCount, 1)
    }

    /// And the mark itself must not have moved, which is the mechanism.
    func testAFailedPushLeavesTheMarkAlone() async throws {
        let cloud = RefusingCloud()
        let (store, id) = try library()
        try store.setLastPage(21, issueID: id)

        _ = try? await LibrarySync(store: store, cloud: cloud).run()

        XCTAssertNil(try store.readingMark(),
                     "the account was recorded as knowing something it refused")
    }
}

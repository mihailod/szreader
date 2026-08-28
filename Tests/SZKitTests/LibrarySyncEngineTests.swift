import XCTest
@testable import SZKit

/// An account, without an account.
///
/// Keeps records by name and hands out a change feed the way CloudKit does:
/// everything since a cursor, in pages. Enough to hold the engine to its
/// contract — order, paging, resumption, idempotence — none of which needs a
/// network to be wrong.
final class FakeLibraryCloud: LibraryCloud, @unchecked Sendable {

    /// One thing that happened, in the order it happened.
    ///
    /// Append-only, which is what makes a cursor an index into it — and is
    /// also how a change feed genuinely behaves. Removing entries instead
    /// would shrink the feed under cursors that already point past the end,
    /// which is a bug in the fake rather than in anything it is testing.
    private enum Entry {
        case record(SyncedIssue)
        case deleted(String)
    }

    private let lock = NSLock()
    private var feed: [Entry] = []
    private var readingLog: [SyncedReading] = []
    private(set) var saves = 0
    private(set) var fetches = 0
    /// How many times a device has asked for something to be removed, which is
    /// what tells an echoed deletion from a silent one.
    private(set) var deleteCalls = 0
    /// How many entries a page holds, so paging can be exercised.
    var pageSize = 1_000
    var failNextSave: Error?

    /// What the account holds now, after everything that has happened to it.
    var recordNames: Set<String> {
        lock.lock(); defer { lock.unlock() }
        var live: Set<String> = []
        for entry in feed {
            switch entry {
            case .record(let issue): live.insert(issue.recordName)
            case .deleted(let name): live.remove(name)
            }
        }
        return live
    }

    private static func index(_ cursor: SyncCursor?) -> Int {
        guard let cursor, let text = String(data: cursor.data, encoding: .utf8),
              let value = Int(text) else { return 0 }
        return value
    }

    private static func cursor(_ index: Int) -> SyncCursor {
        SyncCursor(data: Data(String(index).utf8))
    }

    func changes(since cursor: SyncCursor?) async throws -> CloudChanges {
        lock.lock(); defer { lock.unlock() }
        fetches += 1
        let from = min(Self.index(cursor), feed.count)
        let to = min(from + pageSize, feed.count)

        var issues: [SyncedIssue] = []
        var deleted: [String] = []
        for entry in feed[from..<to] {
            switch entry {
            case .record(let issue): issues.append(issue)
            case .deleted(let name): deleted.append(name)
            }
        }
        return CloudChanges(issues: issues,
                            // Not paged: there are few of them, and what the
                            // engine has to get right is the merge rule.
                            reading: to >= feed.count ? readingLog : [],
                            deletedRecordNames: deleted,
                            cursor: Self.cursor(to),
                            more: to < feed.count)
    }

    func save(_ issues: [SyncedIssue]) async throws {
        lock.lock(); defer { lock.unlock() }
        if let failNextSave { self.failNextSave = nil; throw failNextSave }
        saves += 1
        feed.append(contentsOf: issues.map(Entry.record))
    }

    func saveReading(_ states: [SyncedReading]) async throws {
        lock.lock(); defer { lock.unlock() }
        for state in states {
            readingLog.removeAll { $0.recordName == state.recordName }
            readingLog.append(state)
        }
    }

    func delete(_ recordNames: [String]) async throws {
        lock.lock(); defer { lock.unlock() }
        deleteCalls += 1
        feed.append(contentsOf: recordNames.map(Entry.deleted))
    }
}

/// Carrying the library between devices, over a transport that is not there.
final class LibrarySyncEngineTests: XCTestCase {

    private static let padPage = """
        <title>Zagor - ZLATNA SERIJA - Stripzona</title>
        <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
        <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
        """

    private static let phonePage = """
        <title>Mister No - LUNOV MAGNUS STRIP - Stripzona</title>
        <div>021-Kuca uzasa</div><div>http://www.mediafire.com/?FAKEKEY021</div>
        """

    private func device(_ cloud: FakeLibraryCloud, page: String? = nil)
        throws -> (LibrarySync, Store) {
        let store = try Store()
        if let page { try store.ingest(html: page) }
        return (LibrarySync(store: store, cloud: cloud), store)
    }

    private func titles(_ store: Store) throws -> [String] {
        try store.recent(limit: nil).compactMap(\.title).sorted()
    }

    // MARK: - The union, over the wire

    func testTwoDevicesConvergeThroughTheAccount() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud, page: Self.padPage)
        let (phone, phoneStore) = try device(cloud, page: Self.phonePage)

        // Each device syncs once, then once more to collect what the other
        // sent — which is what actually happens as they are picked up in turn.
        try await pad.run()
        try await phone.run()
        try await pad.run()

        let expected = ["Klark siti", "Kuca uzasa", "Nasilje u Darkvudu"]
        XCTAssertEqual(try titles(padStore), expected)
        XCTAssertEqual(try titles(phoneStore), expected)
    }

    /// Listen before speaking. CloudKit refuses a save whose record is behind
    /// the server's, so a device that pushes first spends its first round trip
    /// collecting conflicts.
    func testASyncFetchesBeforeItPushes() async throws {
        final class OrderRecording: LibraryCloud, @unchecked Sendable {
            let lock = NSLock()
            var order: [String] = []
            func changes(since cursor: SyncCursor?) async throws -> CloudChanges {
                lock.lock(); order.append("fetch"); lock.unlock()
                return CloudChanges(issues: [], cursor: nil)
            }
            func save(_ issues: [SyncedIssue]) async throws {
                lock.lock(); order.append("save"); lock.unlock()
            }
            func saveReading(_ states: [SyncedReading]) async throws {}
            func delete(_ recordNames: [String]) async throws {}
        }
        let cloud = OrderRecording()
        let store = try Store()
        try store.ingest(html: Self.padPage)

        try await LibrarySync(store: store, cloud: cloud).run()

        XCTAssertEqual(cloud.order, ["fetch", "save"])
    }

    // MARK: - Sending only what is new

    /// The second sync of an unchanged library sends nothing. This runs on
    /// every foreground; if it re-sent the whole shelf each time it would be
    /// unusable.
    func testAnUnchangedLibrarySendsNothingTheSecondTime() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, _) = try device(cloud, page: Self.padPage)

        let first = try await pad.run()
        let second = try await pad.run()

        XCTAssertEqual(first.pushed, 2)
        XCTAssertEqual(second.pushed, 0)
        XCTAssertEqual(cloud.saves, 1, "an unchanged library was sent again")
    }

    /// A new import goes up, and only it.
    func testANewImportIsTheOnlyThingSentNext() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud, page: Self.padPage)
        try await pad.run()

        try padStore.ingest(html: Self.phonePage)
        let outcome = try await pad.run()

        XCTAssertEqual(outcome.pushed, 1, "the whole library was re-sent")
    }

    /// An alternate link added to an issue years old. Its rowid moves for
    /// nobody, and that alternate is exactly what the reader needs when the
    /// first link rots — so the mirror mark exists to catch it.
    func testANewLinkOnAnOldIssueIsSent() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud, page: Self.padPage)
        try await pad.run()

        // The same page again, now carrying a second scan for issue 13.
        try padStore.ingest(html: """
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div>
            <div>https://mega.nz/file/SECONDSCAN#KEY</div>
            """)
        let outcome = try await pad.run()

        XCTAssertEqual(outcome.pushed, 1)
    }

    // MARK: - Paging and interruption

    func testAFirstSyncAgainstAFullAccountArrivesInPages() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, _) = try device(cloud, page: Self.padPage)
        let (phone, _) = try device(cloud, page: Self.phonePage)
        try await pad.run()
        try await phone.run()

        cloud.pageSize = 1
        let (fresh, freshStore) = try device(cloud)
        let outcome = try await fresh.run()

        XCTAssertEqual(outcome.merged.added, 3)
        XCTAssertEqual(try titles(freshStore).count, 3)
    }

    /// A sync that dies part-way resumes rather than starting again — iOS
    /// suspends a backgrounded app mid-page as a matter of routine.
    func testAnInterruptedFetchResumesWhereItStopped() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, _) = try device(cloud, page: Self.padPage)
        let (phone, _) = try device(cloud, page: Self.phonePage)
        try await pad.run()
        try await phone.run()

        // One page, and the save it would have done next fails.
        cloud.pageSize = 1
        let (fresh, freshStore) = try device(cloud)
        cloud.failNextSave = URLError(.networkConnectionLost)
        _ = try? await fresh.run()
        let partway = freshStore.issueCount
        XCTAssertGreaterThan(partway, 0, "the premise: some of it landed")

        try await fresh.run()

        XCTAssertEqual(try titles(freshStore).count, 3)
    }

    /// Running twice over the same account cannot duplicate the shelf. This is
    /// the ordinary case, not an edge one: every foreground is another run.
    func testRunningRepeatedlyLeavesOneCopyOfEverything() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud, page: Self.padPage)
        let (phone, _) = try device(cloud, page: Self.phonePage)
        try await phone.run()

        for _ in 1...5 { try await pad.run() }

        XCTAssertEqual(padStore.issueCount, 3)
    }

    // MARK: - Resync

    /// What a resync is actually for: publishing a change the rowid marks
    /// cannot see. A cover found later by the backfill does not move any
    /// rowid, so the incremental push is blind to it — by design, rather than
    /// put a dirty flag on every write path in the app.
    func testResyncSendsAChangeTheMarksCouldNotSee() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud, page: Self.padPage)
        try await pad.run()

        let issue = try XCTUnwrap(try padStore.recent(limit: nil).first)
        try padStore.setCoverURL("https://example.invalid/found.jpg", issueID: issue.id)
        let blind = try await pad.run()
        XCTAssertEqual(blind.pushed, 0, "the premise: the marks cannot see this")

        let full = try await pad.resync()
        XCTAssertEqual(full.pushed, 1)
    }

    /// And it is not a blunt re-upload: a library the account already matches
    /// sends nothing, however often it is asked. Otherwise "fix my sync" would
    /// cost thousands of writes every time somebody tapped it.
    func testResyncOfAnUnchangedLibrarySendsNothing() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, padStore) = try device(cloud, page: Self.padPage)
        try await pad.run()
        let saves = cloud.saves

        let outcome = try await pad.resync()

        XCTAssertEqual(outcome.pushed, 0)
        XCTAssertEqual(cloud.saves, saves)
        XCTAssertEqual(padStore.issueCount, 2, "a resync disturbed the shelf")
    }

    // MARK: - Progress

    func testProgressNamesWhatItIsDoing() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, _) = try device(cloud, page: Self.padPage)
        let (phone, _) = try device(cloud, page: Self.phonePage)
        try await phone.run()

        let stages = LockedBox<[SyncStage]>([])
        try await pad.run { stage in stages.mutate { $0.append(stage) } }

        XCTAssertEqual(stages.value.first, .asking)
        XCTAssertTrue(stages.value.contains(.receiving(issues: 1)))
        XCTAssertTrue(stages.value.contains(.sending(issues: 2)))
    }

    /// The common case is nothing to do, and it must be able to say so — a
    /// "Syncing…" banner on every single launch would be a tax.
    func testASyncWithNothingToDoReportsNothing() async throws {
        let cloud = FakeLibraryCloud()
        let (pad, _) = try device(cloud, page: Self.padPage)
        try await pad.run()

        let outcome = try await pad.run()

        XCTAssertTrue(outcome.isEmpty)
    }
}

/// Collects values from a `@Sendable` callback.
///
/// The progress closure has to be `@Sendable` because a sync is async and may
/// report from anywhere, so a test cannot simply append to a local array.
final class LockedBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T
    init(_ value: T) { storage = value }

    var value: T {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    func mutate(_ change: (inout T) -> Void) {
        lock.lock(); defer { lock.unlock() }
        change(&storage)
    }
}

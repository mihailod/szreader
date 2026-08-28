import Foundation

/// The account's own bookmark, kept opaque.
///
/// CloudKit answers "what changed since this?" with a token it invented, and
/// nothing outside the transport should be able to read or construct one. It
/// is stored, handed back, and otherwise untouched.
public struct SyncCursor: Equatable, Sendable {
    public let data: Data
    public init(data: Data) { self.data = data }
}

/// One page of what the account has to say.
public struct CloudChanges: Sendable {
    public let issues: [SyncedIssue]
    /// Reading positions, which ride the same change feed. One zone, one
    /// cursor, one round trip — a second feed would double the cost of the
    /// check that runs on every foreground and answers "nothing" almost every
    /// time.
    public let reading: [SyncedReading]
    /// Issues deleted elsewhere, by record name. Read and carried now, acted
    /// on later: deletion needs a rule about what a device that has been away
    /// for a month is allowed to remove, and the first merge's rule is that
    /// nothing is ever lost.
    public let deletedRecordNames: [String]
    public let cursor: SyncCursor?
    /// Whether the account has more to say than fitted in this page.
    public let more: Bool

    public init(issues: [SyncedIssue], reading: [SyncedReading] = [],
                deletedRecordNames: [String] = [],
                cursor: SyncCursor?, more: Bool = false) {
        self.issues = issues
        self.reading = reading
        self.deletedRecordNames = deletedRecordNames
        self.cursor = cursor
        self.more = more
    }
}

/// Where a library's pointers are kept between devices.
///
/// A protocol so the rules above it can be tested without an iCloud account, a
/// signed build, or a network — the same trick `KeyValueCloud` plays for the
/// settings, which is what let the settings merge be proved correct while the
/// bug turned out to be somewhere else entirely.
public protocol LibraryCloud: Sendable {
    func changes(since cursor: SyncCursor?) async throws -> CloudChanges
    func save(_ issues: [SyncedIssue]) async throws
    func saveReading(_ states: [SyncedReading]) async throws
    /// Removes records by name. Deleting one that is already gone is not an
    /// error — a deletion may well be sent twice, by a retry or by two devices
    /// that both heard about it.
    func delete(_ recordNames: [String]) async throws
}

/// What one sync did.
public struct SyncOutcome: Equatable, Sendable {
    public var merged = SyncMergeReport()
    public var pushed = 0
    /// Reading positions taken in from other devices, and sent out.
    public var readingApplied = 0
    public var readingPushed = 0
    /// Issues deleted here because another device deleted them.
    public var removed = 0
    public init() {}
    public var isEmpty: Bool {
        merged.isEmpty && pushed == 0 && readingApplied == 0
            && readingPushed == 0 && removed == 0
    }
}

/// What a sync is doing, for the line along the bottom of the shelf.
public enum SyncStage: Equatable, Sendable {
    case asking
    case receiving(issues: Int)
    case sending(issues: Int)
}

/// Carries the library of pointers between one reader's devices.
///
/// Fetch first, then push. Both halves of that matter. CloudKit refuses a save
/// whose record is behind the server's, so a device that pushes before it
/// listens spends its first round trip collecting conflicts it then has to
/// resolve by hand. It is also the right order to think in: take in what the
/// world knows, then publish what only you know.
///
/// Nothing here is a download. Every archive stays where it was fetched, on
/// the device that fetched it — they are third-party files, they are excluded
/// from backup deliberately, and a library of them is measured in gigabytes.
/// What crosses is a few hundred bytes an issue saying where it can be got.
public struct LibrarySync: Sendable {

    private let store: Store
    private let cloud: LibraryCloud

    public init(store: Store, cloud: LibraryCloud) {
        self.store = store
        self.cloud = cloud
    }

    /// One pass: take everything the account has, then send everything it has
    /// not got.
    ///
    /// Safe to run again at any point, and it will be — this runs on every
    /// foreground, retries after a failure, and resumes after iOS suspends the
    /// app mid-way. Every step is built to be repeatable: record names are
    /// derived from the issue itself so a re-sent record is recognised rather
    /// than duplicated, and the merge is a union that cannot lose anything by
    /// running twice.
    @discardableResult
    public func run(progress: (@Sendable (SyncStage) -> Void)? = nil)
        async throws -> SyncOutcome {

        var outcome = SyncOutcome()

        // 1. What the other devices have said since this one last listened.
        //
        // Paged, because a first sync against an established account is the
        // whole library and the server hands it over in batches. The cursor is
        // written after every page: a sync that is interrupted at page four
        // resumes at page four rather than starting again.
        progress?(.asking)
        let startingFresh = try store.syncCursor() == nil
        var cursor = try store.syncCursor()
        var received = 0
        var anythingCameBack = false
        /// What the account already holds, as it holds it.
        ///
        /// Two things make this necessary, and only comparing the whole issue
        /// satisfies both.
        ///
        /// Everything the merge writes is a new local row with a new rowid,
        /// indistinguishable by rowid from something imported here — so
        /// without this a device joining an established account downloads the
        /// whole library and immediately uploads all of it back. Thousands of
        /// pointless writes on the one sync that is already the longest.
        ///
        /// But a device is also sent *its own* records back: the account's
        /// change feed does not know which device wrote what. So "skip
        /// anything whose name arrived" is wrong — it would refuse to publish
        /// a link added here to an issue this device sent last week. Skipping
        /// only what arrived *identical* to what would be sent says exactly
        /// the intended thing: there is nothing here the account has not got.
        ///
        /// Kept by value rather than by rowid on purpose: an import that lands
        /// while this is running is not in here, so it is still sent.
        var arrived: [String: SyncedIssue] = [:]
        while true {
            let changes = try await cloud.changes(since: cursor)
            if !changes.issues.isEmpty {
                received += changes.issues.count
                progress?(.receiving(issues: received))
                for issue in changes.issues { arrived[issue.recordName] = issue }
                outcome.merged.absorb(try store.merge(changes.issues))
            }
            // After the issues in the same page, so a pointer and the position
            // in it can arrive together and the position is not dropped for
            // want of a row that is landing in the same breath.
            if !changes.reading.isEmpty {
                outcome.readingApplied += try store.mergeReading(changes.reading)
            }
            // After the merges. A record deleted on another device may also be
            // sitting in this same page as a modification from before it went;
            // applying the removal last is what makes the order not matter.
            if !changes.deletedRecordNames.isEmpty {
                outcome.removed += try store.applyDeletions(changes.deletedRecordNames).count
            }
            if !changes.issues.isEmpty || !changes.deletedRecordNames.isEmpty {
                anythingCameBack = true
            }
            cursor = changes.cursor
            try store.setSyncCursor(cursor)
            guard changes.more else { break }
        }

        // 2. What this device has that the account has not heard.
        //
        // The marks are read before the export rather than after it. An import
        // that lands while this is running has a higher rowid than the mark
        // being saved, so it is sent now *and* offered again next time — which
        // costs one duplicate save and cannot lose the import. The other order
        // would record it as sent while it was still on its way.
        // An account that answers a *full* read with nothing, to a device that
        // believes it has already sent thousands of records, is not the
        // account this device was talking to.
        //
        // The case that matters is shipping: a development build and a release
        // build use two separate CloudKit databases, and switching between
        // them does not touch the marks kept here. Without this, the first
        // App Store build would find its marks saying everything had been sent,
        // send nothing, and leave the reader with a library that syncs in
        // perfect silence and never uploads. Clearing an account's iCloud data
        // by hand lands in the same place.
        //
        // Only on a full read, so an ordinary "nothing has changed" — which is
        // almost every sync — is never mistaken for it.
        if startingFresh, !anythingCameBack, try store.syncMarks() != Store.SyncMarks() {
            try store.setSyncMarks(Store.SyncMarks())
            try store.setReadingMark(nil)
        }

        let sent = try store.currentSyncMarks()
        let marks = try store.syncMarks()
        let pending = try store.exportableIssues(afterIssue: marks.issue,
                                                 afterMirror: marks.mirror)
            .filter { arrived[$0.recordName] != $0 }
        if !pending.isEmpty {
            progress?(.sending(issues: pending.count))
            try await cloud.save(pending)
            outcome.pushed = pending.count
        }
        try store.setSyncMarks(sent)

        // 3. Where this device has got to.
        //
        // After the pointers, for the reason the merge above takes them in
        // that order: a position is about a row, and the row should be there
        // first. Marked by time rather than by rowid — reading moves on issues
        // that are years old, which is the normal case rather than the edge.
        let readingNow = try store.latestReadingChange()
        let unsent = try store.exportableReading(since: try store.readingMark())
        if !unsent.isEmpty {
            progress?(.sending(issues: unsent.count))
            try await cloud.saveReading(unsent)
            outcome.readingPushed = unsent.count
        }
        if let readingNow { try store.setReadingMark(readingNow) }

        // 4. What this device has thrown away.
        //
        // Last, so a device that deletes an issue and re-imports it in the same
        // sitting sends the pointer first and the removal after — which is the
        // order they happened in, and the order that leaves the account
        // agreeing with this device rather than with neither.
        let gone = try store.pendingDeletions()
        if !gone.isEmpty {
            try await cloud.delete(gone)
            try store.clearDeletions(gone)
        }

        return outcome
    }

    /// Starts again from nothing, as though this device had never synced.
    ///
    /// Re-sends the whole exportable library and re-reads the whole account.
    /// Both sides merge by union, so this cannot lose anything — it is the way
    /// back from a library that has drifted, and the only way to publish a
    /// change to an issue that was sent long ago.
    @discardableResult
    public func resync(progress: (@Sendable (SyncStage) -> Void)? = nil)
        async throws -> SyncOutcome {
        try store.forgetSyncState()
        try store.setReadingMark(nil)
        return try await run(progress: progress)
    }
}

extension SyncMergeReport {
    /// Folds another merge's counts into this one, so a paged fetch reports
    /// one total rather than the last page's.
    mutating func absorb(_ other: SyncMergeReport) {
        added += other.added
        enriched += other.enriched
        mirrors += other.mirrors
        declined += other.declined
    }
}

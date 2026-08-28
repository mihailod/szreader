import Foundation
import CloudKit

/// The library of pointers, kept in the reader's own iCloud.
///
/// The private database, so every record is theirs: it counts against their
/// storage, it is readable by nobody else, and this app never sees it. At
/// roughly two hundred bytes an issue a large library is a megabyte or two,
/// which is why this is worth doing at all.
///
/// A **custom zone**, not the default one, and that is not a preference. Only
/// a custom zone can be asked "what changed since this token", and that
/// question is the whole design: it makes the check on every foreground one
/// cheap round trip that usually answers "nothing", and it is the only way a
/// deletion can ever be told apart from an absence.
public struct CloudKitLibrary: LibraryCloud {

    /// Registered on the App ID, and a one-way door once shipped: change it
    /// and every reader's library is orphaned in a container nothing reads.
    public static let containerID = "iCloud.com.mihailod.szreader"

    static let zoneName = "library"
    static let recordType = "Issue"
    static let readingType = "Reading"

    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID

    public init(containerID: String = CloudKitLibrary.containerID) {
        let container = CKContainer(identifier: containerID)
        database = container.privateCloudDatabase
        zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
    }

    /// Makes sure the zone exists.
    ///
    /// Cheap and idempotent — creating a zone that is already there is not an
    /// error — so this is simply done before anything that needs it rather
    /// than remembered in a flag that could be wrong.
    private func ensureZone() async throws {
        _ = try? await database.modifyRecordZones(
            saving: [CKRecordZone(zoneID: zoneID)], deleting: [])
    }

    // MARK: - Reading

    public func changes(since cursor: SyncCursor?) async throws -> CloudChanges {
        try await ensureZone()
        do {
            return try await fetch(since: cursor.flatMap(Self.token(from:)))
        } catch let error as CKError where error.code == .changeTokenExpired {
            // The server has forgotten the bookmark, which it is entitled to
            // do. Starting over is safe and is the only way forward: the merge
            // is a union, so re-reading the whole account costs time and
            // changes nothing.
            return try await fetch(since: nil)
        } catch let error as CKError where error.code == .zoneNotFound
                                        || error.code == .userDeletedZone {
            // Nobody has ever written here, or the reader has cleared their
            // iCloud data. Either way there is nothing to take, and this
            // device's own library will be sent up next.
            return CloudChanges(issues: [], cursor: nil)
        }
    }

    private func fetch(since token: CKServerChangeToken?) async throws -> CloudChanges {
        let result = try await database.recordZoneChanges(inZoneWith: zoneID, since: token)

        var issues: [SyncedIssue] = []
        var reading: [SyncedReading] = []
        for change in result.modificationResultsByID.values {
            // A record that fails to decode is skipped rather than thrown on.
            // It means a later build of the app wrote something this one does
            // not understand, and refusing the whole page would leave an older
            // device unable to sync anything at all.
            guard let record = try? change.get().record else { continue }
            switch record.recordType {
            case Self.recordType:
                if let issue = Self.issue(from: record) { issues.append(issue) }
            case Self.readingType:
                if let state = Self.reading(from: record) { reading.append(state) }
            default:
                // A type a later build invented. Skipped rather than thrown
                // on, so one new record type cannot stop an older device
                // syncing anything at all.
                continue
            }
        }

        return CloudChanges(
            issues: issues,
            reading: reading,
            deletedRecordNames: result.deletions.map(\.recordID.recordName),
            cursor: Self.cursor(from: result.changeToken),
            more: result.moreComing)
    }

    // MARK: - Writing

    public func save(_ issues: [SyncedIssue]) async throws {
        try await ensureZone()
        // CloudKit takes 400 records to a request. Sent in chunks rather than
        // atomically: a first sync is thousands of records, and one failure
        // rolling back the lot would mean it never completed on a connection
        // that drops. Every chunk that lands is progress the next run keeps,
        // because a record's name is derived from the issue itself.
        try await write(issues.map { Self.record(for: $0, in: zoneID) })
    }

    /// Sends records, and actually looks at what came back.
    ///
    /// `modifyRecords(atomically: false)` throws only when the whole request
    /// fails. Anything the server refuses one record at a time comes back
    /// inside `saveResults` — so discarding that value, which is the obvious
    /// thing to write, makes every per-record rejection silent and reports the
    /// save as a success. That is exactly how reading positions came to stop
    /// syncing with nothing anywhere saying so.
    ///
    /// The rejection worth handling by name is `serverRecordChanged`. Every
    /// record here is built from scratch and so carries no change tag, and
    /// CloudKit will not let a tagless record overwrite one that already
    /// exists — it cannot know the writer ever saw it. A first save creates
    /// the record and succeeds; every save after that is refused.
    ///
    /// Which is why this surfaced on reading state and not on pointers: a
    /// pointer is written once and rarely again, while a position is the same
    /// record rewritten every time the reader turns a page.
    ///
    /// The fix is the one CloudKit intends: take the server's own copy out of
    /// the error, put this device's values onto it — so it keeps the tag that
    /// proves it is current — and send it back. Last writer wins, which is the
    /// rule reading state merges by anyway.
    private func write(_ records: [CKRecord]) async throws {
        // 400 to a request, and not atomic: a first sync is thousands of
        // records, and one failure rolling back the lot would mean it never
        // completed on a connection that drops.
        for chunk in stride(from: 0, to: records.count, by: 400).map({
            Array(records[$0..<min($0 + 400, records.count)])
        }) {
            let results = try await database.modifyRecords(
                saving: chunk, deleting: [], savePolicy: .allKeys, atomically: false)

            var retries: [CKRecord] = []
            var refusal: Error?
            for (id, result) in results.saveResults {
                guard case .failure(let error) = result else { continue }
                guard let conflict = error as? CKError,
                      conflict.code == .serverRecordChanged,
                      let current = conflict.serverRecord,
                      let mine = chunk.first(where: { $0.recordID == id }) else {
                    refusal = refusal ?? error
                    continue
                }
                for key in mine.allKeys() { current[key] = mine[key] }
                retries.append(current)
            }

            if !retries.isEmpty {
                let second = try await database.modifyRecords(
                    saving: retries, deleting: [], savePolicy: .allKeys, atomically: false)
                for (_, result) in second.saveResults {
                    if case .failure(let error) = result { refusal = refusal ?? error }
                }
            }
            // Reported rather than swallowed. A sync that failed changes
            // nothing and the next foreground tries again — but the reader is
            // told, instead of watching a device quietly disagree for ever.
            if let refusal { throw refusal }
        }
    }

    // MARK: - Records

    /// Static, and taking the zone rather than reading it from `self`.
    ///
    /// Building a record needs no container, no account and no network — only
    /// sending one does. Keeping it free of the container is what lets the
    /// half that can silently drop a field be tested at all: constructing a
    /// `CKContainer` for an identifier the running binary is not entitled to
    /// traps the process.
    static func record(for issue: SyncedIssue, in zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: issue.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: Self.recordType, recordID: id)
        record["site"] = issue.site.rawValue as CKRecordValue
        record["code"] = issue.code as CKRecordValue?
        record["number"] = issue.number as CKRecordValue?
        record["numberTo"] = issue.numberTo as CKRecordValue?
        record["title"] = issue.title as CKRecordValue?
        record["titleFolded"] = issue.titleFolded as CKRecordValue
        record["series"] = issue.series as CKRecordValue?
        record["style"] = issue.style.rawValue as CKRecordValue
        record["source"] = issue.source as CKRecordValue?
        record["context"] = issue.context as CKRecordValue?
        record["coverURL"] = issue.coverURL as CKRecordValue?
        record["hero"] = issue.hero as CKRecordValue?
        record["edition"] = issue.edition as CKRecordValue?
        record["publisher"] = issue.publisher as CKRecordValue?
        record["pageCount"] = issue.pageCount as CKRecordValue?
        record["catalogueCode"] = issue.catalogueCode as CKRecordValue?
        record["catalogueNumber"] = issue.catalogueNumber as CKRecordValue?
        // One field rather than five parallel arrays. An issue has one or two
        // links and they belong together; keeping them as arrays that must
        // stay the same length is a bug waiting to be written.
        record["mirrors"] = (try? JSONEncoder().encode(issue.mirrors)) as CKRecordValue?
        return record
    }

    static func issue(from record: CKRecord) -> SyncedIssue? {
        guard let siteName = record["site"] as? String,
              let site = IssueSite(rawValue: siteName),
              let folded = record["titleFolded"] as? String else { return nil }
        let mirrors = (record["mirrors"] as? Data)
            .flatMap { try? JSONDecoder().decode([SyncedMirror].self, from: $0) } ?? []
        return SyncedIssue(
            site: site,
            code: record["code"] as? String,
            number: record["number"] as? Int,
            numberTo: record["numberTo"] as? Int,
            title: record["title"] as? String,
            titleFolded: folded,
            series: record["series"] as? String,
            style: LabelStyle(rawValue: record["style"] as? String ?? "") ?? .labeledBlock,
            source: record["source"] as? String,
            context: record["context"] as? String,
            coverURL: record["coverURL"] as? String,
            hero: record["hero"] as? String,
            edition: record["edition"] as? String,
            publisher: record["publisher"] as? String,
            pageCount: record["pageCount"] as? Int,
            catalogueCode: record["catalogueCode"] as? String,
            catalogueNumber: record["catalogueNumber"] as? Int,
            mirrors: mirrors)
    }

    // MARK: - The bookmark

    static func cursor(from token: CKServerChangeToken?) -> SyncCursor? {
        guard let token,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                           requiringSecureCoding: true)
        else { return nil }
        return SyncCursor(data: data)
    }

    static func token(from cursor: SyncCursor) -> CKServerChangeToken? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self,
                                                from: cursor.data)
    }
}

/// Whether this device can sync at all.
///
/// Not an error worth showing: a reader who is not signed into iCloud has a
/// perfectly good library that simply stays here, which is exactly what the
/// app did before any of this existed.
public enum CloudAvailability {
    public static func isSignedIn(containerID: String = CloudKitLibrary.containerID)
        async -> Bool {
        let status = try? await CKContainer(identifier: containerID).accountStatus()
        return status == .available
    }
}


// MARK: - Reading positions

extension CloudKitLibrary {

    public func saveReading(_ states: [SyncedReading]) async throws {
        try await ensureZone()
        try await write(states.map { Self.record(for: $0, in: zoneID) })
    }

    /// The identity travels as its five terms rather than only as the hashed
    /// name. The name is a digest and cannot be read backwards, and a device
    /// receiving a position has to be able to look up the row it belongs to.
    static func record(for state: SyncedReading, in zoneID: CKRecordZone.ID) -> CKRecord {
        let id = CKRecord.ID(recordName: state.recordName, zoneID: zoneID)
        let record = CKRecord(recordType: Self.readingType, recordID: id)
        record["site"] = state.identity.site.rawValue as CKRecordValue
        record["code"] = state.identity.code as CKRecordValue
        record["number"] = state.identity.number as CKRecordValue
        record["titleFolded"] = state.identity.titleFolded as CKRecordValue
        record["series"] = state.identity.series as CKRecordValue
        record["readAt"] = state.readAt as CKRecordValue?
        record["startedAt"] = state.startedAt as CKRecordValue?
        record["openedAt"] = state.openedAt as CKRecordValue?
        record["lastPage"] = state.lastPage as CKRecordValue?
        record["modifiedAt"] = state.modifiedAt as CKRecordValue
        return record
    }

    static func reading(from record: CKRecord) -> SyncedReading? {
        guard let siteName = record["site"] as? String,
              let site = IssueSite(rawValue: siteName),
              let folded = record["titleFolded"] as? String,
              let modified = record["modifiedAt"] as? Date else { return nil }
        return SyncedReading(
            identity: IssueIdentity(site: site,
                                    code: record["code"] as? String,
                                    number: record["number"] as? Int,
                                    titleFolded: folded,
                                    series: record["series"] as? String),
            readAt: record["readAt"] as? Date,
            startedAt: record["startedAt"] as? Date,
            openedAt: record["openedAt"] as? Date,
            lastPage: record["lastPage"] as? Int,
            modifiedAt: modified)
    }
}

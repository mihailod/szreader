import XCTest
import CloudKit
@testable import SZKit

/// How an issue is written into a CloudKit record and read back.
///
/// No account and no network: building a `CKRecord` and reading its fields is
/// local, so the part of the transport that can silently lose a field is
/// testable and the part that needs iCloud is a thin shell around it.
final class CloudKitRecordTests: XCTestCase {

    private func issue(
        code: String? = "MN_LMS_511", number: Int? = 511, numberTo: Int? = 512,
        title: String? = "Nasilje u Darkvudu", series: String? = "LMS",
        coverURL: String? = "https://example.invalid/c.jpg",
        mirrors: [SyncedMirror] = [
            SyncedMirror(url: "http://mediafire.com/?K", host: "mediafire.com",
                         ordinal: 0, filename: "zagor.cbr", size: 90_112),
            SyncedMirror(url: "https://mega.nz/file/X#Y", host: "mega.nz", ordinal: 1),
        ]) -> SyncedIssue {
        SyncedIssue(site: .stripzona, code: code, number: number, numberTo: numberTo,
                    title: title, titleFolded: "nasilje u darkvudu", series: series,
                    style: .labeledBlock, source: "webview import",
                    context: "Zagor ZLATNA SERIJA", coverURL: coverURL,
                    hero: "Zagor", edition: "Lunov Magnus Strip", publisher: "BONELLI",
                    pageCount: 94, catalogueCode: "SS", catalogueNumber: 305,
                    mirrors: mirrors)
    }

    /// No container is constructed anywhere here — see `CloudKitLibrary
    /// .record(for:in:)`, which is static for exactly this reason.
    private static let zone = CKRecordZone.ID(zoneName: CloudKitLibrary.zoneName,
                                              ownerName: CKCurrentUserDefaultName)

    private func roundTrip(_ issue: SyncedIssue) throws -> SyncedIssue {
        let record = CloudKitLibrary.record(for: issue, in: Self.zone)
        return try XCTUnwrap(CloudKitLibrary.issue(from: record))
    }

    /// Every field survives, or an issue quietly loses something each time it
    /// crosses between devices.
    func testAnIssueSurvivesTheRecord() throws {
        let original = issue()
        XCTAssertEqual(try roundTrip(original), original)
    }

    /// Nil is not the empty string, and an absent number is not zero: the
    /// identity is built from these, so a nil that comes back as "" is a
    /// different issue.
    func testAbsentFieldsComeBackAbsent() throws {
        let sparse = issue(code: nil, number: nil, numberTo: nil,
                           title: nil, series: nil, coverURL: nil, mirrors: [])
        let back = try roundTrip(sparse)
        XCTAssertNil(back.code)
        XCTAssertNil(back.number)
        XCTAssertNil(back.title)
        XCTAssertNil(back.series)
        XCTAssertTrue(back.mirrors.isEmpty)
        XCTAssertEqual(back, sparse)
    }

    /// The name is the identity's, so the record a device writes for an issue
    /// is the record another device writes for the same issue.
    func testTheRecordIsNamedByIdentity() throws {
        let one = issue()
        XCTAssertEqual(try roundTrip(one).recordName, one.recordName)
    }

    /// A record from a later build carrying fields this one does not know is
    /// read for what it does know, not refused — otherwise one new field would
    /// stop an older device syncing at all.
    func testARecordMissingItsCoreFieldsIsSkippedNotCrashed() throws {
        let record = CKRecord(recordType: CloudKitLibrary.recordType)
        record["title"] = "orphan" as CKRecordValue
        XCTAssertNil(CloudKitLibrary.issue(from: record))
    }
}

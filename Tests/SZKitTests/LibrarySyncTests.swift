import XCTest
@testable import SZKit

/// Carrying the pointers between one reader's devices.
///
/// The shape of the problem: an iPad holds a set of imported issues, an iPhone
/// holds a different set, and switching sync on must leave both holding the
/// union with nothing lost on either side. Downloads are not part of it — the
/// archives are third-party files, excluded from backup deliberately, and what
/// travels is a few hundred bytes saying where an issue can be got.
final class LibrarySyncTests: XCTestCase {

    /// A library with issues brought in by hand, as a forum import makes them.
    private func imported(_ html: String) throws -> Store {
        let store = try Store()
        try store.ingest(html: html)
        return store
    }

    private static let padPage = """
        <title>Zagor - ZLATNA SERIJA - ZS i LMS - Stripzona</title>
        <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
        <div>017-Klark siti</div><div>http://www.mediafire.com/?FAKEKEY017</div>
        """

    private static let phonePage = """
        <title>Mister No - LUNOV MAGNUS STRIP - Stripzona</title>
        <div>021-Kuca uzasa</div><div>http://www.mediafire.com/?FAKEKEY021</div>
        <div>025-Zeleni pakao</div><div>http://www.mediafire.com/?FAKEKEY025</div>
        """

    private func titles(_ store: Store) throws -> [String] {
        try store.recent(limit: nil).compactMap(\.title).sorted()
    }

    // MARK: - Identity

    /// Two devices that imported the same page independently have to arrive at
    /// the same name for the same issue, or the union doubles the shelf.
    func testTheSameIssueOnTwoDevicesHasTheSameRecordName() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.padPage)

        let a = try pad.exportableIssues().map(\.recordName).sorted()
        let b = try phone.exportableIssues().map(\.recordName).sorted()

        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a).count, a.count, "two issues share one name")
    }

    /// The identity is the natural key's, so anything the database keeps apart
    /// stays apart. Site is in it because two archives are two namespaces:
    /// RetroSpec's Galaksija and StripZona's are different magazines.
    func testIssuesThatDifferInAnyKeyTermGetDifferentNames() throws {
        let base = IssueIdentity(site: .stripzona, code: "MN_LMS_511", number: 511,
                                 titleFolded: "nasilje", series: "LMS")
        let variants = [
            IssueIdentity(site: .retrospec, code: "MN_LMS_511", number: 511,
                          titleFolded: "nasilje", series: "LMS"),
            IssueIdentity(site: .stripzona, code: "MN_LMS_512", number: 511,
                          titleFolded: "nasilje", series: "LMS"),
            IssueIdentity(site: .stripzona, code: "MN_LMS_511", number: 512,
                          titleFolded: "nasilje", series: "LMS"),
            IssueIdentity(site: .stripzona, code: "MN_LMS_511", number: 511,
                          titleFolded: "klark", series: "LMS"),
            IssueIdentity(site: .stripzona, code: "MN_LMS_511", number: 511,
                          titleFolded: "nasilje", series: "ZS"),
        ]
        let names = Set(variants.map(\.recordName) + [base.recordName])
        XCTAssertEqual(names.count, variants.count + 1)
    }

    /// Two different issues collide the moment a term can contain the
    /// separator: ("a", "b<sep>c") and ("a<sep>b", "c") join to the same
    /// string. This is a property of joining fields at all, and it is why the
    /// *choice* of separator is the whole safety of the scheme.
    func testTermsHoldingTheSeparatorWouldCollide() throws {
        let sep = IssueIdentity.separator
        let left = IssueIdentity(site: .stripzona, code: "", number: -1,
                                 titleFolded: "a", series: "b\(sep)c")
        let right = IssueIdentity(site: .stripzona, code: "", number: -1,
                                  titleFolded: "a\(sep)b", series: "c")
        XCTAssertEqual(left.key, right.key,
                       "if these ever differ the join has gained a length prefix "
                     + "and the separator no longer has to be unforgeable")
    }

    /// So the separator has to be a byte that cannot reach any of these
    /// fields. They hold a site's raw value, a forum code, a number, a folded
    /// title and a series name — all of them text a human typed or a parser
    /// read off a page, and none of which can carry a C0 control character.
    ///
    /// A printable separator — "|", ":", "-" — appears in real titles, and the
    /// collision above stops being theoretical.
    func testTheSeparatorCannotOccurInAnyTerm() throws {
        let scalars = IssueIdentity.separator.unicodeScalars
        XCTAssertEqual(scalars.count, 1)
        let value = try XCTUnwrap(scalars.first).value
        XCTAssertLessThan(value, 0x20, "the separator is printable and can occur in a title")
        XCTAssertNotEqual(value, 0x09, "tab occurs in scraped text")
        XCTAssertNotEqual(value, 0x0A, "newline occurs in scraped text")
        XCTAssertNotEqual(value, 0x0D, "carriage return occurs in scraped text")
    }

    /// And nothing in a real library carries it. Checked against every term
    /// the shelf actually holds rather than argued from first principles.
    func testNoRealFieldContainsTheSeparator() throws {
        let store = try imported(Self.padPage)
        try store.seedCatalogue(for: .retrospec)
        let sep = IssueIdentity.separator

        for issue in try store.recent(limit: nil) {
            for term in [issue.code, issue.title, issue.series, issue.hero,
                         issue.edition, issue.publisher, issue.site.rawValue] {
                XCTAssertFalse(term?.contains(sep) ?? false, "\(term ?? "") holds the separator")
            }
        }
    }

    /// Missing values use the index's own sentinels, so an issue with no code
    /// is the same issue whichever device describes it.
    func testAbsentTermsMatchTheIndexSentinels() throws {
        let absent = IssueIdentity(site: .stripzona, code: nil, number: nil,
                                   titleFolded: "x", series: nil)
        let spelled = IssueIdentity(site: .stripzona, code: "", number: -1,
                                    titleFolded: "x", series: "")
        XCTAssertEqual(absent.recordName, spelled.recordName)
    }

    // MARK: - What travels

    /// Nine rows in ten come from a catalogue inside the app and are rebuilt
    /// by a switch. Sending them would be tens of thousands of records to
    /// reconstruct what a boolean reconstructs.
    func testCatalogueRowsAreNotExported() throws {
        let store = try imported(Self.padPage)
        let seeded = try store.seedCatalogue(for: .retrospec)
        XCTAssertGreaterThan(seeded.inserted, 100, "the catalogue did not load")

        let exported = try store.exportableIssues()

        XCTAssertEqual(exported.count, 2, "a catalogue row was offered for sync")
        XCTAssertTrue(exported.allSatisfy { $0.site == .stripzona })
    }

    /// The reader's own files are the folder on the device. A row synced from
    /// elsewhere would be deleted by the next folder scan.
    func testLocalFilesAreNotExported() throws {
        let store = try Store()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data(repeating: 0x41, count: 32)
            .write(to: folder.appendingPathComponent("029 Brodeckov izvjestaj.cbr"))
        try store.reconcileLocalFiles(LocalFiles.scan(folder))
        XCTAssertEqual(store.issueCount, 1, "the premise: the folder made a row")

        XCTAssertEqual(try store.exportableIssues().count, 0)
    }

    /// The links are the point of the exercise: an issue without them is a
    /// title the other device cannot fetch.
    func testExportCarriesTheLinks() throws {
        let store = try imported(Self.padPage)
        let issue = try XCTUnwrap(try store.exportableIssues()
            .first { $0.title?.contains("Nasilje") == true })
        XCTAssertEqual(issue.mirrors.map(\.url), ["http://www.mediafire.com/?FAKEKEY013"])
    }

    // MARK: - The union

    /// The whole point, in one test: A ∪ B, both ways, nothing lost.
    func testTwoDevicesEndUpWithTheUnionOfBoth() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.phonePage)

        let fromPad = try pad.exportableIssues()
        let fromPhone = try phone.exportableIssues()
        try pad.merge(fromPhone)
        try phone.merge(fromPad)

        let expected = ["Klark siti", "Kuca uzasa", "Nasilje u Darkvudu", "Zeleni pakao"]
        XCTAssertEqual(try titles(pad), expected)
        XCTAssertEqual(try titles(phone), expected)
    }

    /// And the issues that crossed are usable, not just present.
    func testIssuesThatArriveBringTheirLinks() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.phonePage)
        try pad.merge(try phone.exportableIssues())

        let arrived = try XCTUnwrap(try pad.recent(limit: nil)
            .first { $0.title == "Kuca uzasa" })
        XCTAssertEqual(try pad.mirrors(forIssue: arrived.id).map(\.url),
                       ["http://www.mediafire.com/?FAKEKEY021"])
    }

    /// An issue that arrives has to be findable by typing its name — FTS is a
    /// virtual table maintained by hand, and a row inserted without it is on
    /// the shelf and invisible to search.
    func testIssuesThatArriveAreSearchable() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.phonePage)
        try pad.merge(try phone.exportableIssues())

        XCTAssertEqual(try pad.search("kuca").compactMap(\.title), ["Kuca uzasa"])
    }

    /// Merging is idempotent: the same set twice is the same library. Sync
    /// retries, resumes after being backgrounded, and re-runs on every
    /// foreground, so this is the ordinary case and not an edge one.
    func testMergingTheSameSetTwiceChangesNothing() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.phonePage)
        let arriving = try phone.exportableIssues()

        let first = try pad.merge(arriving)
        let second = try pad.merge(arriving)

        XCTAssertEqual(first.added, 2)
        XCTAssertEqual(second.added, 0, "a second merge duplicated the shelf")
        XCTAssertEqual(second.mirrors, 0)
        XCTAssertTrue(second.isEmpty)
        XCTAssertEqual(pad.issueCount, 4)
    }

    /// Both devices holding the same issue is the normal case once sync has
    /// been running, and it must not become two.
    func testAnIssueBothDevicesAlreadyHaveIsNotDuplicated() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.padPage)

        let report = try pad.merge(try phone.exportableIssues())

        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(pad.issueCount, 2)
    }

    // MARK: - Merging into a row that is already here

    /// A device that knows less must not be able to blank a field by not
    /// knowing it.
    func testAnArrivingIssueCannotOverwriteWhatIsAlreadyKnown() throws {
        let pad = try imported(Self.padPage)
        let target = try XCTUnwrap(try pad.recent(limit: nil).first)
        try pad.setCoverURL("https://example.invalid/real-cover.jpg", issueID: target.id)

        let blank = try XCTUnwrap(try imported(Self.padPage).exportableIssues()
            .first { $0.titleFolded == Fold.fold(target.title ?? "") })
        XCTAssertNil(blank.coverURL, "the premise: the other device knows no cover")
        try pad.merge([blank])

        XCTAssertEqual(try pad.coverURL(forIssue: target.id),
                       "https://example.invalid/real-cover.jpg")
    }

    /// And a blank here is filled by a device that does know.
    func testAnArrivingIssueFillsInABlank() throws {
        let pad = try imported(Self.padPage)
        let phone = try imported(Self.padPage)
        let known = try XCTUnwrap(try phone.recent(limit: nil).first)
        try phone.setCoverURL("https://example.invalid/found.jpg", issueID: known.id)

        let report = try pad.merge(try phone.exportableIssues())

        let here = try XCTUnwrap(try pad.recent(limit: nil)
            .first { $0.title == known.title })
        XCTAssertEqual(try pad.coverURL(forIssue: here.id), "https://example.invalid/found.jpg")
        XCTAssertEqual(report.enriched, 1)
        XCTAssertEqual(report.added, 0)
    }

    /// A second link for an issue both devices have is worth having: links rot,
    /// and the alternate scan is there precisely for that.
    func testLinksArePooledOntoAnIssueBothDevicesHave() throws {
        let pad = try imported("""
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        let phone = try imported("""
            <title>Zagor - ZLATNA SERIJA - Stripzona</title>
            <div>013-Nasilje u Darkvudu</div>
            <div>https://mega.nz/file/OTHERID#OTHERKEY</div>
            """)

        let report = try pad.merge(try phone.exportableIssues())

        let issue = try XCTUnwrap(try pad.recent(limit: nil).first)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(report.mirrors, 1)
        XCTAssertEqual(try pad.mirrors(forIssue: issue.id).count, 2)
    }

    // MARK: - What it refuses

    /// A device exporting things it should not must not be able to write them
    /// here. Declining is counted rather than silent: a number above zero
    /// means some other device is misbehaving and this is where it shows.
    func testACatalogueRowOfferedByAnotherDeviceIsDeclined() throws {
        let store = try Store()
        let offered = SyncedIssue(
            site: .retrospec, code: nil, number: 12, numberTo: nil,
            title: "Galaksija", titleFolded: "galaksija", series: "Galaksija",
            style: .labeledBlock, source: Store.catalogueSource(for: .retrospec),
            context: nil, coverURL: nil, hero: nil, edition: nil, publisher: nil,
            pageCount: nil, catalogueCode: nil, catalogueNumber: nil, mirrors: [])

        let report = try store.merge([offered])

        XCTAssertEqual(report.declined, 1)
        XCTAssertEqual(report.added, 0)
        XCTAssertEqual(store.issueCount, 0)
    }

    func testALocalFileOfferedByAnotherDeviceIsDeclined() throws {
        let store = try Store()
        let offered = SyncedIssue(
            site: .local, code: "029 Brodeckov.cbr", number: 29, numberTo: nil,
            title: "Brodeckov izvjestaj", titleFolded: "brodeckov izvjestaj",
            series: nil, style: .labeledBlock, source: nil, context: nil,
            coverURL: nil, hero: nil, edition: nil, publisher: nil,
            pageCount: nil, catalogueCode: nil, catalogueNumber: nil, mirrors: [])

        let report = try store.merge([offered])

        XCTAssertEqual(report.declined, 1)
        XCTAssertEqual(store.issueCount, 0)
    }

    // MARK: - Round trip

    /// Export and merge have to agree about every field, or an issue loses
    /// something each time it crosses between devices.
    func testAnIssueSurvivesTheCrossingIntact() throws {
        let pad = try imported(Self.padPage)
        let fresh = try Store()

        try fresh.merge(try pad.exportableIssues())

        let before = try pad.exportableIssues()
            .sorted { $0.recordName < $1.recordName }
        let after = try fresh.exportableIssues()
            .sorted { $0.recordName < $1.recordName }
        XCTAssertEqual(before, after)
    }
}

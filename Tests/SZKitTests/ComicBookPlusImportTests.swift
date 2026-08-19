import XCTest
@testable import SZKit

/// Reading a Comic Book Plus series page into the library.
///
/// The page fixture is the real `?cid=1751` markup, cut to what is read. It is
/// the useful shape rather than the simple one: three scans of a two-issue
/// series, two of which are the same issue by different members.
final class ComicBookPlusImportTests: XCTestCase {

    private func page(extraRow: String = "") -> String {
        """
        <h1>Adventures in 3-D</h1>
        <main itemscope itemtype="https://schema.org/BookSeries">
        <span itemprop="publisher" itemscope itemtype="https://schema.org/Organization">Published by:
        <a href="/?cid=825" itemprop="url"><span itemprop="name">Harvey Comics</span></a></span>
        <tr class="overrow" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">1</td>
        <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/1fb7fbddfbe79e7c3f2acd58b3db0acd/mediumthumb.jpg">
        <td class="n"><a href="/?dlid=21035" itemprop="url"><span itemprop="name">Adventures in 3-D 1</span></a></td>
        <td class="r"><time itemprop="datePublished" datetime="1953-11">Nov 1953</time></td><td class="r" itemprop="numberOfPages">37</td>
        <td class="l" itemprop="editor"><a href="/?cbplus=contributor_atomicsurgeon_s_s_0">Geo</a></td></tr>
        <tr class="overrow" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">1</td>
        <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/b7d8e24dcbcc56643684ceeea7fe064f/mediumthumb.jpg">
        <td class="n"><a href="/?dlid=79869" itemprop="url"><span itemprop="name">Adventures in 3-D 1 (Odell&#039;s)</span></a></td>
        <td class="r"><time itemprop="datePublished" datetime="1953-11">Nov 1953</time></td><td class="r" itemprop="numberOfPages">38</td>
        <td class="l" itemprop="editor"><a href="/?cbplus=contributor_titansfan_s_s_0">titansfan</a></td></tr>
        <tr class="overrow" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">2</td>
        <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/500f52e934ca1ca8e99c4f5ee8a77936/mediumthumb.jpg">
        <td class="n"><a href="/?dlid=25968" itemprop="url"><span itemprop="name">Adventures in 3-D 2</span></a></td>
        <td class="r"><time itemprop="datePublished" datetime="1954-01">Jan 1954</time></td><td class="r" itemprop="numberOfPages">36</td>
        <td class="l" itemprop="editor"><a href="/?cbplus=contributor_atomicsurgeon_s_s_0">Geo</a></td></tr>
        \(extraRow)
        """
    }

    /// A scan added to the series after the first visit.
    private let laterScan = """
    <tr class="overrow" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">2</td>
    <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/aa11bb22cc33dd44ee55ff6677889900/mediumthumb.jpg">
    <td class="n"><a href="/?dlid=99001" itemprop="url"><span itemprop="name">Adventures in 3-D 2 (rescan)</span></a></td>
    <td class="r"><time itemprop="datePublished" datetime="1954-01">Jan 1954</time></td><td class="r" itemprop="numberOfPages">40</td>
    <td class="l" itemprop="editor"><a href="/?cbplus=contributor_josemas_s_s_0">josemas</a></td></tr>
    """

    // MARK: - The import

    func testItImportsEveryScanOnThePage() throws {
        let store = try Store()
        let report = try store.importComicBookPlus(page: page())

        XCTAssertEqual(report.series, "Adventures in 3-D")
        XCTAssertEqual(report.inserted, 3)
        XCTAssertEqual(report.updated, 0)
        XCTAssertEqual(store.issueCount, 3)
    }

    func testTheIssuesCarryTheSource() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let issues = try store.recent(limit: nil)
        XCTAssertEqual(issues.count, 3)
        for issue in issues { XCTAssertEqual(issue.site, .comicbookplus) }
    }

    /// The series names the shelf column and the filter menu; the publisher is
    /// the one the comic was printed under, not the site.
    func testItFilesTheSeriesAndThePrintPublisher() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        XCTAssertEqual(try store.editions(sites: [.comicbookplus]), ["Adventures in 3-D"])
        XCTAssertEqual(try store.publishers(sites: [.comicbookplus]), ["Harvey Comics"])
    }

    /// Two scans of issue one are two rows. They share a title stem, an issue
    /// number and a cover date, so any key but the site's own id folds them
    /// together and loses one.
    func testTwoScansOfOneIssueAreTwoRows() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())

        let issues = try store.recent(limit: nil)
        let ones = issues.filter { $0.number == 1 }
        XCTAssertEqual(ones.count, 2)
        XCTAssertEqual(Set(ones.map(\.code)), ["21035", "79869"])
    }

    // MARK: - Revisiting a series

    func testReimportingThePageAddsNothing() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let mirrors = store.mirrorCount

        let again = try store.importComicBookPlus(page: page())
        XCTAssertEqual(again.inserted, 0)
        XCTAssertEqual(again.updated, 3)
        XCTAssertEqual(store.issueCount, 3, "re-import duplicated issues")
        XCTAssertEqual(store.mirrorCount, mirrors, "re-import duplicated mirrors")
    }

    /// A series that has gained a scan since the last visit takes the new one
    /// and leaves the rest as they were.
    func testRevisitingPicksUpANewScan() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())

        let report = try store.importComicBookPlus(page: page(extraRow: laterScan))
        XCTAssertEqual(report.inserted, 1)
        XCTAssertEqual(report.updated, 3)
        XCTAssertEqual(store.issueCount, 4)
    }

    /// Re-importing must not disturb what the reader has done. This is the
    /// mistake the archive.org import documents having to be careful about,
    /// and it is worth a test rather than a comment.
    func testReimportKeepsWhereTheReaderStopped() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let issue = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })

        try store.setLastPage(12, issueID: issue.id)
        try store.importComicBookPlus(page: page(extraRow: laterScan))

        let after = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })
        XCTAssertEqual(after.lastPage, 12, "re-import reset the reading position")
    }

    // MARK: - The mirror

    /// The stable page address, never a download address.
    ///
    /// A real download URL carries a session token in its query string. One in
    /// this table would be a credential written into the library file, and a
    /// stale one within days.
    func testTheMirrorIsTheBookPageAndCarriesNoSession() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let issue = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })

        let mirrors = try store.liveMirrors(forIssue: issue.id)
        XCTAssertEqual(mirrors.count, 1)
        XCTAssertEqual(mirrors[0].url, "https://comicbookplus.com/?dlid=21035")
        XCTAssertFalse(mirrors[0].url.contains("sess"))
        XCTAssertFalse(mirrors[0].url.contains("dload"))
    }

    // MARK: - Covers

    /// Built from the file hash, not taken from the row.
    ///
    /// The listing states a `thumbnailUrl` of its own and that URL is dead —
    /// no shard directory, wrong host — so a row that trusted the page would
    /// carry a cover address that 404s, and `CoverStore` would mark it a dead
    /// cover permanently on the first shelf load.
    func testEveryImportedIssueGetsACover() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())

        for issue in try store.recent(limit: nil) {
            let cover = try XCTUnwrap(issue.coverURL, issue.title ?? issue.code ?? "?")
            XCTAssertTrue(cover.hasPrefix("https://box01.comicbookplus.com/viewer/"), cover)
            XCTAssertTrue(cover.hasSuffix("/largethumb.jpg"), cover)
        }
    }

    /// The shard directory, which is what the site's own stated address is
    /// missing and the reason it 404s.
    func testTheCoverAddressCarriesTheShardDirectory() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let issue = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })
        XCTAssertEqual(
            issue.coverURL,
            "https://box01.comicbookplus.com/viewer/1f/1fb7fbddfbe79e7c3f2acd58b3db0acd/largethumb.jpg")
    }

    /// A library imported before the address was right has no cover at all,
    /// and revisiting the series is how those get one.
    func testReimportBackfillsAMissingCover() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let issue = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })
        try store.db.run("UPDATE issue SET cover_url = NULL WHERE id = ?",
                         [.int(Int64(issue.id))])

        try store.importComicBookPlus(page: page())
        let after = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })
        XCTAssertNotNil(after.coverURL)
    }

    /// But never replaces one. A downloaded issue's cover is its own first
    /// page, which is better than any thumbnail the site has.
    func testReimportKeepsACoverItAlreadyHas() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let issue = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })
        try store.db.run("UPDATE issue SET cover_url = ? WHERE id = ?",
                         [.text("szpage:\(issue.id)"), .int(Int64(issue.id))])

        try store.importComicBookPlus(page: page())
        let after = try XCTUnwrap(try store.recent(limit: nil).first { $0.code == "21035" })
        XCTAssertEqual(after.coverURL, "szpage:\(issue.id)")
    }

    // MARK: - Pages that are not listings

    func testAPageThatListsNothingIsRefused() throws {
        let store = try Store()
        XCTAssertThrowsError(try store.importComicBookPlus(
            page: "<h1>About This Site</h1><table><tr><td>49,876 books</td></tr></table>"))
        XCTAssertEqual(store.issueCount, 0)
    }

    // MARK: - The wall between sources

    /// The shelf's whole source-switching contract, applied to the new one.
    func testItIsHiddenWithTheSourceSwitchedOff() throws {
        let store = try Store()
        try store.ingest(html: """
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            """)
        try store.importComicBookPlus(page: page())

        let forumOnly = try store.recent(limit: nil, sites: [.stripzona])
        XCTAssertFalse(forumOnly.isEmpty)
        XCTAssertTrue(forumOnly.allSatisfy { $0.site == .stripzona })
        XCTAssertTrue(try store.search("adventures", limit: nil, sites: [.stripzona]).isEmpty)
        XCTAssertEqual(try store.search("adventures", limit: nil,
                                        sites: [.comicbookplus]).count, 3)
    }

    /// The scanner's name is searchable without becoming a column.
    func testTheScannerIsSearchable() throws {
        let store = try Store()
        try store.importComicBookPlus(page: page())
        let found = try store.search("titansfan", limit: nil)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.code, "79869")
    }
}

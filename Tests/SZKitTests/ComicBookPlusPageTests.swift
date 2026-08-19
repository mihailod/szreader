import XCTest
@testable import SZKit

/// Reading a Comic Book Plus series page, which is the whole of the import.
///
/// The fixture is a real `?cid=1751` page cut down to what is read: the
/// heading, the publisher scope, and the three listing rows exactly as the
/// site serves them. Three rows is not a small sample here — it is the whole
/// series, and it happens to carry two of the shapes that matter: the same
/// issue number twice for two different scans, and a row credited to two
/// contributors.
final class ComicBookPlusPageTests: XCTestCase {

    // MARK: - Fixture

    private let head = """
    <h1>Adventures in 3-D</h1>
    <main itemscope itemtype="https://schema.org/BookSeries">
    <table><tr><td colspan="2" class="indexcardhead">Adventures in 3-D</td></tr>
    <tr><td class="d">Available Books:</td><td class="e">3 |
    <span itemprop="publisher" itemscope itemtype="https://schema.org/Organization">Published by:
    <a href="https://comicbookplus.com/?cid=825" itemprop="url"><span itemprop="name">Harvey Comics</span></a></span></td></tr></table>
    """

    /// The original scan.
    private let firstRow = """
    <tr class="overrow" onclick="mp('21035')" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">1</td>
    <td class="n">
    <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/1fb7fbddfbe79e7c3f2acd58b3db0acd/mediumthumb.jpg">
    <a href="/?dlid=21035"><img src="https://box01.comicbookplus.com/pagecount/1f/1fb7fbddfbe79e7c3f2acd58b3db0acd.png" alt="Adventures in 3-D 1" width="27" height="40"></a></td>
    <td class="n"><a href="/?dlid=21035" itemprop="url"><span itemprop="name">Adventures in 3-D 1</span></a></td>
    <td class="r"><time class="nofloat" itemprop="datePublished" datetime="1953-11"><a href="/?cbplus=yns_5311_0">Nov&nbsp;1953</a></time></td><td class="r" itemprop="numberOfPages">37</td>
    <td class="l" itemprop="editor"><a href="/?cbplus=contributor_atomicsurgeon_s_s_0">Geo</a></td>
    </tr>
    """

    /// A second scan of the same issue, by a different member. Same
    /// `position`, different `dlid`, different page count.
    private let secondRow = """
    <tr class="overrow" onclick="mp('79869')" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">1</td>
    <td class="n">
    <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/b7d8e24dcbcc56643684ceeea7fe064f/mediumthumb.jpg">
    <a href="/?dlid=79869"><img src="https://box01.comicbookplus.com/pagecount/b7/b7d8e24dcbcc56643684ceeea7fe064f.png" alt="Adventures in 3-D 1 (Odell&#039;s)" width="27" height="40"></a></td>
    <td class="n"><a href="/?dlid=79869" itemprop="url"><span itemprop="name">Adventures in 3-D 1 (Odell&#039;s)</span></a></td>
    <td class="r"><time class="nofloat" itemprop="datePublished" datetime="1953-11"><a href="/?cbplus=yns_5311_0">Nov&nbsp;1953</a></time></td><td class="r" itemprop="numberOfPages">38</td>
    <td class="l" itemprop="editor"><a href="/?cbplus=contributor_titansfan_s_s_0">titansfan</a></td>
    </tr>
    """

    /// Issue two, credited to two members.
    private let thirdRow = """
    <tr class="overrow" onclick="mp('25968')" itemprop="hasPart" itemscope itemtype="https://schema.org/Book"><td class="rl" itemprop="position">2</td>
    <td class="n">
    <meta itemprop="thumbnailUrl" content="https://box01.comicbookplus.com/viewer/500f52e934ca1ca8e99c4f5ee8a77936/mediumthumb.jpg">
    <a href="/?dlid=25968"><img src="https://box01.comicbookplus.com/pagecount/50/500f52e934ca1ca8e99c4f5ee8a77936.png" alt="Adventures in 3-D 2" width="27" height="40"></a></td>
    <td class="n"><a href="/?dlid=25968" itemprop="url"><span itemprop="name">Adventures in 3-D 2</span></a></td>
    <td class="r"><time class="nofloat" itemprop="datePublished" datetime="1954-01"><a href="/?cbplus=yns_5401_0">Jan&nbsp;1954</a></time></td><td class="r" itemprop="numberOfPages">36</td>
    <td class="l" itemprop="editor"><a href="/?cbplus=contributor_atomicsurgeon_s_s_0">Geo</a> | <a href="/?cbplus=contributor_josemas_s_s_0">josemas</a></td>
    </tr>
    """

    /// The "Latest Comics" widget, exactly as the site writes it — no
    /// microdata, but real `?dlid=` links and real file hashes.
    private let sidebarWidget = """
    <div class="Wwrapper"><table><tr><td class="Wtd">
    <a href="/?dlid=102336"><img src="/pagecount/a0/a088a0cb39d1d049753a45e841c90250.png" width="27" height="40" alt="tiny comicbook thumbnail"></a></td>
    <td class="Wtd"><a href="/?dlid=102336" class="Wanchor">Journey<br>Planet 95<br>155 pages</a></td></tr>
    <tr><td class="Wtd"><a href="/?dlid=102334"><img src="/pagecount/d1/d12ea352cfd29e1ed804e254c0411fa8.png" width="27" height="40" alt="tiny comicbook thumbnail"></a></td>
    <td class="Wtd"><a href="/?dlid=102334" class="Wanchor">Silberpfeil<br>Piccolo 16<br>36 pages</a></td></tr></table></div>
    """

    private var page: String { head + firstRow + secondRow + thirdRow }

    // MARK: - The whole page

    func testItReadsTheSeriesAndItsPublisher() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page))
        XCTAssertEqual(leaf.series, "Adventures in 3-D")
        XCTAssertEqual(leaf.publisher, "Harvey Comics")
        XCTAssertEqual(leaf.books.count, 3)
    }

    /// Every row, in the order the page lists them — which is reading order,
    /// and is not recoverable from the issue numbers alone here.
    func testItReadsEveryRowInOrder() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page))
        XCTAssertEqual(leaf.books.map(\.dlid), [21035, 79869, 25968])
    }

    // MARK: - One row

    func testItReadsWhatAnIssueNeeds() throws {
        let book = try XCTUnwrap(ComicBookPlusPage.book(from: firstRow))
        XCTAssertEqual(book.dlid, 21035)
        XCTAssertEqual(book.hash, "1fb7fbddfbe79e7c3f2acd58b3db0acd")
        XCTAssertEqual(book.title, "Adventures in 3-D 1")
        XCTAssertEqual(book.number, 1)
        XCTAssertEqual(book.pages, 37)
        XCTAssertEqual(book.year, 1953)
        XCTAssertEqual(book.month, 11)
        XCTAssertEqual(book.contributor, "Geo")
    }

    /// The hash is what the download is keyed on, and taking it off the
    /// listing row is the whole reason a series imports in one page load
    /// rather than forty.
    func testEveryRowCarriesItsFileHash() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page))
        XCTAssertEqual(leaf.books.map(\.hash), [
            "1fb7fbddfbe79e7c3f2acd58b3db0acd",
            "b7d8e24dcbcc56643684ceeea7fe064f",
            "500f52e934ca1ca8e99c4f5ee8a77936",
        ])
    }

    /// Two scans of issue one. The issue number does not tell them apart and
    /// is not meant to — `dlid` is the identity.
    func testTwoScansOfOneIssueAreTwoBooks() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(page))
        let issueOne = leaf.books.filter { $0.number == 1 }
        XCTAssertEqual(issueOne.count, 2)
        XCTAssertEqual(Set(issueOne.map(\.dlid)), [21035, 79869])
        XCTAssertEqual(Set(issueOne.map(\.pages)), [37, 38])
    }

    /// "Odell&#039;s" is what the site writes. A shelf entry spelling that out
    /// is the escaping leaking into the library.
    func testTitlesAreUnescaped() throws {
        let book = try XCTUnwrap(ComicBookPlusPage.book(from: secondRow))
        XCTAssertEqual(book.title, "Adventures in 3-D 1 (Odell's)")
    }

    /// A row can credit several scanners. The first is taken rather than the
    /// list joined: this becomes a shelf column, and "Geo | josemas" is not a
    /// name.
    func testItTakesTheFirstOfSeveralContributors() throws {
        let book = try XCTUnwrap(ComicBookPlusPage.book(from: thirdRow))
        XCTAssertEqual(book.contributor, "Geo")
    }

    /// A date the site knows only to the year would arrive without a month,
    /// and must not invent one.
    func testAYearOnlyDateHasNoMonth() throws {
        let row = firstRow.replacingOccurrences(of: #"datetime="1953-11""#,
                                                with: #"datetime="1953""#)
        let book = try XCTUnwrap(ComicBookPlusPage.book(from: row))
        XCTAssertEqual(book.year, 1953)
        XCTAssertNil(book.month)
    }

    // MARK: - Pages that are not listings

    /// Import is lit by this, so it has to agree with what the reader sees.
    func testALeafPageIsRecognised() {
        XCTAssertTrue(ComicBookPlusPage.isLeaf(page))
    }

    /// Every page on the site carries the same furniture — nav, index card and
    /// the sidebar widget — and all of it is tables. So a page that is not a
    /// listing is still full of `<tr>`, which is exactly what `isLeaf` has to
    /// not be fooled by.
    func testAPageWithNoListingIsNotALeaf() {
        let about = head + """
        <h1>About This Site</h1>
        <table><tr><td>Total:</td><td>49,876 books</td></tr>
        <tr><td>New:</td><td>192 books</td></tr></table>
        """ + sidebarWidget
        XCTAssertFalse(ComicBookPlusPage.isLeaf(about))
        XCTAssertNil(ComicBookPlusPage.leaf(about))
    }

    /// The "Latest Comics" sidebar as the site writes it today: `?dlid=` links
    /// and file hashes for fifteen books from unrelated series, sitting on
    /// every page including this one.
    ///
    /// Today it carries no microdata, so the `itemprop="name"` a book needs is
    /// what excludes it. That is worth pinning even though it is not the
    /// intended guard — see the test below for that one.
    func testTodaysSidebarWidgetIsNotImported() throws {
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(head + firstRow + sidebarWidget))
        XCTAssertEqual(leaf.books.map(\.dlid), [21035])
    }

    /// The same widget, if the site ever marks it up the way it marks up the
    /// listing — which is not far-fetched, given how thoroughly the rest of
    /// the page is annotated.
    ///
    /// Here every field a book needs is present and only the `overrow` class
    /// is missing, so this is the test that actually exercises the keying.
    /// Without it these fifteen books from other series would be filed under
    /// this page's series and publisher.
    func testAMicrodataSidebarWouldStillNotBeImported() throws {
        let annotated = """
        <div class="Wwrapper"><table><tr itemprop="hasPart" itemscope itemtype="https://schema.org/Book">
        <td class="rl" itemprop="position">95</td>
        <td class="Wtd"><a href="/?dlid=102336"><img src="/pagecount/a0/a088a0cb39d1d049753a45e841c90250.png" alt="tiny"></a></td>
        <td class="Wtd"><a href="/?dlid=102336" itemprop="url"><span itemprop="name">Journey Planet 95</span></a></td>
        <td class="r" itemprop="numberOfPages">155</td></tr></table></div>
        """
        let leaf = try XCTUnwrap(ComicBookPlusPage.leaf(head + firstRow + annotated))
        XCTAssertEqual(leaf.books.map(\.dlid), [21035])
        XCTAssertFalse(leaf.books.contains { $0.title == "Journey Planet 95" })
    }

    /// The app imports `document.documentElement.outerHTML`, whose serialiser
    /// writes double quotes whatever the site sent. Both forms have to parse —
    /// this is the mistake `AuthoritativePosts` records having already made.
    func testItReadsSingleQuotedAttributes() throws {
        let single = firstRow
            .replacingOccurrences(of: #"class="overrow""#, with: "class='overrow'")
            .replacingOccurrences(of: #"itemprop="position""#, with: "itemprop='position'")
            .replacingOccurrences(of: #"itemprop="name""#, with: "itemprop='name'")
        let book = try XCTUnwrap(ComicBookPlusPage.book(from: single))
        XCTAssertEqual(book.dlid, 21035)
        XCTAssertEqual(book.number, 1)
        XCTAssertEqual(book.title, "Adventures in 3-D 1")
    }

    // MARK: - Addresses

    /// The form recorded as a mirror: stable, and carrying no session.
    func testTheBookAddressIsTheStableOne() {
        XCTAssertEqual(ComicBookPlus.bookURL(dlid: 21035),
                       "https://comicbookplus.com/?dlid=21035")
    }
}

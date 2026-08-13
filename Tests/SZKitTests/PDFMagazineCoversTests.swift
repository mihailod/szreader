import XCTest
@testable import SZKit

/// The "- pdf" topics: a magazine's whole run posted as PDFs, with artwork
/// whose filenames name the issue from the front.
final class PDFMagazineCoversTests: XCTestCase {

    private static let pagesDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("spike/pages")

    private func html(_ name: String) throws -> String {
        try String(contentsOf: Self.pagesDir.appendingPathComponent(
            "\(name) - Casopisi - Stripzona.html"), encoding: .utf8)
    }

    /// The number is at the head of the filename, not the tail. The tail is
    /// the scanners' credit run, and reading that filed a whole magazine's
    /// art under issue 1.
    func testTheLeadingNumberNamesTheIssue() throws {
        let covers = Catalog.leadingNumberedCovers(
            in: #"<img src="https://i.postimg.cc/QtTx09W6/Galaksija-097-drazen23-Mick-RC-Mad-Mate-1.jpg">"#)
        XCTAssertEqual(covers.count, 1)
        XCTAssertEqual(covers[97]?.hasSuffix("Galaksija-097-drazen23-Mick-RC-Mad-Mate-1.jpg"), true)
        XCTAssertNil(covers[1])
    }

    /// A four-digit leading number is the year the magazine ran, not an issue.
    func testAYearIsNotAnIssueNumber() throws {
        XCTAssertTrue(Catalog.leadingNumberedCovers(
            in: #"<img src="https://i.postimg.cc/aB/Galaksija-1982-arhiva.jpg">"#).isEmpty)
    }

    /// Confined to the last path component, so a number in a directory above
    /// it is not read as the issue.
    ///
    /// The confinement is the `[^/…]` in the run after the number, not the
    /// `/` before the word: a directory that ends at a slash cannot reach the
    /// extension anyway. It takes a directory with something after the number
    /// — the shape of a host's own id — for the two to differ.
    func testANumberInTheDirectoryIsNotRead() throws {
        XCTAssertTrue(Catalog.leadingNumberedCovers(
            in: #"<img src="https://i.postimg.cc/Cover-12-hd/randomid.jpg">"#).isEmpty)
    }

    /// Where a page already had covers from a tier that was right, the
    /// leading reading has to agree with it rather than displace it.
    func testItAgreesWithThePagesThatWereAlreadyCorrect() throws {
        let saved = try FileManager.default.contentsOfDirectory(atPath: Self.pagesDir.path)
        for name in ["Dzudas", "Gigant"] {
            // Matched by fragment: the Gigant page's name carries a decomposed
            // "č" that does not survive being written out as a literal here.
            let file = try XCTUnwrap(saved.first { $0.hasPrefix(name) && $0.hasSuffix(".html") },
                                     name)
            let page = try String(contentsOf: Self.pagesDir.appendingPathComponent(file),
                                  encoding: .utf8)
            let leading = Catalog.leadingNumberedCovers(in: page)
            XCTAssertFalse(leading.isEmpty, name)
            for (number, url) in leading {
                XCTAssertEqual(Catalog.covers(in: page)[number], url,
                               "\(name) disagrees on issue \(number)")
            }
        }
    }

    func testEveryIssueOnThePDFPagesGetsItsCover() throws {
        for (page, count) in [("Alef - pdf", 26), ("Kosmoplov - pdf", 24)] {
            let store = try Store()
            _ = try store.ingest(html: try html(page))
            let rows = try store.recent(limit: nil)
            XCTAssertEqual(rows.count, count, page)
            XCTAssertEqual(rows.filter { $0.coverURL != nil }.count, count, page)
        }
    }

    /// The art and the issues are on different topics: Galaksija's run is
    /// spread over three "obrade" pages, and the page with the covers lists a
    /// different hundred of them.
    func testCoversReachIssuesListedOnAnotherPage() throws {
        let store = try Store()
        for n in 1...3 {
            let suffix = n == 1 ? "" : " - Page \(n)"
            _ = try store.ingest(html: try String(
                contentsOf: Self.pagesDir.appendingPathComponent(
                    "Kosmoplov i Galaksija - obrade\(suffix) - Casopisi - Stripzona.html"),
                encoding: .utf8))
        }
        let before = try store.recent(limit: nil).filter { $0.edition == "Galaksija" }
        XCTAssertEqual(before.filter { $0.coverURL != nil }.count, 7)

        _ = try store.ingest(html: try html("Galaksija - pdf"))
        let after = try store.recent(limit: nil).filter { $0.edition == "Galaksija" }
        // Well past the 102 issues the artwork page lists itself.
        XCTAssertGreaterThan(after.filter { $0.coverURL != nil }.count, 150)
        // Kosmoplov shares the obrade topic and numbers from one too. Its
        // issues must not be wearing Galaksija's covers.
        for row in try store.recent(limit: nil) where row.edition == "Kosmoplov" {
            XCTAssertNotEqual(row.coverURL?.contains("Galaksija"), true,
                              "Kosmoplov \(row.number ?? -1) took a Galaksija cover")
        }
    }

    /// Which page is imported first is arbitrary, so the result must not
    /// depend on it. Alphabetically the artwork page comes first, and a cover
    /// applied before its issue exists is a cover thrown away.
    func testTheImportOrderDoesNotMatter() throws {
        func galaksijaCovers(artworkFirst: Bool) throws -> Int {
            let store = try Store()
            var pages = (1...3).map { n in
                "Kosmoplov i Galaksija - obrade\(n == 1 ? "" : " - Page \(n)") "
                + "- Casopisi - Stripzona.html"
            }
            pages = artworkFirst
                ? ["Galaksija - pdf - Casopisi - Stripzona.html"] + pages
                : pages + ["Galaksija - pdf - Casopisi - Stripzona.html"]
            for p in pages {
                _ = try store.ingest(html: try String(
                    contentsOf: Self.pagesDir.appendingPathComponent(p), encoding: .utf8))
            }
            return try store.recent(limit: nil)
                .filter { $0.edition == "Galaksija" && $0.coverURL != nil }.count
        }
        let issuesFirst = try galaksijaCovers(artworkFirst: false)
        XCTAssertGreaterThan(issuesFirst, 150)
        XCTAssertEqual(try galaksijaCovers(artworkFirst: true), issuesFirst)
    }

    /// A topic holding two runs, each numbered from one, cannot say which of
    /// them a leftover cover belongs to.
    ///
    /// Exercised directly. No page in the corpus is both mixed and carrying
    /// covers for issues it does not list, so going through `ingest` would
    /// pass whether the gate were there or not.
    func testAMixedTopicSpendsNothing() throws {
        let store = try Store()
        _ = try store.ingest(html: try String(
            contentsOf: Self.pagesDir.appendingPathComponent(
                "Kosmoplov i Galaksija - obrade - Casopisi - Stripzona.html"), encoding: .utf8))
        let editions = Set(try store.recent(limit: nil).compactMap(\.edition))
        XCTAssertTrue(editions.isSuperset(of: ["Galaksija", "Kosmoplov"]),
                      "fixture no longer mixes two runs: \(editions)")

        // An issue of each run, both numbered the same and neither with a cover.
        func bare(_ edition: String) throws -> StoredIssue {
            let row = try XCTUnwrap(try store.recent(limit: nil).first {
                $0.edition == edition && $0.number == 12
            }, edition)
            XCTAssertNil(row.coverURL, "\(edition) 12 already had a cover")
            return row
        }
        _ = try bare("Galaksija")
        _ = try bare("Kosmoplov")

        // Recording an offer and claiming it are the two halves of what
        // ingest does; both are needed for the cover to actually land.
        let art = [12: "https://i.postimg.cc/x/Galaksija-012-scan.jpg"]
        try store.spendLeftoverCovers(art, coveredHere: [], editions: ["Galaksija", "Kosmoplov"])
        try store.claimCoverOffers()
        XCTAssertNil(try bare("Galaksija").coverURL)
        XCTAssertNil(try bare("Kosmoplov").coverURL)

        // Named on its own, the same cover does land — so the gate above is
        // what stopped it, not some other reason it could not apply.
        try store.spendLeftoverCovers(art, coveredHere: [], editions: ["Galaksija"])
        try store.claimCoverOffers()
        XCTAssertEqual(try store.recent(limit: nil).first {
            $0.edition == "Galaksija" && $0.number == 12 }?.coverURL, art[12])
        XCTAssertNil(try bare("Kosmoplov").coverURL)
    }
}

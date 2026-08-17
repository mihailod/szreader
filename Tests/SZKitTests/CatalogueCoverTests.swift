import XCTest
@testable import SZKit

/// The number another edition files an issue under, kept rather than read and
/// dropped.
final class CatalogueRefTests: XCTestCase {

    private func label(_ body: String) -> IssueLabel? {
        Catalog.issues(in: "<title>T - Stripzona</title>" + body).first?.label
    }

    /// A topic carrying one story names it in full, the catalogue's number
    /// included: this issue is 02 here and Super Strip 305 there. The bracket
    /// is stripped from the title on its way to the shelf, and what was in it
    /// used to go with it.
    func testATopicNamingOneIssueKeepsItsCatalogueNumber() {
        let one = label("""
            <div>Timothy Tatcher 02 Hollywood protiv mene (SS 305)</div>
            <div>http://www.mediafire.com/?FAKEKEY305</div>
            """)
        XCTAssertEqual(one?.number, 2)
        XCTAssertEqual(one?.title, "Hollywood protiv mene")
        XCTAssertEqual(one?.catalogue, CatalogueRef(code: "SS", number: 305))
    }

    /// A reprint topic numbers from one and names the original beside it.
    func testAReprintTopicKeepsTheOriginalsNumber() {
        let one = label("""
            <div>01 (SS 173) Johnny Logan 001 - Crni tigrovi - \
            http://www.mediafire.com/?FAKEKEY173</div>
            """)
        XCTAssertEqual(one?.number, 1)
        XCTAssertEqual(one?.title, "Crni tigrovi")
        XCTAssertEqual(one?.catalogue, CatalogueRef(code: "SS", number: 173))
    }

    /// The two Timothy Tatcher topics are written by different hands. One
    /// spaces the reference and the other does not, and requiring the space
    /// resolved issue 02 while leaving 01 with no artwork at all.
    func testACatalogueNumberWrittenWithoutASpace() {
        let one = label("""
            <div>Timothy Tatcher 01 Mrtvacima ulaz zabranjen (SS301)(Sabko-BDS)</div>
            <div>http://www.mediafire.com/?FAKEKEY301</div>
            """)
        XCTAssertEqual(one?.number, 1)
        XCTAssertEqual(one?.title, "Mrtvacima ulaz zabranjen")
        XCTAssertEqual(one?.catalogue, CatalogueRef(code: "SS", number: 301))
    }

    /// "(SSB 089/001)" names two numberings at once and so names no single
    /// cover; its leading number would pick one at random.
    func testACompoundReferenceIsRefused() {
        let one = label("""
            <div>001 (SSB 089/001) - Grupa TNT - http://www.mediafire.com/?FAKEKEY1</div>
            """)
        XCTAssertEqual(one?.number, 1)
        XCTAssertNil(one?.catalogue)
    }

    /// These posts bracket dates as freely as catalogue numbers, and a date
    /// read as one would file artwork under the year.
    func testADateIsNotACatalogueNumber() {
        XCTAssertNil(Labels.catalogueRef(in: "Johnny Logan 001 - Crni tigrovi (02.01.1980.)"))
        XCTAssertNil(Labels.catalogueRef(in: "Veliki Blek 128 (enwil-rescan 2014)"))
    }

    /// It reaches the row, and a re-import of the same page finds the row it
    /// already made rather than making a second one.
    func testItIsStoredAndReimportIsStillANoOp() throws {
        let page = """
            <title>Timothy Tatcher 02 Hollywood protiv mene (SS 305) - Timothy Tatcher \
            - Stripzona</title>
            <div>Timothy Tatcher 02 Hollywood protiv mene (SS 305)</div>
            <div>http://www.mediafire.com/?FAKEKEY305</div>
            """
        let store = try Store()
        try store.ingest(html: page)
        try store.ingest(html: page)

        XCTAssertEqual(store.issueCount, 1, "the reference changed the row's identity")
        let pending = try store.coverlessIssues(limit: 10)
        XCTAssertEqual(pending.first?.catalogue, CatalogueRef(code: "SS", number: 305))
    }
}

/// Where the catalogue keeps a cover, read and written.
final class CataloguePathTests: XCTestCase {

    func testReadsTheThumbnailShape() {
        let path = CataloguePath.parse(
            "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_TT_SS_305.jpg")
        XCTAssertEqual(path, CataloguePath(folder: "AlanFord", hero: "TT",
                                           edition: "SS", number: 305))
    }

    /// The full-size copy beside it names the same three things.
    func testReadsTheFullSizeShape() {
        let path = CataloguePath.parse(
            "https://www.stripovi.com/naslovnice/Zagor/ZG_ZS_13.jpg")
        XCTAssertEqual(path, CataloguePath(folder: "Zagor", hero: "ZG",
                                           edition: "ZS", number: 13))
    }

    /// The thumbnail is what the library already holds fifteen hundred of, so
    /// it is what a cover found this way should be too.
    func testTheThumbnailIsWhatIsAskedFor() {
        XCTAssertEqual(CataloguePath(folder: "AlanFord", hero: "TT",
                                     edition: "SS", number: 305).url,
                       "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_TT_SS_305.jpg")
    }

    func testAnotherHostIsNotTheCatalogue() {
        XCTAssertNil(CataloguePath.parse("https://i.postimg.cc/XND22YTd/Galaksija-069-1.jpg"))
        XCTAssertNil(CataloguePath.parse("https://stripzona.com/thumbs/strider/Dzudas/Dzudas_01.jpg"))
    }
}

/// What the library has already learned about the catalogue's naming.
final class CatalogueIndexTests: XCTestCase {

    private let kitTeler = "https://www.stripovi.com/naslovnice/KitTeller/TN/TN_KT_LMS_"

    /// One page in the corpus hotlinks a neighbour's cover among three hundred
    /// of its own. A naming taken from whichever row came back first would
    /// follow the stray.
    func testTheCommonestNamingWins() {
        let index = CatalogueIndex(rows:
            (1...3).map { (hero: "Kit Teler", edition: "LUNOV MAGNUS STRIP",
                           url: kitTeler + "\($0).jpg") }
            + [(hero: "Kit Teler", edition: "LUNOV MAGNUS STRIP",
                url: "https://www.stripovi.com/naslovnice/TexWiller/TN/TN_TX_LMS_9.jpg")])
        XCTAssertEqual(index.naming(hero: "Kit Teler", edition: "LUNOV MAGNUS STRIP").first,
                       CatalogueNaming(folder: "KitTeller", hero: "KT", edition: "LMS"))
    }

    /// Super Strip's covers live in two folders, and a hero the library has
    /// never seen artwork for is somewhere among them.
    func testFoldersAreLearnedPerEdition() {
        let index = CatalogueIndex(rows: [
            (hero: "Alan Ford", edition: "Super Strip Biblioteka",
             url: "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_AF_SS_1.jpg"),
            (hero: "Johnny Logan", edition: "Vjesnik",
             url: "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_JL_SS_173.jpg"),
            (hero: "Druzina od vjesala", edition: "Vjesnik",
             url: "https://www.stripovi.com/naslovnice/DruzinaOdVjesala/TN/TN_DOV_SS_1.jpg"),
        ])
        XCTAssertEqual(index.folders(hostingEdition: "SS"), ["AlanFord", "DruzinaOdVjesala"])
    }

    /// "Kapetan Miki" initials to KM, which is Komandant Mark — and both run
    /// in Zlatna Serija, so the wrong guess returns an image rather than
    /// missing. This is the one way a guess can be wrong and still look right.
    func testACodeBelongingToAnotherHeroIsRecognised() {
        let index = CatalogueIndex(rows: [
            (hero: "Komandant Mark", edition: "Zlatna Serija",
             url: "https://www.stripovi.com/naslovnice/Mark/TN/TN_KM_ZS_100.jpg"),
        ])
        XCTAssertTrue(index.codeIsTaken("KM", byOtherThan: "Kapetan Miki"))
        XCTAssertFalse(index.codeIsTaken("KM", byOtherThan: "Komandant Mark"))
        XCTAssertFalse(index.codeIsTaken("TT", byOtherThan: "Timothy Tatcher"))
    }
}

/// Addressing a cover the page never linked.
final class CatalogueCandidateTests: XCTestCase {

    /// The library's own covers, as they are on the iPad: Alan Ford and Johnny
    /// Logan both filed under AlanFord, Druzina od vjesala under its own name.
    private var index: CatalogueIndex {
        CatalogueIndex(rows: [
            (hero: "Alan Ford", edition: "Super Strip Biblioteka",
             url: "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_AF_SS_1.jpg"),
            (hero: "Johnny Logan", edition: "Vjesnik",
             url: "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_JL_SS_173.jpg"),
            (hero: "Druzina od vjesala", edition: "Vjesnik",
             url: "https://www.stripovi.com/naslovnice/DruzinaOdVjesala/TN/TN_DOV_SS_1.jpg"),
            (hero: "Komandant Mark", edition: "Zlatna Serija",
             url: "https://www.stripovi.com/naslovnice/Mark/TN/TN_KM_ZS_100.jpg"),
        ])
    }

    /// The case the whole path exists for. Nothing about the row says
    /// "AlanFord": the hero is Timothy Tatcher, the edition is the topic's own
    /// name, and the number is 2. The folder comes from the editions the
    /// library has seen, and the rest from the label's "(SS 305)".
    func testTimothyTatcherIsFoundUnderAlanFord() {
        let candidates = CoverGuess.catalogueCandidates(
            hero: "Timothy Tatcher", edition: "Timothy Tatcher",
            catalogue: CatalogueRef(code: "SS", number: 305), number: 2, index: index)
        XCTAssertEqual(candidates.first,
                       "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_TT_SS_305.jpg")
    }

    /// Initials are a guess; a code another hero owns is a wrong answer that
    /// resolves. Nothing addressed to KM may be asked on Miki's behalf.
    func testInitialsAreRefusedWhenAnotherHeroOwnsThem() {
        let candidates = CoverGuess.catalogueCandidates(
            hero: "Kapetan Miki", edition: "ZLATNA SERIJA",
            catalogue: nil, number: 100, index: index)
        XCTAssertFalse(candidates.contains { $0.contains("_KM_") },
                       "asked for another hero's cover: \(candidates)")
    }

    /// Where the library knows the naming, it is used exactly — including the
    /// folder that is not the hero.
    func testAKnownHeroReproducesItsOwnNaming() {
        let candidates = CoverGuess.catalogueCandidates(
            hero: "Johnny Logan", edition: "Vjesnik",
            catalogue: CatalogueRef(code: "SS", number: 179), number: 2, index: index)
        XCTAssertEqual(candidates.first,
                       "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_JL_SS_179.jpg")
    }

    /// A magazine with no character behind it has nothing to address.
    func testNothingWithoutAHero() {
        XCTAssertTrue(CoverGuess.catalogueCandidates(
            hero: nil, edition: "FIBRA", catalogue: nil, number: 3, index: index).isEmpty)
    }

    /// Each candidate is a request against a host that rate-limits.
    func testTheListIsBounded() {
        let candidates = CoverGuess.catalogueCandidates(
            hero: "Timothy Tatcher", edition: "Timothy Tatcher",
            catalogue: CatalogueRef(code: "SS", number: 305), number: 2, index: index)
        XCTAssertLessThanOrEqual(candidates.count, CoverGuess.candidateLimit)
        XCTAssertEqual(Set(candidates).count, candidates.count, "the same URL asked twice")
    }
}

/// A cover URL that leads nowhere is a missing cover, not a settled one.
final class DeadCoverTests: XCTestCase {

    /// The page's own artwork, on a host that has since dropped it. Stored as
    /// https: every cover is normalised on the way in, so the URL to report is
    /// the one the row holds rather than the one the page wrote.
    private func libraryWithADeadCover() throws -> (store: Store, id: Int, dead: String) {
        let store = try Store()
        try store.ingest(html: """
            <title>Timothy Tatcher 02 Hollywood protiv mene (SS 305) - Timothy Tatcher \
            - Stripzona</title>
            <div><img src="http://www.dodaj.rs/f/w/ej/2QvK6abp/ss305b.png"></div>
            <div>Timothy Tatcher 02 Hollywood protiv mene (SS 305)</div>
            <div>http://www.mediafire.com/?FAKEKEY305</div>
            """)
        let issue = try XCTUnwrap(store.recent(limit: nil).first)
        let dead = try XCTUnwrap(issue.coverURL)
        XCTAssertTrue(dead.contains("dodaj.rs"), "the fixture needs the page's own cover")
        XCTAssertEqual(store.coverlessIssueCount, 0)
        return (store, issue.id, dead)
    }

    /// Until the shelf reports it, nothing knows. Once it does, every reader
    /// of the column sees the truth: no artwork here.
    func testADeadCoverIsNotShown() throws {
        let (store, id, dead) = try libraryWithADeadCover()
        try store.markCoverDead(url: dead)

        XCTAssertNil(try store.coverURL(forIssue: id),
                     "the download path would find a URL in the way of the first page")
        XCTAssertNil(try store.recent(limit: nil).first?.coverURL)
        XCTAssertNil(try store.search("tatcher").first?.coverURL)
    }

    /// And it goes back into the queue, which is the point.
    func testADeadCoverIsAskedAboutAgain() throws {
        let (store, _, dead) = try libraryWithADeadCover()
        try store.markCoverDead(url: dead)
        XCTAssertEqual(store.coverlessIssueCount, 1)
        XCTAssertEqual(try store.coverlessIssues(limit: 10).count, 1)
    }

    /// Artwork found later belongs to the row; the mark belonged to the URL it
    /// replaced.
    func testAReplacementClearsTheMark() throws {
        let (store, id, dead) = try libraryWithADeadCover()
        try store.markCoverDead(url: dead)
        try store.setCoverURL("szpage:\(id)", issueID: id)

        XCTAssertEqual(try store.coverURL(forIssue: id), "szpage:\(id)")
        XCTAssertEqual(store.coverlessIssueCount, 0)
    }

    /// A contact sheet is one image shared by six issues, each holding it
    /// under a tile reference. The sheet going means all six are gone, and
    /// only the sheet's own URL is ever fetched.
    func testASheetsDeathReachesEveryTile() throws {
        let sheet = "https://i.imgur.com/jGPdAZ2.jpg"
        let store = try Store()
        var page = "<title>Veliki Blek - LUNOV MAGNUS STRIP - Veliki Blek - Stripzona</title>"
        for n in 128...133 {
            page += "<div>\(n)-Naslov \(n) - http://www.mediafire.com/?FAKEKEY\(n)</div>"
        }
        try store.ingest(html: page)
        for (tile, issue) in try store.recent(limit: nil).enumerated() {
            try store.setCoverURL(CoverTile.reference(sheet, tile: tile, of: 6),
                                  issueID: issue.id)
        }
        XCTAssertEqual(try store.recent(limit: nil).filter { $0.coverURL != nil }.count, 6,
                       "the fixture needs a sheet shared by six issues")

        // Only the sheet is ever fetched, so only the sheet can be reported.
        try store.markCoverDead(url: sheet)
        XCTAssertTrue(try store.recent(limit: nil).allSatisfy { $0.coverURL == nil })
    }

    /// An issue asked about before the parser could read its reference must be
    /// asked again once it can. Without this, every issue the reader had
    /// already imported stayed as it was and only new ones benefited from the
    /// fix — which is exactly what happened to Timothy Tatcher 01.
    func testAReferenceArrivingLateReopensTheQuestion() throws {
        let store = try Store()
        let page = { (reference: String) in """
            <title>Timothy Tatcher 01 Mrtvacima ulaz zabranjen - Timothy Tatcher - Stripzona</title>
            <div>Timothy Tatcher 01 Mrtvacima ulaz zabranjen \(reference)</div>
            <div>http://www.mediafire.com/?FAKEKEY301</div>
            """
        }
        // Imported, asked about, and answered with nothing.
        try store.ingest(html: page(""))
        let id = try XCTUnwrap(store.recent(limit: nil).first).id
        try store.markCoverAsked(issueID: id)
        XCTAssertEqual(store.coverlessIssueCount, 0)

        // The same page again, now that the reference in it can be read.
        try store.ingest(html: page("(SS301)"))
        XCTAssertEqual(store.issueCount, 1)
        XCTAssertEqual(store.coverlessIssueCount, 1, "the new reference changed nothing")
        XCTAssertEqual(try store.coverlessIssues(limit: 5).first?.catalogue,
                       CatalogueRef(code: "SS", number: 301))

        // But an unchanged page still asks nothing twice.
        try store.markCoverAsked(issueID: id)
        try store.ingest(html: page("(SS301)"))
        XCTAssertEqual(store.coverlessIssueCount, 0)
    }

    /// A library carried over from before the change gets its question put
    /// again — once. Re-asking on every launch would be the same as never
    /// recording the answer, which is what `cover_asked_at` exists to prevent.
    func testTheReopenedQuestionIsReopenedOnlyOnce() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("reopen-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }

        let store = try Store(path: file.path)
        try store.ingest(html: """
            <title>Veliki Blek - LUNOV MAGNUS STRIP - Veliki Blek - Stripzona</title>
            <div>140-Zov bubnjeva - http://www.mediafire.com/?FAKEKEY140</div>
            """)
        let id = try XCTUnwrap(store.recent(limit: nil).first).id
        try store.markCoverAsked(issueID: id)
        XCTAssertEqual(store.coverlessIssueCount, 0)
        // A library written before the change carries no note of it. (A new
        // one records them as it is created, having nothing to reopen.)
        try store.db.run("DELETE FROM meta WHERE key LIKE 'cover-question-%'")

        // Opening it now puts the question again.
        XCTAssertEqual(try Store(path: file.path).coverlessIssueCount, 1)

        // Answered again, and opening it a third time leaves that answer alone.
        try store.markCoverAsked(issueID: id)
        XCTAssertEqual(try Store(path: file.path).coverlessIssueCount, 0)
    }

    /// RetroSpec's issues are magazines, and stripovi.com catalogues comics.
    /// Asking would be a request per issue against a host that cannot have the
    /// answer.
    func testRetroSpecIsNotAskedAboutCovers() throws {
        let store = try Store()
        try store.db.run("""
            INSERT INTO issue (title, title_folded, style, number, site, cover_url)
            VALUES ('Galaksija 1', 'galaksija 1', 'nameFirst', 1, 'retrospec', ?)
            """, [.text("https://retrospec.elite.org/covers/1.jpg")])
        try store.markCoverDead(url: "https://retrospec.elite.org/covers/1.jpg")

        XCTAssertEqual(store.coverlessIssueCount, 0)
        XCTAssertEqual(try store.coverlessIssues(limit: 10).count, 0)
    }
}

/// The whole path, on the page it was written for.
final class TimothyTatcherCoverTests: XCTestCase {

    private static var pagesDir: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("spike/pages")
    }

    private let wanted = "https://www.stripovi.com/naslovnice/AlanFord/TN/TN_TT_SS_305.jpg"

    private func fixture(_ fragment: String) throws -> String {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: Self.pagesDir.path)) ?? []
        guard let name = names.first(where: { $0.contains(fragment) }) else {
            throw XCTSkip("\(fragment) fixture not present")
        }
        return try String(contentsOf: Self.pagesDir.appendingPathComponent(name),
                          encoding: .utf8)
    }

    /// The saved topic, its cover host long gone, beside the Alan Ford run
    /// that stands for the catalogued covers a real library is full of.
    ///
    /// Every step is the real one: the page's own artwork is read and stored,
    /// found to be dead, and the replacement is assembled from the row — hero
    /// "Timothy Tatcher", edition "Timothy Tatcher", number 2, and a label
    /// that happened to mention Super Strip 305. Nothing in the row says
    /// "AlanFord"; that comes from where Alan Ford's covers turned out to be.
    func testTheDeadCoverIsReplacedFromTheCatalogue() async throws {
        let store = try Store()
        try store.ingest(html: try fixture("Timothy Tatcher"))
        try store.ingest(html: try fixture("Alan Ford"))

        let tatcher = try XCTUnwrap(store.recent(limit: nil).first { $0.number == 2 })
        let dead = try XCTUnwrap(tatcher.coverURL)
        XCTAssertTrue(dead.contains("dodaj.rs"), "the page's cover should be the dead one")
        XCTAssertEqual(store.coverlessIssueCount, 0, "nothing would ever reconsider it")

        // What the shelf discovers the first time it tries to draw it.
        try store.markCoverDead(url: dead)
        XCTAssertEqual(store.coverlessIssueCount, 1)

        // The catalogue has this one number and nothing else that was asked.
        let catalogue = StubTransport { request in
            request.url.absoluteString == self.wanted
                ? HTTPResponse(status: 200, headers: ["Content-Type": "image/jpeg"])
                : HTTPResponse(status: 301, headers: ["Content-Type": "text/html"])
        }
        let result = try await store.backfillCovers(via: catalogue)
        XCTAssertEqual(result.found, 1)

        let covered = try XCTUnwrap(store.recent(limit: nil).first { $0.number == 2 })
        XCTAssertEqual(covered.coverURL, wanted)
        XCTAssertEqual(store.coverlessIssueCount, 0)
        // HEAD: the catalogue answers it with the same status and content type
        // a GET would, so there is no reason to fetch the picture to find out.
        XCTAssertTrue(catalogue.requests.allSatisfy { $0.method == "HEAD" },
                      "the catalogue was asked with \(Set(catalogue.requests.map(\.method)))")
    }
}

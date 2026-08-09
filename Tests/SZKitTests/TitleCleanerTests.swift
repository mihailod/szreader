import XCTest
@testable import SZKit

/// Regression suite carried over from the Python spike. Every case here is a
/// real filename resolved from a live mirror, and several encode a bug that
/// was actually shipped and then caught by measuring the output.
final class TitleCleanerTests: XCTestCase {

    private func check(_ filename: String, title: String?, edition: String?, number: Int?,
                       _ message: String = "", line: UInt = #line) {
        let p = TitleCleaner.parse(filename)
        let got = TitleCleaner.isPlausible(p.title) ? p.title : nil
        XCTAssertEqual(got, title, "title \(message)", line: line)
        XCTAssertEqual(p.edition, edition, "edition \(message)", line: line)
        XCTAssertEqual(p.number, number, "number \(message)", line: line)
    }

    func testStandardForms() {
        check("LMS+517+-+Mister+No+-+U+celjusti+jaguara+%28drzeko%29.cbr",
              title: "U celjusti jaguara", edition: "LMS", number: 517)
        check("LMS 522 - Mister No - Presuda Fonseku (drzeko).cbr",
              title: "Presuda Fonseku", edition: "LMS", number: 522)
    }

    /// "LMS - 521 - ..." splits the edition and number into separate tokens.
    /// Before the fix the title parsed but edition/number came back nil,
    /// silently disabling the label-vs-file cross-check.
    func testEditionAndNumberAsSeparateTokens() {
        check("LMS+-+521+-+Mister+No+-+POSLEDNJI+KANGACEIRO.rar",
              title: "POSLEDNJI KANGACEIRO", edition: "LMS", number: 521)
    }

    /// A short hero name following an already-parsed number must not be
    /// swallowed as an edition code.
    func testShortHeroNameIsNotEatenAsEdition() {
        check("ZS - 1234 - Zagor - Krvava Rijeka.cbz",
              title: "Krvava Rijeka", edition: "ZS", number: 1234)
        check("ZS 1234 - Zagor - Krvava Rijeka.cbz",
              title: "Krvava Rijeka", edition: "ZS", number: 1234)
    }

    /// Scanner credits appended with underscores contaminated 24% of titles,
    /// which also made two mirrors of one issue look like different comics.
    func testUnderscoreScannerCredits() {
        check("LMS 0757 - Mister No - Strah na Karibima_enwil_borke72.cbr",
              title: "Strah na Karibima", edition: "LMS", number: 757)
        check("LMS 0726 - Mister No - Gauco Ramon_phantom0709_zikateror_quebrasco.cbr",
              title: "Gauco Ramon", edition: "LMS", number: 726)
    }

    /// Repeated trailing tag groups must all be stripped, not just the last.
    func testRepeatedTrailingTagGroups() {
        check("LMS 720 - Mister No - Crno zlato (Ostecene str 3 i 4)(300dpi)(drzeko & folpi).cbr",
              title: "Crno zlato", edition: "LMS", number: 720)
        check("LMS 569 - Mister No - Mambo, Mambo(300dpi)(drzeko).cbr",
              title: "Mambo, Mambo", edition: "LMS", number: 569)
    }

    /// "UFO" is a real title. An earlier plausibility floor of 4 letters
    /// rejected it and under-reported the hit rate as 53/54.
    func testGenuinelyShortTitleIsAccepted() {
        check("LMS 0807 - Mister No - UFO_dejko_unregistred.cbr",
              title: "UFO", edition: "LMS", number: 807)
    }

    func testJunkIsRejected() {
        check("LMS521.cbr", title: nil, edition: nil, number: nil)
        check("scan.rar", title: nil, edition: nil, number: nil)
        check("LMS 518.cbr", title: nil, edition: nil, number: nil)
    }

    /// Search must work without diacritics, and punctuation must not split
    /// two spellings of the same title.
    func testFolding() {
        XCTAssertEqual(Fold.fold("U čeljusti jaguara"), Fold.fold("U celjusti jaguara"))
        XCTAssertEqual(Fold.fold("Bubnjevi u džungli"), Fold.fold("Bubnjevi u dzungli"))
        XCTAssertEqual(Fold.fold("Poslednji Kangaćeiro"), Fold.fold("POSLEDNJI KANGACEIRO"))
        XCTAssertEqual(Fold.fold("Pazi, snima se!"), Fold.fold("PAZI SNIMA SE"))
        XCTAssertEqual(Fold.fold("Šuplji zub"), "suplji zub")
        XCTAssertEqual(Fold.fold("Đavo"), "davo")   // đ is not a decomposable diacritic
    }
}

/// The five label conventions, each asserted in isolation.
final class LabelStyleTests: XCTestCase {

    private func styles(_ html: String) -> [LabelStyle?] {
        Catalog.links(in: html).map(\.style)
    }

    func testLabeledBlock() {
        let recs = Catalog.links(in: """
            <div>MN_LMS_511</div><pre>http://www.mediafire.com/?FAKEKEY511A</pre>
            <div>drugi sken:</div><pre>https://mega.nz/file/FAKEID511B#FAKEKEY</pre>
            """)
        XCTAssertEqual(recs.count, 2)
        XCTAssertEqual(recs.map(\.style), [.labeledBlock, .labeledBlock])
        XCTAssertEqual(recs.first?.label, "MN_LMS_511")
    }

    func testLabeledInline() {
        let recs = Catalog.links(in: "<div>MM_LMS_031 - http://www.mediafire.com/?FAKEKEY031</div>")
        XCTAssertEqual(recs.map(\.style), [.labeledInline])
        XCTAssertEqual(recs.first?.label, "MM_LMS_031")
    }

    func testInlinePrevLine() {
        let recs = Catalog.links(in: """
            <div>013-Nasilje u Darkvudu</div><div>http://www.mediafire.com/?FAKEKEY013</div>
            """)
        XCTAssertEqual(recs.map(\.style), [.inlinePrevLine])
        XCTAssertEqual(recs.first?.label, "Nasilje u Darkvudu")
    }

    func testInlineSameLine() {
        let recs = Catalog.links(in:
            "<div>001 (SSB 089/001) - Grupa TNT - https://mega.nz/file/FAKEID001#FAKEKEY</div>")
        XCTAssertEqual(recs.map(\.style), [.inlineSameLine])
        XCTAssertEqual(recs.first?.label, "Grupa TNT")
    }

    func testNameFirst() {
        let recs = Catalog.links(in: """
            <div>Kolorka 3 Zašto sam ubio Pierrea (Oliver Ka &amp; Alfred) (07.08.2009)</div>
            <div>http://www.mediafire.com/?FAKEKEY003</div>
            """)
        XCTAssertEqual(recs.map(\.style), [.inlinePrevLine])
        XCTAssertEqual(recs.first?.label, "Zašto sam ubio Pierrea")
    }

    /// Name-first with no title at all still identifies the issue.
    func testNameFirstWithoutTitle() {
        let recs = Catalog.links(in: """
            <div>Alef 01 -</div><div>http://www.4shared.com/document/FAKEID/Alef_01.html</div>
            """)
        XCTAssertEqual(recs.first?.label, "Alef 01")
    }

    /// Forum chrome must never become a label.
    func testFurnitureIsNotALabel() {
        XCTAssertNil(Labels.matchNameFirst("Posted 06 March 2011 - 09:26 PM"))
        XCTAssertNil(Labels.matchNameFirst("Edited by lipovac, 20 October 2022 - 11:05 PM."))
        XCTAssertNil(Labels.matchNameFirst("Brojevi od 031 do 036."))
        XCTAssertNotNil(Labels.matchNameFirst("Kolorka 4 Putovanje u Italiju (Cosey)"))
    }

    /// TN_* are cover thumbnails hotlinked from stripovi.com, not issue labels.
    func testThumbnailNamesAreNotLabels() {
        XCTAssertNil(Labels.code.firstGroups("TN_ZG_ZS_39"))
        XCTAssertNotNil(Labels.code.firstGroups("MN_LMS_511"))
    }

    /// An unattributed link must be reported, never silently attached to a
    /// stale label — that is how phantom mismatches get manufactured.
    func testUnlabelledLinkIsReportedAsSuch() {
        XCTAssertEqual(styles("<div>http://www.mediafire.com/?orphan</div>"), [nil])
    }

    /// One label claiming a large block is the signature of an unrecognised
    /// convention and must not be counted as coverage.
    func testStaleLabelIsSuspect() {
        var html = "<div>013-Some Title</div>"
        for i in 0..<10 { html += "<div>http://www.mediafire.com/?u\(i)</div>" }
        let cov = Catalog.coverage(Catalog.links(in: html))
        XCTAssertEqual(cov.total, 10)
        XCTAssertEqual(cov.suspect, 10)
        XCTAssertEqual(cov.attributed, 0)
    }
}

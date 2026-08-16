import XCTest
@testable import SZKit

/// Telling an edition in a topic title from a story in one.
///
/// Written against synthetic titles rather than the saved pages, because those
/// live in the gitignored `spike/pages/` and these two shapes are the whole
/// rule — a fresh clone should still be held to it.
final class EditionFromTitleTests: XCTestCase {

    private func context(topic: String, trail: [String]) -> PageContext {
        PageContext(topic: topic, trail: trail)
    }

    /// The case the hero-strip exists for: the topic runs the character's
    /// name straight into the edition's.
    func testAnEditionAfterTheHeroIsStillAnEdition() {
        let page = context(topic: "Alan Ford Super Strip Biblioteka [425] [Vjesnik] - Alan Ford",
                           trail: ["Magnus - Bunker", "Alan Ford"])
        XCTAssertEqual(page.hero, "Alan Ford")
        XCTAssertEqual(page.edition, "Super Strip Biblioteka")
        XCTAssertEqual(page.editionCode, "SSB")
    }

    /// And the case that broke: the topic names one story, not a run.
    ///
    /// Stripping the hero from "Timothy Tatcher 02 Hollywood protiv mene"
    /// leaves "02 Hollywood protiv mene", which was filed as an edition of its
    /// own and initialled "HPM" — a shelf heading invented from a story title,
    /// with that one topic's issues under it. The number in front is the tell:
    /// editions are not numbered, issues are.
    func testAStoryAfterTheHeroIsNotAnEdition() {
        let page = context(topic: "Timothy Tatcher 02 Hollywood protiv mene (SS 305) "
                                + "- Timothy Tatcher",
                           trail: ["Magnus - Bunker", "Timothy Tatcher"])
        XCTAssertEqual(page.hero, "Timothy Tatcher")
        XCTAssertEqual(page.edition, "Timothy Tatcher",
                       "a topic naming one story has no edition in it")
        XCTAssertEqual(page.editionCode, "TT")
    }

    /// The rule is the leading number, not the presence of one: an edition
    /// that merely carries a count keeps its name.
    ///
    /// The hero here matches the topic exactly, so the strip actually runs —
    /// with a longer crumb like "Zagor Te-Nay" it does not, and the title
    /// would survive whole for reasons that have nothing to do with this rule.
    func testANumberLaterInTheNameIsHarmless() {
        let page = context(topic: "Zagor Zlatna Serija 100 - Zagor",
                           trail: ["Bonelli", "Zagor"])
        XCTAssertEqual(page.hero, "Zagor")
        XCTAssertEqual(page.edition, "Zlatna Serija 100")
        XCTAssertEqual(page.editionCode, "ZS")
    }
}

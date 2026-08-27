import XCTest
@testable import SZKit

/// The two switches above the source list, and what they claim to move.
///
/// The settings screen turns a language on by turning its sources on. That is
/// only a coarse switch rather than a second, disagreeing setting for as long
/// as every source belongs to exactly one language — which is what these check,
/// and what a fifteenth source added later would break silently.
final class SourceLanguageTests: XCTestCase {

    /// Every source is decided by one language or is shared by all of them.
    /// Nothing is left over: a source in neither list is a source no language
    /// switch can reach.
    func testEverySourceBelongsSomewhere() {
        let claimed = SourceLanguage.allCases.flatMap(\.sites)
                    + SourceLanguage.sharedSites
        XCTAssertEqual(Set(claimed), Set(IssueSite.allCases))
        XCTAssertEqual(claimed.count, IssueSite.allCases.count,
                       "a source is claimed by more than one language")
    }

    /// The ex-YU shelves, named. `sharedSites` is deliberately not among them
    /// — archive.org answers to both switches, and counting it here would make
    /// the English switch report itself on with no English shelf behind it.
    ///
    /// Local Files is shared for the same reason arrived at from the other
    /// end: archive.org holds every language, and the folder on the device
    /// holds whatever the reader drags into it. Neither can be filed under
    /// one language without being wrong about half of what it carries.
    func testExYUSites() {
        XCTAssertEqual(SourceLanguage.exYU.sites,
                       [.stripzona, .stripovi, .retrospec,
                        .popboksDzuboks, .popboksRitam])
        for shared in SourceLanguage.sharedSites {
            XCTAssertFalse(SourceLanguage.exYU.sites.contains(shared))
            XCTAssertFalse(SourceLanguage.english.sites.contains(shared))
        }
        XCTAssertEqual(SourceLanguage.sharedSites, [.archive, .local])
    }

    /// The one source with no switch, and the one place that has to know it.
    ///
    /// A language switch moves `sharedSites` along with its own — that is how
    /// archive.org stays on while either language is — so Local Files is
    /// handed to `setSource` in the ordinary course of things. It has to be a
    /// no-op there, and this is the fact the app layer relies on to make it
    /// one.
    func testLocalFilesHasNoSwitch() {
        XCTAssertFalse(IssueSite.local.isSwitchable)
        for site in IssueSite.allCases where site != .local {
            XCTAssertTrue(site.isSwitchable, "\(site) lost its switch")
        }
    }

    /// English is what is left, so the shelves that are plainly English are in
    /// it and the ex-YU ones are not.
    func testEnglishHoldsTheRest() {
        let english = Set(SourceLanguage.english.sites)
        for site in [IssueSite.comicbookplus, .batcave, .atarimania,
                     .spectrumMagazines, .vintageAppleBooks, .bombjackGames] {
            XCTAssertTrue(english.contains(site), "\(site) should be English")
        }
        for site in [IssueSite.stripzona, .stripovi, .retrospec] {
            XCTAssertFalse(english.contains(site), "\(site) is ex-YU")
        }
    }
}

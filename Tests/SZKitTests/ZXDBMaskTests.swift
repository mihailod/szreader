import XCTest
@testable import SZKit

/// The ZXDB mask expander.
///
/// Every mask below is a real one, copied from the published dump, and every
/// issue beside it is that magazine's real row. That matters more here than in
/// most of these tests: the expander's job is to agree with a third party's
/// file naming, so a test written against an invented mask would only prove
/// the expander agrees with itself.
final class ZXDBMaskTests: XCTestCase {

    // MARK: - The ordinary case

    /// Crash issue 1, February 1984 — the mask that exercises the most tokens
    /// at once, including the two optional ones on an issue that has neither.
    func testCrashIssueOne() {
        let mask = "https://archive.org/download/crash-magazine-{i2}{s}{u-}"
                 + "/Crash_{i2}_{M3}_{y4}.pdf"
        let issue = ZXDBMask.Issue(number: 1, volume: 1, year: 1984, month: 2)
        XCTAssertEqual(try expand(mask, issue),
                       "https://archive.org/download/crash-magazine-01"
                       + "/Crash_01_Feb_1984.pdf")
    }

    /// The same mask once the issue count passes the padding width. `{i2}` is
    /// a minimum, not a field width — Crash ran to 98 and Your Sinclair's
    /// `{i3}` runs past 100.
    func testPaddingIsAMinimumNotAWidth() {
        let issue = ZXDBMask.Issue(number: 123)
        XCTAssertEqual(try expand("x{i2}", issue), "x123")
        XCTAssertEqual(try expand("x{i3}", issue), "x123")
        XCTAssertEqual(try expand("x{i5}", issue), "x00123")
    }

    // MARK: - The year

    /// `{y2}` is the two-digit year and `{y4}` the full one. Read as a minimum
    /// width — which is how the README words every other numeric token —
    /// `{y2}` would expand identically to `{y4}` and the token would have no
    /// reason to exist.
    func testTwoDigitYear() {
        let issue = ZXDBMask.Issue(number: 1, year: 1981, month: 11)
        XCTAssertEqual(try expand("{y4}", issue), "1981")
        XCTAssertEqual(try expand("{y2}", issue), "81")
    }

    /// C&VG issue 1, November 1981 — the mask that pairs `{y2}` with `{M3}`.
    func testComputerAndVideoGames() {
        let mask = "https://archive.org/download/ComputerAndVideoGamesIssue{i3}{M3}{y2}"
        let issue = ZXDBMask.Issue(number: 1, year: 1981, month: 11)
        XCTAssertEqual(try expand(mask, issue),
                       "https://archive.org/download/ComputerAndVideoGamesIssue001Nov81")
    }

    func testYearAcrossTheCentury() {
        XCTAssertEqual(try expand("{y2}", ZXDBMask.Issue(year: 2003)), "03")
        XCTAssertEqual(try expand("{y2}", ZXDBMask.Issue(year: 1999)), "99")
    }

    // MARK: - Month names

    /// `{M3}` is three letters, bare `{M}` is the whole name.
    func testMonthNames() {
        let april = ZXDBMask.Issue(month: 4)
        XCTAssertEqual(try expand("{M3}", april), "Apr")
        XCTAssertEqual(try expand("{M}", april), "April")
        XCTAssertEqual(try expand("{M3}", ZXDBMask.Issue(month: 9)), "Sep")
    }

    /// `{M#}` truncates to *exactly* # letters, so `{M4}` on April is "Apri".
    ///
    /// That looks like a bug and is not. It is what ZXDB's README specifies,
    /// and the database cannot settle it either way: `{M4}` occurs once in the
    /// entire dump, on a users-group newsletter with a single issue dated
    /// July — four letters whichever rule applies. So this follows the
    /// specification, and the live check is what would catch it if the
    /// specification is wrong; nothing else can.
    func testMonthNameTruncatesToExactlyTheGivenLength() {
        XCTAssertEqual(try expand("{M4}", ZXDBMask.Issue(month: 4)), "Apri")
        XCTAssertEqual(try expand("{M4}", ZXDBMask.Issue(month: 7)), "July")
    }

    /// Pixel Junior 1, October 1987 — the only mask using a bare `{M}`.
    func testPixelJunior() {
        let mask = "https://archive.org/download/pixel-junior-{i1}-{M}-{y4}"
        let issue = ZXDBMask.Issue(number: 1, year: 1987, month: 10)
        XCTAssertEqual(try expand(mask, issue),
                       "https://archive.org/download/pixel-junior-1-October-1987")
    }

    /// The month name must not follow the machine's locale: the catalogue is
    /// built on one developer's Mac and read by everyone.
    func testMonthNamesAreEnglishRegardlessOfLocale() {
        XCTAssertEqual(ZXDBMask.months.first, "January")
        XCTAssertEqual(ZXDBMask.months.count, 12)
    }

    // MARK: - The optional strings

    /// `{s-}` on an issue that has a special: the argument is a separator to
    /// put in front, not a width.
    func testSpecialCarriesItsSeparator() {
        let issue = ZXDBMask.Issue(year: 1986, special: "Spring")
        XCTAssertEqual(try expand("Quarters%20{s}%20{y4}.pdf", issue),
                       "Quarters%20Spring%201986.pdf")
        XCTAssertEqual(try expand("x{s-}", issue), "x-Spring")
        XCTAssertEqual(try expand("x{s_}", issue), "x_Spring")
    }

    /// And on an issue that has none, the separator disappears with it. This
    /// is the case that covers most of the database.
    func testAbsentSpecialTakesItsSeparatorWithIt() {
        let issue = ZXDBMask.Issue(number: 7)
        XCTAssertEqual(try expand("mag-{i2}{s}{u-}", issue), "mag-07")
        XCTAssertEqual(try expand("mag-{i2}{s_}", issue), "mag-07")
    }

    func testSupplement() {
        let issue = ZXDBMask.Issue(number: 3, supplement: "Extra")
        XCTAssertEqual(try expand("DID{i1}{u-}.pdf", issue), "DID3-Extra.pdf")
    }

    // MARK: - What cannot be expanded

    /// An issue with no number cannot be addressed by a mask that wants one.
    /// Refusing is the point: the alternative is a URL with a hole in it that
    /// looks like a real row on the shelf until someone taps it.
    func testMissingFieldIsRefused() {
        let issue = ZXDBMask.Issue(year: 1984)
        switch ZXDBMask.expand("mag-{i2}.pdf", for: issue) {
        case .success(let url): XCTFail("expanded to \(url) with no issue number")
        case .failure(let why): XCTAssertEqual(why, .missing(field: "i"))
        }
    }

    func testMissingMonthIsRefused() {
        switch ZXDBMask.expand("{M3}", for: ZXDBMask.Issue(year: 1984)) {
        case .success(let text): XCTFail("expanded to \(text) with no month")
        case .failure(let why): XCTAssertEqual(why, .missing(field: "M"))
        }
    }

    /// A token this expander has never seen is an error, not something to
    /// pass through. ZXDB adding a token is exactly how this would otherwise
    /// start emitting URLs with `{q9}` in them.
    func testUnknownTokenIsRefused() {
        switch ZXDBMask.expand("mag-{q9}.pdf", for: ZXDBMask.Issue(number: 1)) {
        case .success(let text): XCTFail("expanded unknown token to \(text)")
        case .failure(let why): XCTAssertEqual(why, .unknownToken("q9"))
        }
    }

    /// A mask with no tokens at all — 396 issue-level overrides are plain
    /// URLs — must survive untouched.
    func testMaskWithoutTokens() {
        let fixed = "https://archive.org/download/eltebeoinformatico/El%20tebeo.pdf"
        XCTAssertEqual(try expand(fixed, ZXDBMask.Issue()), fixed)
    }

    // MARK: - URLs

    func testURLEncodesSubstitutedSpaces() {
        let issue = ZXDBMask.Issue(year: 1986, special: "Late Spring")
        switch ZXDBMask.url("https://x.org/{s}%20{y4}.pdf", for: issue) {
        case .success(let url):
            XCTAssertEqual(url.absoluteString, "https://x.org/Late%20Spring%201986.pdf")
        case .failure(let why):
            XCTFail("did not build a URL: \(why)")
        }
    }

    // MARK: - Plumbing

    private func expand(_ mask: String, _ issue: ZXDBMask.Issue) throws -> String {
        switch ZXDBMask.expand(mask, for: issue) {
        case .success(let text): return text
        case .failure(let why):  throw Unexpanded(why: "\(why)")
        }
    }

    private struct Unexpanded: Error { let why: String }
}

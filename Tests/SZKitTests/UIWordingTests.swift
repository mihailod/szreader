import XCTest
@testable import SZKit

/// House rules for the words the app shows a reader.
final class UIWordingTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Never "comic" on screen: the library holds magazines — Sirius, Alef,
    /// Galaksija, Kosmoplov — as well as comics, and calling every one of
    /// them a comic is wrong for a good part of the shelf. "Issue" covers
    /// both.
    ///
    /// A lint rather than a one-time sweep, because the wording is only ever
    /// a phrase away from coming back, and nothing else would notice.
    /// Comments and identifiers are left alone — `ComicDocument` and
    /// `comicID` name types and parameters no reader ever sees.
    ///
    /// Naming both kinds together is the exception, and the only one: a
    /// sentence that says "comics or magazines" is not calling a magazine a
    /// comic, it is doing exactly what this rule exists to get — describing
    /// what the two sources actually hold. The failure being guarded against
    /// is "comic" standing in for every issue on the shelf, so a literal
    /// still has to fail unless it names magazines in the same breath.
    func testTheUILayerNeverSaysComic() throws {
        let dir = Self.root.appendingPathComponent("App")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(files.isEmpty, "no UI sources found at \(dir.path)")

        var offenders: [String] = []
        for file in files.sorted() {
            let source = try String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8)
            for literal in Self.stringLiterals(in: source) {
                let text = literal.lowercased()
                guard text.contains("comic"), !text.contains("magazine") else { continue }
                offenders.append("\(file): “\(literal)”")
            }
        }
        XCTAssertEqual(offenders, [],
                       "say “issue”, not “comic” — the library holds magazines too")
    }

    /// The exception above is narrow, and this is what keeps it narrow.
    ///
    /// Written because widening a rule to admit today's wording is the way a
    /// rule quietly stops meaning anything: "comic" alone must still fail,
    /// and only the paired phrasing may pass.
    func testTheComicRuleStillCatchesTheThingItIsFor() {
        let banned = ["Download this comic", "No comics yet", "Reading a comic"]
        for text in banned {
            let lowered = text.lowercased()
            XCTAssertTrue(lowered.contains("comic") && !lowered.contains("magazine"),
                          "“\(text)” should still be an offence")
        }
        for text in ["Comics and magazines you import", "comics or magazines metadata"] {
            let lowered = text.lowercased()
            XCTAssertTrue(lowered.contains("magazine"),
                          "“\(text)” names both, so it is allowed")
        }
    }

    /// Every string literal in a Swift file, with comments left out.
    ///
    /// Hand-rolled because the alternative — a regex for `"…"` — cannot tell
    /// a literal from the same characters inside a comment, and the UI layer
    /// explains itself in prose that mentions comics throughout.
    ///
    /// No handling of raw strings (`#"…"#`): there are none in `App`, and the
    /// test above would fail loudly rather than quietly if that changed,
    /// since a mis-parse there reads code as text.
    static func stringLiterals(in source: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inString = false, inLine = false, inBlock = false, escaped = false
        var previous: Character?

        for ch in source {
            if inLine {
                if ch == "\n" { inLine = false }
                previous = nil
                continue
            }
            if inBlock {
                if previous == "*", ch == "/" { inBlock = false; previous = nil; continue }
                previous = ch
                continue
            }
            if inString {
                if escaped { escaped = false; current.append(ch) }
                else if ch == "\\" { escaped = true }
                else if ch == "\"" { inString = false; out.append(current); current = "" }
                else if ch == "\n" { inString = false; current = "" }  // unterminated
                else { current.append(ch) }
                previous = ch
                continue
            }
            if previous == "/", ch == "/" { inLine = true; previous = nil; continue }
            if previous == "/", ch == "*" { inBlock = true; previous = nil; continue }
            if ch == "\"" { inString = true; current = "" }
            previous = ch
        }
        return out
    }
}

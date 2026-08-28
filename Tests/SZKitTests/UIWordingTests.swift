import XCTest
@testable import SZKit

/// House rules for the words the app shows a reader.
final class UIWordingTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Everywhere a sentence the reader will see is written.
    ///
    /// The app layer, and the kit files that hold copy. That second part is
    /// not a nicety: `DeleteCopy` moved out of `App` so it could be called by
    /// a test, and the moment it did, this rule stopped applying to the most
    /// destructive sentences in the app — silently, because a lint that scans
    /// one directory cannot notice that the words left it.
    ///
    /// Named one by one rather than by scanning all of `Sources`, so adding a
    /// file of copy is a decision somebody makes here rather than something
    /// this quietly starts or stops covering.
    private static let copyInTheKit = ["DeleteCopy.swift"]

    private static func sourcesShowingWords() throws -> [(String, String)] {
        let app = root.appendingPathComponent("App")
        let kit = root.appendingPathComponent("Sources/SZKit")
        var out: [(String, String)] = []
        let appFiles = try FileManager.default.contentsOfDirectory(atPath: app.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        XCTAssertFalse(appFiles.isEmpty, "no UI sources found at \(app.path)")
        for file in appFiles {
            out.append((file, try String(contentsOf: app.appendingPathComponent(file),
                                         encoding: .utf8)))
        }
        for file in copyInTheKit {
            let url = kit.appendingPathComponent(file)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                          "\(file) is listed as copy but is not there — if it moved, "
                        + "this list has to move with it or the rule stops applying")
            out.append((file, try String(contentsOf: url, encoding: .utf8)))
        }
        return out
    }

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
        var offenders: [String] = []
        for (file, source) in try Self.sourcesShowingWords() {
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

    /// The interpolation skip, and the line it does not cross.
    ///
    /// Written with the extractor change, because "skip the expression" is one
    /// edit away from "skip the whole literal" — and that edit would empty the
    /// rule out while leaving every test above it green.
    func testInterpolatedExpressionsAreSkippedButTheirTextIsNot() {
        // The expression is code: what reaches a reader is the value.
        let named = #"Text("\(IssueSite.comicbookplus.display) (free account needed)")"#
        XCTAssertEqual(Self.stringLiterals(in: named), [" (free account needed)"])

        // The prose around one is still read, and still an offence.
        let offending = #"Text("Download this comic from \(site.display) now")"#
        let literals = Self.stringLiterals(in: offending)
        XCTAssertTrue(literals.contains { $0.lowercased().contains("comic") },
                      "text beside an interpolation stopped being read")

        // A nested call does not close the interpolation early.
        let nested = #"Text("\(count(of: things.first(where: { $0.ok }))) left")"#
        XCTAssertEqual(Self.stringLiterals(in: nested), [" left"])

        // And an ordinary escape is still a character, not an interpolation.
        let quoted = #"Text("a \"comic\" book")"#
        XCTAssertTrue(Self.stringLiterals(in: quoted)
                        .contains { $0.lowercased().contains("comic") })
    }

    /// Every string literal in a Swift file, with comments left out.
    ///
    /// Hand-rolled because the alternative — a regex for `"…"` — cannot tell
    /// a literal from the same characters inside a comment, and the UI layer
    /// explains itself in prose that mentions comics throughout.
    ///
    /// Interpolated expressions are skipped, for the same reason comments and
    /// identifiers are: `\(IssueSite.comicbookplus.display)` is code, and what
    /// it puts on screen is the *value*, not the property's name. Reading the
    /// expression as prose made a source whose owners called it Comic Book
    /// Plus unnameable in this layer by any route — interpolation included —
    /// which is not what this rule is for.
    ///
    /// The literal text around an interpolation is still read, so
    /// `"Download this comic from \(site.display)"` is still an offence.
    ///
    /// No handling of raw strings (`#"…"#`): there are none in `App`, and the
    /// test above would fail loudly rather than quietly if that changed,
    /// since a mis-parse there reads code as text. A string literal *nested
    /// inside* an interpolation is skipped with the rest of the expression —
    /// the one known hole, and worth less than the parser it would take.
    static func stringLiterals(in source: String) -> [String] {
        var out: [String] = []
        var current = ""
        var inString = false, inLine = false, inBlock = false, escaped = false
        /// Open parens inside `\( … )`, so a nested call does not end it early.
        var interpolation = 0
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
                if interpolation > 0 {
                    if ch == "(" { interpolation += 1 }
                    else if ch == ")" { interpolation -= 1 }
                    previous = ch
                    continue
                }
                if escaped {
                    escaped = false
                    // `\(` opens an interpolation; every other escape is a
                    // character of the text.
                    if ch == "(" { interpolation = 1 } else { current.append(ch) }
                }
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

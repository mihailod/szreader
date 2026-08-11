import XCTest
@testable import SZKit

/// The app imports `document.documentElement.outerHTML`, and a DOM serialiser
/// normalises every attribute to double quotes. The saved pages use single
/// quotes. A parser written for one form is silently inert on the other — and
/// the fixtures are the form that passes, so nothing catches it.
final class QuoteStyleTests: XCTestCase {

    private func page(_ fragment: String) throws -> String {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("spike/pages")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        guard let hit = names.first(where: { $0.contains(fragment) }),
              let html = try? String(contentsOf: dir.appendingPathComponent(hit),
                                     encoding: .utf8)
        else { throw XCTSkip("no saved page matching “\(fragment)”") }
        return html
    }

    /// Approximates what the WebView hands the importer: single-quoted
    /// attributes rewritten as double-quoted.
    private func asSerialisedByTheDOM(_ html: String) -> String {
        html.replacingOccurrences(of: "='", with: "=\"")
            .replacingOccurrences(of: "' ", with: "\" ")
            .replacingOccurrences(of: "'>", with: "\">")
    }

    /// The case that was broken on device while green in the tests.
    func testAlefParsesTheSameEitherWay() throws {
        let saved = try page("Alef")
        let serialised = asSerialisedByTheDOM(saved)

        let a = try Store(); _ = try a.importPage(html: saved, source: "saved")
        let b = try Store(); _ = try b.importPage(html: serialised, source: "serialised")

        XCTAssertEqual(a.issueCount, 26, "saved form")
        XCTAssertEqual(b.issueCount, 26, "double-quoted form parsed differently")
        XCTAssertEqual(try b.recent(limit: nil).compactMap(\.number).sorted(), Array(1...26))
    }

    /// The reduction itself must fire on both forms.
    func testPostReductionWorksOnBothForms() throws {
        let saved = try page("Alef")
        for html in [saved, asSerialisedByTheDOM(saved)] {
            let reduced = Catalog.authoritativeHTML(html)
            XCTAssertLessThan(reduced.count, html.count, "nothing was reduced")
        }
    }

    /// Minimal double-quoted markup, in case the fixture ever changes shape.
    func testDoubleQuotedPostsAreRecognised() {
        let html = """
            <title>Alef - Ostale edicije pisanih romana - Stripzona</title>
            <span itemprop="title">Pisani romani</span>
            <div class="post_block hentry clear clearfix">
              <span itemprop="name">someone_else</span>
              <div>Alef - SF magazin 99 (x)</div><div>http://www.mediafire.com/?FAKE99</div>
            </div>
            <div class="post_block hentry clear clearfix">
              <span itemprop="name">doktor</span>
              <div>Alef - SF magazin 01 (x)</div><div>http://www.mediafire.com/?FAKE01</div>
            </div>
            """
        let store = try? Store()
        _ = try? store?.importPage(html: html, source: "t")
        let numbers = ((try? store?.recent(limit: nil)) ?? [])?.compactMap(\.number) ?? []
        XCTAssertEqual(numbers, [1], "the other member's post was not discarded")
    }
}

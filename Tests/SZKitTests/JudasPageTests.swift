import XCTest
@testable import SZKit

/// Parsed against the real saved topic page, not invented markup.
///
/// Cover matching for this page was "fixed" twice against markup that was
/// guessed at; both attempts found nothing. The page itself is the only
/// authority on what the parser has to cope with.
final class JudasPageTests: XCTestCase {

    /// Repo-relative, so this is skipped rather than failing on a checkout
    /// without the spike pages.
    private func page() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SZKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // repo root
            .appendingPathComponent("spike/pages/"
                + "Dzudas - STRIPZONA SCANLATION - Dzudas - Stripzona.html")
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            throw XCTSkip("saved topic page not present")
        }
        return html
    }

    /// IPB writes `onload='... indexOf("x") > 0'`, putting a literal `>` inside
    /// an attribute. A `[^>]*` tag pattern ends there, before reaching `src`,
    /// and finds no images whatsoever.
    func testImagesSurviveAngleBracketsInsideAttributes() throws {
        let lines = HTMLText.plainLines(try page(), keepingImages: true)
        let images = lines.compactMap(HTMLText.markedImage)
        XCTAssertGreaterThan(images.count, 10, "img tags truncated at a '>' in an attribute")
        XCTAssertTrue(images.contains { $0.contains("Dzudas_01") })
    }

    /// The scanlation's art is not on stripovi.com, but its filename still
    /// carries the issue number.
    func testCoversAreFoundForTheScanlation() throws {
        let covers = Catalog.covers(in: try page())
        XCTAssertGreaterThan(covers.count, 5, "no covers matched")
        for number in 1...5 {
            let cover = try XCTUnwrap(covers[number], "issue \(number) has no cover")
            XCTAssertTrue(cover.hasPrefix("https://"), "would pay a redirect: \(cover)")
            XCTAssertTrue(cover.lowercased().contains("dzudas"))
        }
    }

    /// Avatars and rank pips outnumber the real art on a busy topic.
    func testNoForumFurnitureIsUsedAsACover() throws {
        for (number, url) in Catalog.covers(in: try page()) {
            XCTAssertFalse(url.contains("uploads/profile"), "issue \(number): avatar")
            XCTAssertFalse(url.contains("style_emoticons"), "issue \(number): emoticon")
            XCTAssertFalse(url.contains("picturemissing"), "issue \(number): placeholder")
        }
    }

    /// The end-to-end path: importing the page stores those covers.
    func testImportStoresCovers() throws {
        let store = try Store()
        _ = try store.importPage(html: try page(), source: "judas fixture")
        let withCovers = try store.recent().filter { $0.coverURL != nil }
        XCTAssertGreaterThan(withCovers.count, 5, "covers parsed but not stored")
    }
}

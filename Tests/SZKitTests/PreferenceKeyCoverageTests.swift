import XCTest
@testable import SZKit

/// Every stored preference has to be a decision.
///
/// A preference that syncs and should not is a device describing another
/// device's disk; one that does not sync and should is the reader setting the
/// same thing up twice. Neither announces itself — the app works either way —
/// so the only thing that catches it is being made to choose.
///
/// A lint over the source text rather than a unit test, for the same reason
/// `UIWordingTests` is one: the lists live in the app target, which has no
/// test target of its own, and reading them as text is what lets this run at
/// all. It is coarse on purpose — it asks whether a key was classified, not
/// whether the classification was right.
final class PreferenceKeyCoverageTests: XCTestCase {

    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private static var appDirectory: URL { root.appendingPathComponent("App") }

    private static func appSources() throws -> [(name: String, text: String)] {
        let dir = appDirectory
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        return try names.map {
            ($0, try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8))
        }
    }

    /// `@AppStorage("thing")`, wherever it appears in the app layer.
    ///
    /// Literals only. `@AppStorage(SmartZoom.settingKey)` names its key
    /// through a constant and is not found here, which is fine: what this
    /// guards against is somebody adding a preference in the ordinary way and
    /// nobody noticing it never leaves the device.
    private static func storedKeys(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let start = rest.range(of: "@AppStorage(\"") {
            rest = rest[start.upperBound...]
            guard let end = rest.range(of: "\"") else { break }
            found.append(String(rest[..<end.lowerBound]))
            rest = rest[end.upperBound...]
        }
        return found
    }

    /// The contents of a `static let`/`static var` array of string literals,
    /// read out of the source.
    private static func declaredList(named name: String, in text: String) throws -> Set<String> {
        let anchor = try XCTUnwrap(text.range(of: "static let \(name)")
                                   ?? text.range(of: "static var \(name)"),
                                   "no list called \(name) in SZReaderApp.swift")
        // The first bracket that opens a *literal*, which is not the first
        // bracket: `static var x: [String]` announces its type before it says
        // anything, and taking that one reads the word "String" as the whole
        // list — an empty answer that would quietly pass this lint for ever.
        // A literal is the one whose next non-blank character is a quote.
        let body = text[anchor.upperBound...]
        var search = body
        var contents: Substring?
        while let open = search.range(of: "[") {
            let inside = search[open.upperBound...]
            if inside.drop(while: { $0 == " " || $0 == "\n" }).first == "\"" {
                let close = try XCTUnwrap(inside.range(of: "]"), "\(name) is not closed")
                contents = inside[..<close.lowerBound]
                break
            }
            search = inside
        }
        return Set(Self.storedKeyLiterals(in: String(
            try XCTUnwrap(contents, "\(name) is not a list of string literals"))))
    }

    private static func storedKeyLiterals(in text: String) -> [String] {
        var found: [String] = []
        var rest = Substring(text)
        while let open = rest.range(of: "\"") {
            rest = rest[open.upperBound...]
            guard let close = rest.range(of: "\"") else { break }
            found.append(String(rest[..<close.lowerBound]))
            rest = rest[close.upperBound...]
        }
        return found
    }

    func testEveryStoredPreferenceIsEitherSyncedOrDeliberatelyLocal() throws {
        let sources = try Self.appSources()
        XCTAssertFalse(sources.isEmpty, "no app sources found at \(Self.appDirectory.path)")

        let model = try XCTUnwrap(sources.first { $0.name == "SZReaderApp.swift" }?.text)
        // Two lists make up the synced set: the shelf's own preferences, and
        // the source switches, which are a map because they have to be read
        // backwards as well — a key arriving from another device has to say
        // which source it is.
        let synced = try Self.declaredList(named: "syncedDefaultsKeys", in: model)
            .union(try Self.declaredList(named: "sourceDefaultsKeys", in: model))
        let local = try Self.declaredList(named: "deviceOnlyDefaultsKeys", in: model)
        XCTAssertFalse(synced.isEmpty, "the synced list came back empty — the reader is parsing it wrong")

        var unclassified: [String] = []
        for (name, text) in sources {
            for key in Self.storedKeys(in: text)
            where !synced.contains(key) && !local.contains(key) {
                unclassified.append("\(name): \(key)")
            }
        }
        XCTAssertEqual(unclassified, [],
                       "these preferences sync nowhere and nobody said they shouldn't — "
                     + "add each to syncedDefaultsKeys or deviceOnlyDefaultsKeys")
    }

    /// A key cannot be in both lists, which would be two answers to one
    /// question.
    func testNoPreferenceIsBothSyncedAndLocal() throws {
        let sources = try Self.appSources()
        let model = try XCTUnwrap(sources.first { $0.name == "SZReaderApp.swift" }?.text)
        let synced = try Self.declaredList(named: "syncedDefaultsKeys", in: model)
        let local = try Self.declaredList(named: "deviceOnlyDefaultsKeys", in: model)
        XCTAssertEqual(synced.intersection(local).sorted(), [])
    }

    /// Every source with a switch has to be reachable from a stored key, or a
    /// reader who switches it on here finds it off on their other device with
    /// no way to tell why.
    ///
    /// Checked against `IssueSite` itself rather than a written-down count, so
    /// adding a source is what makes this fail.
    func testEverySwitchableSourceHasASyncedKey() throws {
        let model = try XCTUnwrap(try Self.appSources()
            .first { $0.name == "SZReaderApp.swift" }?.text)
        let named = try Self.declaredList(named: "sourceDefaultsKeys", in: model)

        // The four spelled out by hand, plus the generated `show_<site>` for
        // the rest — which is the same rule `sourceDefaultsKeys` builds.
        let generated = Set(IssueSite.allCases.filter(\.isSwitchable).map { "show_\($0.rawValue)" })
        let covered = named.union(generated)

        let missing = IssueSite.allCases.filter(\.isSwitchable).filter { site in
            !covered.contains("show_\(site.rawValue)") && !named.contains(where: {
                // The hand-named four, matched by the site they stand for.
                ["showStripZona": IssueSite.stripzona, "showRetroSpec": .retrospec,
                 "showArchive": .archive, "showCBPlus": .comicbookplus][$0] == site
            })
        }
        XCTAssertEqual(missing.map(\.rawValue), [], "these sources would not follow the reader")
    }

    /// Local Files has no switch and must not gain a key: the folder on the
    /// device is the source, and a device without those files has nothing to
    /// show whatever any account says.
    func testLocalFilesIsNotSynced() throws {
        let model = try XCTUnwrap(try Self.appSources()
            .first { $0.name == "SZReaderApp.swift" }?.text)
        let named = try Self.declaredList(named: "sourceDefaultsKeys", in: model)
        XCTAssertFalse(named.contains("show_\(IssueSite.local.rawValue)"))
        XCTAssertFalse(IssueSite.local.isSwitchable)
    }
}

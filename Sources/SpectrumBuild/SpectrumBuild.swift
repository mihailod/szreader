import Foundation
import SZKit

/// Reports what ZXDB actually holds, before anything is built against it.
///
///     swift run spectrum-build --probe              # what is in there, write nothing
///     swift run spectrum-build --probe --no-network # from the cached dump alone
///
/// ZXDB is the database behind Spectrum Computing: everything published for
/// the Sinclair machines, magazines and books included. It is an *index*, not
/// an archive — which is the whole question this probe exists to answer, since
/// an index whose files live somewhere unreachable is not a source.
///
/// There are three places a scan can be, and they are not equally useful:
///
///   * `magazines.archive_mask` — a URL template for a whole issue, with the
///     issue's own numbers substituted in. This is the one that matters.
///   * `magazines.link_mask` — a template for a *single page*, so an issue is
///     as many fetches as it has pages. The app has that shape already, for
///     Stripovi, but it is the expensive one.
///   * the `files` and `downloads` tables — real recorded files, with sizes
///     and MD5s, but see the counts: for magazine issues there are almost
///     none. They are mostly covers.
///
/// The masks and the file links carry a prefix that decides which host serves
/// them, and two of the three prefixes resolve to a path *inside a zip* on
/// archive.org. That is the finding worth having before writing a downloader
/// against it, so counting it is what this does.
@main
struct SpectrumBuild {

    static func main() async throws {
        // Progress from a run that takes minutes is worth nothing if it
        // arrives all at once at the end, which is what happens by default the
        // moment stdout is a pipe rather than a terminal.
        setvbuf(stdout, nil, _IOLBF, 0)

        let arguments = Array(CommandLine.arguments.dropFirst())

        let root = URL(fileURLWithPath: #filePath)   // .../Sources/SpectrumBuild/<this>
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let dump = try await ZXDBDump.load(
            cache: root.appendingPathComponent(".zxdb-cache"),
            allowNetwork: !arguments.contains("--no-network"),
            // `publishers` and `labels` are what shelve the books by imprint.
            // Left out of this list, the join silently finds nothing and every
            // book lands under "Other publishers" — which is exactly what the
            // first build did, and the catalogue looked perfectly valid.
            tables: ["magazines", "issues", "files", "downloads",
                     "entries", "filetypes", "genretypes", "countries",
                     "publishers", "labels"])

        let cache = root.appendingPathComponent(".zxdb-cache")
        let builder = SpectrumCatalog(dump: dump, cache: cache,
                                      allowNetwork: !arguments.contains("--no-network"))

        if arguments.contains("--plan") {
            let (planned, unexpandable) = builder.plan()
            let books = builder.planBooks()
            print(String(repeating: "\u{2500}", count: 68))
            print("What a full build would ask for\n")
            for group in Spectrum.Group.inMenuOrder {
                let mine = group == .books ? books : planned.filter { $0.group == group }
                print("  \(group.display.padded(to: 12)) "
                      + "\(String(mine.count).leftPadded(to: 5)) rows  "
                      + "\(String(Set(mine.map(\.identifier)).count).leftPadded(to: 5)) items  "
                      + "\(String(Set(mine.map(\.seriesKey)).count).leftPadded(to: 4)) series")
            }
            if !unexpandable.isEmpty {
                print("\n  not expandable:")
                for (why, n) in unexpandable.sorted(by: { $0.value > $1.value }) {
                    print("      \(String(n).leftPadded(to: 5))  \(why)")
                }
            }
            return
        }

        if arguments.contains("--build") {
            guard let name = value(of: "--build", in: arguments),
                  let group = Spectrum.Group(rawValue: name) else {
                throw ZXDBDump.Failure(
                    "--build needs one of: "
                    + Spectrum.Group.allCases.map(\.rawValue).joined(separator: ", "))
            }
            let output = value(of: "--output", in: arguments).map { URL(fileURLWithPath: $0) }
                ?? root.appendingPathComponent(
                    "Sources/SZKit/Resources/\(group.resource).json")
            print(String(repeating: "\u{2500}", count: 68))
            print("Building \(group.resource)\n")
            try await builder.build(
                group: group,
                limit: value(of: "--limit", in: arguments).flatMap(Int.init),
                output: output)
            return
        }

        if arguments.contains("--validate") {
            let perToken = value(of: "--per-token", in: arguments).flatMap(Int.init) ?? 8
            print(String(repeating: "─", count: 68))
            print("Checking expanded masks against archive.org\n")
            await Validator(dump: dump, perToken: perToken).run()
            return
        }

        guard arguments.contains("--probe") else {
            throw ZXDBDump.Failure(
                "expected --probe (what ZXDB holds) or --validate (whether the "
                + "expanded masks resolve); no catalogue is built yet")
        }

        let report = Report(dump: dump)
        report.legend()
        report.masks()
        report.reachability()
        report.recordedFiles()
        report.books()
        report.inventory()
    }

    static func value(of flag: String, in arguments: [String]) -> String? {
        guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
        return arguments[i + 1]
    }
}

// MARK: - Where a path resolves to

/// What a ZXDB path prefix means.
///
/// From ZXDB's own README. The distinction that matters is the last column:
/// `/pub/` and `/nvg/` do not name files on a web server, they name entries
/// *inside a zip* that archive.org unpacks on demand. Such a URL is a real
/// download and does work, but it is served by extracting from a multi-gigabyte
/// archive per request — so it is slow, and range requests are not the plain
/// static-file behaviour the app's resume logic is written against.
enum ZXDBPath: String, CaseIterable {
    case zxdb   = "/zxdb/"
    case pub    = "/pub/"
    case nvg    = "/nvg/"

    var base: String {
        switch self {
        case .zxdb: return "https://spectrumcomputing.co.uk/zxdb/"
        case .pub:  return "https://archive.org/download/World_of_Spectrum_June_2017_Mirror/"
                         + "World%20of%20Spectrum%20June%202017%20Mirror.zip/"
                         + "World%20of%20Spectrum%20June%202017%20Mirror/"
        case .nvg:  return "https://archive.org/download/mirror-ftp-nvg/Mirror_ftp_nvg.zip/"
        }
    }

    /// Whether the resolved URL is an ordinary file on a web server.
    var isDirect: Bool { self == .zxdb }

    var label: String {
        switch self {
        case .zxdb: return "/zxdb/  spectrumcomputing.co.uk (direct)"
        case .pub:  return "/pub/   archive.org WoS mirror (INSIDE .zip)"
        case .nvg:  return "/nvg/   archive.org nvg mirror (INSIDE .zip)"
        }
    }

    static func of(_ link: String?) -> ZXDBPath? {
        guard let link else { return nil }
        return allCases.first { link.hasPrefix($0.rawValue) }
    }

    /// How a link that is not one of the three prefixes should be described.
    static func describe(_ link: String?) -> String {
        guard let link else { return "(none)" }
        if let known = of(link) { return known.rawValue }
        if link.contains(".zip/") { return "(absolute, inside .zip)" }
        if link.hasPrefix("http") {
            let host = link.split(separator: "/").dropFirst().first.map(String.init) ?? "?"
            return "(absolute: \(host))"
        }
        return "(unrecognised)"
    }
}

// MARK: - The report

struct Report {
    let dump: ZXDBDump

    /// Filetypes worth naming. The numbers are ZXDB's own; the probe prints
    /// the table's text beside them so a renumbering shows up rather than
    /// quietly selecting the wrong thing.
    static let magazineIssue = "56"
    static let electronicMagazine = "47"
    static let magazineCover = "55"
    static let completeBook = "46"
    static let booklet = "60"

    private var filetypes: [String: String] {
        Dictionary(uniqueKeysWithValues: dump["filetypes"].compactMap { row in
            guard let id = row["id"], let text = row["text"] else { return nil }
            return (id, text)
        })
    }

    private var magazines: [String: ZXDBDump.Row] {
        Dictionary(uniqueKeysWithValues: dump["magazines"].compactMap { row in
            guard let id = row["id"] else { return nil }
            return (id, row)
        })
    }

    // MARK: 0. Legend

    /// What the three prefixes resolve to, printed before the counts that use
    /// them — the counts mean nothing until you know that two of the three are
    /// not web servers.
    func legend() {
        heading("0. What a ZXDB path prefix resolves to")
        for path in ZXDBPath.allCases {
            print("  \(path.label)")
            print("      → \(path.base)")
            print("      \(path.isDirect ? "ordinary file" : "extracted from a zip per request")\n")
        }
    }

    // MARK: 1. Masks

    func masks() {
        heading("1. Where a magazine says its scans are")

        let mags = dump["magazines"]
        print("  \(mags.count) magazines")

        for column in ["archive_mask", "link_mask"] {
            var shapes: [String: Int] = [:]
            var used = 0
            for row in mags {
                guard let mask = row[column] else { continue }
                used += 1
                shapes[ZXDBPath.describe(mask), default: 0] += 1
            }
            print("\n  \(column): \(used) magazines")
            for (shape, n) in shapes.sorted(by: { $0.value > $1.value }) {
                print("      \(shape.padded(to: 30)) \(n)")
            }
        }

        let issues = dump["issues"]
        let perIssue = ["archive_mask", "link_mask"].map { column in
            "\(column)=\(issues.filter { $0[column] != nil }.count)"
        }
        print("\n  per-issue overrides: \(perIssue.joined(separator: " "))")
        print("      (an issue's own mask wins over its magazine's — a build")
        print("       that reads only the magazine row gets these wrong)")
    }

    // MARK: 2. Reachability

    func reachability() {
        heading("2. How many issues that actually reaches")

        let mags = magazines
        let typeNames = ["P": "Paper magazine", "E": "Electronic magazine",
                         "Z": "Newsletter/zine"]
        var tally: [String: [String: Int]] = [:]

        for issue in dump["issues"] {
            guard let magazineID = issue["magazine_id"] else { continue }
            let magazine = mags[magazineID]
            let type = magazine?["magtype_id"] ?? "?"

            // The issue's own mask first, then its magazine's. Whole-issue
            // beats per-page: if both exist, the app wants the one file.
            let route: String
            if issue["archive_mask"] != nil || magazine?["archive_mask"] != nil {
                route = "whole issue (archive_mask)"
            } else if issue["link_mask"] != nil || magazine?["link_mask"] != nil {
                route = "per page  (link_mask)"
            } else {
                route = "no mask — unreachable"
            }
            tally[type, default: [:]][route, default: 0] += 1
        }

        for (type, name) in typeNames.sorted(by: { $0.key < $1.key }) {
            let rows = tally[type] ?? [:]
            print("\n  \(name): \(rows.values.reduce(0, +)) issues")
            for (route, n) in rows.sorted(by: { $0.value > $1.value }) {
                print("      \(route.padded(to: 30)) \(n)")
            }
        }
    }

    // MARK: 3. Recorded files

    func recordedFiles() {
        heading("3. What the files table actually holds")
        print("  (files rows are magazine material: issue_id is set)\n")

        let names = filetypes
        let interesting = [Self.magazineIssue, Self.electronicMagazine, Self.magazineCover]
        var byType: [String: [String: Int]] = [:]
        var extensions: [String: [String: Int]] = [:]

        for row in dump["files"] {
            guard let type = row["filetype_id"], interesting.contains(type) else { continue }
            let link = row["file_link"]
            byType[type, default: [:]][ZXDBPath.describe(link), default: 0] += 1
            extensions[type, default: [:]][link.fileExtension, default: 0] += 1
        }

        for type in interesting {
            let counts = byType[type] ?? [:]
            let total = counts.values.reduce(0, +)
            print("  \(names[type] ?? type) (type \(type)): \(total) files")
            for (shape, n) in counts.sorted(by: { $0.value > $1.value }) {
                print("      \(shape.padded(to: 30)) \(n)")
            }
            let ext = (extensions[type] ?? [:]).sorted { $0.value > $1.value }
                .prefix(5).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
            print("      ext: \(ext)\n")
        }
    }

    // MARK: 4. Books

    func books() {
        heading("4. Books")

        // ZXDB files books as entries, the same table as games, told apart by
        // genre. There is no "books" table.
        let genres = dump["genretypes"]
        let bookGenres = Set(genres.compactMap { row -> String? in
            guard let id = row["id"], let text = row["text"] else { return nil }
            return text.hasPrefix("Book:") || text == "E-Book" ? id : nil
        })
        let genreNames = Dictionary(uniqueKeysWithValues: genres.compactMap { row in
            row["id"].flatMap { id in row["text"].map { (id, $0) } }
        })

        var bookIDs: Set<String> = []
        var byGenre: [String: Int] = [:]
        for row in dump["entries"] {
            guard let genre = row["genretype_id"], bookGenres.contains(genre),
                  let id = row["id"] else { continue }
            bookIDs.insert(id)
            byGenre[genreNames[genre] ?? genre, default: 0] += 1
        }
        print("  \(bookIDs.count) book entries")
        for (genre, n) in byGenre.sorted(by: { $0.value > $1.value }) {
            print("      \(genre.padded(to: 24)) \(n)")
        }

        // A book's scan lives in `downloads`, not `files` — downloads hangs
        // off entries, files hangs off magazine issues.
        let readable = [Self.completeBook, Self.booklet]
        var shapes: [String: Int] = [:]
        var extensions: [String: Int] = [:]
        var withScan: Set<String> = []
        for row in dump["downloads"] {
            guard let entry = row["entry_id"], bookIDs.contains(entry),
                  let type = row["filetype_id"], readable.contains(type) else { continue }
            withScan.insert(entry)
            let link = row["file_link"]
            shapes[ZXDBPath.describe(link), default: 0] += 1
            extensions[link.fileExtension, default: 0] += 1
        }
        print("\n  readable scans (Complete book / Booklet): "
              + "\(shapes.values.reduce(0, +)) files across \(withScan.count) books")
        for (shape, n) in shapes.sorted(by: { $0.value > $1.value }) {
            print("      \(shape.padded(to: 30)) \(n)")
        }
        let ext = extensions.sorted { $0.value > $1.value }
            .prefix(6).map { "\($0.key) \($0.value)" }.joined(separator: ", ")
        print("      ext: \(ext)")
    }

    // MARK: 5. Inventory

    func inventory() {
        heading("5. What is in there — paper magazines with a whole-issue route")

        var counts: [String: Int] = [:]
        for issue in dump["issues"] {
            guard let id = issue["magazine_id"] else { continue }
            counts[id, default: 0] += 1
        }
        let countryNames = Dictionary(uniqueKeysWithValues: dump["countries"].compactMap { row in
            row["id"].flatMap { id in row["text"].map { (id, $0) } }
        })

        let titles = magazines.values
            .filter { $0["magtype_id"] == "P" && $0["archive_mask"] != nil }
            .sorted { counts[$0["id"] ?? "", default: 0] > counts[$1["id"] ?? "", default: 0] }

        print("  \(titles.count) titles\n")
        for row in titles.prefix(50) {
            let n = counts[row["id"] ?? "", default: 0]
            let country = row["country_id"].flatMap { countryNames[$0] } ?? "?"
            print("      \(String(n).leftPadded(to: 5))  "
                  + "\((row["name"] ?? "?").padded(to: 38))  \(country)")
        }
        if titles.count > 50 { print("      … and \(titles.count - 50) more") }

        var byCountry: [String: Int] = [:]
        for row in titles {
            let country = row["country_id"].flatMap { countryNames[$0] } ?? "?"
            byCountry[country, default: 0] += 1
        }
        print("\n  by country:")
        for (country, n) in byCountry.sorted(by: { $0.value > $1.value }).prefix(14) {
            print("      \(country.padded(to: 18)) \(n)")
        }
    }

    private func heading(_ text: String) {
        print("\n\(String(repeating: "─", count: 68))\n\(text)\n")
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

extension Optional where Wrapped == String {
    /// The extension of a path, or `(none)`.
    ///
    /// Guards the dotless case, which `split(separator: ".").last` answers
    /// with the whole path — two ZXDB rows are `readme` files with no suffix
    /// at all, and they printed as their full path in the first run of this.
    var fileExtension: String {
        guard let self, let dot = self.lastIndex(of: "."),
              dot < self.index(before: self.endIndex) else { return "(none)" }
        let ext = self[self.index(after: dot)...].lowercased()
        return ext.contains("/") ? "(none)" : ext
    }
}

import Foundation
import SZKit

/// Builds the shipped bombjack catalogue.
///
///     swift run bombjack-build                # walk what is missing, rebuild
///     swift run bombjack-build --no-network   # rebuild from the cache alone
///
/// The same shape as `retrospec-build`, and for the same reasons: it parses
/// with `BombJack`, the code the tests cover, and it caches every page under
/// `.bombjack-cache/` so the site is asked for each one exactly once.
///
/// **This site's robots.txt asks crawlers not to.** It says `Disallow: /` with
/// a comment reading "go away", on both the root and this subdomain. Building
/// this index is that request being set aside deliberately, by the person
/// running the tool, to evaluate whether the source is worth asking its owner
/// about. It is not something to run casually or repeatedly: the cache exists
/// so that one pass is all that is ever spent, and the pace below is set to
/// one page a second for a hobby server paid for out of somebody's pocket.
@main
struct BombJackBuild {

    static let root = "https://commodore.bombjack.org/"
    /// Stop rather than walk forever. The tree is deep and self-referential —
    /// year archives link back into every platform — so this is the safety
    /// rail, not an estimate of the size.
    ///
    /// It was 2,500 for the first pass and that bound: the walk stopped with
    /// the queue still full, and the platforms reached last — aquarius,
    /// calculators, oric-1, hp — came out with nothing at all. High enough now
    /// that the queue drains and the rail is only a rail.
    static let pageLimit = 25_000

    static func main() async throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        let allowNetwork = !arguments.contains("--no-network")
        arguments.removeAll { $0 == "--no-network" }

        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let output = repo.appendingPathComponent("Sources/SZKit/Resources/bombjack-catalog.json")
        let cacheDirectory = repo.appendingPathComponent(".bombjack-cache")
        let cache = PageCache(directory: cacheDirectory, allowNetwork: allowNetwork)
        var prober = Prober(file: cacheDirectory.appendingPathComponent("archive-status.json"),
                            allowNetwork: allowNetwork && !arguments.contains("--no-probe"))

        // 1. Walk the tree, breadth first, collecting every cell that links an
        //    archive. Breadth first so that a run stopped early has covered
        //    the shallow, high-value pages rather than one deep corner.
        var queue = [root]
        var visited: Set<String> = []
        var pages: [(url: String, title: String, entries: [BombJackEntry])] = []

        while let url = queue.first, visited.count < pageLimit {
            queue.removeFirst()
            guard visited.insert(url).inserted else { continue }
            guard let html = try await cache.page(url) else { continue }

            let entries = isChangelog(url) ? [] : BombJack.entries(in: html, pageURL: url)
            if !entries.isEmpty {
                pages.append((url, pageTitle(html) ?? url, entries))
                print("  \(entries.count) items  \(pageTitle(html) ?? url)")
            }
            for link in BombJack.pageLinks(in: html, pageURL: url) where !visited.contains(link) {
                queue.append(link)
            }
        }
        print("\nwalked \(visited.count) pages, \(pages.count) of them with archives")

        // 2. Turn pages into runs, in two passes.
        //
        // A run's name is the last segment of the page's own title, and on its
        // own that is not enough: twenty-one separate pages are titled
        // "... - Books", so the shelf's Series filter ended up listing "Books"
        // twenty-one times with nothing to tell them apart. So the short name
        // is worked out first, and any that collides is re-made with the
        // platform it belongs to in front of it — "Commodore - Books".
        var shortNames: [String] = []
        for page in pages { shortNames.append(runName(page.title, url: page.url)) }
        var nameUses: [String: Int] = [:]
        for name in shortNames { nameUses[name, default: 0] += 1 }

        var series: [ShippedCatalog.Series] = []
        var issues: [ShippedCatalog.Issue] = []
        var usedKeys: Set<String> = []
        var usedIDs: Set<String> = []
        var usedNames: Set<String> = []
        var dropped = 0
        // Every archive already written, so the same file is never listed
        // twice. The tree reaches one page under several addresses — with a
        // trailing slash, as `index.htm`, through a year archive — and the
        // walk sees each as new. Left alone that put the Atari ST Basic
        // Sourcebook on the shelf five times, under five runs of the same
        // name, and 600 rows across the catalogue were repeats.
        var seenFiles: Set<String> = []

        // A directory listing shows the files in its subdirectories too, so
        // the same archive is reachable at `/generic/X.pdf` and at
        // `/generic/advertisements/X.pdf`. Those are one file at two
        // addresses, and left alone a quarter of the catalogue was a second
        // copy of something already in it.
        //
        // The deeper path wins: it is the one filed under a directory that
        // says what the thing is, which is also the better run name. Only
        // parent/child pairs are folded — two files of the same name in
        // unrelated directories, an Atari book and a Commodore one, are two
        // books and stay two.
        var deepest: [String: String] = [:]
        for page in pages {
            for entry in page.entries {
                guard let file = usableURL(entry.file) else { continue }
                let name = file.lowercased().components(separatedBy: "/").last ?? file
                guard let rival = deepest[name] else { deepest[name] = file; continue }
                let a = file.components(separatedBy: "/").dropLast().joined(separator: "/")
                let b = rival.components(separatedBy: "/").dropLast().joined(separator: "/")
                if a.hasPrefix(b + "/") { deepest[name] = file }
                else if !b.hasPrefix(a + "/") { deepest[name] = rival }  // unrelated: leave it
            }
        }
        /// Whether this address is the one kept for its file name.
        func isPreferred(_ file: String) -> Bool {
            let name = file.lowercased().components(separatedBy: "/").last ?? file
            guard let winner = deepest[name], winner != file else { return true }
            let a = file.components(separatedBy: "/").dropLast().joined(separator: "/")
            let b = winner.components(separatedBy: "/").dropLast().joined(separator: "/")
            // Only defer to the winner when one really contains the other.
            return !(b.hasPrefix(a + "/") || a.hasPrefix(b + "/"))
        }

        var repeated = 0, notReadable = 0, missing = 0
        for (index, page) in pages.enumerated() {
            let short = shortNames[index]
            var name = (nameUses[short] ?? 0) > 1
                ? [platform(of: page.url), short].compactMap { $0 }.joined(separator: " - ")
                : short
            // Two genuinely different pages can still land on one name — a
            // platform with more than one shelf of books. The page's own file
            // name is what tells those apart, and it is unique by definition.
            if usedNames.contains(name), let stem = pageStem(page.url) {
                name = "\(name) (\(stem))"
            }
            // And if even that collides, count. A run name has to be unique
            // because the Series filter shows nothing else, so this is an
            // invariant rather than a preference — `ShippedBombJackCatalog`
            // asserts it, and it is what caught the last two.
            if usedNames.contains(name) {
                var attempt = 2
                while usedNames.contains("\(name) \(attempt)") { attempt += 1 }
                name = "\(name) \(attempt)"
            }

            var key = Fold.fold(name).replacingOccurrences(of: " ", with: "-")
            if key.isEmpty { key = "page-\(series.count)" }
            var unique = key, n = 2
            while !usedKeys.insert(unique).inserted { unique = "\(key)-\(n)"; n += 1 }

            var written = 0
            for entry in page.entries {
                // Anything that is not a real address on a host this source
                // actually uses is dropped rather than shipped. The tree
                // contains hrefs like "https:///commodore.bombjack.org/..." —
                // three slashes, no host, a typo in the site's own markup —
                // and a handful pointing at other people's servers entirely.
                guard let file = usableURL(entry.file) else { dropped += 1; continue }
                guard isPublication(file) else { notReadable += 1; continue }
                guard isPreferred(file) else { repeated += 1; continue }
                guard seenFiles.insert(file).inserted else { repeated += 1; continue }

                // What the server actually has. A link the pages still list
                // but the server no longer serves is not an issue — it is a
                // tap that fails, and about one in ten of them is that.
                let answer = await prober.answer(for: file)
                if let answer, answer.status == 404 { missing += 1; continue }

                let date = dateIn(entry.title)
                var id = identifier(file)
                var m = 2
                while !usedIDs.insert(id).inserted { id = "\(identifier(file))-\(m)"; m += 1 }

                issues.append(ShippedCatalog.Issue(
                    id: id, series: unique, number: written + 1,
                    title: entry.title, year: date.year, month: date.month,
                    zip: file, cover: entry.cover.flatMap { usableURL($0, requireHTTPS: false) },
                    thumb: nil,
                    bytes: answer?.bytes, pages: entry.pages, dead: nil))
                written += 1
            }
            // A page whose every entry was unusable is not a run.
            if written > 0 {
                usedNames.insert(name)
                series.append(ShippedCatalog.Series(key: unique, name: name,
                                                    code: unique, language: "en"))
            } else {
                usedKeys.remove(unique)
            }
        }
        print("dropped \(dropped) with no usable address, \(repeated) repeats, "
              + "\(notReadable) disk contents, \(missing) gone from the server")

        // 3. Joystik, which lives on two other hosts entirely: the scans on
        //    xmission, the covers on bombjack's arcade side. Listed by hand
        //    because there are ten of them, the run is finished, and the site
        //    says so — "9 regular issues and 1 special edition were published".
        let (joystikSeries, joystikIssues) = joystik()
        series.append(joystikSeries)
        issues += joystikIssues

        // One file per category rather than one of eighteen thousand.
        //
        // Shipped whole, this took fifteen seconds to seed and froze the app
        // in both directions; nobody wants all of it either. Split, each piece
        // is a size the app handles without noticing and a reader switches on
        // the parts they care about.
        //
        // `base` is empty and every URL is absolute. The other two catalogues
        // share one prefix and store it once; this source spans three hosts —
        // commodore.bombjack.org, bombjack.org and arcarc.xmission.com — so
        // there is no prefix to share and pretending otherwise would mean
        // rewriting URLs at read time.
        let generated = ISO8601DateFormatter().string(from: Date()).prefix(10).description
        let runs = Dictionary(uniqueKeysWithValues: series.map { ($0.key, $0) })

        var written: [(BombJack.Category, Int)] = []
        for category in BombJack.Category.allCases {
            let mine = issues.filter { BombJack.category(of: $0.zip) == category }
            guard !mine.isEmpty else { continue }
            // Only the runs this category actually uses: a catalogue that
            // names series it has no issues for is a filter menu full of
            // empty rows.
            let used = Set(mine.map(\.series)).compactMap { runs[$0] }
                .sorted { $0.key < $1.key }

            let file = ShippedCatalog(version: ShippedCatalog.currentVersion,
                                      generated: generated, base: "",
                                      series: used, issues: mine)
            let path = repo.appendingPathComponent(
                "Sources/SZKit/Resources/\(category.resource).json")
            try ShippedCatalog.encoder().encode(file).write(to: path)
            written.append((category, mine.count))
        }

        print()
        for (category, count) in written.sorted(by: { $0.1 > $1.1 }) {
            print("  \(pad(category.display, to: 20)) \(count)")
        }
        print("\n\(issues.count) issues across \(series.count) runs, "
              + "in \(written.count) catalogues")
    }

    /// Pads a name so the summary lines up.
    private static func pad(_ s: String, to width: Int) -> String {
        s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
    }

    // MARK: - Reading a page

    static func pageTitle(_ html: String) -> String? {
        guard let found = firstGroup(#"(?is)<title>(.*?)</title>"#, in: html) else { return nil }
        let title = BombJack.text(found)
        return title.isEmpty ? nil : title
    }

    /// The first capture group of a pattern, or nil.
    ///
    /// SZKit's `Rx` is internal to it, and this tool needs three patterns —
    /// not enough to justify widening that type's visibility just so a build
    /// script can share it.
    static func firstGroup(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound
        else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Hosts this source is allowed to point at.
    ///
    /// The archive links out to other people's servers here and there — a
    /// bookshop, another preservation site — and those are somebody else's
    /// files on somebody else's bandwidth, not this source.
    static let allowedHosts: Set<String> = [
        "commodore.bombjack.org", "bombjack.org", "www.bombjack.org",
        "arcarc.xmission.com",
    ]

    /// The one host that serves TLS.
    ///
    /// Measured, not assumed: `bombjack.org` and `www.bombjack.org` refuse a
    /// TLS connection outright — not a bad certificate, no HTTPS at all — while
    /// `commodore.bombjack.org` serves the whole archive over it. So an
    /// http link is an inconsistency worth correcting on one of these hosts
    /// and a fact of life on the others.
    static let httpsHosts: Set<String> = ["commodore.bombjack.org", "arcarc.xmission.com"]

    /// One address, normalised, or nil if it is not one this source can use.
    ///
    /// - Parameter requireHTTPS: true for downloads, which must not go over
    ///   cleartext. False for covers: the Joystik ones are on a host with no
    ///   TLS at all, and the alternative to fetching them over http is ten
    ///   grey rectangles.
    /// Whether an address is a publication rather than the software that came
    /// with one.
    ///
    /// Everything under `/disks/` is a magazine's cover-mounted floppy: the
    /// programs that shipped *with* the issue, one file per program. They land
    /// on a shelf as "worldgam tap", "battlecards", "staf13" — real files, but
    /// not something anyone can read, and nothing this app can open.
    ///
    /// PDFs there are kept, and that distinction is the whole rule: the same
    /// directories also hold scanned disk inlays and newsletters like The
    /// Spinner, which are exactly what the shelf is for.
    static func isPublication(_ url: String) -> Bool {
        let lowered = url.lowercased()
        guard lowered.contains("/disks/") else { return true }
        // A magazine's cover disk is the software that shipped with the issue,
        // not the issue: Zzap64's extras and Compute Gazette's disk-utility
        // screens, which land on a shelf as "battlecards" and "0-Edit-mode".
        // Junk whether they are zipped programs or PDFs of a menu.
        if lowered.contains("/disks/magazines/") { return false }
        // Everywhere else under `/disks/`, a PDF is a scan worth having — The
        // Spinner's newsletters, disk-label artwork, book supplements — and a
        // zip is a disk image nothing here can open.
        return lowered.hasSuffix(".pdf")
    }

    static func usableURL(_ raw: String, requireHTTPS: Bool = true) -> String? {
        guard var parts = URLComponents(string: raw),
              let host = parts.host?.lowercased(), !host.isEmpty,
              allowedHosts.contains(host)
        else { return nil }
        // 581 links are written as plain http while ten thousand on the very
        // same host are https, so the scheme there is a slip in hand-written
        // markup rather than a statement about the server.
        if parts.scheme?.lowercased() == "http", httpsHosts.contains(host) {
            parts.scheme = "https"
        }
        // A download has to be fetchable over TLS, which means being on a
        // host that serves it. Checking the scheme alone is not enough: the
        // tree contains links written as https to a host that answers no TLS
        // connection at all, and that link is simply dead.
        if requireHTTPS, parts.scheme?.lowercased() != "https" || !httpsHosts.contains(host) {
            return nil
        }
        // Written back lowercased. The tree spells the same host three ways —
        // "Commodore.Bombjack.org" among them — and while DNS does not care,
        // a catalogue that stores one host under several spellings is one
        // every later check has to remember to normalise.
        parts.host = host
        return parts.url?.absoluteString
    }

    /// Whether a page is a record of what was added in some year rather than
    /// a run of anything.
    ///
    /// `archive/index-archive-2014.htm` and its siblings are changelogs. They
    /// list files that live on real pages elsewhere, and they lay their cells
    /// out differently — what sits above the link is the scanner's credit, not
    /// a title, so entries taken from them arrive called "This was scanned and
    /// imaged by MadMax . Games (VIC-20)".
    ///
    /// Skipped for entries but still followed for links: they point at the
    /// real pages, which is exactly where those files should be claimed from.
    ///
    /// Matched on the path rather than the title. Several perfectly good pages
    /// are titled "... Main Page" — the generic books shelf is 99 real books —
    /// and a rule written against titles would have thrown those away.
    static func isChangelog(_ url: String) -> Bool {
        url.lowercased().contains("/archive/index-archive-")
    }

    /// A page's own file name, prettified — the last resort for telling two
    /// runs apart when the tree gives them the same title.
    static func pageStem(_ url: String) -> String? {
        guard let last = URL(string: url)?.deletingPathExtension().lastPathComponent,
              !last.isEmpty, last != "index" else { return nil }
        return last.replacingOccurrences(of: "-", with: " ")
                   .split(separator: " ")
                   .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                   .joined(separator: " ")
    }

    /// The platform a page belongs to, from the first segment of its path.
    static func platform(of url: String) -> String? {
        guard let path = URL(string: url)?.pathComponents.dropFirst().first,
              !path.hasSuffix(".htm"), !path.hasSuffix(".html") else { return nil }
        return path.replacingOccurrences(of: "-", with: " ")
                   .split(separator: " ")
                   .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                   .joined(separator: " ")
    }

    /// What to call the run a page holds.
    ///
    /// Normally the last segment of its title. Some corners of the tree are
    /// served as bare Apache listings whose title is "Index of /atari-st/…",
    /// which is a directory rather than a name, so those are named from the
    /// path instead.
    static func runName(_ title: String, url: String) -> String {
        if title.lowercased().hasPrefix("index of") {
            // The last path segment names the run — unless it is a container
            // rather than a name. A newsletter kept at `…/64plus4/pdf/` is the
            // 64plus4 run; sixteen runs were called "Pdf" before this.
            let containers: Set<String> = ["pdf", "pdfs", "zip", "zips", "files",
                                           "images", "img", "thumbnails", "thumbs",
                                           "scans", "docs", "download", "downloads"]
            let parts = (URL(string: url)?.pathComponents ?? []).filter { $0 != "/" }
            let segment = parts.reversed().first { !containers.contains($0.lowercased()) }
                ?? parts.last ?? title
            return segment.replacingOccurrences(of: "-", with: " ")
                          .split(separator: " ")
                          .map { $0.prefix(1).uppercased() + $0.dropFirst() }
                          .joined(separator: " ")
        }
        return tidy(seriesName(title))
    }

    /// Trims the wording the site uses for navigation out of a run's name.
    /// "Q-link Main Page" is the Q-Link run; the two words say where you are,
    /// not what it is.
    static func tidy(_ name: String) -> String {
        var out = name
        for tail in [" Main Page", " main page"] where out.hasSuffix(tail) {
            out = String(out.dropLast(tail.count))
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// "Commodore - Magazines - Ahoy" is the Ahoy run.
    ///
    /// The last segment names the thing; the ones before it are where it sits
    /// in the tree. A title with no dashes is its own name.
    static func seriesName(_ title: String) -> String {
        let parts = title.components(separatedBy: " - ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return parts.last ?? title
    }

    /// A stable id for one archive: its path, minus the host and the extension.
    static func identifier(_ url: String) -> String {
        guard let parsed = URL(string: url) else { return url }
        let path = parsed.deletingPathExtension().path
            .removingPercentEncoding ?? parsed.deletingPathExtension().path
        return path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                   .replacingOccurrences(of: "/", with: "_")
    }

    private static let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
                                 "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]

    /// The cover date a cell states, when it states one.
    ///
    /// Magazines say "Issue 01 1984 Jan"; books say nothing, and get nil
    /// rather than a guess.
    static func dateIn(_ title: String) -> (year: Int?, month: Int?) {
        let y = firstGroup(#"\b(19[5-9]\d|20[0-2]\d)\b"#, in: title).flatMap { Int($0) }
        let lowered = title.lowercased()
        let m = months.first { lowered.contains($0.key) }?.value
        return (y, y == nil ? nil : m)
    }
}

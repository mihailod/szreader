import Foundation
import SZKit

/// Checks expanded masks against the live archive.
///
/// The expander's unit tests prove it agrees with ZXDB's README. They cannot
/// prove the README is right, and two tokens are genuinely ambiguous — `{y2}`,
/// which the wording says is a minimum width but which would then be identical
/// to `{y4}`, and `{M#}`, whose truncation rule the database never exercises.
/// Only archive.org can settle those, so this asks it.
///
/// Sampled by token rather than at random. A uniform sample of eleven thousand
/// issues would be almost entirely `{i2}` and `{y4}`, and would say nothing
/// about the fifty-four `{y2}` masks that are the actual question. Drawing a
/// fixed number per token means every reading gets tested, and a token read
/// wrongly shows up as one column at zero rather than as a rounding error in
/// the total.
struct Validator {
    let dump: ZXDBDump
    /// How many issues to check per distinct token.
    let perToken: Int

    /// One issue, and the mask that should reach it.
    struct Candidate {
        let magazine: String
        let mask: String
        let tokens: [String]
        let issue: ZXDBMask.Issue
    }

    // MARK: - Building the sample

    func candidates() -> [Candidate] {
        let magazines = Dictionary(uniqueKeysWithValues: dump["magazines"].compactMap {
            row in row["id"].map { ($0, row) }
        })
        var all: [Candidate] = []

        for issue in dump["issues"] {
            guard let magazineID = issue["magazine_id"],
                  let magazine = magazines[magazineID],
                  magazine["magtype_id"] == "P" else { continue }
            // The issue's own mask wins over its magazine's.
            guard let mask = issue["archive_mask"] ?? magazine["archive_mask"]
            else { continue }

            all.append(Candidate(
                magazine: magazine["name"] ?? magazineID,
                mask: mask,
                tokens: Self.tokens(in: mask),
                issue: ZXDBMask.Issue(
                    number: issue.int("number"),
                    volume: issue.int("volume"),
                    year: issue.int("date_year"),
                    month: issue.int("date_month"),
                    day: issue.int("date_day"),
                    special: issue["special"],
                    supplement: issue["supplement"])))
        }
        return all
    }

    /// A sample that covers every token, spread across magazines.
    ///
    /// Spread deliberately: ten issues of one magazine test one publisher's
    /// file naming ten times over. Different magazines using the same token is
    /// what tells a token misread from one archive.org item being incomplete.
    func sample(from all: [Candidate]) -> [Candidate] {
        var chosen: [Candidate] = []
        var seen: Set<String> = []
        var vocabulary: Set<String> = []
        for candidate in all { vocabulary.formUnion(candidate.tokens) }

        for token in vocabulary.sorted() {
            let users = all.filter { $0.tokens.contains(token) }
            var perMagazine: [String: Int] = [:]
            var taken = 0
            for candidate in users {
                guard taken < perToken else { break }
                // At most two issues from any one magazine per token.
                guard perMagazine[candidate.magazine, default: 0] < 2 else { continue }
                guard case .success(let url) =
                        ZXDBMask.url(candidate.mask, for: candidate.issue) else { continue }
                guard !seen.contains(url.absoluteString) else { continue }
                seen.insert(url.absoluteString)
                perMagazine[candidate.magazine, default: 0] += 1
                chosen.append(candidate)
                taken += 1
            }
        }
        return chosen
    }

    static func tokens(in mask: String) -> [String] {
        var found: [String] = []
        var rest = Substring(mask)
        while let open = rest.firstIndex(of: "{") {
            guard let close = rest[open...].firstIndex(of: "}") else { break }
            found.append("{" + rest[rest.index(after: open)..<close] + "}")
            rest = rest[rest.index(after: close)...]
        }
        return found
    }

    // MARK: - Asking the archive

    /// What became of one expanded mask.
    ///
    /// Three outcomes rather than pass/fail, because they call for three
    /// different responses from the build. Only `missingItem` means the
    /// expansion was wrong.
    enum Outcome {
        /// The item exists and holds the file the mask names.
        case ok
        /// The item exists, but under a different filename. The *identifier*
        /// half of the mask was right and the filename half is stale — the
        /// build can recover this by asking the item what it holds.
        case wrongFilename(has: [String])
        /// No such item. Either the mask expanded wrongly or the scan was
        /// never uploaded.
        case missingItem
        case error(String)
    }

    func run() async {
        let all = candidates()
        let chosen = sample(from: all)
        print("  \(all.count) paper-magazine issues have a whole-issue mask")
        print("  checking \(chosen.count) of them, up to \(perToken) per token")
        print("  via the metadata API, not /download/ — it is the same question")
        print("  asked more cheaply, and the client behind it forgives a 5xx\n")

        let client = ArchiveOrgClient(transport: URLSessionTransport())
        var items: [String: ArchiveOrgItem?] = [:]      // one lookup per item
        var byToken: [String: (ok: Int, bad: Int)] = [:]
        var wrongNames: [(Candidate, String, [String])] = []
        var missing: [(Candidate, String)] = []
        var ok = 0

        for (n, candidate) in chosen.enumerated() {
            guard case .success(let url) =
                    ZXDBMask.url(candidate.mask, for: candidate.issue) else { continue }
            guard let (identifier, filename) = Self.split(url) else { continue }

            if items[identifier] == nil {
                items[identifier] = try? await client.item(identifier)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let item = items[identifier] ?? nil

            let outcome: Outcome
            if let item {
                let names = item.files.map(\.name)
                outcome = names.contains(filename)
                    ? .ok
                    : .wrongFilename(has: names.filter { $0.lowercased().hasSuffix(".pdf") })
            } else {
                outcome = .missingItem
            }

            switch outcome {
            case .ok:
                ok += 1
            case .wrongFilename(let has):
                wrongNames.append((candidate, url.absoluteString, has))
            case .missingItem, .error:
                missing.append((candidate, url.absoluteString))
            }

            // Only a missing *item* counts against a token. A stale filename
            // says nothing about whether the tokens were read correctly — the
            // identifier it built was right.
            let goodForToken = if case .missingItem = outcome { false } else { true }
            for token in Set(candidate.tokens) {
                var tally = byToken[token] ?? (0, 0)
                if goodForToken { tally.ok += 1 } else { tally.bad += 1 }
                byToken[token] = tally
            }

            if (n + 1) % 25 == 0 {
                print("  \(n + 1)/\(chosen.count) — \(ok) exact, "
                      + "\(wrongNames.count) renamed, \(missing.count) missing")
            }
        }

        let resolved = ok + wrongNames.count
        let total = max(chosen.count, 1)
        print("""

          \(resolved)/\(chosen.count) expanded to a real archive.org item \
        (\(resolved * 100 / total)%)
              of those, \(ok) also name the right file, \
        \(wrongNames.count) name a file the item does not have
          \(missing.count)/\(chosen.count) reached no item at all

        """)

        print("  by token — counting only whether the ITEM resolved:")
        for token in byToken.keys.sorted() {
            let tally = byToken[token] ?? (0, 0)
            let seen = tally.ok + tally.bad
            let rate = seen == 0 ? 0 : tally.ok * 100 / seen
            let flag = rate < 90 ? "   <-- suspect" : ""
            print("      \(token.padded(to: 8)) \(String(rate).padded(to: 4))% of \(seen)\(flag)")
        }

        if !wrongNames.isEmpty {
            print("\n  item found, filename stale (first 8 of \(wrongNames.count)):")
            for (candidate, url, has) in wrongNames.prefix(8) {
                print("      \(candidate.magazine)")
                print("        mask says: \(url.split(separator: "/").last ?? "")")
                print("        item has:  \(has.prefix(3).joined(separator: ", "))")
            }
        }
        if !missing.isEmpty {
            print("\n  no such item (first 10 of \(missing.count)):")
            for (candidate, url) in missing.prefix(10) {
                print("      \(candidate.magazine)  \(url)")
            }
        }
    }

    /// The identifier and filename inside an `archive.org/download/<id>/<path>`
    /// URL, percent-decoded so it can be compared with the metadata listing.
    static func split(_ url: URL) -> (String, String)? {
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 3, parts[0] == "download" else { return nil }
        let identifier = String(parts[1])
        let file = parts.dropFirst(2).joined(separator: "/")
        return (identifier, file.removingPercentEncoding ?? file)
    }
}

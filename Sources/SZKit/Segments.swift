import Foundation

/// A single download covering a run of issues.
///
/// Sirius is why this exists: every individual link on its page is dead, and
/// what survives is three archives — "Sirius 001-116 (pdf)" and its
/// companions — each holding one PDF per issue. The page already lists those,
/// and the parser deliberately refuses to import them as issues; this reads
/// them for what they are instead.
public struct IssueSegment: Equatable, Sendable {
    /// Row id, so every issue in the set shares one place on disk.
    public var id: Int = 0
    public let url: String
    /// The text the topic used, kept so a special with no number of its own
    /// can still be recognised as part of the set: "Sirius 143-164+YU (pdf)".
    public let label: String
    public let first: Int
    public let last: Int

    public init(id: Int = 0, url: String, label: String, first: Int, last: Int) {
        self.id = id; self.url = url; self.label = label
        self.first = first; self.last = last
    }

    /// How to describe the set to someone about to download it.
    public var describedRange: String { "\(first)–\(last)" }

    public func covers(number: Int) -> Bool { number >= first && number <= last }

    /// Whether an issue with no number belongs to this set.
    ///
    /// "Sirius 143-164+YU" says so in words, which is all there is to go on
    /// for an issue the run numbers as nothing.
    public func covers(title: String) -> Bool {
        let words = Set(Fold.fold(title).split(whereSeparator: { !$0.isLetter }).map(String.init))
        let mine = Set(Fold.fold(label).split(whereSeparator: { !$0.isLetter }).map(String.init))
        // "sirius" is the series name and says nothing about membership.
        return !words.intersection(mine).subtracting(["sirius", "pdf", "doc", "epub"]).isEmpty
    }
}

extension Catalog {

    /// A link labelled with a span of issues rather than one:
    /// "http://… - Sirius 001-116 (pdf)".
    /// No spaces around the dash, which is what separates a span from a title
    /// that begins with a number: the sets are written "Sirius 001-116 (pdf)"
    /// while issue 99 is "Sirius 099 - 900 Baka" and is one comic.
    private static let segmentLabel = Rx(
        #"^\s*[-–]?\s*(.*?(\d{1,4})[-–](\d{1,4}).*?)\s*$"#)

    /// The sets a page offers, if any.
    ///
    /// Only spans of more than two issues: two consecutive numbers are a
    /// double issue — one magazine — and belong to the issue parser.
    public static func segments(in html: String) -> [IssueSegment] {
        var out: [IssueSegment] = []
        for line in HTMLText.plainLines(html) {
            let urls = url.allMatches(line).filter { u in
                !noise.contains(where: u.contains) && !imageHosts.contains(where: u.contains)
            }
            guard let url = urls.first else { continue }
            let after = line.components(separatedBy: urls[urls.count - 1]).last?
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–\t")) ?? ""
            guard !after.isEmpty, let g = segmentLabel.firstGroups(after),
                  let first = Int(g[2]), let last = Int(g[3]),
                  last > first + 1
            else { continue }
            out.append(IssueSegment(url: url, label: g[1], first: first, last: last))
        }
        return out
    }
}

extension Store {

    /// Records the sets a page offers, alongside its issues.
    func recordSegments(_ segments: [IssueSegment], context: String) throws {
        for segment in segments {
            try db.run("""
                INSERT OR IGNORE INTO segment (context, url, label, first, last)
                VALUES (?, ?, ?, ?, ?)
                """, [.text(context), .text(segment.url), .text(segment.label),
                      .int(Int64(segment.first)), .int(Int64(segment.last))])
        }
    }

    /// The set an issue belongs to, if its topic offers one.
    ///
    /// Matched inside the issue's own topic: a span of numbers means nothing
    /// across series, and every topic numbers from one.
    public func segment(forIssue issueID: Int) throws -> IssueSegment? {
        var context: String?
        var number: Int?
        var title: String?
        try db.query("SELECT context, number, title FROM issue WHERE id = ?",
                     [.int(Int64(issueID))]) { row in
            context = row.string(0); number = row.int(1); title = row.string(2)
        }
        guard let context else { return nil }

        var found: IssueSegment?
        try db.query("""
            SELECT url, label, first, last, id FROM segment WHERE context = ? ORDER BY first
            """, [.text(context)]) { row in
            guard found == nil,
                  let url = row.string(0), let label = row.string(1),
                  let first = row.int(2), let last = row.int(3) else { return }
            let candidate = IssueSegment(id: row.int(4) ?? 0, url: url, label: label,
                                         first: first, last: last)
            if let number, candidate.covers(number: number) { found = candidate }
            else if number == nil, let title, candidate.covers(title: title) { found = candidate }
        }
        return found
    }

    /// Every issue the set covers, so one download can serve them all.
    public func issues(inSegment segment: IssueSegment, context: String) throws -> [Int] {
        var out: [Int] = []
        try db.query("""
            SELECT id, number, title FROM issue WHERE context = ? ORDER BY number
            """, [.text(context)]) { row in
            guard let id = row.int(0) else { return }
            if let number = row.int(1), segment.covers(number: number) { out.append(id) }
            else if row.int(1) == nil, let title = row.string(2),
                    segment.covers(title: title) { out.append(id) }
        }
        return out
    }

    /// The number, span and title of one issue — what it takes to find its
    /// file inside a set.
    public func issueIdentity(id: Int) throws -> (number: Int?, numberTo: Int?, title: String?)? {
        var out: (Int?, Int?, String?)?
        try db.query("SELECT number, number_to, title FROM issue WHERE id = ?",
                     [.int(Int64(id))]) { row in
            out = (row.int(0), row.int(1), row.string(2))
        }
        return out
    }

    /// The topic an issue was imported from.
    public func context(forIssue issueID: Int) throws -> String? {
        var out: String?
        try db.query("SELECT context FROM issue WHERE id = ?",
                     [.int(Int64(issueID))]) { row in out = row.string(0) }
        return out
    }
}

extension IssueSegment {

    /// Which file inside the set belongs to an issue.
    ///
    /// The archives name their members the way the topic names its issues:
    /// "Sirius 143.pdf" for one, "Sirius 155-156.pdf" for a double, and
    /// "YU Sirius.pdf" for the special that closes the run.
    public static func member(_ entries: [String],
                              number: Int?, numberTo: Int?, title: String?) -> String? {
        func name(_ path: String) -> String {
            String(path[(path.lastIndex(where: { $0 == "/" || $0 == "\\" })
                .map { path.index(after: $0) } ?? path.startIndex)...])
        }
        let readable = entries.filter { name($0).lowercased().hasSuffix(".pdf") }

        // A double issue is filed under both its numbers, and must be looked
        // for that way first: "155-156" also contains "155".
        if let number, let numberTo {
            let pair = "\(number)-\(numberTo)"
            if let hit = readable.first(where: { name($0).contains(pair) }) { return hit }
        }
        if let number {
            let padded = ["\(number)", String(format: "%02d", number), String(format: "%03d", number)]
            if let hit = readable.first(where: { entry in
                let stem = name(entry).replacingOccurrences(of: ".pdf", with: "",
                                                            options: .caseInsensitive)
                // Anchored on the end so "143" does not match "1143" or a
                // double it is only half of.
                return padded.contains { stem.hasSuffix($0) }
            }) { return hit }
        }
        if let title {
            let words = Set(Fold.fold(title).split(whereSeparator: { !$0.isLetter }).map(String.init))
                .subtracting(["sirius"])
            if let hit = readable.first(where: { entry in
                let stem = Set(Fold.fold(name(entry)).split(whereSeparator: { !$0.isLetter })
                    .map(String.init))
                return !words.isEmpty && !words.intersection(stem).isEmpty
            }) { return hit }
        }
        return nil
    }
}

extension IssueSegment {

    /// What to tell someone before a set is fetched.
    ///
    /// Named for what it is rather than its size alone: "issues 1–116" says
    /// why one tap moves a hundred comics, which a megabyte count does not.
    public var downloadWarning: String {
        "Issues \(describedRange) are published as a single download, "
        + "so this will fetch all of them."
    }

    /// And before one is discarded.
    public var removalWarning: String {
        "Issues \(describedRange) share the files they were downloaded in, "
        + "so removing this one removes all of them."
    }
}

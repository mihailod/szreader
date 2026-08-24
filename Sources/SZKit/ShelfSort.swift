import Foundation

/// How the shelf is ordered.
///
/// Declaration order is menu order, so the case a reader wants first is
/// written first.
///
/// `imported` is not a comparator: it means "leave the query's own order
/// alone", which is insertion order when browsing and relevance rank when
/// searching. `newest` is its opposite and *is* a comparator, because
/// reversing "whatever order the query produced" is only meaningful when that
/// order was insertion.
public enum ShelfSort: String, CaseIterable, Sendable {
    /// Most recently opened first, then everything never opened.
    ///
    /// The default, and first in the menu, because a shelf of several thousand
    /// answers "what was I reading" badly by every other order: what the
    /// reader had open last week is scattered through it by title, by number
    /// or by arrival date, none of which has anything to do with reading.
    ///
    /// A rearrangement and nothing more. An issue never opened has no key to
    /// sort on, but the shelf still holds it, so it goes below everything that
    /// does — the same place a missing number or a missing title puts a row.
    ///
    /// Read state is deliberately not part of it: a comic finished last night
    /// and one abandoned on page three are both things the reader had open,
    /// which is the only question being asked.
    case opened

    /// Most recently imported first, which is what someone who has just
    /// imported something is looking for — and, on a shelf of several
    /// thousand, the only order in which a new arrival is visible without
    /// scrolling to the end.
    ///
    /// The raw value is deliberately new rather than a rename of `imported`:
    /// a reader who has chosen a sort has that choice stored, and it must keep
    /// meaning what they picked.
    case newest
    case imported
    case title
    case series
    case hero
    case number

    /// Biggest scan first, with everything not downloaded below all of it.
    ///
    /// Last in the menu because it is the one order that is not about the
    /// comics at all — it answers "what is filling the device", which is a
    /// question asked while clearing space rather than while reading.
    case size

    /// What a fresh install sorts by.
    public static let `default` = ShelfSort.opened

    public var label: String {
        switch self {
        case .opened:   return "Recently Open"
        case .newest:   return "Reverse Import Order"
        case .imported: return "Import Order"
        case .title:    return "Title"
        case .series:   return "Series"
        case .hero:     return "Hero"
        case .number:   return "Number"
        case .size:     return "Scan Size"
        }
    }

    public var symbol: String {
        switch self {
        // A book rather than a third clock: two of the orders below are
        // already clocks, and at menu size the difference between them is
        // exactly the thing nobody reads.
        case .opened:   return "book"
        case .newest:   return "clock.arrow.circlepath"
        case .imported: return "clock"
        case .title:    return "textformat"
        case .series:   return "books.vertical"
        case .hero:     return "person"
        case .number:   return "number"
        // A disk, because the figure being sorted on is disk space — none of
        // the others are about the device.
        case .size:     return "internaldrive"
        }
    }
}

/// The derived keys a sort compares on, worked out once per issue.
///
/// `editionCode` and `heroDisplay` are computed properties, and both run
/// `Fold.fold` — two `replacingOccurrences`, an NSString folding, and two
/// regular-expression passes. Asking for them *inside* the comparator meant
/// deriving them once per comparison rather than once per row, which is a
/// different order of growth: sorting 27,801 issues by Series makes 292,412
/// comparisons and asked for a key roughly 1.17 million times, at four and a
/// half seconds for the sort.
///
/// Keyed by issue id, which is unique and stable for the length of one sort.
/// Nothing about the comparison changes — same localised `compare`, same
/// case-insensitive grouping, same tie-breaks — so the order this produces is
/// the order the old code produced, arrived at without doing the same work
/// hundreds of thousands of times.
///
/// A class rather than a struct because the comparator closure has to be able
/// to fill it in as it goes; `Array.sort(by:)` calls that closure from one
/// thread, so there is nothing here to synchronise.
private final class SortKeys {
    private var editions: [Int: String] = [:]
    private var heroes: [Int: String] = [:]

    /// Empty rather than nil, because that is what the comparison did with a
    /// nil anyway: both `same` and `byText` coalesce it before looking.
    func edition(_ issue: StoredIssue) -> String {
        if let cached = editions[issue.id] { return cached }
        let key = issue.editionCode ?? ""
        editions[issue.id] = key
        return key
    }

    func hero(_ issue: StoredIssue) -> String {
        if let cached = heroes[issue.id] { return cached }
        let key = issue.heroDisplay ?? ""
        heroes[issue.id] = key
        return key
    }
}

public extension StoredIssue {

    /// The comparator for a sort, or nil to keep the query's own order.
    ///
    /// `whileSearching` is what keeps a search sorted by relevance. The two
    /// import orders describe *arrival*, which is the useful answer to "what
    /// is on my shelf" and the wrong one to "what matches what I typed" — a
    /// search already comes back best-match-first, and re-sorting it by age
    /// buries the row the reader was looking for. The five explicit keys are
    /// unaffected: someone who asks for Title means Title, question or no
    /// question.
    ///
    /// `sizes` is what each downloaded issue weighs, keyed by id, and only
    /// `.size` reads it. It is handed in rather than looked up per row because
    /// the figure lives in the database and a comparator runs hundreds of
    /// thousands of times: one bulk read, then a dictionary lookup per
    /// comparison. An id the map does not carry weighs nothing, which is the
    /// same answer the info panel gives when the download record has no byte
    /// count.
    static func comparator(for sort: ShelfSort,
                           whileSearching: Bool = false,
                           sizes: [Int: Int64] = [:])
        -> ((StoredIssue, StoredIssue) -> Bool)? {
        switch sort {
        case .imported: return nil
        // An explicit key like the four below it, not an arrival order: a
        // reader searching inside Recently Open asked for their reading
        // history, and relevance rank is not it.
        case .opened:   return byOpened
        // The id is the insertion counter, so descending is newest first.
        // Reversing the *rows* would not do even when browsing: it is the
        // order that has to be defined, not the array that came back.
        case .newest:   return whileSearching ? nil : { $0.id > $1.id }
        case .title:    return { byText($0.title ?? $0.code, $1.title ?? $1.code, $0, $1) }
        // One cache per comparator, so it lives exactly as long as the sort
        // that is using it and a later sort never reads keys derived from a
        // row as it was before an edit.
        case .series:
            let keys = SortKeys()
            return { bySeries($0, $1, keys) }
        case .hero:
            let keys = SortKeys()
            return { byHero($0, $1, keys) }
        case .number:   return byNumber
        case .size:     return { bySize($0, $1, sizes) }
        }
    }

    /// Biggest scan first, then everything not downloaded.
    ///
    /// The tail is not a rounding of the order above it: an issue that is only
    /// catalogued occupies nothing, and a shelf that mixed those in with the
    /// small downloads would answer "what is filling the device" with mostly
    /// rows that are not on it. Downloaded and not is asked first, so a
    /// download whose record carries no byte count still sits with the files
    /// rather than among the rows that have none.
    ///
    /// Ties break on the id ascending, which keeps a set — one archive shared
    /// by a whole run, every issue of it recorded at the same weight — in its
    /// own numbered order rather than backwards.
    private static func bySize(_ a: StoredIssue, _ b: StoredIssue,
                               _ sizes: [Int: Int64]) -> Bool {
        if a.isDownloaded != b.isDownloaded { return a.isDownloaded }
        let left = sizes[a.id] ?? 0, right = sizes[b.id] ?? 0
        if left != right { return left > right }
        return a.id < b.id
    }

    /// Most recently opened first, and everything never opened after all of
    /// it — on the same principle as a missing number, which sorts last rather
    /// than leading the shelf with the rows that have the least to say.
    ///
    /// The whole tail is a tie, so its own order matters. Descending id, which
    /// is reverse import order: it matches the direction the opened rows above
    /// it run in, and it is the order that shelf had before this one became
    /// the default.
    ///
    /// Two opens in the same instant is not a real case; a shelf that
    /// reshuffles between refreshes would be.
    private static func byOpened(_ a: StoredIssue, _ b: StoredIssue) -> Bool {
        switch (a.openedAt, b.openedAt) {
        case let (x?, y?) where x != y: return x > y
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.id > b.id
        }
    }

    /// Series, then number within it — an edition is one numbered run, so its
    /// issues belong together in order regardless of who stars in them.
    private static func bySeries(_ a: StoredIssue, _ b: StoredIssue,
                                 _ keys: SortKeys) -> Bool {
        let left = keys.edition(a), right = keys.edition(b)
        if !same(left, right) { return byText(left, right, a, b) }
        if a.number != b.number { return byNumber(a, b) }
        return a.id < b.id
    }

    private static func byHero(_ a: StoredIssue, _ b: StoredIssue,
                               _ keys: SortKeys) -> Bool {
        let left = keys.hero(a), right = keys.hero(b)
        if !same(left, right) { return byText(left, right, a, b) }
        return bySeries(a, b, keys)
    }

    /// Numeric, so 9 comes before 21 and 100 last.
    private static func byNumber(_ a: StoredIssue, _ b: StoredIssue) -> Bool {
        switch (a.number, b.number) {
        case let (x?, y?) where x != y: return x < y
        // A missing number sorts last rather than leading the shelf with the
        // rows that have the least to say.
        case (nil, _?): return false
        case (_?, nil): return true
        default: return a.id < b.id
        }
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        (a ?? "").caseInsensitiveCompare(b ?? "") == .orderedSame
    }

    /// Case- and diacritic-insensitive, so "Šuplji" files with the S's rather
    /// than after Z. Empty values sort last, then id keeps it stable — equal
    /// keys must not shuffle between refreshes.
    private static func byText(_ a: String?, _ b: String?,
                               _ lhs: StoredIssue, _ rhs: StoredIssue) -> Bool {
        let left = a ?? "", right = b ?? ""
        if left.isEmpty != right.isEmpty { return right.isEmpty }
        let order = left.compare(right, options: [.caseInsensitive, .diacriticInsensitive],
                                 range: nil, locale: .current)
        if order != .orderedSame { return order == .orderedAscending }
        return lhs.id < rhs.id
    }
}

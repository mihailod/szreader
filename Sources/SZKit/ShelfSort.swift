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
        }
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
    static func comparator(for sort: ShelfSort,
                           whileSearching: Bool = false)
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
        case .series:   return bySeries
        case .hero:     return byHero
        case .number:   return byNumber
        }
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
    private static func bySeries(_ a: StoredIssue, _ b: StoredIssue) -> Bool {
        if !same(a.editionCode, b.editionCode) { return byText(a.editionCode, b.editionCode, a, b) }
        if a.number != b.number { return byNumber(a, b) }
        return a.id < b.id
    }

    private static func byHero(_ a: StoredIssue, _ b: StoredIssue) -> Bool {
        if !same(a.heroDisplay, b.heroDisplay) { return byText(a.heroDisplay, b.heroDisplay, a, b) }
        return bySeries(a, b)
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

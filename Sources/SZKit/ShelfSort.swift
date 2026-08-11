import Foundation

/// How the shelf is ordered.
///
/// `imported` is not a comparator: it means "leave the query's own order
/// alone", which is insertion order when browsing and relevance rank when
/// searching. Those are the defaults because they answer the two questions
/// each view is actually asked — what did I add recently, and what matches
/// what I typed — and a reader who wants something else can say so.
public enum ShelfSort: String, CaseIterable, Sendable {
    case imported
    case title
    case series
    case hero
    case number

    public var label: String {
        switch self {
        case .imported: return "Import order"
        case .title:    return "Title"
        case .series:   return "Series"
        case .hero:     return "Hero"
        case .number:   return "Number"
        }
    }

    public var symbol: String {
        switch self {
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
    static func comparator(for sort: ShelfSort) -> ((StoredIssue, StoredIssue) -> Bool)? {
        switch sort {
        case .imported: return nil
        case .title:    return { byText($0.title ?? $0.code, $1.title ?? $1.code, $0, $1) }
        case .series:   return bySeries
        case .hero:     return byHero
        case .number:   return byNumber
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

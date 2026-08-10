import Foundation

/// The outcome of importing one topic page, with enough detail to explain a
/// disappointing result.
///
/// "Imported 0 issues" is almost always one of three very different problems,
/// and the user can only fix one of them. Distinguishing them is the whole
/// point of this type.
public struct ImportReport: Equatable, Sendable {
    public let issues: Int
    public let mirrors: Int
    public let links: Int
    public let attributed: Int
    public let hiddenBlocks: Int

    public var isEmpty: Bool { issues == 0 && mirrors == 0 }

    /// Plain-language next step, or nil when the import went fine.
    public var advice: String? {
        if links == 0 && hiddenBlocks > 0 {
            return "Every download block on this page is still hidden. Like the "
                 + "posts you want, then import again."
        }
        if links == 0 {
            return "No download links found. Is this a topic page rather than a "
                 + "forum index?"
        }
        if hiddenBlocks > 0 && issues > 0 {
            return "Imported what was visible. \(hiddenBlocks) block(s) are still "
                 + "hidden — like those posts to get the rest."
        }
        if attributed < links {
            return "\(links - attributed) link(s) could not be matched to an issue "
                 + "and were skipped, rather than guessing at a title."
        }
        return nil
    }
}

extension Store {

    /// Ingests a page and reports what happened.
    ///
    /// Re-importing is expected and cheap: the like quota means a page is
    /// usually unlocked in batches over several visits, so the same page gets
    /// imported repeatedly and must only add what is new.
    @discardableResult
    public func importPage(html: String, source: String? = nil) throws -> ImportReport {
        let coverage = Catalog.coverage(Catalog.links(in: html))
        let added = try ingest(html: html, source: source)
        return ImportReport(issues: added.issues,
                            mirrors: added.mirrors,
                            links: coverage.total,
                            attributed: coverage.attributed,
                            hiddenBlocks: Self.hiddenBlockCount(in: html))
    }

    /// IPB renders a "Hidden Content" placeholder for every block gated behind
    /// a Like, so counting them measures what is still locked.
    ///
    /// Case-SENSITIVE on purpose. The placeholder contains the phrase twice —
    /// the title-case heading "Hidden Content" and the lowercase sentence
    /// "…see the hidden content once you like this post" — so matching
    /// case-insensitively reports exactly double. Verified against a locked
    /// page: 250 case-insensitive hits for 125 real blocks.
    static func hiddenBlockCount(in html: String) -> Int {
        Rx(#"Hidden Content"#).allMatches(html).count
    }
}

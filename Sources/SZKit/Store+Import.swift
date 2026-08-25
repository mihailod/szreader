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
            return "It seems you are on a topic with no liked posts (all download "
                 + "links are hidden). Click on [LIKE THIS] on a post you want and "
                 + "then tap Import again."
        }
        if links == 0 {
            return "No download links found. Seems you are not on a topic page at "
                 + "all. Make sure you are on a topic page with links and that you "
                 + "clicked on [LIKE THIS] to reveal them."
        }
        if hiddenBlocks > 0 && issues > 0 {
            return "Imported what was visible. \(hiddenBlocks) block(s) are still "
                 + "hidden — like those posts to get the rest."
        }
        if attributed < links {
            return "\(links - attributed) link(s) could not be matched to an issue "
                 + "and were skipped, rather than guessing at a title."
        }
        // Nothing new and nothing wrong: this page has been imported before.
        // By far the most common empty import — the like quota unlocks a topic
        // in batches, so people come back to the same page — and the one case
        // where a bare count of matched links explains nothing at all.
        if isEmpty {
            return hiddenBlocks > 0
                ? "Everything visible here is already in your library. "
                    + "\(hiddenBlocks) block(s) are still hidden — like those "
                    + "posts to get the rest."
                : "Everything on this page is already in your library."
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

import Foundation

extension Catalog {

    /// Topics where one member's posts supersede the rest of the thread.
    ///
    /// Most topics are a single well-formed index post plus chatter, and the
    /// parser copes. A few are the opposite: years of partial lists, dead
    /// links and re-uploads, with one member having later posted the complete
    /// run. Alef is that shape — reading the whole page yields broken images
    /// and links that no longer resolve, while `doktor`'s six posts hold all
    /// 26 issues with their covers.
    ///
    /// Keyed on the folded topic, and deliberately a short list: this is a
    /// statement about specific threads, not a heuristic that might fire
    /// somewhere unintended.
    static let authoritativeAuthors: [String: String] = [
        "alef": "doktor",
    ]

    /// The author whose posts should be read alone, if this topic has one.
    static func authoritativeAuthor(for context: PageContext) -> String? {
        guard let edition = context.edition else { return nil }
        return authoritativeAuthors[Fold.fold(edition)]
    }

    // Quote-agnostic, and tolerant of the class list's order and spacing.
    //
    // The saved pages use single quotes; the app imports
    // `document.documentElement.outerHTML`, and a DOM serialiser normalises
    // every attribute to double quotes. A pattern written for one form matches
    // nothing in the other — so this silently did nothing on every real
    // import while passing against the fixtures.
    private static let postBlock = Rx(#"class=["'][^"']*post_block"#)
    private static let postAuthor = Rx(#"itemprop=["']name["'][^>]*>([^<]{1,40})<"#)

    /// The page reduced to one member's posts, or unchanged when the topic has
    /// no designated author.
    ///
    /// Everything before the first post — `<title>` and the breadcrumb trail —
    /// is kept, because that is where the series, hero and publisher come from.
    public static func authoritativeHTML(_ html: String) -> String {
        guard let author = authoritativeAuthor(for: pageContext(in: html)) else { return html }
        let wanted = Fold.fold(author)

        let ns = html as NSString
        let starts = postBlock.re
            .matches(in: html, range: NSRange(location: 0, length: ns.length))
            .map { $0.range.location }
        guard starts.count > 1 else { return html }

        var out = ns.substring(to: starts[0])          // head and breadcrumbs
        var kept = 0
        for (index, start) in starts.enumerated() {
            let end = index + 1 < starts.count ? starts[index + 1] : ns.length
            let post = ns.substring(with: NSRange(location: start, length: end - start))
            // The first itemprop="name" inside a post is its author; later ones
            // belong to quoted members and must not claim the post.
            guard let name = postAuthor.firstGroups(post)?[1],
                  Fold.fold(name) == wanted else { continue }
            out += post
            kept += 1
        }
        // Refuse to hand back an empty page: if the author cannot be found the
        // thread is better read whole than not at all.
        return kept > 0 ? out : html
    }
}

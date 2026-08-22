import Foundation

/// Reads one page of a Stripovi comic off the site.
///
/// The shipped index normally makes this unnecessary: `StripoviCatalog.Comic`
/// builds every page address from a rule, and a download asks the site for
/// pictures and nothing else. This is what the download falls back to when
/// that rule stops being true.
///
/// That fallback is the whole reason the rule is safe to ship. A rule inferred
/// from a site that never promised it will eventually be wrong — a directory
/// renamed, a comic re-scanned at a different padding — and without a way to
/// notice, a stale rule fails silently and permanently for every reader.
/// With one, a broken rule costs a second request per page and nothing else.
public enum StripoviPage {

    /// The site's own markup, decoded.
    ///
    /// These pages are Windows-1250 — what a Croatian ASP site of this vintage
    /// serves — and they state no `charset` at all, so it cannot be read off
    /// the response and has to be known.
    ///
    /// **UTF-8 is tried first even though the site is not UTF-8**, and the
    /// order is the whole of this function. Windows-1250 is a single-byte
    /// encoding: every byte maps to some character, so decoding *never fails*
    /// and it can never be a fallback for anything — put first, it would
    /// silently turn a genuine UTF-8 page into mojibake and no later branch
    /// would ever run. UTF-8 is strict and rejects the site's high bytes, so
    /// asking it first is free: a real page falls through to Windows-1250,
    /// and a page that is really UTF-8 is read correctly instead of mangled.
    ///
    /// The image address is plain ASCII either way. This matters for the
    /// title beside it, and for the day the site is modernised.
    public static func decode(_ data: Data) -> String? {
        String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1250)
    }

    /// The page image this page is showing, relative to the site root.
    ///
    /// Anchored on `comic-container`, which is the one element that holds the
    /// comic. The page carries half a dozen other images — a masthead, a
    /// header illustration, two book covers in the sidebar — and a parser that
    /// swept for the first `<img>` would download the site's furniture in
    /// reading order.
    private static let container =
        Rx(#"<div[^>]+id=["']comic-container["'][\s\S]{0,600}?<img[^>]+src=["']([^"']+)["']"#,
           [.caseInsensitive])

    public static func pageImage(_ html: String) -> String? {
        guard let found = container.firstGroups(html)?[1] else { return nil }
        let trimmed = HTMLText.decodeEntities(found)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// How many pages the comic has, from the site's own page menu.
    ///
    /// The shipped index states this too. Read again here so a comic that has
    /// gained pages since the catalogue was built is noticed rather than
    /// silently truncated.
    private static let chooser =
        Rx(#"<select[^>]+id=["']ChoosePage["'][\s\S]*?</select>"#, [.caseInsensitive])
    private static let option = Rx(#"<option[^>]+value=["'](\d+)["']"#, [.caseInsensitive])

    public static func pageCount(_ html: String) -> Int? {
        guard let menu = chooser.firstGroups(html)?[0] else { return nil }
        let numbers = option.allMatches(menu, group: 1).compactMap(Int.init)
        return numbers.max()
    }
}

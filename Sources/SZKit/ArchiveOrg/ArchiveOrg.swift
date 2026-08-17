import Foundation

/// The Internet Archive, as far as this app is concerned.
///
/// Nothing here is a parser. Unlike RetroSpec — a set of generated HTML pages
/// that have to be read to find out what exists — archive.org publishes each
/// item as JSON at a fixed address, and every file that item holds is at a URL
/// derivable from the item's identifier. So this is the small set of address
/// rules, and `ArchiveOrgItem` is the JSON.
///
/// The app never asks archive.org anything at runtime: the catalogue is built
/// by `archive-build` and shipped. These rules exist so the builder and the
/// tests agree on what a URL looks like.
public enum ArchiveOrg {

    /// Prefix every path in the shipped catalogue hangs off.
    ///
    /// `/download/` redirects to whichever of the archive's servers holds the
    /// item today, which is exactly why it is the form recorded: the node
    /// names in the metadata ("ia803104.us.archive.org") are true this week
    /// and would be baked into the app for years.
    public static let base = "https://archive.org/download/"

    /// Where an item's own file lives, relative to `base`.
    ///
    /// Percent-encoded, because the scans are named as their uploader typed
    /// them — "Amiga Bilten 1.pdf" — and a space in a URL is not a URL.
    public static func path(item: String, file: String) -> String {
        "\(encode(item))/\(encode(file))"
    }

    /// The first page of an item, at print size.
    ///
    /// This is the cover, and asking for it this way is what saves shipping
    /// one: `/page/n0_w1024.jpg` is the archive's own BookReader endpoint, so
    /// the image is served from the item rather than copied into the app.
    /// It answers with the derivative nearest the requested width, which for
    /// these fanzines is the full-size scan at around 1200x1750 — the same
    /// order as RetroSpec's covers, which is what `CoverStore` is sized for.
    public static func firstPagePath(item: String) -> String {
        "\(encode(item))/page/n0_w1024.jpg"
    }

    /// The square item tile every item has, for a stand-in while the cover
    /// loads. About 180px, and never the whole cover.
    public static func thumbnailPath(item: String) -> String {
        "\(encode(item))/__ia_thumb.jpg"
    }

    /// Where the item's metadata is served, which is the builder's one source.
    public static func metadataURL(item: String) -> String {
        "https://archive.org/metadata/\(encode(item))"
    }

    // MARK: - Scandata

    private static let leafCount = Rx(#"(?i)<leafCount>\s*(\d+)\s*</leafCount>"#)
    private static let pageElement = Rx(#"(?i)<page\b"#)

    /// How many pages a scan has, out of the scanner's own record of it.
    ///
    /// `<leafCount>` is the file's own answer and is what this takes. The
    /// `<page>` elements are counted as the fallback, because the count is
    /// stated once and the elements are the thing being counted — a file that
    /// disagreed with itself would be a scan half-recorded, and the pages are
    /// what actually exist.
    public static func pageCount(inScandata xml: String) -> Int? {
        if let stated = leafCount.firstGroups(xml).flatMap({ Int($0.capture(1)) }),
           stated > 0 {
            return stated
        }
        let counted = pageElement.allGroups(xml).count
        return counted > 0 ? counted : nil
    }

    /// Escapes one path segment.
    ///
    /// `urlPathAllowed` leaves "/" alone, which would let a filename split
    /// itself across segments, so it is removed from the allowed set.
    static func encode(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }
}

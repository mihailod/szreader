import Foundation

/// Covers that exist in the catalogue but are not linked on the page.
///
/// The forum's index posts link a thumbnail per issue, named after the issue:
/// `…/naslovnice/VelikiBlek/TN/TN_VB_LMS_128.jpg`. Some posts miss a few out —
/// fourteen of Veliki Blek's fifty-four — and those issues arrive with no
/// artwork at all even though the catalogue has it. The name is entirely
/// determined by the issue number, so a sibling that *is* linked says where
/// the missing one lives.
///
/// Guessing a URL is cheap and wrong answers are harmless in themselves, but a
/// wrong one recorded as a cover would sit there forever showing nothing and
/// block the fallback that puts the comic's own first page on the shelf. So a
/// guess is only kept once the catalogue has confirmed it.
public enum CoverGuess {

    /// The trailing number of a filename — the issue it belongs to.
    private static let trailingNumber = Rx(#"(\d+)(?=\.[A-Za-z0-9]+$)"#)

    /// The URL an issue's cover would have, given a sibling issue's.
    ///
    /// Nil unless the sibling's filename really is named after its own issue
    /// number: that is what makes the pattern readable. Zero padding is
    /// carried over, since a catalogue that writes `TN_ZG_ZS_013` writes it
    /// that way throughout.
    public static func url(likeSibling sibling: String, number: Int, wanted: Int) -> String? {
        guard wanted > 0, number > 0, wanted != number else { return nil }
        // Split the string rather than using the path APIs: those normalise
        // "https://" down to "https:/" and quietly produce a URL that cannot
        // be fetched.
        guard let slash = sibling.lastIndex(of: "/") else { return nil }
        let directory = sibling[..<slash]
        let name = String(sibling[sibling.index(after: slash)...])
        guard let groups = trailingNumber.firstGroups(name),
              Int(groups[1]) == number else { return nil }

        let digits = groups[1].count
        let replacement = digits > String(wanted).count
            ? String(format: "%0\(digits)d", wanted)
            : String(wanted)

        // Only the trailing number: a name like TN_VB_LMS_128 has others in
        // front of it that belong to the series, not the issue.
        guard let range = name.range(of: groups[1], options: .backwards) else { return nil }
        return directory + "/" + name.replacingCharacters(in: range, with: replacement)
    }

    /// Whether a response really is the cover, and not the catalogue's way of
    /// saying there isn't one.
    ///
    /// A number with no cover behind it does not 404 — it redirects to an HTML
    /// page — so the check is that an image came back.
    public static func isImage(status: Int, contentType: String?, body: Data) -> Bool {
        guard status == 200 else { return false }
        if let contentType, contentType.lowercased().contains("image") { return true }
        // Fall back to the bytes when the header is missing or vague.
        return body.starts(with: [0xFF, 0xD8, 0xFF])            // JPEG
            || body.starts(with: [0x89, 0x50, 0x4E, 0x47])      // PNG
    }
}

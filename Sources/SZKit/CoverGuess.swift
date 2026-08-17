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

    /// How many URLs one issue is worth asking about.
    ///
    /// Each is a request against a host that rate-limits, spaced a second and
    /// a half apart, and the candidates are ordered by how likely they are —
    /// so the tail of a long list is both the slowest and the least likely to
    /// be right. Four covers the shapes that actually occur: the naming this
    /// hero's own covers use, and the two or three folders an edition is known
    /// to live in.
    static let candidateLimit = 4

    /// Where the catalogue would keep this issue's cover, best guesses first.
    ///
    /// The name is the identity and the folder is only a shelf, which is what
    /// makes asking twice safe: `Miki/TN/TN_KM_ZS_100.jpg` is not found while
    /// `Mark/TN/TN_KM_ZS_100.jpg` is, so a wrong folder costs a request rather
    /// than producing somebody else's artwork. The three parts of the name are
    /// each taken from the best evidence there is:
    ///
    ///  * the number the *catalogue* uses, where the label gave one. A topic
    ///    numbering an issue 02 while the cover is filed under 305 is the case
    ///    this whole path exists for;
    ///  * the edition code from that same reference, then whatever this hero's
    ///    other covers used, and only then the edition's initials — a topic
    ///    carrying one story calls its edition "Timothy Tatcher", which
    ///    initials to `TT` and names no edition anywhere;
    ///  * the hero code the library has seen for this hero, or its initials
    ///    where that leaves no room for confusion.
    static func catalogueCandidates(hero: String?, edition: String?,
                                    catalogue: CatalogueRef?, number: Int?,
                                    index: CatalogueIndex) -> [String] {
        guard let hero, !hero.isEmpty,
              let wanted = catalogue?.number ?? number, wanted > 0 else { return [] }
        let known = index.naming(hero: hero, edition: edition)

        var heroCodes = known.map(\.hero)
        if let initials = code(for: hero), !heroCodes.contains(initials),
           !index.codeIsTaken(initials, byOtherThan: hero) {
            heroCodes.append(initials)
        }

        var editionCodes: [String] = []
        if let referenced = catalogue?.code.uppercased() { editionCodes.append(referenced) }
        editionCodes += known.map(\.edition)
        // The edition's own initials last, and only where it is not simply the
        // hero's name repeated.
        if let edition, Fold.fold(edition) != Fold.fold(hero),
           let initials = PageContext.code(forEdition: edition)?.uppercased() {
            editionCodes.append(initials)
        }

        var out: [String] = []
        for heroCode in heroCodes {
            for editionCode in editionCodes {
                // Folders this hero is known to use, then folders the edition
                // is known to occupy, then the hero's own name — which is what
                // a run with a folder to itself is called.
                var folders = known.filter { $0.hero == heroCode }.map(\.folder)
                folders += known.map(\.folder)
                folders += index.folders(hostingEdition: editionCode)
                folders.append(hero.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                    .map { $0.capitalized }.joined())
                for folder in folders {
                    guard !folder.isEmpty else { continue }
                    let url = CatalogueNaming(folder: folder, hero: heroCode,
                                              edition: editionCode).url(number: wanted)
                    if !out.contains(url) { out.append(url) }
                    if out.count >= candidateLimit { return out }
                }
            }
        }
        return out
    }

    /// A hero's initials, as the catalogue writes them: "Timothy Tatcher" is
    /// `TT`, "Druzina od vjesala" is `DOV`.
    ///
    /// Only for a name of several words. A single word gives one letter, and
    /// no cover in the catalogue is named by one — the contractions it uses
    /// there (`ZG` for Zagor, `DK` for Diabolik) are not derivable from the
    /// spelling, so they are left to the library's own examples.
    static func code(for hero: String) -> String? {
        let words = hero.split(whereSeparator: { $0 == " " || $0 == "-" })
            .filter { $0.contains(where: \.isLetter) }
        guard words.count > 1 else { return nil }
        return words.compactMap { $0.first?.uppercased() }.joined()
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

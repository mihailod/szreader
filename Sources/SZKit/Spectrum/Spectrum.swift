import Foundation

/// The Sinclair archive: ZXDB's magazine index, resolved against archive.org.
///
/// ZXDB is the open database behind Spectrum Computing — every magazine,
/// newsletter and book published for the ZX Spectrum, ZX81 and QL. It stores
/// no scans. What it stores is a URL *template* per magazine which, expanded
/// against an issue's own numbers, names that issue's scan on archive.org. See
/// `ZXDBMask` for the templates and `spectrum-build` for the resolution.
///
/// Only the English-language titles ship. ZXDB reaches about 11,500 issues in
/// twenty-odd languages, and the rest were built and then dropped: a shelf is
/// a thing you scroll, and 62 Spanish and Portuguese titles are dead weight to
/// a reader of neither in a way that more English issues never are. The build
/// tool can still produce the others — the language test is one comparison —
/// but nothing ships them.
public enum Spectrum {

    /// The two shelves this archive makes.
    ///
    /// Split by what the material *is* rather than by size, which is the same
    /// rule BombJack's seven follow. The newsstand press and a user group's
    /// photocopied newsletter are different kinds of reading, and a reader who
    /// wants one rarely wants both mixed into it — where a reader who wants
    /// Crash generally also wants Sinclair User.
    ///
    /// Two rather than more. The magazines are 3,955 issues in one shelf,
    /// which is a fifth again as large as BombJack's biggest and nowhere near
    /// the 18,219 that made BombJack unshippable whole; `SpectrumCatalogTests`
    /// times the seed rather than trusting that.
    public enum Group: String, CaseIterable, Sendable {
        /// The newsstand press: Crash, Your Sinclair, Sinclair User, ZX
        /// Computing, and the general 8-bit magazines that covered the
        /// Spectrum alongside everything else.
        case magazines
        /// User-group newsletters and fanzines — 39 titles of real scanned
        /// paper, produced by readers rather than publishers.
        case fanzines
        /// The Sinclair programming library, shelved by imprint: Usborne,
        /// Interface, Melbourne House, Sunshine.
        ///
        /// Not a magazine at all, and it does not come from the same place.
        /// Magazines hang off ZXDB's `issues`; a book is an `entries` row with
        /// a book genre and its scan hangs off `downloads`. It is a separate
        /// path in `spectrum-build` rather than a third predicate.
        case books

        /// The order the settings list shows them in.
        public static let inMenuOrder: [Group] = [.magazines, .fanzines, .books]

        public var display: String {
            switch self {
            case .magazines: return "Magazines"
            case .fanzines:  return "Fanzines"
            case .books:     return "Books"
            }
        }

        public var resource: String { "spectrum-\(rawValue)" }

        /// ZXDB's own type letter for this group, for the two that have one.
        ///
        /// The letter it does not use is `E`, an *electronic* magazine — a
        /// disk image meant to be run on a Spectrum rather than a scan of
        /// anything. There is nothing in one for a reader to open, so no group
        /// claims it.
        var magtype: String? {
            switch self {
            case .magazines: return "P"
            case .fanzines:  return "Z"
            case .books:     return nil
            }
        }

        /// Which shelf a periodical belongs on, or nil when it belongs on
        /// neither. Books never come through here — they are not periodicals
        /// and have no `magtype`.
        public static func of(magtype: String?, language: String?) -> Group? {
            guard language == "en", let magtype else { return nil }
            return allCases.first { $0.magtype == magtype }
        }
    }

    /// Whether a book's recorded scan is one the app can actually fetch.
    ///
    /// ZXDB holds 406 English books with a scan, and only 187 of them are
    /// ordinary files. The rest sit behind its `/pub/` prefix, which resolves
    /// to a path *inside* a multi-gigabyte zip on archive.org — and archive.org
    /// serves those by extracting on demand, which means it ignores `Range`.
    /// Measured, not assumed: a 1 KB range request for one such book returned
    /// HTTP 200 and all 34 MB of it, where the same request against an ordinary
    /// item returned 206 and 1,024 bytes.
    ///
    /// No `Range` means no resume, and a 34 MB download that fails at 90% on a
    /// train starts again from nothing. So those are left out until the
    /// download path has something to say about non-resumable sources.
    ///
    /// Worth knowing if this is ever revisited: `accept-ranges: bytes` *does*
    /// come back for those URLs — on the 302 redirect, not on the response
    /// that carries the file. Checking that header alone would say resume
    /// works.
    public static func canFetchBook(link: String) -> Bool {
        !link.hasPrefix("/pub/") && !link.hasPrefix("/nvg/")
    }
}

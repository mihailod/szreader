import Foundation

/// One chapter's reader page: the list of page images, and what the site says
/// about them.
///
/// This is the only route to the scans. The site serves no archive file, so
/// there is nothing to hand a file host — a download here means fetching
/// `images` in order and writing them out as the pages of a comic.
public struct BatCaveReading: Equatable, Sendable {

    public let seriesID: Int
    public let chapterID: Int
    /// The *series* title — "Republic of the Skull (2022-)" — which is what
    /// the reader page states, with no issue number in it. Not what the shelf
    /// row is called: that came from the series page, which titles each
    /// chapter properly. Kept only for reporting on a download in progress.
    public let title: String

    /// Every page image, in the order the site lists them.
    ///
    /// Taken in array order rather than sorted on the number leading each
    /// filename. The array *is* the site's stated reading order; the filename
    /// is a convention it happens to follow today, and a run whose pages were
    /// named "cover", "000" or "inside-back" would be reordered into nonsense
    /// by anything that parsed them.
    public let images: [String]

    /// The count the site states, which is not where the pages come from.
    ///
    /// Kept so the two can be compared: they agreed on every page examined,
    /// and a disagreement means the reader page was not fully formed, which is
    /// worth refusing rather than half-downloading.
    public let statedPages: Int?

    /// The site's own flag for a chapter whose scans are missing.
    public let isBroken: Bool

    /// Whether the site intends to deliver the image list by a later request
    /// instead of inlining it.
    ///
    /// False on every page examined, and the images were inlined. It is read
    /// anyway because it is the site's own name for the other arrangement, and
    /// an empty list means something different depending on it: with this
    /// false, the chapter genuinely has no pages; with it true, they are
    /// simply somewhere else and this app has not been taught where.
    public let usesAjax: Bool

    public init(seriesID: Int, chapterID: Int, title: String, images: [String],
                statedPages: Int?, isBroken: Bool, usesAjax: Bool) {
        self.seriesID = seriesID; self.chapterID = chapterID; self.title = title
        self.images = images; self.statedPages = statedPages
        self.isBroken = isBroken; self.usesAjax = usesAjax
    }

    /// How many pages will actually be fetched.
    public var pageCount: Int { images.count }
}

/// Reads a BatCave reader page.
///
/// The same `window.__DATA__` object the series page carries, with different
/// contents — so the awkward half of this, taking a nested JSON object out of
/// a page by counting braces, is already written and shared. See
/// `BatCavePage.balancedObject`.
///
/// **Why the reader page must be loaded at all.** Each page image is addressed
/// as `/img/5/<series>/<chapter>/<n>-<32 hex>.jpg`, and that hash is per page
/// and not derivable from anything the series page states. So there is no
/// shortcut: one reader page load per issue, and it must happen before any
/// image can be asked for.
public enum BatCaveReaderPage {

    /// The fields this app uses. The rest of a real payload — bookmark,
    /// session hashes, the feedback challenge, whether the reader is signed in
    /// — is ignored by `JSONDecoder`, which is what keeps them from being a
    /// decode failure.
    struct Payload: Decodable {
        let news_id: Int
        let chapter_id: Int
        let post_title: String
        let images: [String]
        let pages: Int?
        let broken: Bool?
        let rdr_ajax: Bool?
    }

    /// What the reader page says, or nil if this is not one.
    public static func reading(_ html: String) -> BatCaveReading? {
        guard let json = BatCavePage.balancedObject(in: html, after: "window.__DATA__"),
              let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return nil }

        return BatCaveReading(
            seriesID: payload.news_id,
            chapterID: payload.chapter_id,
            title: payload.post_title,
            // Blank entries dropped rather than fetched: an empty string is
            // not an address, and one of them in the middle of a run would
            // otherwise become a zero-byte page.
            images: payload.images.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
            statedPages: payload.pages,
            isBroken: payload.broken ?? false,
            usesAjax: payload.rdr_ajax ?? false)
    }

    /// Why a reader page cannot be turned into a download.
    ///
    /// Checked before a single image is asked for, so a chapter that cannot
    /// work costs the site no requests and the reader no wait.
    public static func refusal(_ reading: BatCaveReading) -> PageFetchError? {
        if reading.isBroken { return .chapterIsBroken }
        if reading.images.isEmpty {
            return reading.usesAjax ? .imagesNotInlined : .noPages
        }
        // Both numbers are stated by the same page, so disagreeing means it
        // was not fully formed — a truncated response, or a reader that had
        // not finished. Refused rather than half-fetched: the alternative is a
        // comic that is quietly missing its last pages, which nothing later
        // would notice.
        if let stated = reading.statedPages, stated != reading.images.count {
            return .pageCountMismatch(stated: stated, listed: reading.images.count)
        }
        return nil
    }
}

/// Why one chapter could not be fetched.
public enum PageFetchError: Error, Equatable, CustomStringConvertible {
    case notAReaderPage
    case chapterIsBroken
    case noPages
    case imagesNotInlined
    case pageCountMismatch(stated: Int, listed: Int)
    /// A page image that did not arrive. Named by its number, because that is
    /// what a reader can act on — the issue is missing that page.
    case pageFailed(page: Int, reason: String)

    public var description: String {
        switch self {
        case .notAReaderPage:
            return "This is not a reader page."
        case .chapterIsBroken:
            // The site's word, and the reader's answer is not to try again.
            return "The site marks this issue as broken — its scans are missing."
        case .noPages:
            return "This issue lists no pages."
        case .imagesNotInlined:
            return "This issue's pages are served in a way this app does not "
                 + "yet read. Please report it."
        case .pageCountMismatch(let stated, let listed):
            return "The page did not load completely — it claims \(stated) "
                 + "pages and lists \(listed). Try again."
        case .pageFailed(let page, let reason):
            return "Page \(page) could not be fetched: \(reason)"
        }
    }
}

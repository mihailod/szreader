import Foundation

/// One chapter — one issue of a series, as the site's own page data lists it.
///
/// "Chapter" is the site's word and is kept here because it is the key into
/// its data; everything a reader sees calls these issues.
public struct BatCaveChapter: Equatable, Sendable {

    /// The site's id for this chapter, and the whole of its identity here.
    /// Also the second half of its reader address — see `BatCave.readerURL`.
    public let id: Int
    /// Where the site places it in the run. Not the issue number: The Walking
    /// Dead's position 1 is "#1 10th Anniversary" and its position 194 is
    /// "#193", because a later reissue sorts among the originals.
    public let position: Int
    /// How many pages, stated by the site.
    ///
    /// The reason this parser reads the page data rather than the markup: it
    /// is what a page-by-page download counts against, so it is what turns
    /// the progress bar from a guess into a measurement.
    public let pages: Int?
    /// "The Walking Dead (2003-) #193" — the series name repeated with the
    /// number on the end, which is how the site titles every one of them.
    public let title: String
    /// `dd.MM.yyyy`, as the site writes it. Kept as stated rather than parsed
    /// into a date: it is the upload date, not a cover date, and nothing on
    /// the shelf sorts by it.
    public let date: String?
    /// The site's own flag for a chapter whose scans are missing.
    ///
    /// Worth reading rather than discovering at download time: a row that can
    /// never be fetched is worse than no row, so these are left out of an
    /// import and counted in what it reports.
    public let isBroken: Bool

    public init(id: Int, position: Int, pages: Int?, title: String,
                date: String?, isBroken: Bool) {
        self.id = id; self.position = position; self.pages = pages
        self.title = title; self.date = date; self.isBroken = isBroken
    }

    /// The issue number, read off the title.
    ///
    /// From the title rather than from `position`, which is a sort order, and
    /// rather than from the JSON-LD's `issueNumber`, which the site states for
    /// only the newest twenty chapters of a run however long it is.
    ///
    /// Anchored on the `#`, because the series name in front of it routinely
    /// carries digits of its own — "(2003-)" — and an unanchored number would
    /// hand back the year for every issue of the run.
    public var number: Int? {
        BatCavePage.issueNumber.firstGroups(title).flatMap { Int($0[1]) }
    }
}

/// One series, and the chapters listed under it.
public struct BatCaveSeries: Equatable, Sendable {
    /// The site's `news_id`, which is also the number leading its address.
    public let id: Int
    /// "The Walking Dead (2003-)".
    public let title: String
    /// The print publisher — "Image Comics", "Europe Comics".
    public let publisher: String?
    /// Full URL of the series poster, as the page states it.
    public let coverURL: String?
    /// The year the run started, from the page's `startDate`.
    public let year: Int?
    public let chapters: [BatCaveChapter]

    public init(id: Int, title: String, publisher: String?, coverURL: String?,
                year: Int?, chapters: [BatCaveChapter]) {
        self.id = id; self.title = title; self.publisher = publisher
        self.coverURL = coverURL; self.year = year; self.chapters = chapters
    }
}

/// Reads a BatCave series page.
///
/// The page states everything twice and the two statements do not agree, so
/// which one is read matters:
///
///  * **`window.__DATA__`**, an inline JSON object, holds the *complete*
///    chapter list with a page count and a broken flag on each. This is what
///    the chapter list is read from.
///  * **JSON-LD**, in `<script type="application/ld+json">`, describes the
///    series — poster, publisher, start date — but its `hasPart` list is
///    truncated to the newest twenty. The Walking Dead has 194 chapters and
///    lists 20 there. So the description is taken from it and the chapters
///    never are.
///
/// Both survive the trip through `document.documentElement.outerHTML`, which
/// is how the app hands a page to an importer: serialising the DOM normalises
/// attribute quoting but leaves the text of a `<script>` element exactly as
/// authored. Nothing here depends on the Vue components that render the list
/// on screen having run.
public enum BatCavePage {

    /// `#193` in a chapter title. Used by `BatCaveChapter.number`.
    static let issueNumber = Rx(#"#(\d+)"#)

    // MARK: - Whether this page can be imported

    /// Whether the page on screen is a series page carrying chapters.
    ///
    /// Cheap enough to ask on every navigation, and it agrees with what the
    /// reader can see: a page showing a list of issues is importable, anything
    /// else is not. The address is checked separately and first — see
    /// `BatCave.isIssuePage` — because this has to read the whole document.
    public static func isSeriesPage(_ html: String) -> Bool {
        guard let payload = dataPayload(html) else { return false }
        return !payload.chapters.isEmpty
    }

    // MARK: - Reading

    /// The series and every chapter under it, or nil if this is not a series
    /// page.
    ///
    /// Nil rather than an empty series, for the same reason the Comic Book
    /// Plus reader returns nil: "this is not a page you can import" and "this
    /// series has nothing in it" are different sentences and only the first is
    /// ever true here.
    public static func series(_ html: String) -> BatCaveSeries? {
        guard let payload = dataPayload(html), !payload.chapters.isEmpty else { return nil }

        let description = seriesDescription(html)
        let chapters = payload.chapters.map { row in
            BatCaveChapter(id: row.id,
                           position: row.posi,
                           // Zero means "not stated", not "an issue with no
                           // pages in it" — and a zero-length download is the
                           // one thing a page-by-page fetch cannot be asked
                           // for.
                           pages: row.pages > 0 ? row.pages : nil,
                           title: title(of: row, fallback: payload.title),
                           date: row.date.isEmpty ? nil : row.date,
                           isBroken: row.broken)
        }
        // Ascending, so the shelf receives a run in reading order rather than
        // in the newest-first order the site displays.
        .sorted { $0.position < $1.position }

        return BatCaveSeries(id: payload.news_id,
                             title: payload.title,
                             publisher: description?.publisher,
                             coverURL: description?.coverURL,
                             year: description?.year,
                             chapters: chapters)
    }

    /// What one chapter is called.
    ///
    /// `title_en` is preferred where the site has one and is routinely empty —
    /// The Walking Dead's own tenth-anniversary reissue has `""` — so this
    /// falls back to `title`, and to the series name only if both are blank.
    /// A row on the shelf with no title at all is not something to write.
    private static func title(of row: DataPayload.Chapter, fallback: String) -> String {
        for candidate in [row.title_en, row.title] {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return fallback
    }

    // MARK: - window.__DATA__

    /// The inline page data, decoded.
    ///
    /// Only the fields this app uses are declared; `JSONDecoder` ignores the
    /// rest, which is what keeps the site's `readed`, `limit`, `xhash` and
    /// bulk-download quota block from being a decode failure here.
    struct DataPayload: Decodable {
        struct Chapter: Decodable {
            let id: Int
            let posi: Int
            let pages: Int
            let title: String
            let title_en: String
            let date: String
            let broken: Bool
        }
        let news_id: Int
        let title: String
        let chapters: [Chapter]
    }

    static func dataPayload(_ html: String) -> DataPayload? {
        guard let json = balancedObject(in: html, after: "window.__DATA__"),
              let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(DataPayload.self, from: data)
    }

    /// The `{ … }` following a marker, matched by counting braces.
    ///
    /// A regex cannot do this. The object nests several levels deep and holds
    /// a 194-element array, and the only patterns that "work" are the greedy
    /// one — which runs to the last brace on the page, somewhere in a
    /// different script — and the lazy one, which stops at the first nested
    /// close. Both produce a string that is not JSON, and both do it silently.
    ///
    /// String literals are tracked so that a brace inside a title cannot
    /// unbalance the count, and escapes so that a `\"` inside one cannot end
    /// it early. Comic titles contain both.
    static func balancedObject(in text: String, after marker: String) -> String? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let tail = text[markerRange.upperBound...]
        guard let start = tail.firstIndex(of: "{") else { return nil }

        var depth = 0, inString = false, escaped = false
        var index = start
        while index < tail.endIndex {
            let character = tail[index]
            if inString {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { inString = false }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(tail[start...index]) }
            }
            index = tail.index(after: index)
        }
        // Ran off the end with the object still open: a truncated page, which
        // is not something to hand a JSON decoder.
        return nil
    }

    // MARK: - JSON-LD

    /// What the linked data says about the series itself.
    struct SeriesDescription {
        let publisher: String?
        let coverURL: String?
        let year: Int?
    }

    private static let ldBlock =
        Rx(#"<script[^>]*type=["']application/ld\+json["'][^>]*>([\s\S]*?)</script>"#,
           [.caseInsensitive])

    /// Poster, publisher and start year, from the `ComicSeries` node.
    ///
    /// `JSONSerialization` rather than `Codable`: the graph is a heterogeneous
    /// array of nodes and the publisher arrives as a reference — an `@id`
    /// pointing at an `Organization` elsewhere in the same graph — so this has
    /// to look nodes up by identity rather than decode a fixed shape.
    static func seriesDescription(_ html: String) -> SeriesDescription? {
        for block in ldBlock.allMatches(html, group: 1) {
            guard let data = block.data(using: .utf8),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let graph = root["@graph"] as? [[String: Any]],
                  let series = graph.first(where: { $0["@type"] as? String == "ComicSeries" })
            else { continue }

            var publisher: String?
            if let reference = (series["publisher"] as? [String: Any])?["@id"] as? String {
                publisher = graph.first {
                    $0["@id"] as? String == reference && $0["@type"] as? String == "Organization"
                }?["name"] as? String
            }

            // "2003-01-01" — the day and month are always the first of
            // January, so only the year is meaningful.
            var year: Int?
            if let start = series["startDate"] as? String {
                year = Int(start.prefix(4))
            }

            return SeriesDescription(publisher: publisher,
                                     coverURL: series["image"] as? String,
                                     year: year)
        }
        return nil
    }
}

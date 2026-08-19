import Foundation

/// One scan, as a leaf page describes it.
///
/// A series holds several scans of the same issue often enough that `number`
/// is not a key: "Adventures in 3-D 1" and "Adventures in 3-D 1 (Odell's)" are
/// both issue 1, from different scanners, at different page counts. `dlid` is
/// the identity; everything else is description.
public struct ComicBookPlusBook: Equatable, Sendable {

    /// The site's own id for this scan, and the whole of its identity here.
    public let dlid: Int
    /// The 32-hex file hash — `f` in a download address, and the shard key for
    /// the thumbnail. Taken from the row rather than the book page, which is
    /// what lets a whole series be imported from one page load.
    public let hash: String
    /// What the row calls it: "Adventures in 3-D 1 (Odell's)".
    public let title: String
    /// Which issue of the run, from `itemprop="position"`. Stated by the site
    /// rather than parsed out of the title, so a re-scan and the original
    /// agree without `TitleCleaner` being asked.
    public let number: Int?
    public let pages: Int?
    /// Cover date. The site marks it up as `datetime="1953-11"`, so the month
    /// is there when the site knows it and absent when it does not.
    public let year: Int?
    public let month: Int?
    /// The member who scanned and uploaded it, credited on every row.
    public let contributor: String?

    public init(dlid: Int, hash: String, title: String, number: Int?,
                pages: Int?, year: Int?, month: Int?, contributor: String?) {
        self.dlid = dlid; self.hash = hash; self.title = title
        self.number = number; self.pages = pages
        self.year = year; self.month = month; self.contributor = contributor
    }
}

/// One series, and the scans listed under it.
public struct ComicBookPlusLeaf: Equatable, Sendable {
    /// "Adventures in 3-D".
    public let series: String
    /// "Harvey Comics" — the original print publisher, which is what the site
    /// files a series under.
    public let publisher: String?
    public let books: [ComicBookPlusBook]

    public init(series: String, publisher: String?, books: [ComicBookPlusBook]) {
        self.series = series; self.publisher = publisher; self.books = books
    }
}

/// Reads a Comic Book Plus series page.
///
/// The site marks its listing up as schema.org microdata — each row is a
/// `schema.org/Book` inside a `BookSeries` — so this reads named attributes
/// rather than counting columns. That matters more than it looks: the visible
/// table has eleven columns, four of them dates or counts that differ only by
/// position, and a parser keyed on column order would swap "date added" for
/// "cover date" the first time the site adds a column, silently and with
/// plausible-looking results.
///
/// One column is deliberately not read. File size sits in a bare `<td>` with
/// no microdata on it, so the only way to it is by counting. It is not worth
/// guessing for: `FileHost.probe` caches a filename and size against the
/// mirror the first time a download is prepared, which is where every other
/// source's size comes from too.
public enum ComicBookPlusPage {

    // MARK: - Patterns
    //
    // Every one of these is quote-agnostic. The site serves single quotes in
    // places and the app imports `document.documentElement.outerHTML`, which
    // normalises every attribute to double quotes — a pattern written for one
    // form matches nothing in the other, and does so silently. That mistake
    // has already been made once here, in `AuthoritativePosts`.

    /// A listing row. `overrow` is the class the site puts on the rows of the
    /// catalogue table and nowhere else.
    ///
    /// Keying on it rather than on `?dlid=` links is what keeps the sidebar
    /// out: the "Latest Comics" widget on the same page carries fifteen more
    /// `dlid` links, for books belonging to entirely different series, and a
    /// parser that swept the page for links would import all of them under
    /// this page's series name.
    private static let row = Rx(#"<tr[^>]*class=["'][^"']*overrow[^"']*["'][\s\S]*?</tr>"#,
                                [.caseInsensitive])

    /// A row's own opening tag, so the type below is read from the row itself
    /// rather than from anything nested inside it.
    private static let openingTag = Rx(#"^<tr[^>]*>"#, [.caseInsensitive])

    /// What the site says the row *is*.
    ///
    /// The catalogue table is shared by everything the site files, and not all
    /// of it is readable: an Old Time Radio series lists its episodes in the
    /// same `overrow` rows, with a `?dlid=`, a file hash and a name — every
    /// field a book needs — and an mp3 behind them. Nothing about the shape of
    /// those rows says they are not comics; the type does.
    ///
    /// Checked rather than inferred from the missing page count, because that
    /// would quietly discard a genuine scan whose page count the site never
    /// filled in. Every readable category — comics, pulps, story papers, dime
    /// novels, newspaper strips — declares `Book`; audio declares `Episode`.
    private static let bookType =
        Rx(#"itemtype=["']https?://schema\.org/Book["']"#, [.caseInsensitive])

    private static let dlid = Rx(#"\?dlid=(\d+)"#)
    private static let hash = Rx(#"\b([0-9a-f]{32})\b"#)
    private static let position = Rx(#"itemprop=["']position["'][^>]*>\s*(\d+)"#, [.caseInsensitive])
    private static let name = Rx(#"itemprop=["']name["'][^>]*>([^<]*)<"#, [.caseInsensitive])
    private static let numberOfPages =
        Rx(#"itemprop=["']numberOfPages["'][^>]*>\s*(\d+)"#, [.caseInsensitive])

    /// The whole `<time>` tag, so `datetime` can be pulled out of it
    /// separately. Matching the two attributes in one pattern would fix their
    /// order, and the site writes `itemprop` first here and could as easily
    /// not.
    private static let timeTag =
        Rx(#"<time[^>]*itemprop=["']datePublished["'][^>]*>"#, [.caseInsensitive])
    private static let datetimeAttr = Rx(#"datetime=["'](\d{4})(?:-(\d{2}))?"#, [.caseInsensitive])

    /// The scanner credit, which the site marks as the row's `editor` and
    /// renders as a link to that member's uploads.
    private static let editor =
        Rx(#"itemprop=["']editor["'][^>]*>\s*<a[^>]*>([^<]*)<"#, [.caseInsensitive])

    /// The series title. The page states it as an `<h1>` and again in the
    /// index card; the `<h1>` is taken because it is the one a redesign is
    /// least likely to move.
    private static let heading = Rx(#"<h1[^>]*>([\s\S]*?)</h1>"#, [.caseInsensitive])
    private static let indexCard =
        Rx(#"class=["'][^"']*indexcardhead[^"']*["'][^>]*>([^<]*)<"#, [.caseInsensitive])

    /// The print publisher, from the `publisher` scope in the index card.
    /// Not the breadcrumb, which carries the same name one level up but would
    /// also happily hand back "Comic Books" on a page whose publisher scope is
    /// missing.
    private static let publisher =
        Rx(#"itemprop=["']publisher["'][\s\S]{0,400}?itemprop=["']name["'][^>]*>([^<]*)<"#,
           [.caseInsensitive])

    // MARK: - Reading

    /// Whether this page is one that can be imported.
    ///
    /// The test is a listing row, which is the same thing the reader can see:
    /// a page showing a table of issues is importable and a page showing
    /// anything else is not. Used to decide whether Import is lit, so it has
    /// to be cheap and it has to agree with what is on screen.
    public static func isLeaf(_ html: String) -> Bool {
        row.allMatches(html).contains(where: isReadable)
    }

    /// Whether one row is something this app can open.
    static func isReadable(_ row: String) -> Bool {
        guard let tag = openingTag.firstGroups(row)?[0] else { return false }
        return bookType.matches(tag)
    }

    /// The series and every scan listed under it, or nil if this is not a
    /// listing page.
    ///
    /// Returns nil rather than an empty leaf for a page with no rows: "this is
    /// not a page you can import from" and "this series has nothing in it" are
    /// different sentences, and only the first one is ever true here.
    public static func leaf(_ html: String) -> ComicBookPlusLeaf? {
        let books = row.allMatches(html).compactMap(book(from:))
        guard !books.isEmpty else { return nil }

        let series = text(heading.firstGroups(html)?[1])
            ?? text(indexCard.firstGroups(html)?[1])
        guard let series, !series.isEmpty else { return nil }

        return ComicBookPlusLeaf(series: series,
                                 publisher: text(publisher.firstGroups(html)?[1]),
                                 books: books)
    }

    /// One row, or nil when it is missing either half of its identity.
    ///
    /// A row without a `dlid` cannot be fetched and a row without a hash
    /// cannot be addressed, so neither is an issue this app could do anything
    /// with. Dropped quietly rather than failing the page: one malformed row
    /// should not cost the reader the other forty.
    static func book(from row: String) -> ComicBookPlusBook? {
        guard isReadable(row),
              let id = dlid.firstGroups(row).flatMap({ Int($0[1]) }),
              let fileHash = hash.firstGroups(row)?[1],
              let title = text(name.firstGroups(row)?[1]), !title.isEmpty
        else { return nil }

        var year: Int?, month: Int?
        if let tag = timeTag.firstGroups(row)?[0],
           let stamp = datetimeAttr.firstGroups(tag) {
            year = Int(stamp[1])
            month = stamp.count > 2 ? Int(stamp[2]) : nil
        }

        return ComicBookPlusBook(
            dlid: id,
            hash: fileHash,
            title: title,
            number: position.firstGroups(row).flatMap { Int($0[1]) },
            pages: numberOfPages.firstGroups(row).flatMap { Int($0[1]) },
            year: year,
            month: month,
            contributor: text(editor.firstGroups(row)?[1]))
    }

    /// A captured group as the text a reader would see.
    ///
    /// Entities are decoded because the site writes them — "Odell&#039;s" is a
    /// real title on a real page — and a shelf entry spelling that out is the
    /// escaping leaking through into the library. Empty comes back as nil so
    /// callers can use `??` rather than testing twice.
    private static func text(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = HTMLText.decodeEntities(raw)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? nil : stripped
    }
}

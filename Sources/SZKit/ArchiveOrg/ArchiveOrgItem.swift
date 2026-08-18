import Foundation

/// One archive.org item, as `https://archive.org/metadata/<identifier>`
/// describes it.
///
/// Only the fields the catalogue is built from. The endpoint returns a great
/// deal more — OCR confidence, torrent info, which servers hold the item — and
/// decoding what is not used would be a promise to keep it working.
///
/// `files[].size` is a string of digits rather than a number, which is simply
/// how the endpoint serves it.
public struct ArchiveOrgItem: Equatable, Sendable {

    public let identifier: String
    /// The item's own title — "Amiga Bilten 1". Not what the shelf shows for a
    /// shipped issue: that wants "Septembar 1988", which is assembled from
    /// `date`. For an item imported out of the browser it is all there is, and
    /// `Store.archiveLabel` is what makes a shelf entry of it.
    public let title: String
    /// "1988-09" on all four of the items shipped today. The month is what the
    /// title is built from, so an item dated by year alone gets a title of
    /// just the year.
    public let year: Int?
    public let month: Int?
    public let files: [File]
    /// What kind of thing the archive thinks this is — "texts", "image",
    /// "audio", "collection". Lowercased.
    ///
    /// Not used to decide anything: an item is importable when it holds a file
    /// this app can open, which is a better test than a word its uploader
    /// picked off a menu. Kept because it is the one honest sentence to put in
    /// front of a reader whose item yields nothing.
    public let mediatype: String?
    /// The uploader's own tags. Searchable, and nothing else.
    public let subjects: [String]

    public struct File: Equatable, Sendable {
        public let name: String
        /// The archive's own word for what it is — "Image Container PDF",
        /// "Page Numbers JSON". More reliable than the extension, and the only
        /// way to tell an uploaded scan from a derivative made out of it.
        public let format: String?
        public let bytes: Int64?

        public init(name: String, format: String?, bytes: Int64?) {
            self.name = name; self.format = format; self.bytes = bytes
        }
    }

    /// The two fields the browser added carry defaults, so the shape the
    /// catalogue builder and its tests construct an item in is unchanged.
    public init(identifier: String, title: String,
                year: Int?, month: Int?, files: [File],
                mediatype: String? = nil, subjects: [String] = []) {
        self.identifier = identifier; self.title = title
        self.year = year; self.month = month; self.files = files
        self.mediatype = mediatype; self.subjects = subjects
    }

    // MARK: - The files that matter

    /// The scan itself: the PDF the item was uploaded as.
    ///
    /// "Image Container PDF" is the archive's name for a PDF that is pages of
    /// images, which is what a scanned magazine is. Its `_text.pdf` sibling is
    /// a derivative — the same pages re-compressed with an OCR layer, at a
    /// third of the size and visibly worse — so matching on the format rather
    /// than on ".pdf" is what keeps the good one.
    ///
    /// The other complete copy of the scan is `_jp2.zip`, which is four times
    /// the bytes and JPEG 2000, a format iOS cannot decode at all.
    ///
    /// One format and no fallback. An item that does not have this file is not
    /// one this app can read, and the builder saying so by name is worth more
    /// than a guess that ships the OCR derivative and looks like a bad scan.
    public var scan: File? {
        files.first { $0.format == "Image Container PDF" }
    }

    /// The scanner's own record of the book, which is where the page count
    /// comes from — the metadata itself never states one.
    ///
    /// Not `_page_numbers.json`, which looks like the same thing and is not:
    /// it lists the leaves OCR found a printed page number on, so A-Profy's
    /// first issue is 19 there and 20 here, and 20 is what the PDF opens with.
    public var scandata: File? {
        files.first { $0.format == "Scandata" }
    }

    // MARK: - Decoding

    /// Reads one metadata response.
    ///
    /// Returns nil rather than throwing for an item that does not exist:
    /// archive.org answers a missing identifier with `{}` and HTTP 200, so an
    /// absent `metadata` object is the real "no such item" and the builder
    /// should say so in those words.
    public static func decode(_ data: Data) throws -> ArchiveOrgItem? {
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let metadata = payload.metadata else { return nil }
        let date = Self.dateComponents(of: metadata.date?.first)
        let title = metadata.title?.first?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ArchiveOrgItem(
            identifier: metadata.identifier,
            // An item with no title at all is rare and real. Its identifier is
            // the only name it has, and is a better one to put on a shelf than
            // an empty string — which would also fold to an empty search key
            // and make the row unfindable.
            title: (title?.isEmpty == false ? title : nil) ?? metadata.identifier,
            year: date.year, month: date.month,
            files: (payload.files ?? []).map {
                File(name: $0.name, format: $0.format, bytes: $0.size.flatMap(Int64.init))
            },
            mediatype: metadata.mediatype?.first?.lowercased(),
            subjects: metadata.subject?.values ?? [])
    }

    /// "1988-09" — year, and month when the item is dated to one.
    ///
    /// Items are dated in whatever precision their uploader had: "1988",
    /// "1988-09", "1988-09-01". Taking the first two dash-separated numbers
    /// reads all three without a date formatter, which would have to be told
    /// which of those it was being handed.
    static func dateComponents(of text: String?) -> (year: Int?, month: Int?) {
        guard let text else { return (nil, nil) }
        let parts = text.split(separator: "-").map(String.init)
        guard let year = parts.first.flatMap(Int.init), (1000...9999).contains(year) else {
            return (nil, nil)
        }
        let month = parts.count > 1 ? Int(parts[1]).flatMap { (1...12).contains($0) ? $0 : nil }
                                    : nil
        return (year, month)
    }

    private struct Payload: Decodable {
        let metadata: Metadata?
        let files: [RawFile]?

        /// Every field but the identifier is read loosely, and every one of
        /// them is optional.
        ///
        /// The four items this app ships were chosen by hand and are as
        /// well-formed as the archive gets. Anything a reader browses to was
        /// filled in by whoever uploaded it: a title can be missing, a date
        /// can be "n.d.", and any of these can arrive as a list where the same
        /// key on the next item is a string. A strict decoder throws on the
        /// second shape and loses the whole item over a field that may not
        /// even be read.
        struct Metadata: Decodable {
            let identifier: String
            let title: LooseText?
            let date: LooseText?
            let mediatype: LooseText?
            let subject: LooseText?
        }

        struct RawFile: Decodable {
            let name: String
            let format: String?
            let size: String?
        }
    }
}

/// A metadata value archive.org states as either one string or a list of them.
///
/// Which shape a given key arrives in is decided by whoever filled in the
/// upload form, not by the key: `subject` is a string on one Zagor item and an
/// array on the next. Decoding both as a list means nothing downstream has to
/// know or care.
struct LooseText: Decodable {

    let values: [String]

    var first: String? { values.first }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let one = try? container.decode(String.self) {
            values = [one]
        } else if let many = try? container.decode([String].self) {
            values = many
        } else if let number = try? container.decode(Int.self) {
            // A title of "1988" decodes as a number, and losing an item over
            // that would be absurd.
            values = [String(number)]
        } else {
            values = []
        }
    }
}

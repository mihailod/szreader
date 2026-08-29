import Foundation

/// Turns raw archive entry names into an ordered list of pages.
///
/// Comic archives are made by hundreds of different people and contain
/// whatever their machine left behind. Two rules do most of the work: throw
/// away everything that is not an image, and sort the rest the way a human
/// would.
public enum PageManifest {

    /// Public because `PageDownload` in SZKit picks a file extension for a
    /// downloaded page against this same set — one list of what counts as an
    /// image, rather than a second one that can drift from it.
    public static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "bmp", "tif", "tiff", "avif", "heic",
    ]

    static let junkNames: Set<String> = ["thumbs.db", "desktop.ini", ".ds_store"]

    public static func isImage(_ path: String) -> Bool {
        guard let ext = path.split(separator: ".").last, path.contains(".") else { return false }
        return imageExtensions.contains(ext.lowercased())
    }

    public static func isJunk(_ path: String) -> Bool {
        if path.hasSuffix("/") { return true }                       // directory entry
        let components = path.split(separator: "/")
        guard let base = components.last.map(String.init) else { return true }
        if components.contains(where: { $0 == "__MACOSX" }) { return true }
        // "._page1.jpg" is an AppleDouble resource fork, not a page.
        if base.hasPrefix(".") { return true }
        return junkNames.contains(base.lowercased())
    }

    /// Human ordering: `page2` before `page10`.
    ///
    /// Plain lexicographic sorting puts page10 between page1 and page2, which
    /// silently shuffles a comic into nonsense.
    public static func naturalLess(_ a: String, _ b: String) -> Bool {
        var i = a.startIndex, j = b.startIndex
        while i < a.endIndex, j < b.endIndex {
            let ca = a[i], cb = b[j]
            if ca.isNumber, cb.isNumber {
                var ni = i, nj = j
                while ni < a.endIndex, a[ni].isNumber { ni = a.index(after: ni) }
                while nj < b.endIndex, b[nj].isNumber { nj = b.index(after: nj) }
                // Compare as numbers so leading zeros do not matter.
                let na = Int(a[i..<ni]) ?? 0, nb = Int(b[j..<nj]) ?? 0
                if na != nb { return na < nb }
                i = ni; j = nj
                continue
            }
            let la = String(ca).lowercased(), lb = String(cb).lowercased()
            if la != lb { return la < lb }
            i = a.index(after: i); j = b.index(after: j)
        }
        return a.count < b.count
    }

    static let archiveExtensions: Set<String> = ["cbz", "cbr", "zip", "rar"]

    /// Archive entries inside an archive, in reading order.
    ///
    /// Scanlations are often packaged as a wrapper around the real comic —
    /// a zip whose only entry is "01 Some Title.cbz". The pages are one level
    /// down, so an archive with no images but a nested archive is not empty,
    /// it is wrapped.
    public static func nestedArchives(in entries: [String]) -> [String] {
        entries.filter { path in
            guard !isJunk(path), let ext = path.split(separator: ".").last else { return false }
            return archiveExtensions.contains(ext.lowercased())
        }.sorted(by: naturalLess)
    }

    /// Documents that are a whole comic in themselves.
    ///
    /// A PDF inside an archive is not a page and not an archive, so neither of
    /// the two lists above sees it — and a zip whose only content is a PDF
    /// therefore looked like an archive with nothing readable in it. That is
    /// how bombjack packages most of its books, and how 60% of that catalogue
    /// arrives.
    public static func nestedDocuments(in entries: [String]) -> [String] {
        entries.filter { path in
            guard !isJunk(path), let ext = path.split(separator: ".").last else { return false }
            return ext.lowercased() == "pdf"
        }.sorted(by: naturalLess)
    }

    /// Image entries only, in reading order.
    public static func pages(from entries: [String]) -> [String] {
        entries.filter { !isJunk($0) && isImage($0) }.sorted(by: naturalLess)
    }
}

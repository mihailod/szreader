import Foundation

/// One file the reader put in the app's folder on the device.
///
/// A file, not a row: this is what a scan of the folder saw, and nothing
/// here has met the library yet. `Store.reconcileLocalFiles` is what turns a
/// list of these into shelf rows and back again.
public struct LocalFile: Equatable, Sendable {
    /// The name on disk, extension and all — "029 Brodeckov izvjestaj.cbr".
    ///
    /// The identity of the row this file becomes. Not the path: the folder
    /// moves with every reinstall and its absolute path is different on each
    /// launch of a simulator, while the name is what the reader dropped in
    /// and what they see in the Finder.
    public let name: String
    public let url: URL
    public let bytes: Int64
    /// When the file was last written. Read for one purpose: telling a file
    /// that has finished arriving from one still being copied — see
    /// `settled(_:against:)`.
    public let modified: Date

    public init(name: String, url: URL, bytes: Int64, modified: Date = .distantPast) {
        self.name = name
        self.url = url
        self.bytes = bytes
        self.modified = modified
    }
}

/// The folder on the device that the reader fills themselves.
///
/// Everything else on the shelf arrives over the network from an archive the
/// app knows about. These arrive over a cable, over AirDrop or out of the
/// Files app, and the app learns of them by looking. That is the whole
/// mechanism: a flat scan of one directory, matched against the rows the last
/// scan wrote.
///
/// In SZKit rather than the app layer so it is covered by tests that run
/// without a simulator: what counts as a readable file, and what a file is
/// called on the shelf, are the two things here worth getting wrong.
public enum LocalFiles {

    /// What the app will attempt to open.
    ///
    /// The reader's folder is theirs, so it will hold things that are not
    /// issues — a stray `.txt`, whatever macOS leaves behind — and a row for
    /// each of those is a shelf full of items that cannot be read. Extension
    /// rather than magic bytes: this runs over every file in the folder on
    /// every launch, and opening each one to sniff it is a cost paid for
    /// nothing. The sniff still happens, once, when the issue is opened.
    ///
    /// `zip`, `rar` and `7z` are here beside their comic-book spellings
    /// because a scan downloaded from anywhere but a reader app is usually
    /// named that way, and refusing it would be refusing the same file under
    /// a different name.
    public static let readableExtensions: Set<String> = [
        "cbz", "cbr", "cb7", "zip", "rar", "7z", "pdf",
    ]

    /// Whether a name in the folder is one this app should offer to open.
    ///
    /// Dotfiles are skipped whatever they are called: `.DS_Store` arrives the
    /// first time the folder is opened in the Finder, and macOS writes
    /// `._name` beside a file copied from some volumes. Neither is the
    /// reader's, and neither should appear on a shelf.
    public static func isReadable(_ name: String) -> Bool {
        guard !name.hasPrefix(".") else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return readableExtensions.contains(ext)
    }

    /// What the shelf calls a file.
    ///
    /// The same recovery the forum's own downloads get — `TitleCleaner` reads
    /// a title, an edition and a number out of a filename and has been
    /// measured against a corpus of them — with one difference: a reader's
    /// own file is allowed to be called whatever it is called. When the
    /// cleaner cannot make a plausible title of it, the name without its
    /// extension is used rather than nothing, because the reader chose that
    /// name and will recognise it.
    public static func describe(_ name: String) -> ParsedFilename {
        let parsed = TitleCleaner.parse(name)
        if TitleCleaner.isPlausible(parsed.title) { return parsed }
        let stem = (name as NSString).deletingPathExtension
            .trimmingCharacters(in: .whitespaces)
        return ParsedFilename(title: stem.isEmpty ? name : stem,
                              edition: parsed.edition, number: parsed.number)
    }

    /// Every readable file sitting directly in the folder.
    ///
    /// Flat on purpose. The folder is one the reader drags files into from a
    /// Finder window, and a shelf that reads sub-folders would have to answer
    /// what a folder of loose page images means, what a nested folder of
    /// archives means, and what happens when one is renamed. A file dropped
    /// in the window it opens onto is the whole of the feature.
    ///
    /// Directories are skipped rather than descended into, which also passes
    /// over `Inbox` — the folder iOS itself writes into when another app
    /// hands this one a file. `adopt` empties that folder into this one.
    public static func scan(_ directory: URL) -> [LocalFile] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants]) else { return [] }

        var found: [LocalFile] = []
        for url in entries {
            let name = url.lastPathComponent
            guard isReadable(name) else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            found.append(LocalFile(name: name, url: url,
                                   bytes: Int64(values?.fileSize ?? 0),
                                   modified: values?.contentModificationDate ?? .distantPast))
        }
        // Sorted so a scan is reproducible and rows arrive in the order the
        // Finder shows them, which is the order the reader dropped them in
        // as far as they are concerned.
        return found.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// How long a file must have sat unchanged before it is taken to have
    /// finished arriving.
    ///
    /// The folder is watched, so a scan now runs *during* a copy rather than
    /// only after one. Over a cable a 300 MB issue takes the better part of a
    /// minute, and the directory entry appears at the start of it — so the
    /// first thing a scan sees of a big file is a few megabytes of it.
    public static let settleTime: TimeInterval = 2

    /// Splits a listing into the files that have finished arriving and the
    /// ones still being written.
    ///
    /// Two ways to be sure, because neither covers both cases. A file nobody
    /// has touched for a couple of seconds is done — that is every file in
    /// the folder at launch, whatever it was doing yesterday. And a file
    /// whose size is exactly what the *previous* scan saw is done too, which
    /// is what settles a copy that has just finished while the app watched it
    /// grow.
    ///
    /// Getting this wrong is not a crash: the row would carry a fraction of
    /// the file, and the scan that followed the copy finishing would correct
    /// it as a replacement. But between the two, the reader has an issue on
    /// the shelf that does not open, and that is worth two seconds.
    public static func settled(_ files: [LocalFile], against previous: [String: Int64],
                               now: Date = Date())
        -> (ready: [LocalFile], waiting: [LocalFile]) {

        var ready: [LocalFile] = []
        var waiting: [LocalFile] = []
        for file in files {
            if now.timeIntervalSince(file.modified) >= settleTime
                || previous[file.name] == file.bytes {
                ready.append(file)
            } else {
                waiting.append(file)
            }
        }
        return (ready, waiting)
    }

    /// Whether an arriving file is one iOS has already put in the app's own
    /// Inbox.
    ///
    /// The folder another app's hand-over lands in — AirDrop, the share
    /// sheet, Open With — and one nothing ever empties, so a file taken in
    /// from there has to be *moved* rather than copied or the reader ends up
    /// with it twice: once on the shelf and once in a folder they cannot see.
    ///
    /// Symlinks are resolved on both sides before anything is compared, and
    /// that is the entire reason this is a function rather than a `hasPrefix`
    /// at the call site. `FileManager` names the container
    /// "/var/mobile/…" while the URL handed over names the same file
    /// "/private/var/mobile/…", `/var` being a symlink to `/private/var`. The
    /// string test is false for every file it is asked about, and the bug it
    /// makes is invisible: everything works, and a second copy of every
    /// AirDropped issue accumulates out of sight for good.
    ///
    /// Compared as path components rather than as strings for the same reason
    /// `LibraryPaths.owns` is: a folder called "Inbox-old" beside it is not
    /// inside it.
    public static func isInInbox(_ url: URL, of directory: URL) -> Bool {
        let inbox = directory.appendingPathComponent("Inbox")
            .resolvingSymlinksInPath().pathComponents
        let theirs = url.resolvingSymlinksInPath().pathComponents
        guard theirs.count > inbox.count else { return false }
        return Array(theirs.prefix(inbox.count)) == inbox
    }

    /// A name for an arriving file that no file in the folder already has.
    ///
    /// AirDrop and the share sheet hand over whatever the file is called at
    /// the other end, and the same issue sent twice is the ordinary case —
    /// once by mistake, once because the first attempt was interrupted.
    /// Overwriting would silently replace a file the reader may have been
    /// reading; failing would look like the transfer not working.
    ///
    /// "Name 2.cbr", then "Name 3.cbr", which is what the Finder does.
    public static func vacantName(for name: String, in directory: URL) -> String {
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.appendingPathComponent(name).path) else {
            return name
        }
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        // Two upwards: "Name" is taken, so the next one a reader would write
        // is "Name 2". Capped rather than looping for ever on a folder that
        // cannot be written to at all.
        for suffix in 2...999 {
            let candidate = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            if !fm.fileExists(atPath: directory.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        return name
    }
}

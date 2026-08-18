import SwiftUI
import SZKit

/// Find something on archive.org and put it on the shelf.
///
/// Unlike the forum importer, this reads nothing off the page. archive.org
/// serves every fact about an item as JSON at a fixed address, so the browser
/// is only ever a way of *choosing* an item — the app watches which one you are
/// looking at and asks the archive about it directly.
///
/// Which is also why Import is dark on the search page and lights up on an
/// item's own page. Search results are a list of thousands that scrolls for
/// ever; there is no sane "import all of this", and an item page names exactly
/// one thing.
struct ArchiveBrowserView: View {

    @ObservedObject var model: AppModel
    @StateObject private var browser = BrowserModel(fence: .archive, desktopSite: false)

    /// What is known about the page currently open.
    @State private var page: PageState = .idle
    /// The identifier `page` describes, so navigating within one item — into
    /// its reader, back out — costs nothing.
    @State private var shown: String?
    /// And which file of it, for a pack: turning to another volume is the same
    /// item and a different issue.
    @State private var shownFile: String?
    @State private var choosingFile = false
    /// Set when the chosen file would replace one already on the device.
    @State private var pendingSwap: Swap?
    /// The last import, until it is dismissed or the reader moves on.
    @State private var report: Report?

    private enum PageState {
        /// Not looking at an item: the search page, a collection, a profile.
        case idle
        case loading
        /// An item, and the issues in it this page is about — every issue the
        /// item holds, or the single one the address names.
        case ready(ArchiveOrgItem, [ArchiveOrgItem.ReadableIssue])
        /// An item holding nothing this app can open.
        case unusable(ArchiveOrgItem)
        case failed(String)

        var item: ArchiveOrgItem? {
            switch self {
            case .ready(let item, _), .unusable(let item): return item
            case .idle, .loading, .failed:                 return nil
            }
        }

        var issues: [ArchiveOrgItem.ReadableIssue] {
            if case .ready(_, let issues) = self { return issues }
            return []
        }
    }

    private struct Swap {
        let item: ArchiveOrgItem
        let file: ArchiveOrgItem.ReadableFile
    }

    private struct Report {
        let title: String
        let detail: String
        let good: Bool
    }

    var body: some View {
        BrowserScreen(model: browser, fallbackTitle: "Archive.org") {
            importButton
        } banner: {
            banner
        }
        .onAppear { if browser.url == nil { browser.load(ArchiveOrg.searchURL) } }
        .onChange(of: browser.url) { url in resolve(url) }
        .alert("Replace the downloaded file?", isPresented: Binding(
            get: { pendingSwap != nil },
            set: { if !$0 { pendingSwap = nil } }
        ), presenting: pendingSwap) { swap in
            Button("Replace", role: .destructive) {
                pendingSwap = nil
                perform(swap.item, file: swap.file)
            }
            Button("Cancel", role: .cancel) { pendingSwap = nil }
        } message: { swap in
            // Named, because the reader is choosing between two files whose
            // only visible difference is a format and a size.
            Text("“\(swap.item.title)” is already downloaded from a different "
                 + "file. Switching to \(swap.file.label) removes what is on "
                 + "the device; the issue stays on your shelf and can be "
                 + "downloaded again.")
        }
    }

    // MARK: - The button

    private var importButton: some View {
        Button {
            choosingFile = true
        } label: {
            if case .loading = page {
                ProgressView()
            } else {
                // The same explicit stack as the forum importer: a toolbar
                // collapses a Label to its icon, and the word is what makes
                // this the same button as the one on the shelf.
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                    Text("Import")
                }
                .font(.headline)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canImport)
        // Attached to the button rather than to the screen around it: on an
        // iPad this presents as a popover, and a popover anchored to the whole
        // view floats in the middle of the page with nothing to say which tap
        // produced it.
        .confirmationDialog(fileDialogTitle, isPresented: $choosingFile,
                            titleVisibility: .visible) {
            fileButtons
        } message: {
            Text(fileDialogMessage)
        }
    }

    private var canImport: Bool {
        if case .ready = page { return true }
        return false
    }

    // MARK: - Picking what to import

    /// Whether the choice on offer is between issues or between formats.
    ///
    /// An item usually holds one issue and the question is which format to
    /// take. A pack holds a run — thirteen issues of Transactor, one PDF each
    /// — and then the question is which issue, asked first and on its own,
    /// because thirteen rows all reading "PDF · as uploaded" are not a choice
    /// anybody can make.
    private var choosingBetweenIssues: Bool { page.issues.count > 1 }

    private var fileDialogTitle: String {
        page.item?.title ?? "Import"
    }

    /// What the choice is between.
    ///
    /// The sizes are the whole point of asking rather than picking: the same
    /// comic is 313 MB as the CBR its scanner uploaded and 28 MB as the PDF
    /// the archive derived from it, and which of those is the right answer
    /// depends on the device and the reader, not on the app.
    private var fileDialogMessage: String {
        if choosingBetweenIssues {
            return "This item holds \(page.issues.count) issues. Importing one "
                 + "adds it to your shelf; come back for the others."
        }
        if let issue = page.issues.first, alreadyInLibrary(issue) != nil {
            return "Already in your library. Choosing a different file changes "
                 + "which one this issue downloads."
        }
        return "Only the issue's details are imported now. Download it from "
             + "your shelf whenever you want it."
    }

    @ViewBuilder private var fileButtons: some View {
        if choosingBetweenIssues, let item = page.item {
            // One row per issue, named by the part of the filename the item's
            // own title does not already say, and taking that issue's best
            // format. A pack's issues have one format each in practice, and a
            // second question asked thirteen times over would be worse than
            // the app choosing between a scan and its own OCR copy.
            ForEach(page.issues) { issue in
                Button("\(item.shortName(for: issue)) · \(issue.best.label) "
                       + "· \(Self.size(issue.best.bytes))") {
                    choose(issue.best)
                }
            }
        } else {
            ForEach(page.issues.first?.files ?? []) { file in
                Button("\(file.label) · \(file.detail) · \(Self.size(file.bytes))") {
                    choose(file)
                }
            }
        }
        Button("Cancel", role: .cancel) { }
    }

    /// The library row for one issue of the item on screen, if it has one.
    private func alreadyInLibrary(_ issue: ArchiveOrgItem.ReadableIssue) -> ArchiveRow? {
        guard let item = page.item else { return nil }
        return model.archiveRow(item.code(for: issue))
    }

    // MARK: - The banner

    @ViewBuilder private var banner: some View {
        if let report {
            BrowserBanner(icon: report.good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                          tint: report.good ? .green : .orange,
                          title: report.title, detail: report.detail,
                          dismiss: { self.report = nil })
        } else {
            switch page {
            case .unusable(let item):
                BrowserBanner(
                    icon: "questionmark.circle.fill", tint: .orange,
                    title: "Nothing here this app can read",
                    detail: unusableDetail(item),
                    dismiss: { page = .idle })
            case .failed(let reason):
                BrowserBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                              title: "archive.org could not be asked about this item",
                              detail: reason, dismiss: { page = .idle })
            case .ready(let item, let issues) where issues.count > 1:
                BrowserBanner(
                    icon: "square.stack", tint: .secondary,
                    title: "\(issues.count) issues in one item",
                    detail: "“\(item.title)” is a pack. Import brings in one "
                          + "issue at a time, each onto its own shelf entry.",
                    dismiss: { page = .idle })
            case .ready(_, let issues) where issues.first.flatMap(alreadyInLibrary) != nil:
                let existing = issues.first.flatMap(alreadyInLibrary)
                BrowserBanner(
                    icon: "checkmark.circle", tint: .secondary,
                    title: "Already in your library",
                    detail: existing?.isDownloaded == true
                        ? "Downloaded. Import again only to change which file it uses."
                        : "Import again only to change which file it downloads.",
                    dismiss: { page = .idle })
            case .idle, .loading, .ready:
                EmptyView()
            }
        }
    }

    /// Why an item yields nothing, in terms of what it actually holds.
    ///
    /// Every item on archive.org carries a torrent and a handful of metadata
    /// files whether or not anyone wanted them, so "it only has a torrent" is
    /// never the real reason and saying it would send someone looking for a
    /// setting to turn on.
    private func unusableDetail(_ item: ArchiveOrgItem) -> String {
        switch item.mediatype {
        case "collection":
            return "This is a collection, not a single item. Open one of the "
                 + "items inside it."
        case "audio", "etree":
            return "This is a recording, not a scanned issue."
        case "movies":   return "This is a video, not a scanned issue."
        case "software":
            // The one that reads as a false negative unless it says why: these
            // items often hold plain zips, which look exactly like a scan
            // until you open one and find disk images.
            return "This is software, not a scanned issue — its archives hold "
                 + "programs rather than pages."
        case "image":
            // The single-image items: a scanner uploading one cover at a time.
            return "This is a single picture, not a scanned issue."
        default:
            return "Its files are all things this app cannot open — JPEG 2000 "
                 + "pages, text layers, EPUB or torrents. A CBR, CBZ, ZIP or "
                 + "PDF is what it would need."
        }
    }

    // MARK: - Actions

    /// Works out what the page now open is, and asks the archive about it.
    ///
    /// Guarded on the identifier rather than the URL: one item is a dozen
    /// addresses — its details page, its reader, a page number, a sort order —
    /// and asking again on each of them would be a request per scroll.
    private func resolve(_ url: URL?) {
        let identifier = url.flatMap { ArchiveOrg.identifier(inURL: $0) }
        // Which file of the item the reader has open, when the address says.
        // Not part of the guard below: opening a second volume of the same
        // pack keeps the identifier and changes only this.
        let stem = url.flatMap { ArchiveOrg.fileStem(inURL: $0) }
        guard identifier != shown || stem != shownFile else { return }
        shown = identifier
        shownFile = stem
        // A result belongs to the issue it was about; moving on drops it.
        report = nil

        guard let identifier else {
            page = .idle
            return
        }
        page = .loading
        Task { @MainActor in
            do {
                let item = try await model.archiveItem(identifier)
                // The reader has moved on; this answer is about a page that is
                // no longer open.
                guard shown == identifier, shownFile == stem else { return }
                guard let item else {
                    page = .failed("archive.org has no item called “\(identifier)”.")
                    return
                }
                let issues = item.readableIssues
                guard !issues.isEmpty else {
                    page = .unusable(item)
                    return
                }
                // The archive's reader puts the open file in the address, so
                // on a pack the app can import exactly what is on screen
                // rather than asking again which of thirteen it was.
                if let stem, let named = item.issue(named: stem) {
                    page = .ready(item, [named])
                } else {
                    page = .ready(item, issues)
                }
            } catch {
                guard shown == identifier, shownFile == stem else { return }
                page = .failed(Library.reason(error))
            }
        }
    }

    /// A file was picked: import it, unless doing so would throw away a
    /// download the reader already has.
    private func choose(_ file: ArchiveOrgItem.ReadableFile) {
        guard let item = page.item, let issue = item.issue(holding: file) else { return }
        let url = file.url(item: item.identifier)
        if let existing = alreadyInLibrary(issue), existing.isDownloaded,
           existing.mirrorURL != url {
            pendingSwap = Swap(item: item, file: file)
            return
        }
        perform(item, file: file)
    }

    private func perform(_ item: ArchiveOrgItem, file: ArchiveOrgItem.ReadableFile) {
        let offered = page.issues
        do {
            let done = try model.importFromArchive(item, file: file)
            // The rows have changed underneath the state that described them,
            // so the notes are re-read rather than left saying what was true a
            // moment ago. The same issues stay on offer: importing one volume
            // of a pack is not a reason to stop showing the other twelve.
            page = .ready(item, offered)
            report = Report(
                title: done.existed && !done.fileChanged
                    ? "Already in your library"
                    : (done.existed ? "Now downloads the \(file.label)"
                                    : "Added “\(done.title)”"),
                detail: done.existed && !done.fileChanged
                    ? "“\(done.title)” already uses this file — nothing changed."
                    : "\(file.label), \(Self.size(file.bytes)). It is on your "
                    + "shelf now; downloading is a separate tap, whenever you want it.",
                good: true)
        } catch {
            report = Report(title: "Could not import",
                            detail: Library.reason(error), good: false)
        }
    }

    /// Sizes as the shelf writes them.
    private static func size(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "size unknown" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB, .useGB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }
}

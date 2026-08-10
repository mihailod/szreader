import SwiftUI
import SZKit

enum LibraryLayout: String {
    case list, grid
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var selected: StoredIssue?
    @State private var showingImport = false
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @State private var pending: PendingAction?

    /// A destructive action awaiting confirmation.
    private enum PendingAction: Identifiable {
        case deleteDownload(StoredIssue)
        case remove(StoredIssue)
        case removeAllDownloads(Int)
        case deleteAll(Int)

        var id: String {
            switch self {
            case .deleteDownload(let i): return "dl-\(i.id)"
            case .remove(let i): return "rm-\(i.id)"
            case .removeAllDownloads: return "all-downloads"
            case .deleteAll: return "all"
            }
        }
    }

    private var layout: LibraryLayout { LibraryLayout(rawValue: layoutRaw) ?? .grid }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Divider()
                content
                statusBar
            }
            // No navigation bar: the app is stripzona-only, so a title row says
            // nothing, and its search field slid the toolbar away when focused.
            .toolbar(.hidden, for: .navigationBar)
            .sheet(item: $selected) { issue in
                IssueDetail(issue: issue, mirrors: model.mirrors(for: issue))
            }
            .alert(item: $pending) { action in confirmation(for: action) }
            .fullScreenCover(item: $model.reading) { open in
                ReaderView(document: open.document, title: open.title)
            }
            // On its own view deliberately: SwiftUI honours only one `.alert`
            // per view, and the confirmation alert above already claims this
            // one.
            .background(
                Color.clear
                    .alert("Download failed", isPresented: Binding(
                        get: { model.failure != nil },
                        set: { if !$0 { model.failure = nil } }
                    )) {
                        Button("OK", role: .cancel) { model.failure = nil }
                    } message: {
                        Text(model.failure ?? "")
                    }
            )
        }
        // Kept off the view that owns .sheet(item:): SwiftUI honours only one
        // presentation modifier per view, and the sheet would win.
        .fullScreenCover(isPresented: $showingImport) {
            ImportView { html in try model.importPage(html: html) }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .font(.title3).foregroundStyle(.secondary)
                // "your library": this searches what has been imported, never
                // the forum. Implying otherwise would be misleading.
                TextField("Search your library — title, hero, publisher, number",
                          text: Binding(get: { model.query },
                                        set: { model.search($0) }))
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .submitLabel(.search)
                if !model.query.isEmpty {
                    Button { model.search("") } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3).foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
            .background(Color(.secondarySystemBackground), in: Capsule())

            Picker("", selection: $layoutRaw) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid.rawValue)
                Image(systemName: "list.bullet").tag(LibraryLayout.list.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: 120)

            // Filled icon when a filter is on, so a narrowed library never
            // looks like a missing one.
            Menu {
                Toggle(isOn: $model.downloadedOnly) {
                    Label("Downloaded", systemImage: "arrow.down.circle")
                }
            } label: {
                Image(systemName: model.downloadedOnly
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30))
                    .frame(height: 44)
            }
            .menuStyle(.borderlessButton)
            .tint(model.downloadedOnly ? .accentColor : .secondary)

            Button { showingImport = true } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .font(.headline).padding(.horizontal, 6).frame(height: 40)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Actions

    /// One menu for both layouts — long-pressing cover art behaves identically
    /// in grid and list, so there is only one thing to learn.
    /// One menu for both layouts — long-pressing cover art behaves identically
    /// in grid and list, so there is only one thing to learn.
    ///
    /// Ordered by consequence: fetching, then the two that only reclaim disk,
    /// then — below a divider and marked destructive so they render red — the
    /// two that actually remove things from the library. Only "Delete" ever
    /// costs an import to undo.
    @ViewBuilder private func issueMenu(for issue: StoredIssue) -> some View {
        // Green for the only action that adds something; red is reserved for
        // the two that remove from the library.
        Button {
            model.download(issue)
        } label: {
            Label(issue.isDownloaded ? "Download again" : "Download",
                  systemImage: "arrow.down.circle")
        }
        .tint(.green)
        .disabled(model.downloading.contains(issue.id))

        Button {
            pending = .deleteDownload(issue)
        } label: { Label("Remove Download", systemImage: "trash") }
            .disabled(!issue.isDownloaded)

        Button {
            pending = .removeAllDownloads(model.downloadedCount)
        } label: { Label("Remove All Downloads", systemImage: "arrow.down.circle.dotted") }
            .disabled(model.downloadedCount == 0)

        Divider()

        Button(role: .destructive) {
            pending = .remove(issue)
        } label: { Label("Delete", systemImage: "xmark.bin") }

        Button(role: .destructive) {
            pending = .deleteAll(model.issueCount)
        } label: { Label("Delete Entire Library", systemImage: "trash.slash") }
    }

    private func confirmation(for action: PendingAction) -> Alert {
        switch action {
        case .deleteDownload(let issue):
            return Alert(
                title: Text("Are you sure?"),
                message: Text("Remove the downloaded files for “\(name(issue))”. "
                              + "It stays in your library and can be "
                              + "downloaded again."),
                primaryButton: .destructive(Text("Yes")) { model.deleteDownload(issue) },
                secondaryButton: .cancel(Text("No")))
        case .remove(let issue):
            return Alert(
                title: Text("Are you sure?"),
                message: Text("Delete “\(name(issue))” from the library, including "
                              + "any download. Getting it back means importing "
                              + "its page again."),
                primaryButton: .destructive(Text("Yes")) { model.delete(issue) },
                secondaryButton: .cancel(Text("No")))
        case .removeAllDownloads(let count):
            return Alert(
                title: Text("Are you sure?"),
                message: Text("Remove \(count) downloaded comic\(count == 1 ? "" : "s") "
                              + "from this device. The library keeps every title, "
                              + "so nothing needs importing again."),
                primaryButton: .destructive(Text("Yes")) { model.removeAllDownloads() },
                secondaryButton: .cancel(Text("No")))
        case .deleteAll(let count):
            return Alert(
                title: Text("Are you sure?"),
                message: Text("Delete all \(count) issues and every downloaded "
                              + "comic, resetting the app to empty. This cannot "
                              + "be undone."),
                primaryButton: .destructive(Text("Yes")) { model.deleteEverything() },
                secondaryButton: .cancel(Text("No")))
        }
    }

    private func name(_ issue: StoredIssue) -> String {
        issue.title ?? issue.code ?? "this issue"
    }

    // MARK: - Content

    @ViewBuilder private var content: some View {
        if model.results.isEmpty {
            emptyState
        } else if layout == .grid {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 18)],
                          spacing: 22) {
                    ForEach(model.results, id: \.id) { issue in
                        gridCell(issue)
                            .contextMenu { issueMenu(for: issue) }
                    }
                }
                .padding(20)
            }
        } else {
            List(model.results, id: \.id) { issue in
                row(issue)
            }
            .listStyle(.plain)
        }
    }

    /// Two tap targets, deliberately.
    ///
    /// The artwork opens the comic, the caption opens its details — the same
    /// split as a bookshelf app, where tapping a cover means "read this" and
    /// tapping the title means "tell me about it". An issue that is not
    /// downloaded has nothing to read, so its artwork opens the details too,
    /// which is where the Download action lives.
    private func gridCell(_ issue: StoredIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if issue.isDownloaded { model.read(issue) } else { selected = issue }
            } label: {
                artwork(issue)
            }
            .buttonStyle(.plain)

            Button { selected = issue } label: { caption(issue) }
                .buttonStyle(.plain)
        }
    }

    private func artwork(_ issue: StoredIssue) -> some View {
        ZStack(alignment: .topTrailing) {
            cover(issue)
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            if model.downloading.contains(issue.id) {
                ProgressView().padding(8)
            } else if model.opening == issue.id {
                // Unpacking a solid RAR takes a moment; without this the tap
                // looks ignored.
                ProgressView().padding(8)
            } else if issue.isDownloaded {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.white, .green)
                    .padding(6)
            }
        }
        .contentShape(Rectangle())
    }

    private func caption(_ issue: StoredIssue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name(issue))
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let mark = issue.shelfMark {
                Text(mark).font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }

    private func row(_ issue: StoredIssue) -> some View {
        HStack(spacing: 16) {
            // Long-pressing the artwork gives the same menu as the grid.
            cover(issue)
                .frame(width: 58, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contentShape(Rectangle())
                // Same rule as the grid: artwork reads, metadata describes.
                .onTapGesture {
                    if issue.isDownloaded { model.read(issue) } else { selected = issue }
                }
                .overlay {
                    if model.opening == issue.id { ProgressView() }
                }
                .contextMenu { issueMenu(for: issue) }

            Button { selected = issue } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        // Monospaced digits so numbers line up down the column
                        // rather than jittering with digit width.
                        if let mark = issue.shelfMark {
                            Text(mark)
                                .font(.title3.weight(.semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(name(issue)).font(.title3.weight(.medium))
                    }
                    // Who it is about and what it is from. The mirror count
                    // lived here and told the reader nothing about the comic;
                    // it is in the details, where it belongs.
                    if let provenance = issue.provenance {
                        Text(provenance).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            rowActions(issue)
        }
        .padding(.vertical, 6)
    }

    private func rowActions(_ issue: StoredIssue) -> some View {
        HStack(spacing: 10) {
            if model.downloading.contains(issue.id) {
                ProgressView().frame(width: 92)
            } else {
                // One button for both directions, because the two states are
                // mutually exclusive: a comic either is on disk or is not, and
                // a permanently greyed-out twin of the button next to it says
                // nothing a reader cannot already see from the cover.
                Button(issue.isDownloaded ? "Remove Download" : "Download") {
                    if issue.isDownloaded {
                        pending = .deleteDownload(issue)
                    } else {
                        model.download(issue)
                    }
                }
                .buttonStyle(.bordered)
                .tint(issue.isDownloaded ? .red : .green)
            }
            Button("Delete") { pending = .remove(issue) }
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }

    /// Cover art, greyed until the comic is downloaded — the quickest way to
    /// see what you have versus what is only catalogued.
    ///
    /// The grey version is a separately cached image, not a live filter: the
    /// filter re-ran on the GPU for every visible cell on every render.
    private func cover(_ issue: StoredIssue) -> some View {
        CoverImage(url: issue.coverURL, number: issue.number,
                   grayscale: !issue.isDownloaded)
            .opacity(issue.isDownloaded ? 1 : 0.75)
            .overlay(alignment: .bottom) {
                // These are ~80 MB over throttled third-party hosts, so a
                // download runs for a while. Without a bar it reads as hung.
                if let fraction = model.progress[issue.id] {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(.green)
                        .padding(.horizontal, 6)
                        .padding(.bottom, 6)
                }
            }
    }

    /// Three distinct empty cases, because "nothing here" for three different
    /// reasons needs three different next steps.
    private var emptyIcon: String {
        if model.downloadedOnly { return "arrow.down.circle" }
        return model.issueCount == 0 ? "books.vertical" : "magnifyingglass"
    }

    private var emptyTitle: String {
        if model.downloadedOnly { return "No downloaded comics yet" }
        return model.issueCount == 0 ? "No imported comics yet" : "No match"
    }

    private var emptyDetail: String {
        if model.downloadedOnly {
            return model.query.isEmpty
                ? "Turn off the Downloaded filter and download some comics!"
                : "Nothing you have downloaded matches “\(model.query)”."
        }
        return model.issueCount == 0
            ? "Tap Import, login to StripZona (if needed), browse and like a post "
              + "with the comics you want to read and then import that page."
            : "Nothing in your \(model.issueCount) imported issues matches “\(model.query)”."
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: emptyIcon)
                .font(.system(size: 96)).foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: 44, weight: .bold))
            Text(emptyDetail)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryLine: String {
        var line = "\(model.results.count) shown · \(model.issueCount) imported"
        line += " · \(model.downloadedCount) downloaded (\(Self.gb(model.diskUsage)))"
        return line
    }

    /// Under a gigabyte, which is not enough for one more comic — these run
    /// 80–100 MB each, but a download also needs room to unpack alongside the
    /// archive before it is deleted.
    private var lowOnSpace: Bool { model.freeSpace < 1_000_000_000 }

    /// Whole gigabytes, rounded down: this is a "have I room for another one"
    /// figure, and rounding up would promise space that is not there. Below a
    /// gigabyte that rounds to "0 GB free", which reads like a bug, so it
    /// becomes "<1 GB free".
    private var freeText: String {
        lowOnSpace ? "<1 GB free" : "\(model.freeSpace / 1_000_000_000) GB free"
    }

    private static func gb(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        // Without this, zero formats as "Zero KB". Showing "0 MB" keeps the
        // storage readout present from the start, so the feature is visible
        // before anything has been downloaded.
        f.allowsNonnumericFormatting = false
        return f.string(fromByteCount: bytes)
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Text(summaryLine)
            if model.freeSpace > 0 {
                Text("·")
                Text(freeText)
                    // Red only when the disk is nearly full — a colour that
                    // means "act on this" loses its meaning if it is on screen
                    // all the time.
                    .foregroundStyle(lowOnSpace ? Color.red : Color.secondary)
            }
            // Only present when something actually happened; the counts above
            // are the resting state.
            if !model.status.isEmpty {
                Text("·")
                Text(model.status)
            }
        }
        .font(.system(size: 25, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 20)
        // maxWidth centres horizontally, the fixed height centres vertically.
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(.bar)
    }
}

/// Cover art, served from `CoverStore`.
///
/// The image is read out of the cache **synchronously in `init`**, so a
/// redisplay — scrolling a cell back, or switching grid to list — paints on
/// the first frame instead of showing a placeholder while an async task
/// re-checks a cache it was always going to hit.
private struct CoverImage: View {
    let url: String?
    let number: Int?
    let grayscale: Bool

    @State private var image: UIImage?

    init(url: String?, number: Int?, grayscale: Bool) {
        self.url = url
        self.number = number
        self.grayscale = grayscale
        _image = State(initialValue: CoverStore.shared.cached(url, grayscale: grayscale))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .background(Color(.tertiarySystemFill))
        // Keyed on the variant, so finishing a download re-runs this and the
        // cover turns colour immediately. It must NOT bail on a non-nil image:
        // that is exactly the case where a grey one is already showing.
        .task(id: (url ?? "") + (grayscale ? "#gray" : "")) {
            if let hit = CoverStore.shared.cached(url, grayscale: grayscale) {
                image = hit          // both variants are cached, so this is instant
                return
            }
            image = await CoverStore.shared.image(url, grayscale: grayscale)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Text(number.map(String.init) ?? "-")
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

struct IssueDetail: View {
    let issue: StoredIssue
    let mirrors: [MirrorLink]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("Issue") {
                    LabeledContent("Title", value: issue.title ?? "—")
                    LabeledContent("Hero", value: issue.heroDisplay ?? "—")
                    LabeledContent("Series", value: issue.edition ?? "—")
                    // Spelled out, because the shelf shows only the short form
                    // and an unexplained "LMS" is not obviously an abbreviation
                    // of anything.
                    if let code = issue.editionCode, let edition = issue.edition,
                       code.caseInsensitiveCompare(edition) != .orderedSame {
                        LabeledContent("Series code") {
                            Text("\(code) — \(edition)")
                        }
                    }
                    LabeledContent("Number", value: issue.number.map(String.init) ?? "—")
                    LabeledContent("Code", value: issue.code ?? "—")
                    LabeledContent("Mirrors", value: "\(issue.mirrorCount)")
                    LabeledContent("Parsed as", value: issue.style.rawValue)
                    LabeledContent("Downloaded", value: issue.isDownloaded ? "yes" : "no")
                }
                Section("Mirrors") {
                    ForEach(Array(mirrors.enumerated()), id: \.offset) { index, mirror in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(index == 0 ? "primary" : "drugi sken \(index)")
                                .font(.caption).foregroundStyle(.secondary)
                            Text(mirror.host).font(.body.monospaced())
                        }
                    }
                }
            }
            .navigationTitle(issue.title ?? issue.code ?? "Issue")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() } } }
        }
    }
}

extension StoredIssue: Identifiable {}

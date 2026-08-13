import SwiftUI
import SZKit

enum LibraryLayout: String {
    case list, grid
}

/// A destructive action awaiting confirmation.
///
/// At file scope because the detail sheet raises these too, and a
/// confirmation that only exists on the shelf would mean the same action
/// asking in one place and not the other.
/// Starts a download, asking first when the issue is published as part of a
/// set — one archive holding a run of issues, so a single tap fetches all of
/// them and a single removal discards all of them.
@MainActor
func beginDownload(_ issue: StoredIssue, model: AppModel, pending: inout PendingAction?) {
    if let set = model.set(for: issue) {
        pending = .downloadSet(issue, set.downloadWarning)
    } else {
        model.download(issue)
    }
}

/// The same question before removing one.
@MainActor
func beginRemoveDownload(_ issue: StoredIssue, model: AppModel, pending: inout PendingAction?) {
    if let set = model.set(for: issue) {
        pending = .removeSet(issue, set.removalWarning)
    } else {
        pending = .deleteDownload(issue)
    }
}

enum PendingAction: Identifiable {
    case deleteDownload(StoredIssue)
    case remove(StoredIssue)
    case removeAllDownloads(Int)
    case deleteAll(Int)
    /// Everything the shelf is currently showing. The count travels with the
    /// case so the warning can say how much is about to go.
    case removeVisibleDownloads(count: Int, touchesASet: Bool)
    case deleteVisible(Int)
    /// Issues published as one download: taking or discarding any of them
    /// does the same to all of them, so both are asked about first.
    case downloadSet(StoredIssue, String)
    case removeSet(StoredIssue, String)

    var id: String {
        switch self {
        case .downloadSet(let i, _): return "set-dl-\(i.id)"
        case .removeSet(let i, _): return "set-rm-\(i.id)"
        case .deleteDownload(let i): return "dl-\(i.id)"
        case .remove(let i): return "rm-\(i.id)"
        case .removeAllDownloads: return "all-downloads"
        case .deleteAll: return "all"
        case .removeVisibleDownloads: return "visible-downloads"
        case .deleteVisible: return "visible"
        }
    }
}

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var selected: StoredIssue?
    @State private var showingImport = false
    @AppStorage("libraryLayout") private var layoutRaw = LibraryLayout.grid.rawValue
    @State private var pending: PendingAction?

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
                IssueDetail(model: model, issue: issue,
                            mirrors: model.mirrors(for: issue), pending: $pending)
            }
            .alert(item: $pending) { action in confirmation(for: action) }
            .fullScreenCover(item: $model.reading) { open in
                ReaderView(model: model, comicID: open.id, title: open.title,
                           startPage: open.startPage)
                    // The place is saved on every page turn but the shelf is
                    // deliberately not rebuilt for each one. Closing the reader
                    // is when it needs to catch up — otherwise the badge for a
                    // comic you just started only appears on next launch.
                    .onDisappear { model.search(model.query) }
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

            // Filled icon when the order is not the default, for the same
            // reason the filter fills: a shelf in an unexpected order should
            // say so rather than look wrong.
            Menu {
                Picker("Sort by", selection: $model.sortOrder) {
                    ForEach(ShelfSort.allCases, id: \.self) { order in
                        Label(order.label, systemImage: order.symbol).tag(order)
                    }
                }
            } label: {
                Image(systemName: model.sortOrder == .imported
                      ? "arrow.up.arrow.down.circle"
                      : "arrow.up.arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .frame(height: 44)
            }
            .menuStyle(.borderlessButton)
            .tint(model.sortOrder == .imported ? .secondary : .accentColor)

            // Filled icon when a filter is on, so a narrowed library never
            // looks like a missing one.
            Menu {
                Toggle(isOn: $model.downloadedOnly) {
                    Label("Downloaded", systemImage: "arrow.down.circle")
                }

                Toggle(isOn: $model.showUnread) {
                    Label("Unread", systemImage: "circle")
                }
                Toggle(isOn: $model.showReading) {
                    Label("Reading", systemImage: "book")
                }
                Toggle(isOn: $model.showRead) {
                    Label("Read", systemImage: "checkmark.circle")
                }

                // Series are built from what has actually been imported, so
                // the menu never offers an edition the library does not hold.
                if !model.availableSeries.isEmpty {
                    Section("Series") {
                        ForEach(model.availableSeries, id: \.self) { edition in
                            Toggle(isOn: Binding(
                                get: { model.selectedSeries.contains(edition) },
                                set: { _ in model.toggleSeries(edition) }
                            )) {
                                // Shown in sentence case: the forum shouts its
                                // editions, and a menu of LUNOV MAGNUS STRIP
                                // reads as an error message.
                                Text(TitleCleaner.normaliseCase(edition))
                            }
                        }
                    }
                }

                if !model.availableHeroes.isEmpty {
                    Section("Hero") {
                        ForEach(model.availableHeroes, id: \.self) { hero in
                            Toggle(isOn: Binding(
                                get: { model.selectedHeroes.contains(hero) },
                                set: { _ in model.toggleHero(hero) }
                            )) {
                                // Shown short, filtered long: the row holds
                                // "Zagor Te-Nay" and the menu says "Zagor".
                                Text(PageContext.displayName(forHero: hero))
                            }
                        }
                    }
                }

                if !model.availablePublishers.isEmpty {
                    // "Publisher/Creator" because the crumb above a hero is
                    // whichever the forum happened to file it under — an
                    // imprint for BONELLI and FIBRA, the authors for
                    // "Magnus - Bunker" or "Hugo Pratt". Naming it for both
                    // beats inventing logic to tell them apart.
                    Section("Publisher/Creator") {
                        ForEach(model.availablePublishers, id: \.self) { publisher in
                            Toggle(isOn: Binding(
                                get: { model.selectedPublishers.contains(publisher) },
                                set: { _ in model.togglePublisher(publisher) }
                            )) {
                                Text(TitleCleaner.normaliseCase(publisher))
                            }
                        }
                    }
                }

                if !model.selectedSeries.isEmpty || !model.selectedPublishers.isEmpty
                    || !model.selectedHeroes.isEmpty {
                    Section {
                        Button("Show everything", systemImage: "xmark.circle") {
                            model.clearSeriesFilter()
                        }
                    }
                }
            } label: {
                Image(systemName: filtering
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30))
                    .frame(height: 44)
            }
            .menuStyle(.borderlessButton)
            .tint(filtering ? .accentColor : .secondary)

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
            beginDownload(issue, model: model, pending: &pending)
        } label: {
            Label(issue.isDownloaded ? "Download again" : "Download",
                  systemImage: "arrow.down.circle")
        }
        .tint(.green)
        .disabled(model.downloading.contains(issue.id))

        Button {
            beginRemoveDownload(issue, model: model, pending: &pending)
        } label: { Label("Remove Download", systemImage: "trash") }
            .disabled(!issue.isDownloaded)

        // Between one and all of them, and wearing the shelf's own filter mark
        // so "visible" reads as "whatever the filters and the search left".
        Button {
            pending = .removeVisibleDownloads(count: model.visibleDownloadedCount,
                                              touchesASet: model.visibleDownloadsTouchASet)
        } label: {
            Label("Remove All Visible Downloads",
                  systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(model.visibleDownloadedCount == 0)

        Button {
            pending = .removeAllDownloads(model.downloadedCount)
        } label: { Label("Remove All Downloads", systemImage: "arrow.down.circle.dotted") }
            .disabled(model.downloadedCount == 0)

        Button {
            model.setRead(!issue.isRead, for: issue)
        } label: {
            Label(issue.isRead ? "Mark as Unread" : "Mark as Read",
                  systemImage: issue.isRead ? "circle" : "checkmark.circle")
        }

        Divider()

        Button(role: .destructive) {
            pending = .remove(issue)
        } label: { Label("Delete", systemImage: "xmark.bin") }

        Button(role: .destructive) {
            pending = .deleteVisible(model.results.count)
        } label: { Label("Delete All Visible Issues", systemImage: "xmark.bin.circle") }
            .disabled(model.results.isEmpty)

        Button(role: .destructive) {
            pending = .deleteAll(model.issueCount)
        } label: { Label("Delete Entire Library", systemImage: "trash.slash") }
    }

    private func confirmation(for action: PendingAction) -> Alert {
        switch action {
        case let .downloadSet(issue, description):
            return Alert(
                title: Text("Download the whole set?"),
                message: Text(description),
                primaryButton: .default(Text("Download")) { model.download(issue, asSet: true) },
                secondaryButton: .cancel())
        case let .removeSet(issue, description):
            return Alert(
                title: Text("Remove the whole set?"),
                message: Text(description),
                primaryButton: .destructive(Text("Remove")) { model.deleteDownload(issue) },
                secondaryButton: .cancel(Text("No")))
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
                message: Text("Remove \(count) downloaded issue\(count == 1 ? "" : "s") "
                              + "from this device. The library keeps every title, "
                              + "so nothing needs importing again."),
                primaryButton: .destructive(Text("Yes")) { model.removeAllDownloads() },
                secondaryButton: .cancel(Text("No")))
        case let .removeVisibleDownloads(count, touchesASet):
            return Alert(
                title: Text(Self.removeVisibleTitle(count)),
                message: Text(Self.removeVisibleMessage(count, touchesASet: touchesASet)),
                primaryButton: .destructive(Text("Yes")) { model.removeVisibleDownloads() },
                secondaryButton: .cancel(Text("No")))
        case .deleteVisible(let count):
            return Alert(
                title: Text(Self.deleteVisibleTitle(count)),
                message: Text(Self.deleteVisibleMessage(count, wholeLibrary: count == model.issueCount)),
                primaryButton: .destructive(Text("Yes")) { model.deleteVisible() },
                secondaryButton: .cancel(Text("No")))
        case .deleteAll(let count):
            return Alert(
                title: Text("Are you sure?"),
                message: Text("Delete all \(count) issues and every download, "
                              + "resetting the app to empty. This cannot "
                              + "be undone."),
                primaryButton: .destructive(Text("Yes")) { model.deleteEverything() },
                secondaryButton: .cancel(Text("No")))
        }
    }

    // The wording for the two bulk actions, built as plain strings rather than
    // inline in the `Alert`: as one concatenated `Text` the type checker gave
    // up on the expression entirely.
    //
    // Static so they can be checked without standing up a view.

    static func removeVisibleTitle(_ count: Int) -> String {
        "Remove \(count) download\(count == 1 ? "" : "s")?"
    }

    static func removeVisibleMessage(_ count: Int, touchesASet: Bool) -> String {
        // Says what is being counted, because it is not the shelf. Most of
        // what is shown is usually not downloaded — 572 issues on screen and
        // one of them on disk — and "the issue shown" read as though the
        // shelf held a single row.
        let subject = count == 1
            ? "One downloaded issue is currently shown."
            : "\(count) downloaded issues are currently shown."
        // The set caveat only when one is actually involved: warning about
        // something that cannot happen here teaches a reader to stop reading
        // these at all.
        let sets: String
        switch (touchesASet, count) {
        case (false, _): sets = ""
        case (true, 1):  sets = " It belongs to a set published as one download, "
                              + "so issues not shown here are removed too."
        default:         sets = " Some belong to sets published as one download, "
                              + "so issues not shown here are removed too."
        }
        return "\(subject) Remove \(count == 1 ? "its" : "their") files from this "
            + "device.\(sets) Every title stays in your library and can be "
            + "downloaded again."
    }

    static func deleteVisibleTitle(_ count: Int) -> String {
        "Delete \(count) issue\(count == 1 ? "" : "s")?"
    }

    static func deleteVisibleMessage(_ count: Int, wholeLibrary: Bool) -> String {
        let issues = count == 1 ? "the issue shown" : "the \(count) issues shown"
        // Worth saying plainly: with no search and no filters the shelf is the
        // whole library, and "delete the ones shown" is then not the narrower
        // thing it sounds like.
        let scope = wholeLibrary ? " That is everything in the library." : ""
        let back = count == 1 ? "it back means importing its page"
                              : "them back means importing their pages"
        return "Delete \(issues) from the library, including any "
            + "downloads.\(scope) Getting \(back) again."
    }

    /// The title, or the code when the post gave none.
    ///
    /// Nil when there is neither, which is the normal case for a magazine
    /// listed only as "Alef - SF magazin 01": the shelf mark already says
    /// "Alef 1", and the placeholder that used to sit here read as though
    /// every issue were actually called "this issue".
    private func name(_ issue: StoredIssue) -> String? {
        issue.title ?? issue.code
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
            }
            // No "downloaded" tick: the cover being in colour already says it,
            // and a second green check would compete with the read badge —
            // two marks meaning different things and looking the same.
        }
        .contentShape(Rectangle())
    }

    private func caption(_ issue: StoredIssue) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let name = name(issue) {
                Text(name)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
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
                        if let name = name(issue) {
                            Text(name).font(.title3.weight(.medium))
                        }
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
                        beginRemoveDownload(issue, model: model, pending: &pending)
                    } else {
                        beginDownload(issue, model: model, pending: &pending)
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
    private static let readGreen = Color(red: 0.24, green: 0.63, blue: 0.29)
    private static let readingYellow = Color(red: 0.95, green: 0.75, blue: 0.10)

    private static let failedRed = Color(red: 0.90, green: 0.16, blue: 0.16)

    private func badged(_ issue: StoredIssue) -> Bool {
        issue.downloadFailed || issue.readState != .unread
    }

    /// A cross for a failed download, a tick for finished, an ellipsis for
    /// part-way.
    ///
    /// Each state gets its own shape as well as its own colour: a tick says
    /// "done" whatever colour it is, so a yellow one on a comic you are
    /// halfway through reads as a contradiction. Shape carries the meaning
    /// and colour reinforces it.
    ///
    /// A failed download wins the corner. It is the only one of the three that
    /// asks the reader to do something, and it is cleared the moment a
    /// download succeeds.
    @ViewBuilder
    private func badge(for issue: StoredIssue) -> some View {
        if issue.downloadFailed {
            Image(systemName: "xmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white, Self.failedRed)
        } else {
            readBadge(for: issue.readState)
        }
    }

    @ViewBuilder
    private func readBadge(for state: ReadState) -> some View {
        switch state {
        case .read:
            Image(systemName: "checkmark.circle.fill")
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white, Self.readGreen)
        case .reading:
            // Drawn rather than `ellipsis.circle.fill`: at a quarter of a
            // thumbnail that symbol's dots shrink to specks, and these need to
            // read across a shelf.
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height)
                ZStack {
                    Circle().fill(Self.readingYellow)
                    HStack(spacing: d * 0.09) {
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(.white).frame(width: d * 0.19, height: d * 0.19)
                        }
                    }
                }
                .frame(width: d, height: d)
            }
            .aspectRatio(1, contentMode: .fit)
        case .unread:
            EmptyView()
        }
    }

    private func cover(_ issue: StoredIssue) -> some View {
        CoverImage(url: issue.coverURL, number: issue.number,
                   grayscale: !issue.isDownloaded,
                   awaitingDownload: !issue.isDownloaded)
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
            // Sized against the cover rather than fixed, so it reads the same
            // on a grid thumbnail and on a list row.
            .overlay(alignment: .bottomTrailing) {
                if badged(issue) {
                    GeometryReader { geo in
                        let side = min(geo.size.width, geo.size.height) * 0.25
                        badge(for: issue)
                            .frame(width: side, height: side)
                            // Sits over the corner, so it reads as a stamp on
                            // the cover rather than part of the artwork.
                            .position(x: geo.size.width - side * 0.45,
                                      y: geo.size.height - side * 0.45)
                            .shadow(radius: 2)
                    }
                }
            }
    }

    /// Anything narrowing the shelf, so the icon reports the whole filter and
    /// not just its first switch.
    private var filtering: Bool {
        model.downloadedOnly || !model.selectedSeries.isEmpty
            || !model.selectedPublishers.isEmpty || !model.selectedHeroes.isEmpty
            || !model.readStates.isEmpty
    }

    /// Whether the shelf is empty because nothing has been downloaded at all.
    ///
    /// Not the same as "the Downloaded filter is on and the shelf is empty",
    /// which is what this used to test. With downloads in the library and a
    /// series filter that none of them fall under, that told the reader to go
    /// and download issues they already had.
    ///
    /// `downloadedCount` is the whole library's, not the shelf's, so it still
    /// answers the question once the filters have emptied what is on screen.
    private var nothingDownloaded: Bool {
        model.downloadedOnly && model.downloadedCount == 0
    }

    /// Three distinct empty cases, because "nothing here" for three different
    /// reasons needs three different next steps.
    private var emptyIcon: String {
        if nothingDownloaded { return "arrow.down.circle" }
        return model.issueCount == 0 ? "books.vertical" : "magnifyingglass"
    }

    private var emptyTitle: String {
        if nothingDownloaded { return "No downloaded issues yet" }
        return model.issueCount == 0 ? "No imported issues yet" : "No match"
    }

    private var emptyDetail: String {
        if nothingDownloaded {
            return "Turn off the Downloaded filter and download some issues!"
        }
        // One sentence for both ways of narrowing the shelf. Quoting the query
        // was only ever right when there was one: a filter with no search text
        // — a series with nothing downloaded in it, say — rendered as
        // “Nothing in your 192 imported issues matches “”.”
        return model.issueCount == 0
            ? "Tap Import, login to StripZona (if needed), browse and like a post "
              + "with the issues you want to read and then import that page."
            : "Nothing in your library matches that search / filter."
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
    /// Whether the comic is still to be fetched, which decides what the
    /// empty frame should say.
    var awaitingDownload = true

    @State private var image: UIImage?

    init(url: String?, number: Int?, grayscale: Bool, awaitingDownload: Bool = true) {
        self.url = url
        self.number = number
        self.grayscale = grayscale
        self.awaitingDownload = awaitingDownload
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

    /// What stands in when there is no artwork.
    ///
    /// An issue number in an empty frame says only what the caption below
    /// already says. Once the comic is here its own first page becomes the
    /// cover, so the frame can say what to do about it instead.
    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            VStack(spacing: 6) {
                if awaitingDownload {
                    Image(systemName: "arrow.down.circle")
                        .font(.title2)
                    Text("Download to\nsee the cover")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                } else {
                    Text(number.map(String.init) ?? "-")
                        .font(.title2.weight(.semibold).monospacedDigit())
                }
            }
            .foregroundStyle(.secondary)
            .padding(6)
            .minimumScaleFactor(0.7)
        }
    }
}

struct IssueDetail: View {
    @ObservedObject var model: AppModel
    let issue: StoredIssue
    let mirrors: [MirrorLink]
    @Binding var pending: PendingAction?
    @Environment(\.dismiss) private var dismiss

    /// The row as it stands now, not as it was when the sheet opened.
    ///
    /// `sheet(item:)` hands over a snapshot and never revisits it, so a
    /// download finishing while this is open would otherwise leave the button
    /// offering to download a comic that is already on disk.
    private var current: StoredIssue {
        model.results.first { $0.id == issue.id } ?? issue
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // The same one-button pair as the shelf row: a comic is
                    // either here or not, so one control covers both.
                    if model.downloading.contains(current.id) {
                        HStack {
                            ProgressView()
                            Text(model.progress[current.id].map {
                                String(format: "downloading… %.0f%%", $0 * 100)
                            } ?? "downloading…")
                            .foregroundStyle(.secondary)
                        }
                    } else {
                        Button {
                            if current.isDownloaded {
                                beginRemoveDownload(current, model: model, pending: &pending)
                            } else {
                                beginDownload(current, model: model, pending: &pending)
                            }
                        } label: {
                            Label(current.isDownloaded ? "Remove Download" : "Download",
                                  systemImage: current.isDownloaded
                                  ? "trash" : "arrow.down.circle")
                        }
                        .tint(current.isDownloaded ? .red : .green)
                    }
                }

                Section("Issue") {
                    LabeledContent("Title", value: issue.title ?? "—")
                    LabeledContent("Hero", value: issue.heroDisplay ?? "—")
                    LabeledContent("Series", value: issue.edition ?? "—")
                    LabeledContent("Publisher/Creator", value: issue.publisher ?? "—")
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

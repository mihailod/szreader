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

/// Deleting one issue, or explaining why this one cannot be deleted.
///
/// A row the app seeded from a catalogue it ships is the one thing on the
/// shelf with no way back: the seed writes its stamp once and skips a library
/// that already carries it, so a deleted seeded row stays deleted for the life
/// of the install, and no import reaches it. Rather than a permanently greyed
/// out Delete button — which says nothing about why — the action is offered
/// and answers.
@MainActor
func beginDelete(_ issue: StoredIssue, model: AppModel, pending: inout PendingAction?) {
    pending = issue.isCatalogued ? .undeletable(issue) : .remove(issue)
}

enum PendingAction: Identifiable {
    case deleteDownload(StoredIssue)
    case remove(StoredIssue)
    /// Delete asked for on an issue that came out of a shipped catalogue.
    case undeletable(StoredIssue)
    case removeAllDownloads(Int)
    /// The library, less what came with the app. Both numbers travel with the
    /// case: the warning has to say how much is going and how much stays.
    case deleteAll(count: Int, shipped: Int)
    /// Everything the shelf is currently showing. The count travels with the
    /// case so the warning can say how much is about to go.
    case removeVisibleDownloads(count: Int, touchesASet: Bool)
    /// Likewise for the shelf as it stands.
    case deleteVisible(count: Int, shipped: Int)
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
        case .undeletable(let i): return "shipped-\(i.id)"
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
    /// Which browser is open, if either.
    @State private var browsing: BrowseTarget?
    @State private var showingSettings = false
    /// Set when Import was tapped with every source switched off, so the
    /// reader is told why rather than shown a browser onto nothing.
    @State private var promptingForSource = false
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
                ReadingSurface(model: model, comicID: open.id, title: open.title)
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
                    .alert(model.failure?.title ?? "", isPresented: Binding(
                        get: { model.failure != nil },
                        set: { if !$0 { model.failure = nil } }
                    )) {
                        Button("OK", role: .cancel) { model.failure = nil }
                    } message: {
                        Text(model.failure?.message ?? "")
                    }
            )
        }
        // Kept off the view that owns .sheet(item:): SwiftUI honours only one
        // presentation modifier per view, and the sheet would win.
        //
        // One cover for both browsers rather than one each, for that same
        // reason: two `fullScreenCover` modifiers on one view means only the
        // last of them ever presents anything.
        .fullScreenCover(item: $browsing) { target in
            switch target {
            case .stripzona:     ImportView { html in try model.importPage(html: html) }
            case .archive:       ArchiveBrowserView(model: model)
            case .comicbookplus: ComicBookPlusBrowserView(model: model)
            case .batcave:       BatCaveBrowserView(model: model)
            }
        }
        .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
        // Importing into a hidden source would land a page of issues nowhere
        // the reader can see them — the shelf would be exactly as empty
        // afterwards, and nothing on screen would say why.
        //
        // Says that in general terms rather than naming one source. This used
        // to offer to switch StripZona back on, from the days when it was the
        // only thing Import could open; with four sources that sentence was
        // simply wrong, and it named the forum at a reader who may have turned
        // it off deliberately and be after something else entirely. Which
        // source to enable is theirs to choose, so this opens the screen where
        // they are all listed rather than choosing for them.
        //
        // On a view of its own, for the reason this file has already had to
        // learn twice: SwiftUI honours one presentation modifier per view, and
        // this line already carries a `.sheet` and a `.fullScreenCover`. An
        // alert added beside them is not a bug you see — it is a button that
        // silently does nothing.
        .background(
            Color.clear
                .alert("No Importable Sources", isPresented: $promptingForSource) {
                    Button("Open Settings") { showingSettings = true }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Import brings content from an importable source and every "
                         + "importable source is turned off. "
                         + "Turn them ON in Settings.")
                }
        )
        // Shown wherever the switch was thrown. The empty shelf carries the
        // same switches, so a reader can enable a source without ever opening
        // Settings — and then needs telling what just arrived.
        .alert(model.sourceNotice?.site.display ?? "", isPresented: Binding(
            get: { model.sourceNotice != nil && !showingSettings },
            set: { if !$0 { model.sourceNotice = nil } }
        )) {
            Button("OK", role: .cancel) { model.sourceNotice = nil }
        } message: {
            Text(model.sourceNotice?.message ?? "")
        }
    }

    // MARK: - Header

    /// One row on iPad, two on a phone.
    ///
    /// The iPad branch is the original row, untouched. A phone cannot hold it:
    /// the picker, the two menus and the Import button alone come to about
    /// 394pt before the search field gets anything, which is wider than the
    /// screen — so the field ended up unusably narrow and Import sat off the
    /// edge. Giving the field a row of its own is the whole fix.
    @ViewBuilder private var header: some View {
        if Device.isPhone {
            VStack(spacing: 10) {
                searchField
                HStack(spacing: 10) { headerControls }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        } else {
            HStack(spacing: 14) {
                searchField
                headerControls
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
    }

    private var searchField: some View {
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
    }

    @ViewBuilder private var headerControls: some View {
            Picker("", selection: $layoutRaw) {
                Image(systemName: "square.grid.2x2").tag(LibraryLayout.grid.rawValue)
                Image(systemName: "list.bullet").tag(LibraryLayout.list.rawValue)
            }
            .pickerStyle(.segmented)
            .frame(width: Device.isPhone ? 96 : 120)

            // Filled icon when the order is not the default, for the same
            // reason the filter fills: a shelf in an unexpected order should
            // say so rather than look wrong.
            Menu {
                // Toggles rather than a `Picker`, for the heading.
                //
                // A menu draws a section header for rows; wrap a `Picker` in
                // that same section and the header is dropped without a word,
                // because the picker becomes its own group. Two builds went by
                // before that was visible. Toggles carry the tick just as a
                // picker's selection does, they match the filter menu beside
                // this one, and the heading survives.
                //
                // Radio semantics: the setter ignores being switched *off*, so
                // tapping the order already in force does nothing rather than
                // leaving the shelf with no order at all.
                Section("Sort by:") {
                    ForEach(ShelfSort.allCases, id: \.self) { order in
                        Toggle(isOn: Binding(
                            get: { model.sortOrder == order },
                            set: { if $0 { model.sortOrder = order } }
                        )) {
                            Label(order.label, systemImage: order.symbol)
                        }
                    }
                }
            } label: {
                Image(systemName: model.sortOrder == .default
                      ? "arrow.up.arrow.down.circle"
                      : "arrow.up.arrow.down.circle.fill")
                    .font(.system(size: 30))
                    .frame(height: 44)
            }
            .menuStyle(.borderlessButton)
            .tint(model.sortOrder == .default ? .secondary : .accentColor)

            // Filled icon when a filter is on, so a narrowed library never
            // looks like a missing one.
            Menu {
                // Monochrome, deliberately. These matched the shelf's green
                // tick and yellow dots for a while, by baking the colour into
                // the symbol and marking it `.alwaysOriginal` — the trick
                // that works for a `UIAction`. Through SwiftUI's `Label` it
                // does not: the menu re-tints them and the result was neither
                // the shelf's colours nor the system's. The shape carries the
                // meaning here, as it does on the shelf; the colour is the
                // part the menu will not give up.
                // Above the heading, in a section of its own, because it is
                // not a thing you filter on — it is the way out of every
                // filter below it.
                //
                // There whether or not anything is on. It used to appear only
                // once a filter was set, which meant the one control that
                // undoes a narrowed shelf was missing from every menu opened
                // to check whether the shelf *was* narrowed. A button that
                // does nothing costs far less than a button nobody can find.
                Section {
                    Button("Show All", systemImage: "xmark.circle") {
                        model.showAll()
                    }
                }

                Section("Filter on:") {
                    Toggle(isOn: $model.downloadedOnly) {
                        Label("Downloaded", systemImage: "arrow.down.circle")
                    }

                    Toggle(isOn: $model.showUnread) {
                        Label("Unread", systemImage: "circle")
                    }
                    Toggle(isOn: $model.showReading) {
                        // The same three dots in a circle the shelf badge
                        // draws, which is what a part-read issue looks like
                        // there. The shelf draws its own because at a quarter
                        // of a thumbnail the symbol's dots shrink to specks;
                        // at menu size the symbol is fine.
                        Label("Reading", systemImage: "ellipsis.circle")
                    }
                    Toggle(isOn: $model.showRead) {
                        Label("Read", systemImage: "checkmark.circle")
                    }
                }

                // Series are built from what has actually been imported, so
                // the menu never offers an edition the library does not hold.
                if !model.availableSeries.isEmpty {
                    // One section per source while both are showing, so the
                    // forum's editions and the nineteen magazine runs are not
                    // one alphabetical list a reader has to already know their
                    // way around. With a single source there is nothing to
                    // tell apart, and a heading naming it would be noise.
                    if model.seriesBySite.count > 1 {
                        ForEach(IssueSite.allCases, id: \.self) { site in
                            if let editions = model.seriesBySite[site], !editions.isEmpty {
                                Section("\(site.display) series") {
                                    seriesToggles(editions)
                                }
                            }
                        }
                    } else {
                        Section("Series") { seriesToggles(model.availableSeries) }
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
                    //
                    // "/Source" since RetroSpec sits in this list too, and it
                    // is neither: it is where the issue came from. Worth
                    // keeping — narrowing to it is a useful filter — so the
                    // heading grew to admit what is actually in the list
                    // rather than the entry being dropped for tidiness.
                    Section("Publisher/Creator/Source") {
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

            } label: {
                Image(systemName: filtering
                      ? "line.3.horizontal.decrease.circle.fill"
                      : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 30))
                    .frame(height: 44)
            }
            .menuStyle(.borderlessButton)
            .tint(filtering ? .accentColor : .secondary)

            // Built from the sources that are actually switched on, and
            // nothing else. Anything showing here opens something.
            //
            // This has been wrong twice in the same place. First it was `if
            // model.showArchive`, which was right while there were two sources
            // and silently wrong the moment a third arrived. Then it listed
            // StripZona unconditionally, so a reader who had switched the
            // forum off was still offered it — the one entry in the menu that
            // led nowhere they had asked to go.
            switch importSources.count {
            case 0:
                // Nothing on. The button still exists, because it is the one
                // control the first screen is built around, and it says so
                // rather than opening a browser onto a source the reader has
                // hidden.
                Button { promptForASource() } label: { importLabel }
                    .buttonStyle(.borderedProminent)
                    .controlSize(Device.isPhone ? .regular : .large)
            case 1:
                // One source is not a choice, so it is not a menu.
                Button { browsing = BrowseTarget(importSources[0]) } label: { importLabel }
                    .buttonStyle(.borderedProminent)
                    .controlSize(Device.isPhone ? .regular : .large)
            default:
                Menu {
                    ForEach(importSources, id: \.self) { site in
                        Button { browsing = BrowseTarget(site) } label: {
                            Label(site.display, systemImage: Self.importIcon(site))
                        }
                    }
                } label: {
                    importLabel
                }
                .buttonStyle(.borderedProminent)
                .controlSize(Device.isPhone ? .regular : .large)
            }
    }

    /// The sources Import can actually open, in menu order.
    ///
    /// Two filters, and both matter. **Switched on**, because an entry for a
    /// hidden source would import a page of issues onto a shelf that will not
    /// show them. **Has something to browse**, which is what leaves RetroSpec
    /// out: it is a source like the others and ships its whole index, so there
    /// is no page to import from and an entry would open a browser onto
    /// nothing.
    ///
    /// StripZona leads when it is here, because it is what the button has
    /// meant since the app had one button.
    private var importSources: [IssueSite] {
        [.stripzona, .archive, .comicbookplus, .batcave].filter(model.isEnabled)
    }

    private static func importIcon(_ site: IssueSite) -> String {
        switch site {
        case .archive:       return "building.columns"
        case .comicbookplus: return "books.vertical"
        case .batcave:       return "globe"
        case .stripzona:     return "text.bubble"
        case .retrospec:     return "tray.full"
        default:             return "desktopcomputer"
        }
    }

    /// The icon goes on a phone. Even on its own row the controls came to
    /// about 420pt against a 6.1" screen's 393, and Import — the one button
    /// the first screen exists for — was what ran off the edge. The word alone
    /// is unambiguous; the icon was decoration.
    @ViewBuilder private var importLabel: some View {
        if Device.isPhone {
            Text("Import")
                .font(.headline).padding(.horizontal, 4).frame(height: 36)
        } else {
            Label("Import", systemImage: "square.and.arrow.down")
                .font(.headline).padding(.horizontal, 6).frame(height: 40)
        }
    }

    /// The series rows themselves, shared by the grouped and ungrouped forms
    /// so the two cannot drift into behaving differently.
    @ViewBuilder private func seriesToggles(_ editions: [String]) -> some View {
        ForEach(editions, id: \.self) { edition in
            Toggle(isOn: Binding(
                get: { model.selectedSeries.contains(edition) },
                set: { _ in model.toggleSeries(edition) }
            )) {
                // Shown in sentence case: the forum shouts its editions, and
                // a menu of LUNOV MAGNUS STRIP reads as an error message.
                Text(TitleCleaner.normaliseCase(edition))
            }
        }
    }

    // MARK: - Actions

    /// What Import does when there is nothing for it to open.
    ///
    /// The button stays on screen rather than being disabled: it is the
    /// control the first screen is built around, and a greyed-out one leaves a
    /// reader who has hidden every source with no route back except a settings
    /// screen they have no reason to open. So it still answers — by saying
    /// what is wrong and offering that screen.
    private func promptForASource() {
        promptingForSource = true
    }

    /// Which browser the Import button opens.
    ///
    /// Identifiable so one `fullScreenCover(item:)` can present either — see
    /// the note on that modifier for why there is only one.
    enum BrowseTarget: String, Identifiable {
        case stripzona, archive, comicbookplus, batcave
        var id: String { rawValue }

        /// The browser a source opens, for the menu that is built by
        /// iterating sources rather than by naming each one.
        ///
        /// RetroSpec and BombJack have no browser and never reach here — see
        /// `importSources` — so they fall back to the forum rather than
        /// making this initialiser optional and every call site handle a nil
        /// that cannot happen.
        init(_ site: IssueSite) {
            switch site {
            case .archive:       self = .archive
            case .comicbookplus: self = .comicbookplus
            case .batcave:       self = .batcave
            // RetroSpec and the BombJack catalogues have no browser and
            // never reach here — see `importSources`.
            default: self = .stripzona
            }
        }
    }

    /// One menu for both layouts — long-pressing cover art behaves identically
    /// in grid and list, so there is only one thing to learn.
    /// One menu for both layouts — long-pressing cover art behaves identically
    /// in grid and list, so there is only one thing to learn.
    ///
    /// Labels are kept short enough to sit on one line. A context menu's width
    /// is UIKit's to decide — there is no API for it in SwiftUI or UIKit — so
    /// a label that does not fit wraps to two lines, and eight wrapped rows
    /// made the menu tall enough to scroll. Each row names its scope only
    /// ("Visible", "All"); the noun is established by the row above it and by
    /// the icon.
    ///
    /// Ordered by consequence: the two that act on this issue, then the two
    /// that only reclaim disk, then — below a divider and marked destructive
    /// so they render red — the three that remove things from the library.
    /// Only the deletes ever cost an import to undo.
    @ViewBuilder private func issueMenu(for issue: StoredIssue) -> some View {
        // One item for both directions, the same as the list row: an issue
        // either is on disk or is not, so the other item could only ever be a
        // greyed-out twin saying what the cover already shows.
        //
        // Green for the only action that adds something. No red here: in this
        // menu red is reserved for the three below the divider, and this one
        // reclaims disk without touching the library.
        Button {
            if issue.isDownloaded {
                beginRemoveDownload(issue, model: model, pending: &pending)
            } else {
                beginDownload(issue, model: model, pending: &pending)
            }
        } label: {
            Label(issue.isDownloaded ? "Remove Download" : "Download",
                  systemImage: issue.isDownloaded ? "trash" : "arrow.down.circle")
        }
        .tint(issue.isDownloaded ? nil : Color.green)
        .disabled(model.downloading.contains(issue.id))

        // Second, because like the item above it this is about the issue in
        // hand rather than the shelf.
        //
        // Blue, matching its button in the list: the tint here colours the
        // icon, so the same action wears the same colour in both views.
        Button {
            model.setRead(!issue.isRead, for: issue)
        } label: {
            Label(issue.isRead ? "Mark as Unread" : "Mark as Read",
                  systemImage: issue.isRead ? "circle" : "checkmark.circle")
        }
        .tint(.accentColor)

        // Between one and all of them, and wearing the shelf's own filter mark
        // so "visible" reads as "whatever the filters and the search left".
        Button {
            pending = .removeVisibleDownloads(count: model.visibleDownloadedCount,
                                              touchesASet: model.visibleDownloadsTouchASet)
        } label: {
            Label("Remove Visible", systemImage: "line.3.horizontal.decrease.circle")
        }
        .disabled(model.visibleDownloadedCount == 0)

        Button {
            pending = .removeAllDownloads(model.downloadedCount)
        } label: { Label("Remove All", systemImage: "arrow.down.circle.dotted") }
            .disabled(model.downloadedCount == 0)

        Divider()

        Button(role: .destructive) {
            beginDelete(issue, model: model, pending: &pending)
        } label: { Label("Delete", systemImage: "xmark.bin") }

        Button(role: .destructive) {
            pending = .deleteVisible(count: model.visibleDeletableCount,
                                     shipped: model.results.count - model.visibleDeletableCount)
        } label: { Label("Delete Visible", systemImage: "xmark.bin.circle") }
            // Nothing to do when the shelf holds only issues that came with
            // the app, which is the usual state of a library nobody has
            // imported into yet.
            .disabled(model.visibleDeletableCount == 0)

        Button(role: .destructive) {
            pending = .deleteAll(count: model.deletableCount, shipped: model.shippedCount)
        } label: { Label("Delete Library", systemImage: "trash.slash") }
            .disabled(model.deletableCount == 0)
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
                message: Text(Self.removeDownloadMessage(name(issue))),
                primaryButton: .destructive(Text("Yes")) { model.deleteDownload(issue) },
                secondaryButton: .cancel(Text("No")))
        case .remove(let issue):
            return Alert(
                title: Text("Are you sure?"),
                message: Text(Self.deleteMessage(name(issue))),
                primaryButton: .destructive(Text("Yes")) { model.delete(issue) },
                secondaryButton: .cancel(Text("No")))
        case .undeletable(let issue):
            // The explanation alone when there is nothing on disk, and the
            // action the reader was probably after when there is: what a
            // delete on a downloaded issue mostly wants back is the space,
            // and that much this row can give.
            guard issue.isDownloaded else {
                return Alert(title: Text("From the app index"),
                             message: Text(Self.undeletableMessage(downloaded: false)),
                             dismissButton: .default(Text("OK")))
            }
            return Alert(
                title: Text("From the app index"),
                message: Text(Self.undeletableMessage(downloaded: true)),
                primaryButton: .destructive(Text("Remove Download")) {
                    // Worked out here and handed over afterwards, so a set
                    // still gets the whole-set warning it would have got from
                    // the button on the shelf.
                    var next: PendingAction?
                    beginRemoveDownload(issue, model: model, pending: &next)
                    handOver(to: next)
                },
                secondaryButton: .cancel(Text("Cancel")))
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
        case let .deleteVisible(count, shipped):
            return Alert(
                title: Text(Self.deleteVisibleTitle(count)),
                message: Text(Self.deleteVisibleMessage(count, shipped: shipped,
                                                        wholeLibrary: count == model.deletableCount)),
                primaryButton: .destructive(Text("Yes")) { model.deleteVisible() },
                secondaryButton: .cancel(Text("No")))
        case let .deleteAll(count, shipped):
            return Alert(
                title: Text("Are you sure?"),
                message: Text(Self.deleteAllMessage(count, shipped: shipped)),
                primaryButton: .destructive(Text("Yes")) { model.deleteEverything() },
                secondaryButton: .cancel(Text("No")))
        }
    }

    /// Raises the next alert once this one has finished going away.
    ///
    /// `.alert(item:)` clears its own binding as part of dismissing, so a case
    /// set from inside a button's action is wiped again before SwiftUI reads
    /// it and the second alert never appears. Waiting out the dismissal is
    /// what makes the two read as one flow.
    private func handOver(to action: PendingAction?) {
        guard let action else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            pending = action
        }
    }

    /// The name goes in only when there is one.
    ///
    /// A magazine listed as "Alef - SF magazin 01" has neither title nor code,
    /// and `name` is nil for it — which read as `Optional("…")` on screen
    /// when it was interpolated straight into the sentence. Unquoted "this
    /// issue" is what a nameless one is called instead: quoting it, as the
    /// old placeholder did, read as though the issue were actually titled
    /// that.
    static func removeDownloadMessage(_ name: String?) -> String {
        let subject = name.map { "the downloaded files for “\($0)”" }
            ?? "the downloaded files for this issue"
        return "Remove \(subject). It stays in your library and can be "
            + "downloaded again."
    }

    static func deleteMessage(_ name: String?) -> String {
        let subject = name.map { "“\($0)”" } ?? "this issue"
        return "Delete \(subject) from the library, including any download. "
            + "Getting it back means importing its page again."
    }

    /// Why Delete refused, and what is still on offer.
    ///
    /// The second half only when there is a download to remove: telling a
    /// reader they may free space they are not using explains nothing.
    static func undeletableMessage(downloaded: Bool) -> String {
        let refusal = "This item's location is shipped in the application's index "
            + "and cannot be deleted since there would be no way to recover it "
            + "(there is no Import for it)."
        guard downloaded else { return refusal }
        return refusal + " You can remove the download for it to free the space "
            + "on your device but you cannot delete the entry."
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

    /// "Item" rather than "issue" through the two delete warnings, and only
    /// them: what a delete acts on is an entry in the library — a row that may
    /// stand for a whole set — and the pair reads as one alert only if its
    /// title and its sentence use one word.
    static func deleteVisibleTitle(_ count: Int) -> String {
        "Delete \(count) item\(count == 1 ? "" : "s")?"
    }

    /// `shipped` is how many of the issues on screen a delete will pass over.
    /// The count has to account for them: a warning that says "the 653 issues
    /// shown" and then deletes four of them is worse than no warning at all.
    ///
    /// What it does not do is explain where those issues came from. The
    /// distinction that matters to a reader is whether an Import can bring a
    /// thing back, and that is all these say.
    static func deleteVisibleMessage(_ count: Int, shipped: Int, wholeLibrary: Bool) -> String {
        let items: String
        if shipped == 0 {
            items = count == 1 ? "the item shown" : "the \(count) items shown"
        } else {
            items = count == 1 ? "the one imported item shown"
                               : "the \(count) imported items shown"
        }
        // Worth saying plainly: with no search and no filters the shelf is the
        // whole library, and "delete the ones shown" is then not the narrower
        // thing it sounds like.
        let scope: String
        switch (wholeLibrary, shipped) {
        case (false, _): scope = ""
        case (true, 0):  scope = " That is everything in the library."
        default:         scope = " That is every imported item in the library."
        }
        // Said only when something is actually being passed over. A caveat
        // about what cannot happen here teaches a reader to stop reading
        // these at all.
        let kept = shipped == 0 ? "" : " Items that cannot be imported again stay."
        let back = count == 1 ? "it back means importing its page"
                              : "them back means importing their pages"
        return "Delete \(items) from the library, including any "
            + "downloads.\(scope)\(kept) Getting \(back) again."
    }

    /// Delete Library, which reaches everything an Import can bring back and
    /// nothing else.
    static func deleteAllMessage(_ count: Int, shipped: Int) -> String {
        guard shipped > 0 else {
            let items = count == 1 ? "the one item" : "all \(count) items"
            return "Delete \(items) and every download, resetting the app to "
                + "empty. This cannot be undone."
        }
        let items = count == 1 ? "the one imported item" : "all \(count) imported items"
        return "Delete \(items) and every download of them. Items that "
            + "cannot be imported again stay. This cannot be undone."
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
                                // A phone's caption column is narrow, and an
                                // unbroken title was being hyphenated down the
                                // middle of a word — "Op-eracija Franke
                                // nstein". Two lines, shrinking before it
                                // wraps, keeps it readable.
                                .lineLimit(Device.isPhone ? 2 : nil)
                                .minimumScaleFactor(Device.isPhone ? 0.8 : 1)
                        }
                    }
                    // Who it is about and what it is from. The mirror count
                    // lived here and told the reader nothing about the comic;
                    // it is in the details, where it belongs.
                    if let provenance = issue.provenance {
                        Text(provenance).font(.subheadline).foregroundStyle(.secondary)
                            .lineLimit(Device.isPhone ? 1 : nil)
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

    /// A row button's label: the word on iPad, the icon alone on a phone.
    ///
    /// Three worded buttons need about 380pt between them. A phone row has
    /// nowhere near that, so SwiftUI squeezed each one until its text wrapped
    /// to a single character per line and the buttons read vertically. The
    /// words are kept for VoiceOver, and every one of these actions is also in
    /// the long-press menu, spelled out.
    @ViewBuilder private func rowLabel(_ title: String, icon: String) -> some View {
        if Device.isPhone {
            Image(systemName: icon)
                .font(.body)
                .frame(minWidth: 24)
                .accessibilityLabel(title)
        } else {
            Text(title)
        }
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
                Button {
                    if issue.isDownloaded {
                        beginRemoveDownload(issue, model: model, pending: &pending)
                    } else {
                        beginDownload(issue, model: model, pending: &pending)
                    }
                } label: {
                    rowLabel(issue.isDownloaded ? "Remove Download" : "Download",
                             icon: issue.isDownloaded ? "trash" : "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .tint(issue.isDownloaded ? .red : .green)
            }
            // Marking something read was buried in the long press, which is
            // not where a reader looks for it — the list is the view where
            // every other action is already a button in front of them.
            //
            // Its own colour: the two either side are about having the files,
            // this one is about having read them. Not the green the read badge
            // uses — sitting next to the green Download button, the two pills
            // read as the same action at a glance.
            if !Device.isPhone {
                Button {
                    model.setRead(!issue.isRead, for: issue)
                } label: {
                    rowLabel(issue.isRead ? "Mark as Unread" : "Mark as Read",
                             icon: issue.isRead ? "circle" : "checkmark.circle")
                }
                .buttonStyle(.bordered)
                .tint(.accentColor)

                Button { beginDelete(issue, model: model, pending: &pending) } label: {
                    rowLabel("Delete", icon: "xmark.bin")
                }
                .buttonStyle(.bordered)
                .tint(.red)
            }
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
    /// Every source is switched off, so the shelf is blank by instruction
    /// rather than because the library is empty. Checked before everything
    /// else: with nothing switched on there is no library to describe.
    private var allSourcesOff: Bool { model.visibleSites.isEmpty }

    private var emptyIcon: String {
        if allSourcesOff { return "eye.slash" }
        if nothingDownloaded { return "arrow.down.circle" }
        return model.issueCount == 0 ? "books.vertical" : "magnifyingglass"
    }

    private var emptyTitle: String {
        if allSourcesOff { return "Nothing switched on" }
        if nothingDownloaded { return "No downloaded issues yet" }
        return model.issueCount == 0 ? "Your library is empty" : "No match"
    }

    private var emptyDetail: String {
        if allSourcesOff {
            return "Every source is switched off. Switch them on in "
                 + "Settings."
        }
        if nothingDownloaded {
            return "Turn off the Downloaded filter and download some issues!"
        }
        // One sentence for both ways of narrowing the shelf. Quoting the query
        // was only ever right when there was one: a filter with no search text
        // — a series with nothing downloaded in it, say — rendered as
        // “Nothing in your 192 imported issues matches “”.”
        // "Issues" throughout: most of the sources are not comics.
        return model.issueCount == 0 ? firstRunInvitation
                                     : "Nothing in your library matches that search / filter."
    }

    /// What a brand-new shelf says.
    ///
    /// Every source named, because this is the one screen that says the app
    /// has more than one library in it, and the switches are right below.
    ///
    /// Assembled from `SourceCopy` rather than written out. Spelled out, this
    /// sentence named three sources and went stale the moment a fourth
    /// arrived — a reader on a fresh install was told about RetroSpec and
    /// Archive.org and never about the source sitting in the list under it.
    private var firstRunInvitation: String {
        // Each phrase once. The seven BombJack catalogues share one — they are
        // one archive split by category — and listing them separately repeated
        // the same nine words seven times over.
        var phrases: [String] = []
        for site in IssueSite.allCases {
            let phrase = SourceCopy.of(site).shelfPhrase
            if !phrases.contains(phrase) { phrases.append(phrase) }
        }
        guard let last = phrases.last, phrases.count > 1 else {
            return "Nothing here yet. Open Settings to switch on a source."
        }
        let leading = phrases.dropLast().joined(separator: ", ")
        // "In Settings", not "below": the switches used to sit under this
        // sentence and now do not — there are eleven of them and they did not
        // fit on a screen that cannot scroll.
        return "Nothing here yet. In Settings you can switch on \(leading) "
             + "or \(last) — then Import to bring issues in."
    }

    /// Type sizes for the empty screen.
    ///
    /// The iPad keeps the numbers it shipped with, untouched. A phone gets
    /// smaller ones: at 44pt "Nothing switched on" does not fit a 428pt screen
    /// and was being clipped mid-word, and the sentence under it fared no
    /// better. Wrapping alone was not enough — three lines of 44pt type is a
    /// wall — so the size comes down as well.
    private static var emptyTitleSize: CGFloat { Device.isPhone ? 32 : 44 }
    private static var emptyDetailSize: CGFloat { Device.isPhone ? 19 : 26 }
    /// The icon shrinks with them, or it dominates a screen whose text has
    /// just got smaller.
    private static var emptyIconSize: CGFloat { Device.isPhone ? 72 : 96 }

    /// Whether the empty screen should offer the way to Settings.
    ///
    /// Only where it is the way out. A reader whose search matched nothing
    /// does not need to be offered another library — they need to clear the
    /// search — and a Settings button under every empty shelf would read as
    /// part of the search UI.
    private var offersSourceSwitches: Bool {
        allSourcesOff || (model.issueCount == 0 && !nothingDownloaded)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: emptyIcon)
                .font(.system(size: Self.emptyIconSize)).foregroundStyle(.tertiary)
            Text(emptyTitle)
                .font(.system(size: Self.emptyTitleSize, weight: .bold))
                .multilineTextAlignment(.center)
                // Both of these, and both are needed. Without `fixedSize` the
                // stack hands the text one line's height and it truncates
                // rather than wrapping — "Nothing switched on" rendered as
                // "Nothing switch…" — and without the scale factor a long
                // word still has nowhere to go on the narrowest phone.
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.6)
            Text(emptyDetail)
                .font(.system(size: Self.emptyDetailSize, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .minimumScaleFactor(0.7)
                .frame(maxWidth: 760)
            // The switches, on the one screen where a reader has no other way
            // to find them. Settings is a gear in the corner of a shelf that
            // is currently blank, which is a poor place to discover that the
            // app has a second library in it at all.
            if offersSourceSwitches { openSettingsButton }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// The way in to the sources, on the one screen with no other route to
    /// them.
    ///
    /// This was the switches themselves, inline, and that was right while
    /// there were three of them: Settings is a gear in the corner of a blank
    /// shelf, which is a poor place to discover that the app has other
    /// libraries in it at all.
    ///
    /// It stopped being right at eleven. The screen does not scroll, so the
    /// last two switches sat below the bottom of the display with no way to
    /// reach them — the one screen whose whole job is to offer a way out, and
    /// half the exits were off-screen. A button costs one row and leads
    /// somewhere that can hold them all.
    private var openSettingsButton: some View {
        Button { showingSettings = true } label: {
            Label("Open Settings", systemImage: "gearshape")
                .font(.system(size: Device.isPhone ? 17 : 20, weight: .semibold))
                .padding(.horizontal, 8)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .padding(.top, 4)
    }

    private var summaryLine: String {
        // A phone cannot hold the sentence. Spelled out it is wider than the
        // screen even shrunken, which truncated it *and* stretched the bar it
        // sits in until the settings button was pushed off the left edge.
        if Device.isPhone {
            return "\(model.results.count)/\(model.issueCount) · "
                + "\(model.downloadedCount) ↓ \(Self.gb(model.diskUsage))"
        }
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

    /// The counts stay centred in the bar, so the button is laid over the
    /// left of it rather than placed in the same row — a row would push the
    /// summary off-centre by exactly the button's width.
    private var statusBar: some View {
        ZStack {
            summary
            HStack {
                Button { showingSettings = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 27))
                        // A 27pt glyph is not a 44pt target; the frame is what
                        // makes the corner tappable.
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .foregroundStyle(.secondary)
                .accessibilityLabel("Settings")
                Spacer()
            }
            .padding(.leading, 12)
        }
        .frame(height: 64)
        .background(.bar)
    }

    private var summary: some View {
        HStack(spacing: 14) {
            // Three segments never fit a phone. A status message is the news —
            // it says what just happened — so while there is one it has the
            // bar to itself, and the standing counts come back when it clears.
            if Device.isPhone {
                if model.status.isEmpty {
                    Text(summaryLine)
                    if model.freeSpace > 0 {
                        Text("·")
                        Text(freeText)
                            .foregroundStyle(lowOnSpace ? Color.red : Color.secondary)
                    }
                } else {
                    Text(model.status)
                }
            } else {
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
        }
        .font(.system(size: Device.isPhone ? 15 : 25, weight: .semibold))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        // Clear of the settings button at either end, so a long status line
        // shrinks rather than running underneath it.
        .padding(.horizontal, Device.isPhone ? 60 : 64)
        // Held to the width it was given. Without this the line's own ideal
        // width — one unbroken sentence — sizes the bar around it, and on a
        // phone that pushed the settings button off the screen. Phone only:
        // the iPad's bar is already right, and this is the one modifier here
        // that would change it.
        .frame(maxWidth: .infinity)
        .modifier(ClampWidth(active: Device.isPhone))
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
    /// Set once asking for the cover has come back empty, which is what tells
    /// "still arriving" apart from "not coming".
    @State private var fetchFailed = false

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
                // Filled, except when the artwork is wider than it is tall.
                //
                // Every cover was portrait until the RetroSpec catalogue
                // arrived, and three of its books are scanned landscape — the
                // "Uvod u rad i programiranje" manuals. Filling a portrait
                // frame with a landscape scan crops it to a magnified strip
                // out of the middle, which is not a cover. Fitting instead
                // caps it on width and leaves a bar above and below, which is
                // the honest shape of the thing.
                //
                // Conditional rather than fitting everything: a portrait cover
                // very slightly off 2:3 would gain hairline bars, and the
                // iPad shelf as shipped is full-bleed.
                if image.size.width > image.size.height {
                    // The frame is what it should fill. Fitting alone sizes
                    // the image from its own ideal dimensions, which left
                    // these sitting at about a third of the cell with the
                    // caption stretching well past them; claiming the frame
                    // first makes "fit" mean fit *this*, so the scan spans
                    // the full width and the bars fall above and below.
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                }
            } else {
                placeholder
            }
        }
        .background(Color(.tertiarySystemFill))
        // Keyed on the variant, so finishing a download re-runs this and the
        // cover turns colour immediately. It must NOT bail on a non-nil image:
        // that is exactly the case where a grey one is already showing.
        .task(id: (url ?? "") + (grayscale ? "#gray" : "")) {
            // Cleared per cover, not once: this view is recycled down a
            // scrolling grid, and a failure carried over from the tile that
            // used it last would label a perfectly good cover as missing.
            fetchFailed = false
            if let hit = CoverStore.shared.cached(url, grayscale: grayscale) {
                image = hit          // both variants are cached, so this is instant
                return
            }
            let fetched = await CoverStore.shared.image(url, grayscale: grayscale)
            image = fetched
            fetchFailed = fetched == nil
        }
    }

    /// What stands in when there is no artwork.
    ///
    /// An issue number in an empty frame says only what the caption below
    /// already says. Once the comic is here its own first page becomes the
    /// cover, so the frame can say what to do about it instead.
    /// Whether artwork is on its way.
    ///
    /// True from the moment a cover with a URL is asked for until it either
    /// arrives or fails. There is nothing to wait for when the issue has no
    /// cover reference at all — that artwork does not exist yet and will not
    /// until the archive is here and its first page becomes the cover.
    private var fetching: Bool { url != nil && !fetchFailed }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            VStack(spacing: 6) {
                if fetching {
                    // A cover that is merely late is not a cover that is
                    // missing. Six hundred RetroSpec covers come off a web
                    // server one at a time, and telling a reader to download
                    // the issue to see artwork that is already on its way
                    // sends them to do work they do not need to do.
                    Image(systemName: "ellipsis.circle")
                        .font(.title2)
                    Text("Fetching\nthe cover")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                } else if awaitingDownload {
                    // Nothing to fetch: either the issue carries no cover
                    // reference, or asking for it failed. Both are answered
                    // the same way, because in both the artwork only appears
                    // once the archive is here and its first page stands in.
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
    @State private var showingCover = false

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
                        // Two of equal width rather than one wide one. Both
                        // are bordered: in a `List` row the plain style makes
                        // the whole row one tap target, so side-by-side plain
                        // buttons would fire whichever they liked.
                        HStack(spacing: 12) {
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
                                .frame(maxWidth: .infinity)
                            }
                            .tint(current.isDownloaded ? .red : .green)

                            Button {
                                showingCover = true
                            } label: {
                                Label("Show Cover", systemImage: "photo")
                                    .frame(maxWidth: .infinity)
                            }
                            // Nothing to open until there is artwork. A
                            // downloaded issue always has some, because its
                            // own first page is right there.
                            .disabled(current.coverURL == nil && !current.isDownloaded)
                        }
                        .buttonStyle(.bordered)
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
                // Between the issue and where its file comes from, because
                // that is the order the two answer in: what this is, then
                // whose archive it came out of, then the address it is
                // fetched from.
                //
                // Worth a section of its own now there are ten sources. The
                // shelf shows the source only as a publisher — and for the
                // BombJack catalogues that column reads "BombJack: Books",
                // which says the archive but not that the row was seeded
                // rather than imported.
                Section("Source") {
                    LabeledContent("Archive", value: issue.site.display)
                    // The source's own name for it: a StripZona code, an
                    // archive.org identifier, a Comic Book Plus `dlid`, or the
                    // path bombjack keeps the file under. It is what a reader
                    // would search for on the source's own site, and it is the
                    // key this app files the issue under.
                    if let code = issue.code, !code.isEmpty {
                        LabeledContent("Reference") {
                            Text(code)
                                .font(.body.monospaced())
                                .multilineTextAlignment(.trailing)
                        }
                    }
                    // The row's own stamp, not its site: archive.org is both
                    // a shipped index and a source the reader browses, and
                    // only the rows the seed wrote came with the app.
                    LabeledContent("Arrived by",
                                   value: issue.isCatalogued ? "Shipped index" : "Imported")
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
        .fullScreenCover(isPresented: $showingCover) {
            CoverViewer(url: current.coverURL,
                        title: current.title ?? current.code ?? "Issue",
                        fullPage: current.isDownloaded
                        ? { [id = current.id] in await model.firstPage(forIssue: id) }
                        : nil)
        }
    }
}

extension StoredIssue: Identifiable {}

/// Stops a view's own ideal width from sizing its parent.
private struct ClampWidth: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.fixedSize(horizontal: false, vertical: true) }
        else { content }
    }
}

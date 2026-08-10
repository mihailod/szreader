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
        }
        // Kept off the view that owns .sheet(item:): SwiftUI honours only one
        // presentation modifier per view, and the sheet would win.
        .fullScreenCover(isPresented: $showingImport) {
            ImportView { html in model.importPage(html: html) }
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
    @ViewBuilder private func issueMenu(for issue: StoredIssue) -> some View {
        Button {
            model.download(issue)
        } label: {
            Label(issue.isDownloaded ? "Download again" : "Download",
                  systemImage: "arrow.down.circle")
        }
        .disabled(model.downloading.contains(issue.id))

        // Naming deliberately parallel to the bulk actions below: "Remove"
        // always means the files, "Delete" always means the library entry.
        // The earlier Delete/Remove pair meant the opposite in singular and
        // plural, which is a bad way to lose a catalogue.
        Button(role: .destructive) {
            pending = .deleteDownload(issue)
        } label: { Label("Remove Download", systemImage: "trash") }
            .disabled(!issue.isDownloaded)

        Button(role: .destructive) {
            pending = .remove(issue)
        } label: { Label("Delete From Library", systemImage: "xmark.bin") }

        Divider()

        Button(role: .destructive) {
            pending = .removeAllDownloads(model.downloadedCount)
        } label: { Label("Remove All Downloads", systemImage: "arrow.down.circle.dotted") }
            .disabled(model.downloadedCount == 0)

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
                        Button { selected = issue } label: { gridCell(issue) }
                            .buttonStyle(.plain)
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

    private func gridCell(_ issue: StoredIssue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                cover(issue)
                    .aspectRatio(2.0 / 3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
                if model.downloading.contains(issue.id) {
                    ProgressView().padding(8)
                } else if issue.isDownloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.white, .green)
                        .padding(6)
                }
            }
            Text(name(issue))
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let number = issue.number {
                Text("#\(number)").font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ issue: StoredIssue) -> some View {
        HStack(spacing: 16) {
            // Long-pressing the artwork gives the same menu as the grid.
            cover(issue)
                .frame(width: 58, height: 82)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .contextMenu { issueMenu(for: issue) }

            Button { selected = issue } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(name(issue)).font(.title3.weight(.medium))
                    HStack(spacing: 8) {
                        if let series = issue.series {
                            Text(series).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("\(issue.mirrorCount) mirror\(issue.mirrorCount == 1 ? "" : "s")")
                            .font(.subheadline).foregroundStyle(.secondary)
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
                Button(issue.isDownloaded ? "Re-download" : "Download") {
                    model.download(issue)
                }
                .buttonStyle(.bordered)
            }
            Button("Remove Download") { pending = .deleteDownload(issue) }
                .buttonStyle(.bordered)
                .tint(.red)
                // Nothing to remove until the archive is actually on disk.
                .disabled(!issue.isDownloaded)
            Button("Delete From Library") { pending = .remove(issue) }
                .buttonStyle(.bordered)
                .tint(.red)
        }
        .buttonBorderShape(.capsule)
        .controlSize(.regular)
    }

    /// Cover art, desaturated until the comic is actually downloaded — the
    /// quickest way to see what you have versus what is only catalogued.
    private func cover(_ issue: StoredIssue) -> some View {
        CoverImage(url: issue.coverURL, number: issue.number)
            .saturation(issue.isDownloaded ? 1 : 0)
            .opacity(issue.isDownloaded ? 1 : 0.55)
    }

    private var emptyState: some View {
        VStack(spacing: 22) {
            Image(systemName: model.issueCount == 0 ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 96)).foregroundStyle(.tertiary)
            Text(model.issueCount == 0 ? "No comics yet" : "No match")
                .font(.system(size: 44, weight: .bold))
            Text(model.issueCount == 0
                 ? "Tap Import, browse StripZona, like a post, then import that page"
                 : "Nothing in your \(model.issueCount) imported issues matches “\(model.query)”.")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 760)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var statusBar: some View {
        HStack {
            Text("\(model.results.count) shown · \(model.issueCount) imported")
            Spacer()
            Text(model.status)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Cover art, hotlinked from stripovi.com the same way the forum does it.
/// Falls back to the issue number: an empty tile is worse than a plain one.
private struct CoverImage: View {
    let url: String?
    let number: Int?

    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { phase in
            switch phase {
            case .success(let image): image.resizable().aspectRatio(contentMode: .fill)
            case .failure, .empty: placeholder
            @unknown default: placeholder
            }
        }
        .background(Color(.tertiarySystemFill))
    }

    private var placeholder: some View {
        ZStack {
            Color(.tertiarySystemFill)
            Text(number.map(String.init) ?? "—")
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
                    LabeledContent("Code", value: issue.code ?? "—")
                    LabeledContent("Number", value: issue.number.map(String.init) ?? "—")
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

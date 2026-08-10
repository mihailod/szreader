import SwiftUI
import SZKit

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var selected: StoredIssue?
    @State private var showingSample = false

    var body: some View {
        NavigationStack {
            Group {
                if model.results.isEmpty {
                    // An empty library and a search that found nothing look
                    // identical on screen, and both look like a bug. Say which.
                    emptyState
                } else {
                    List(model.results, id: \.id) { issue in
                        Button { selected = issue } label: { row(issue) }
                            .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .searchable(text: Binding(get: { model.query },
                                      set: { model.search($0) }),
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search by title")
            .navigationTitle("StripZona")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sample comic") { showingSample = true }
                }
                ToolbarItem(placement: .bottomBar) {
                    Text("\(model.results.count) shown · \(model.issueCount) in library · \(model.status)")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .sheet(item: $selected) { issue in
                IssueDetail(issue: issue, mirrors: model.mirrors(for: issue))
            }
            .fullScreenCover(isPresented: $showingSample) {
                ReaderView(document: SampleComic.document(), title: "Sample comic")
            }
        }
    }

    /// Distinguishes "nothing imported yet" from "no match for this query".
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: model.issueCount == 0 ? "books.vertical" : "magnifyingglass")
                .font(.system(size: 52))
                .foregroundStyle(.tertiary)
            Text(model.issueCount == 0 ? "No comics yet" : "No match")
                .font(.title3.weight(.semibold))
            Text(model.issueCount == 0
                 ? "Import a topic page to fill the library."
                 : "Nothing in \(model.issueCount) issues matches “\(model.query)”.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(model.status)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ issue: StoredIssue) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 6).fill(.tertiary)
                Text(issue.number.map(String.init) ?? "—")
                    .font(.headline.monospacedDigit())
            }
            .frame(width: 52, height: 70)

            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title ?? issue.code ?? "untitled")
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    if let series = issue.series {
                        Text(series).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(issue.style.rawValue)
                        .font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text("\(issue.mirrorCount) mirror\(issue.mirrorCount == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
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
                Section {
                    Text("Downloading is wired up in SZKit but not triggered from this "
                         + "build — mirror resolution and unpacking are covered by tests.")
                        .font(.footnote).foregroundStyle(.secondary)
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

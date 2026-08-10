import SwiftUI
import SZKit

struct LibraryView: View {
    @ObservedObject var model: AppModel
    @State private var selected: StoredIssue?
    @State private var showingSample = false

    var body: some View {
        NavigationStack {
            List(model.results, id: \.id) { issue in
                Button { selected = issue } label: { row(issue) }
                    .buttonStyle(.plain)
            }
            .listStyle(.plain)
            .searchable(text: Binding(get: { model.query },
                                      set: { model.search($0) }),
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search comics — try “celjusti” or “kuca”")
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

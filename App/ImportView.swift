import SwiftUI
import SZKit

/// Browse stripzona, like the posts you want, tap Import.
///
/// Deliberately manual. The app does not store credentials, does not log in for
/// you, and never clicks Like on your behalf — likes are public actions on a
/// hand-approved account, and there is a daily quota. You do the browsing; the
/// app just reads the page you are already looking at.
struct ImportView: View {

    let onImport: (String) throws -> ImportReport
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserModel()

    @State private var report: ImportReport?
    @State private var errorText: String?
    @State private var importing = false

    // The forum path directly: the bare root 302s to plain http, and every
    // cleartext hop would expose a session cookie that is not marked Secure.
    private static let home = "https://www.stripzona.com/port/index.php"

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if browser.isLoading {
                    ProgressView(value: browser.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                }
                BrowserView(model: browser)
                banner
            }
            .navigationTitle(browser.title.isEmpty ? "Import" : browser.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) {
                // Shows the live URL and its scheme. If a login bounces, this
                // is what tells you where it actually landed.
                HStack(spacing: 8) {
                    Image(systemName: browser.url?.scheme == "https"
                          ? "lock.fill" : "lock.open.fill")
                        .font(.caption2)
                        .foregroundStyle(browser.url?.scheme == "https" ? .green : .orange)
                    Text(browser.url?.absoluteString ?? "—")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(.bar)
            }
            .toolbar {
                ToolbarItemGroup(placement: .topBarLeading) {
                    Button { browser.webView.goBack() } label: {
                        Image(systemName: "chevron.backward")
                    }.disabled(!browser.canGoBack)
                    Button { browser.webView.goForward() } label: {
                        Image(systemName: "chevron.forward")
                    }.disabled(!browser.canGoForward)
                    Button { browser.webView.reload() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Done sits to the LEFT of Import so that Import keeps the
                    // top-right corner it occupies on the shelf. It said
                    // "Import this page" here and "Import" there, in a
                    // different place and a different style — three differences
                    // that made the one button you came in to press look like a
                    // new one you had not seen before.
                    Button("Done") { dismiss() }

                    Button {
                        Task { await performImport() }
                    } label: {
                        if importing {
                            ProgressView()
                        } else {
                            // Spelled out as an explicit stack: a toolbar
                            // collapses a Label to its icon regardless of
                            // labelStyle, and the word "Import" is what makes
                            // this recognisably the same button as on the
                            // shelf.
                            HStack(spacing: 6) {
                                Image(systemName: "square.and.arrow.down")
                                Text("Import")
                            }
                            .font(.headline)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importing || browser.isLoading)
                }
            }
            .onAppear { if browser.url == nil { browser.load(Self.home) } }
        }
    }

    @ViewBuilder private var banner: some View {
        if let errorText {
            bannerBody(icon: "exclamationmark.triangle.fill",
                       tint: .orange, title: "Import failed", detail: errorText)
        } else if let report {
            bannerBody(
                icon: report.isEmpty ? "questionmark.circle.fill" : "checkmark.circle.fill",
                tint: report.isEmpty ? .orange : .green,
                title: report.isEmpty
                    ? "Nothing new imported"
                    : "Imported \(report.issues) issue\(report.issues == 1 ? "" : "s"), \(report.mirrors) mirror\(report.mirrors == 1 ? "" : "s")",
                detail: report.advice
                    ?? "\(report.attributed) of \(report.links) links matched an issue.")
        }
    }

    private func bannerBody(icon: String, tint: Color,
                            title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                report = nil; errorText = nil
            } label: { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial)
    }

    private func performImport() async {
        importing = true
        defer { importing = false }
        report = nil
        errorText = nil

        guard let html = await browser.currentHTML() else {
            errorText = "Could not read the page."
            return
        }
        do {
            report = try onImport(html)
        } catch {
            // The real reason, not a guess at it. This used to report "the
            // library could not be written to" for every failure, which sent
            // an entire debugging session after a database problem that was
            // never there.
            errorText = SZKit.Library.reason(error)
        }
    }
}

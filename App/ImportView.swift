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
    @StateObject private var browser = BrowserModel(fence: .stripzona, desktopSite: true)

    @State private var report: ImportReport?
    @State private var errorText: String?
    @State private var importing = false

    /// What the popup says, when there is a popup — an import that brought
    /// nothing in, whether because the page had nothing new on it or because
    /// the import failed outright.
    ///
    /// It says exactly what the banner below already says. The banner on its
    /// own was being missed: a line of small text at the edge of a browser is
    /// not where someone who has just tapped Import is looking, and both of
    /// these outcomes leave a question that the shelf will not answer. So they
    /// have to be dismissed before carrying on. A successful import needs no
    /// popup — the issues are on the shelf — and keeps the quiet banner.
    @State private var notice: Notice?

    private struct Notice {
        let title: String
        let message: String
    }

    /// The two titles the banner and the popup share, so the same outcome
    /// cannot end up named two different things.
    private static let failureTitle = "Import failed"
    private static let emptyTitle = "Nothing new imported"

    // The forum path directly: the bare root 302s to plain http, and every
    // cleartext hop would expose a session cookie that is not marked Secure.
    private static let home = "https://www.stripzona.com/port/index.php"

    var body: some View {
        BrowserScreen(model: browser, fallbackTitle: "Import") {
            Button {
                Task { await performImport() }
            } label: {
                if importing {
                    ProgressView()
                } else {
                    // Spelled out as an explicit stack: a toolbar collapses a
                    // Label to its icon regardless of labelStyle, and the word
                    // "Import" is what makes this recognisably the same button
                    // as on the shelf.
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                        Text("Import")
                    }
                    .font(.headline)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(importing || browser.isLoading)
        } banner: {
            banner
        }
        .onAppear { if browser.url == nil { browser.load(Self.home) } }
        // Presented with the notice rather than reading the state back, so the
        // message stays put through the dismiss animation instead of blanking
        // as the popup goes.
        .alert(notice?.title ?? "", isPresented: Binding(
            get: { notice != nil },
            set: { if !$0 { notice = nil } }
        ), presenting: notice) { _ in
            Button("OK", role: .cancel) { }
        } message: { notice in
            Text(notice.message)
        }
    }

    @ViewBuilder private var banner: some View {
        if let errorText {
            BrowserBanner(icon: "exclamationmark.triangle.fill", tint: .orange,
                          title: Self.failureTitle, detail: errorText,
                          dismiss: clearBanner)
        } else if let report {
            BrowserBanner(
                icon: report.isEmpty ? "questionmark.circle.fill" : "checkmark.circle.fill",
                tint: report.isEmpty ? .orange : .green,
                title: report.isEmpty
                    ? Self.emptyTitle
                    : "Imported \(report.issues) issue\(report.issues == 1 ? "" : "s"), \(report.mirrors) mirror\(report.mirrors == 1 ? "" : "s")",
                detail: Self.detail(report),
                dismiss: clearBanner)
        }
    }

    /// The line under the banner's title, and the whole of the popup's
    /// message: one place, so the two can never come to say different things.
    private static func detail(_ report: ImportReport) -> String {
        report.advice ?? "\(report.attributed) of \(report.links) links matched an issue."
    }

    private func clearBanner() {
        report = nil
        errorText = nil
    }

    private func performImport() async {
        importing = true
        defer { importing = false }
        report = nil
        errorText = nil
        notice = nil

        guard let html = await browser.currentHTML() else {
            fail("Could not read the page.")
            return
        }
        do {
            let outcome = try onImport(html)
            report = outcome
            // A page that brought issues in does not interrupt: the shelf
            // behind this browser is the receipt.
            if outcome.isEmpty {
                notice = Notice(title: Self.emptyTitle, message: Self.detail(outcome))
            }
        } catch {
            // The real reason, not a guess at it. This used to report "the
            // library could not be written to" for every failure, which sent
            // an entire debugging session after a database problem that was
            // never there.
            fail(SZKit.Library.reason(error))
        }
    }

    /// Both halves of a failed import: the banner keeps the record on screen,
    /// the popup makes sure it was read.
    private func fail(_ reason: String) {
        errorText = reason
        notice = Notice(title: Self.failureTitle, message: reason)
    }
}

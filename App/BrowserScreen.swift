import SwiftUI
import SZKit

/// The chrome around an in-app browser: what is the same whichever site it is
/// pointed at.
///
/// Two screens import from a browser now — a forum topic and an archive.org
/// item — and the parts that make them recognisably one app are the parts a
/// second copy would have quietly let drift: the read-only address line, the
/// progress bar, Done sitting to the left of the one button the screen exists
/// for, and Back on every device with Forward and Reload only where there is
/// room for them.
///
/// The caller supplies two things: the button in the top right, and a banner
/// under the page for whatever it has to say afterwards.
struct BrowserScreen<Action: View, Banner: View>: View {

    @ObservedObject var model: BrowserModel
    /// Shown until the page states a title of its own.
    let fallbackTitle: String

    @Environment(\.dismiss) private var dismiss

    private let action: Action
    private let banner: Banner

    init(model: BrowserModel, fallbackTitle: String,
         @ViewBuilder action: () -> Action,
         @ViewBuilder banner: () -> Banner) {
        self.model = model
        self.fallbackTitle = fallbackTitle
        self.action = action()
        self.banner = banner()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if model.isLoading {
                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                }
                BrowserView(model: model)
                // The fence's own message, above whatever the importer has to
                // say: it explains a tap that just did nothing, and that needs
                // answering before anything else on screen.
                if let refused = model.refused {
                    BrowserBanner(
                        icon: "hand.raised.fill", tint: .orange,
                        title: "This browser stays on \(model.fence.name)",
                        detail: "That link goes to \(refused), so it was not followed.",
                        dismiss: { model.refused = nil })
                }
                banner
            }
            .navigationTitle(model.title.isEmpty ? fallbackTitle : model.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .top, spacing: 0) { addressLine }
            .toolbar {
                // Five items do not fit a phone's navigation bar: it folds
                // the overflow into a "…" menu, and Import — the last one, and
                // the only reason to be here — was what disappeared into it.
                // The web view keeps its edge-swipe back and forward either
                // way, so on a phone these three cost little.
                ToolbarItemGroup(placement: .topBarLeading) {
                    // Back on every device: on a phone it is the one you
                    // actually need, since neither site gives you a way back
                    // to where you came from.
                    Button { model.webView.goBack() } label: {
                        Image(systemName: "chevron.backward")
                    }.disabled(!model.canGoBack)
                    if !Device.isPhone {
                        Button { model.webView.goForward() } label: {
                            Image(systemName: "chevron.forward")
                        }.disabled(!model.canGoForward)
                        Button { model.webView.reload() } label: {
                            Image(systemName: "arrow.clockwise")
                        }
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
                    action
                }
            }
        }
    }

    /// The live URL and its scheme.
    ///
    /// Shown, never edited. There is no field here and there is not going to
    /// be one: an address bar is what would turn a fenced view of one site
    /// into a general-purpose web browser. As a readout it earns its place —
    /// if a login bounces, this is what says where it actually landed.
    private var addressLine: some View {
        HStack(spacing: 8) {
            Image(systemName: model.url?.scheme == "https"
                  ? "lock.fill" : "lock.open.fill")
                .font(.caption2)
                .foregroundStyle(model.url?.scheme == "https" ? .green : .orange)
            Text(model.url?.absoluteString ?? "—")
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.disabled)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

/// One line of news under the page.
///
/// Shared so that a refusal, a failed import and a successful one are the same
/// object in three colours rather than three things that look nearly alike.
struct BrowserBanner: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: dismiss) { Image(systemName: "xmark.circle.fill") }
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(.thinMaterial)
    }
}

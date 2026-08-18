import SwiftUI
import SZKit
import WebKit

/// Holds the web view and its navigation state.
///
/// The session lives entirely in WebKit's persistent data store — the app never
/// sees, stores, or replays a password. You log in once in a real login form
/// and the cookie survives relaunches, which is also why nothing here needs the
/// Keychain.
@MainActor
final class BrowserModel: NSObject, ObservableObject {

    @Published var url: URL?
    @Published var title = ""
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var progress: Double = 0
    /// The host a link tried to reach and was not allowed to.
    ///
    /// A cancelled navigation leaves the page exactly as it was, so without
    /// this a tap on an outward link is a tap that does nothing — which reads
    /// as a broken app rather than as a rule. Cleared by going somewhere, or
    /// by dismissing it; deliberately not on a timer, because the message
    /// explains a screen that has not changed and there is nothing to say when
    /// it has gone.
    @Published var refused: String?

    /// Where this browser may go. See `HostFence`.
    let fence: HostFence

    let webView: WKWebView

    private var observers: [NSKeyValueObservation] = []

    /// - Parameter desktopSite: ask for the desktop layout, the way Safari's
    ///   "Request Desktop Website" does. True for a site whose markup the app
    ///   has to read, false for one it only shows.
    init(fence: HostFence, desktopSite: Bool) {
        self.fence = fence
        let config = WKWebViewConfiguration()
        // .default() is the persistent store: the login cookie outlives launches.
        config.websiteDataStore = .default()
        // StripZona serves a different forum entirely to phones — different
        // markup, different link shapes — and the import reads the page it is
        // shown. That mobile skin is not what any of the parsing was built
        // against, so on a phone the same topic imported differently, or not
        // at all. Asking for the desktop site makes the page the app sees the
        // same page on every device.
        //
        // archive.org is not parsed at all: the app reads an item from the
        // metadata API, not from the page. So it gets whichever layout the
        // device would normally be served, which on a phone is the one built
        // for a phone.
        config.defaultWebpagePreferences.preferredContentMode =
            desktopSite ? .desktop : .recommended
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.allowsBackForwardNavigationGestures = true
        webView.navigationDelegate = self
        // Without this, a link that opens in a new window does nothing at all
        // — WebKit asks for a view to put it in and the default answer is
        // none. See `createWebViewWith` below.
        webView.uiDelegate = self

        observers = [
            webView.observe(\.url, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in
                    self?.url = view.url
                    // Going somewhere is what makes the refusal notice stale:
                    // it explains a page that did not change, and this is the
                    // page changing. A cancelled navigation never gets here,
                    // which is exactly why the notice survives one.
                    self?.refused = nil
                }
            },
            webView.observe(\.title, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.title = view.title ?? "" }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.isLoading = view.isLoading }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoBack = view.canGoBack }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.canGoForward = view.canGoForward }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] view, _ in
                Task { @MainActor in self?.progress = view.estimatedProgress }
            },
        ]
    }

    func load(_ address: String) {
        // Upgrade before the first request too, not just on redirects.
        guard let url = URL(string: address) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Says a link was turned away.
    func noteRefusal(of host: String) {
        refused = host
    }

    /// The **live DOM**, not the originally fetched source.
    ///
    /// This is the whole reason the import lives in the app. IPB reveals hidden
    /// content by AJAX after a Like, so a page saved from the browser still
    /// contains the locked markup unless it is force-reloaded first. Reading
    /// outerHTML sidesteps that entirely: what you can see is what gets parsed.
    func currentHTML() async -> String? {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript("document.documentElement.outerHTML") { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }
}

extension BrowserModel: WKNavigationDelegate {

    /// Keeps the browser on its own site, and on TLS.
    ///
    /// Two rules, in that order.
    ///
    /// **The fence.** A main-frame navigation to anywhere outside `fence` is
    /// cancelled and reported. Sub-frames are left alone: an iframe is part of
    /// the page being shown rather than somewhere the reader has gone, and
    /// blocking those would break the archive's own reader while stopping
    /// nobody from going anywhere. A new-window action has no target frame at
    /// all and is treated as a main-frame one, which is what it becomes.
    ///
    /// **The upgrade.** StripZona serves the forum over TLS but emits plain-http
    /// links, and its session cookie is not marked Secure, so a cleartext hop
    /// would put a live session on the wire.
    ///
    /// GET ONLY, and that restriction is load-bearing. Upgrading works by
    /// cancelling the navigation and re-issuing it, but WebKit does not expose
    /// `httpBody` to this delegate — it is always nil — so a re-issued form
    /// submission arrives as a bodyless GET with no Referer. That silently
    /// broke logging in: the credentials never reached the server and the page
    /// just bounced back. Non-GET navigations are left exactly as the page
    /// made them; the login form already posts to https regardless.
    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let request = navigationAction.request
        guard let url = request.url else { return .allow }

        if navigationAction.targetFrame?.isMainFrame ?? true, !fence.admits(url) {
            let host = url.host ?? url.scheme ?? "somewhere else"
            Task { @MainActor in self.noteRefusal(of: host) }
            return .cancel
        }

        guard request.httpMethod == nil || request.httpMethod == "GET",
              navigationAction.navigationType != .formSubmitted,
              navigationAction.navigationType != .formResubmitted,
              url.scheme == "http",
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return .allow }

        parts.scheme = "https"
        guard let secure = parts.url else { return .allow }
        // Carry the original headers over; only the scheme changes.
        var upgraded = request
        upgraded.url = secure
        Task { @MainActor in webView.load(upgraded) }
        return .cancel
    }
}

extension BrowserModel: WKUIDelegate {

    /// Opens a `target="_blank"` link in the view the reader is looking at.
    ///
    /// Returning a new web view is not an option — there is one browser here,
    /// not a tab bar — and returning nil without doing anything else is what
    /// WebKit does by default, which makes those links look broken. The fence
    /// has already had its say: an action that gets this far passed it, so
    /// loading it in place is exactly as safe as following any other link.
    nonisolated func webView(_ webView: WKWebView,
                             createWebViewWith configuration: WKWebViewConfiguration,
                             for navigationAction: WKNavigationAction,
                             windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url, fence.admits(url) else { return nil }
        Task { @MainActor in self.webView.load(URLRequest(url: url)) }
        return nil
    }
}

struct BrowserView: UIViewRepresentable {
    let model: BrowserModel

    func makeUIView(context: Context) -> WKWebView { model.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

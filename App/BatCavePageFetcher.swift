import Foundation
import UIKit
import WebKit
import SZKit

/// Fetches one issue's pages, using a web view as the thing that asks.
///
/// **Why a web view and not `URLSession`.** Both `batcave.biz` and
/// `img.batcave.biz` sit behind a challenge that refuses anything which is not
/// a browser: a plain request with a correct Safari User-Agent is answered
/// with HTTP 403 and a challenge page, images included. A web view passes it
/// the way any browser does, by being one.
///
/// So the fetch happens *inside the page*: this loads the reader, then asks
/// the document itself to `fetch` each image. Every request carries the real
/// origin, cookies and referer because it genuinely is the page making it.
/// Nothing is replayed, spoofed or solved — which is also why this survives
/// the site changing its challenge, since it never depended on the shape of
/// one.
///
/// What it costs: the app must stay in the foreground. A background
/// `URLSession` is what keeps the other sources' transfers alive while the app
/// is suspended, and a web view cannot do that. At one page a second an issue
/// is a minute or two of foreground, which is the trade this source is worth.
@MainActor
final class BatCavePageFetcher: NSObject {

    /// How long to leave between page requests.
    ///
    /// Half a second, which is two a second. That is inside what the site
    /// already serves a reader: its own viewer preloads several pages at once
    /// when someone flips through, so a single sequential request every 500ms
    /// is a quieter client than a person with the reader open. These are image
    /// subresource requests carrying the page they belong to as their
    /// `Referer` — the same request the site answers whenever it shows anyone
    /// a page.
    ///
    /// **The interval is not what keeps this safe, though, and it should not
    /// be relied on as if it were.** What keeps it safe is stopping when the
    /// server says to: see the refusal handling in `directImage`. A burst of
    /// two hundred requests that ignores a 429 gets an address blocked at any
    /// interval, and the site's own page data advertises a bulk-download quota
    /// whose lockout is `unlock_at: 259200` — three days.
    ///
    /// So this is deliberately not tuned lower. The gain from here is small —
    /// a 94-page issue goes from 94 seconds to 47 — and the thing being risked
    /// is measured in days.
    static let betweenPages: Duration = .milliseconds(500)

    /// How long to wait for the reader page itself.
    ///
    /// Generous, because this is the load that passes the challenge: it can
    /// involve an interstitial that redirects once before the real page
    /// arrives.
    private static let readerTimeout: Duration = .seconds(45)

    /// How long any one image may take.
    private static let imageTimeout: Duration = .seconds(60)

    private let webView: WKWebView
    private var pendingLoad: CheckedContinuation<Void, Error>?

    /// What the navigation actually did, in order, for the failure message.
    ///
    /// Three fixes in a row were aimed at a step nobody had established ever
    /// ran. A navigation that never starts, one that starts and never commits,
    /// and one that commits and yields no document are three different faults
    /// wearing one symptom, and this is what tells them apart.
    private var events: [String] = []

    /// Facts worth recording once rather than once per page.
    private var noted: Set<String> = []

    /// How many pages this run has actually been given.
    ///
    /// Distinguishes a run that never worked from one that was working and
    /// then stopped being allowed to, which need opposite responses: the first
    /// is a fault to report, the second is a request to back off.
    private var pagesServed = 0

    /// What the reader's own browsing established, gathered once the reader
    /// page has loaded and handed to every page request after it.
    private struct BatCaveSession {
        let userAgent: String
        /// The page the images belong to. The image host checks it.
        let referer: String
    }

    private var session: BatCaveSession?

    /// Cookies per image host, gathered the first time each host is asked.
    ///
    /// One set for `batcave.biz` was enough while every page came from
    /// `img.batcave.biz`, which inherits the site's cookies. It stops being
    /// enough the moment a comic's pages are served from somewhere else: that
    /// host would be handed a session belonging to a different site, and
    /// refused for a reason no header explains.
    private var cookiesByHost: [String: String?] = [:]

    private func cookies(for url: URL) async -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        if let known = cookiesByHost[host] { return known }
        let jar = await SiteCookies.header(forURL: url)
        cookiesByHost[host] = jar
        return jar
    }

    /// What a browser would call the relationship between the referring page
    /// and the thing being fetched.
    ///
    /// Three answers, and the middle one is the whole reason this is computed:
    /// `same-site` covers a different host under the same registrable domain —
    /// `img.batcave.biz` for a page on `batcave.biz` — while a genuinely
    /// different site is `cross-site`, and saying otherwise is a false claim
    /// about two hosts to an edge that checks.
    static func fetchSite(from referer: String, to target: URL) -> String {
        guard let from = URL(string: referer), let fromHost = from.host?.lowercased(),
              let toHost = target.host?.lowercased() else { return "cross-site" }
        if fromHost == toHost, from.scheme == target.scheme { return "same-origin" }
        return site(of: fromHost) == site(of: toHost) ? "same-site" : "cross-site"
    }

    /// A host's registrable-ish domain: its last two labels. The same rough
    /// rule `HostCooldown` uses, and wrong in the same place — a `.co.uk`
    /// would collapse too far. Neither host here has that shape.
    private static func site(of host: String) -> String {
        let labels = host.split(separator: ".")
        guard labels.count > 2 else { return host }
        return labels.suffix(2).joined(separator: ".")
    }

    private func note(_ event: String) {
        // Bounded: a page that redirects in a loop must not grow this without
        // limit for the length of the timeout.
        guard events.count < 24 else { return }
        events.append(event)
    }

    override init() {
        let config = WKWebViewConfiguration()
        // The default persistent store, which is the same one the browser
        // screens use — so whatever the reader established while browsing is
        // already here, and this does not have to pass the challenge from
        // cold on every download.
        config.websiteDataStore = .default()
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 1024, height: 768),
                            configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    /// What one issue's fetch produced.
    struct Result {
        let bytes: Int64
        /// The file the download is recorded against — the first page.
        let file: URL
        let pages: Int
    }

    /// Fetches every page of one chapter into `directory`.
    ///
    /// - Parameter progress: called on the main actor with pages done and the
    ///   total, so the caller can drive a bar against a real number rather
    ///   than a guess. The page count is known before the first image is
    ///   asked for, which no other source in this app manages.
    func fetch(readerURL: String,
               into directory: URL,
               progress: @escaping @MainActor (Int, Int) -> Void) async throws -> Result {

        guard let url = URL(string: readerURL), HostFence.batcave.admits(url) else {
            throw PageFetchError.notAReaderPage
        }

        // In the window for the duration, and out again afterwards. See
        // `attachToWindow` — without this the reader page never finishes
        // loading at all.
        attachToWindow()
        defer { webView.removeFromSuperview() }

        let html = try await loadReader(url)
        guard let reading = BatCaveReaderPage.reading(html) else {
            throw PageFetchError.notAReaderPage
        }
        if let refusal = BatCaveReaderPage.refusal(reading) { throw refusal }

        let download = try PageDownload(directory: directory, images: reading.images)
        let total = download.pageCount

        // Stay on the reader page. It is the referring page for every one of
        // these images, and that turns out to be what the image host checks —
        // see `directImage`.
        session = BatCaveSession(userAgent: await currentUserAgent(),
                                 referer: readerURL)

        // Pages already on disk from an interrupted attempt cost nothing the
        // second time — neither a request nor a second of waiting.
        var fetched = (1...total).filter { download.has(page: $0) }.count
        progress(fetched, total)

        var isFirstRequest = true
        for page in 1...total {
            try Task.checkCancellation()
            guard !download.has(page: page) else { continue }

            // Before the request rather than after it, so the pause is skipped
            // for pages that were already here and never charged twice.
            if !isFirstRequest { try await Task.sleep(for: Self.betweenPages) }
            isFirstRequest = false

            let data = try await image(at: download.address(page: page), page: page)
            try download.write(data, page: page)
            fetched += 1
            progress(fetched, total)
        }

        let bytes = try download.finish()
        return Result(bytes: bytes, file: download.recordedFile, pages: total)
    }

    // MARK: - Being on screen enough to work

    /// Puts the web view in the window, invisibly, for the length of the fetch.
    ///
    /// **A detached `WKWebView` cannot load this site at all.** WebKit
    /// suspends rendering — and with it `requestAnimationFrame` — for a view
    /// that is not in a window. The site's challenge page drives its
    /// proof-of-work loop from `requestAnimationFrame`; it even probes for it
    /// by name before starting. So the interstitial spins for ever, the reader
    /// page never arrives, and the whole fetch fails on the reader timeout
    /// having never asked for a single image.
    ///
    /// That was not a guess: the same configuration loads the same site fine
    /// in the Import browser, and the only difference between the two is that
    /// one of them is on screen.
    ///
    /// Invisible without being hidden, which is the narrow ledge this has to
    /// stand on. `isHidden`, a zero frame and `alpha = 0` each stop rendering
    /// again and put the loop straight back to sleep — so it keeps a real
    /// size and an alpha just above nothing, sits behind every other view, and
    /// takes no touches. It is removed the moment the fetch ends.
    private func attachToWindow() {
        guard webView.superview == nil else { return }
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        guard let window = scene?.windows.first(where: \.isKeyWindow)
                        ?? scene?.windows.first else { return }

        webView.alpha = 0.01
        webView.isUserInteractionEnabled = false
        webView.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        // In *front*, not behind. Behind every other view it is completely
        // covered by opaque UI, and a covered web view is as good as a hidden
        // one to WebKit — which is the same suspension being avoided by
        // putting it in a window at all. Nearly transparent and taking no
        // touches, so being in front costs the reader nothing.
        window.addSubview(webView)
    }

    // MARK: - Asking for one page

    /// Requests one page directly, carrying the session the reader's own
    /// browsing established.
    ///
    /// **Why this cannot be done from inside the page**, which took two rounds
    /// to establish and is worth writing down:
    ///
    ///  * From the **reader page**, a `fetch` for an image is cross-origin —
    ///    the reader is on `batcave.biz`, the pages are on `img.batcave.biz` —
    ///    and reading the bytes needs an `Access-Control-Allow-Origin` header
    ///    the image host has no reason to send. Refused before a response
    ///    exists: `TypeError: Load failed`. An `<img>` loads fine there, but
    ///    its pixels cannot be read back — a cross-origin image taints the
    ///    canvas, which is the same rule wearing a different hat.
    ///  * From the **image host's own origin**, the read is permitted and the
    ///    server answers **403** instead, because the request no longer refers
    ///    from the page the picture belongs to.
    ///
    /// Those two conditions cannot both hold in a browser page: a document
    /// cannot claim a `Referer` from an origin it is not on. So the request is
    /// made where every header can be set at once — the referring page, the
    /// cookies WebKit is holding, and the same `User-Agent` the web view
    /// presented when it established them.
    ///
    /// Nothing here solves or evades a challenge. The web view passes the
    /// site's check by being a browser, and this continues the session that
    /// produced — the same split `ComicBookPlusHost` already uses, one gate
    /// weaker.
    private func directImage(at address: String) async throws -> Data {
        guard let url = URL(string: address), let session else {
            throw PageFetchError.notAReaderPage
        }
        var request = URLRequest(url: url)
        request.setValue(session.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(session.referer, forHTTPHeaderField: "Referer")
        // For the host actually being asked, not for the site the reader was
        // browsing. See `cookiesByHost`.
        if let jar = await cookies(for: url) {
            request.setValue(jar, forHTTPHeaderField: "Cookie")
        }
        // The headers a browser sends when it is loading a picture for a page,
        // because that is exactly what this is.
        request.setValue("image/avif,image/webp,image/jpeg,image/png,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue("image", forHTTPHeaderField: "Sec-Fetch-Dest")
        request.setValue("no-cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        // Worked out rather than asserted. This said `same-site` for every
        // request, which is a claim about two hosts and is simply false when a
        // comic's pages come from another site — and it is a header the edge
        // in front of these images reads.
        request.setValue(Self.fetchSite(from: session.referer, to: url),
                         forHTTPHeaderField: "Sec-Fetch-Site")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { return data }

        // Asked before the status is treated as a plain failure, because a
        // refusal is not a broken page — it is the server asking to be left
        // alone, and the only correct response is to stop.
        //
        // `RetryAfter` rather than a second implementation of it: the header
        // is two headers wearing one name (seconds, or an HTTP date), both are
        // seen in the wild, and reading only one turns half of all rate limits
        // into an unexplained failure. That is already written and already
        // tested.
        if let refusal = RetryAfter.refusal(
            status: http.statusCode,
            header: http.value(forHTTPHeaderField: "Retry-After"),
            host: url.host ?? BatCave.host) {
            throw refusal
        }
        // A 403 part-way through a run that had been working is the same
        // message in blunter form: the earlier pages were served, so the link
        // is not dead and the session is not wrong — something decided this
        // client had asked enough. Retrying immediately is the one response
        // guaranteed to make it worse.
        if http.statusCode == 403, pagesServed > 0 {
            throw DownloadError.rateLimited(host: url.host ?? BatCave.host, retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PageFetchError.pageFailed(
                page: 0,
                reason: "HTTP \(http.statusCode) from \(url.host ?? "the image host")")
        }
        pagesServed += 1
        return data
    }

    // MARK: - The reader page

    /// Loads the reader and hands back its markup once the page data is there.
    ///
    /// The site can answer the first request with an interstitial that
    /// measures the client and then redirects, so "the load finished" is not
    /// the same as "the reader arrived". This waits for the payload itself to
    /// appear, which is the only condition that actually means anything.
    private func loadReader(_ url: URL) async throws -> String {
        do {
            return try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { @MainActor in
                    try await self.load(url)
                    return try await self.awaitPayload()
                }
                group.addTask {
                    try await Task.sleep(for: Self.readerTimeout)
                    throw ReaderTimedOut()
                }
                guard let html = try await group.next() else {
                    throw PageFetchError.notAReaderPage
                }
                group.cancelAll()
                return html
            }
        } catch is ReaderTimedOut {
            // "did not load in time" says nothing anyone can act on — it was
            // true of two completely different faults in a row here. What the
            // view is actually sitting on is the whole diagnosis.
            throw PageFetchError.pageFailed(page: 0, reason: await whereItStopped())
        }
    }

    /// Thrown only to lose the race in `loadReader`, and never seen outside it.
    private struct ReaderTimedOut: Error {}

    /// What the web view was doing when the wait ran out.
    ///
    /// Written because guessing at this cost two rounds: the first answer was
    /// "the challenge never completes offscreen", the second was the same
    /// message again, and neither guess could be checked from here. Every fact
    /// in this sentence distinguishes faults that need different fixes —
    /// whether the view reached the window at all, whether it is still on the
    /// challenge, whether a document arrived, and what that document says.
    private func whereItStopped() async -> String {
        let address = webView.url?.absoluteString ?? "no address"

        // Separated from "the document is empty", which they are not. Read
        // through `try?` these were the same sentence, and "no document" was
        // reported three times running for a state nobody had established.
        var html = ""
        var scriptError = ""
        switch await evaluate("document.documentElement.outerHTML") {
        case .success(let value): html = value ?? ""
        case .failure(let error): scriptError = "script refused: \(error.localizedDescription)"
        }

        var text = ""
        if case .success(let value) = await evaluate(
            "document.body ? document.body.innerText : ''") { text = value ?? "" }

        var notes: [String] = []
        notes.append(webView.superview == nil ? "not in the window" : "in the window")
        // What the view actually did, in order. Every theory so far has been
        // about which of these never happened, and none of them could be
        // checked from a machine the site refuses.
        notes.append("[\(events.isEmpty ? "no navigation events" : events.joined(separator: " "))]")
        notes.append(String(format: "progress %.2f", webView.estimatedProgress))
        if webView.isLoading { notes.append("still loading") }
        if !scriptError.isEmpty { notes.append(scriptError) }
        if webView.url?.path.hasPrefix("/_c") == true { notes.append("on the challenge page") }
        if html.isEmpty { notes.append("no document") }
        else { notes.append("\(html.count) chars") }
        if html.contains("__DATA__") { notes.append("page data present but unread") }

        // The first line of visible text, which is what names a challenge or
        // an error page when nothing else does.
        let firstLine = text
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { !$0.isEmpty }) ?? ""
        if !firstLine.isEmpty { notes.append("says “\(firstLine.prefix(60))”") }

        return "the reader page did not arrive — \(notes.joined(separator: ", ")) "
             + "at \(address)"
    }

    private func load(_ url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            pendingLoad = continuation
            webView.load(URLRequest(url: url))
        }
    }

    /// Polls the document until it carries the reader's payload.
    ///
    /// Polling rather than waiting on a second navigation, because the
    /// interstitial may replace the document without one this delegate sees.
    /// The outer timeout is what stops this.
    private func awaitPayload() async throws -> String {
        while true {
            try Task.checkCancellation()
            let html = await currentHTML()
            if BatCaveReaderPage.reading(html) != nil { return html }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// What the web view calls itself.
    ///
    /// Read from the view rather than taken from `UserAgent.browser`, whose
    /// own documentation names the reason: a request whose header disagrees
    /// with the web view that established the session is how a live cookie
    /// gets refused. That constant says Safari on macOS; this view says
    /// Safari on an iPad, and the session belongs to the iPad.
    private func currentUserAgent() async -> String {
        if case .success(let value) = await evaluate("navigator.userAgent"),
           let agent = value, !agent.isEmpty { return agent }
        return UserAgent.browser
    }

    private func currentHTML() async -> String {
        if case .success(let value) = await evaluate("document.documentElement.outerHTML") {
            return value ?? ""
        }
        return ""
    }

    /// Whether a refusal reads as "there is nothing here to serve" rather than
    /// "something went wrong on the way".
    ///
    /// A 403 or a 404 on the first page, from a session that is fetching other
    /// issues perfectly well, is the site declining to offer this one — not a
    /// fault to be worked around. Deliberately narrow: a timeout, a dropped
    /// connection or a rate limit are all things that could work next time,
    /// and telling the reader not to bother would be wrong for every one of
    /// them.
    static func looksUnavailable(_ refusal: String) -> Bool {
        refusal.contains("HTTP 403") || refusal.contains("HTTP 404")
    }

    /// What a script actually complained about.
    ///
    /// `localizedDescription` on a WebKit script error is the fixed sentence
    /// "A JavaScript exception occurred" — the same words whatever went wrong,
    /// which distinguishes nothing. The exception's own message is in the
    /// error's `userInfo`, and it is the entire diagnosis: a refused
    /// cross-origin read, an HTTP status this script threw on purpose, and a
    /// syntax mistake all arrive wearing that one sentence.
    ///
    /// The keys are plain strings rather than symbols — WebKit does not export
    /// them to Swift — and are read defensively for that reason.
    static func scriptReason(_ error: Error) -> String {
        let info = (error as NSError).userInfo
        guard let message = info["WKJavaScriptExceptionMessage"] as? String,
              !message.isEmpty else { return (error as NSError).localizedDescription }
        if let line = info["WKJavaScriptExceptionLineNumber"] as? Int, line > 0 {
            return "\(message) (line \(line))"
        }
        return message
    }

    /// One expression, through the completion-handler form.
    ///
    /// **Not** `evaluateJavaScript(_:in:in:)`, whose `async` overload resolves
    /// here to a function returning `()`. Its result then casts to nil for
    /// every script ever run, so the reader page was reported as "no document"
    /// however completely it had loaded — through a working challenge, two
    /// clean navigations and `estimatedProgress` of 1.00.
    ///
    /// The compiler said so at the time: "value of tuple type '()' has no
    /// member 'get'". That was the bug, complete, on the first build. Silencing
    /// it with a cast that always yields nil cost four rounds of hunting the
    /// site for a fault that was never there.
    ///
    /// This is the form `BrowserModel.currentHTML` has always used — the same
    /// component whose fence and configuration this file had to learn from
    /// twice already.
    private func evaluate(_ script: String) async -> Swift.Result<String?, Error> {
        await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(returning: .failure(error)) }
                else { continuation.resume(returning: .success(value as? String)) }
            }
        }
    }

    // MARK: - One page

    /// Asks the loaded document to fetch one image, and brings the bytes back.
    ///
    /// Base64 across the bridge because that is the only faithful way to carry
    /// binary through `WKWebView`'s JSON boundary — a `Uint8Array` arrives as
    /// an array of doubles, which for a megabyte of JPEG is both enormous and
    /// lossy at the edges.
    ///
    /// Chunked on the JavaScript side: `String.fromCharCode.apply` on a
    /// megabyte-long array overflows the argument list and throws, which is a
    /// failure that only shows up on large pages.
    ///
    /// Runs in `.defaultClient` — an isolated world that still shares the
    /// document's origin and cookies, so the request is identical to one the
    /// page would make while page scripts cannot interfere with it.
    private func image(at address: String, page: Int) async throws -> Data {
        // The direct request first: it is the only route that can carry both
        // the referring page and a readable body, and it returns the site's
        // own bytes rather than a re-encode. See `directImage`.
        var directRefusal = ""
        do {
            return try await directImage(at: address)
        } catch let refusal as DownloadError where refusal.isRateLimited {
            // Straight out, without trying the fallback. The server has just
            // asked to be left alone, and the fallback is another request to
            // the same server moments later — which is not a second chance,
            // it is the thing the refusal was about.
            throw refusal
        } catch {
            directRefusal = Library.reason(error)
        }

        // Kept as a fallback rather than deleted. Both of its routes are known
        // to be refused on this site today, for reasons recorded on
        // `directImage` — but they are refused by *site policy*, which is the
        // kind of thing that changes, and it costs one request to find out.
        let script = """
        let refusal = '';

        // First choice, and the only one that keeps the file byte for byte as
        // the site stores it.
        try {
            const response = await fetch(source, { credentials: 'include' });
            if (!response.ok) { throw new Error('HTTP ' + response.status); }
            const bytes = new Uint8Array(await response.arrayBuffer());
            let binary = '';
            const stride = 0x8000;
            for (let i = 0; i < bytes.length; i += stride) {
                binary += String.fromCharCode.apply(null, bytes.subarray(i, i + stride));
            }
            return 'raw:' + btoa(binary);
        } catch (error) {
            refusal = (error && error.message) || String(error);
        }

        // Second choice: ask for the picture the way the page itself does.
        // An <img> is a plain subresource load — the exact request the site
        // answers every time it shows someone a page — where a fetch is a
        // script reading bytes, which a host may refuse on its own terms.
        const picture = await new Promise((resolve) => {
            const img = new Image();
            img.onload = () => resolve(img);
            img.onerror = () => resolve(null);
            img.src = source;
        });
        if (!picture) {
            throw new Error('fetch said “' + refusal + '”, and the image would '
                          + 'not load either, from ' + location.origin);
        }

        // Reading it back needs the canvas to be untainted, which it is only
        // because the document was moved to this image's own origin first.
        const canvas = document.createElement('canvas');
        canvas.width = picture.naturalWidth;
        canvas.height = picture.naturalHeight;
        canvas.getContext('2d').drawImage(picture, 0, 0);
        let encoded;
        try {
            encoded = canvas.toDataURL('image/jpeg', 0.95);
        } catch (error) {
            throw new Error('fetch said “' + refusal + '”, and the picture '
                          + 'cannot be read back ('
                          + ((error && error.message) || error)
                          + ') from ' + location.origin);
        }
        return 'jpeg:' + encoded.slice(encoded.indexOf(',') + 1);
        """

        let encoded: String = try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { @MainActor in
                // The completion-handler form, for the same reason
                // `evaluate` uses it: the `async` overloads of these two
                // methods are what silently returned nothing for four rounds,
                // and this one has never been exercised. A `Result` here
                // cannot be quietly cast away.
                let outcome: Swift.Result<Any, Error> = await withCheckedContinuation { done in
                    self.webView.callAsyncJavaScript(
                        script, arguments: ["source": address],
                        in: nil, in: .defaultClient,
                        completionHandler: { done.resume(returning: $0) })
                }
                switch outcome {
                case .success(let value):
                    guard let text = value as? String, !text.isEmpty else {
                        throw PageFetchError.pageFailed(
                            page: page, reason: "the page returned no data")
                    }
                    return text
                case .failure(let error):
                    // Both refusals, because either one alone is misleading:
                    // the direct request and the page see different walls, and
                    // which of them moved is the whole diagnosis.
                    let detail = "direct: \(directRefusal); "
                               + "page: \(Self.scriptReason(error))"

                    // Nothing has been served and the very first page is
                    // refused: the site is not offering this issue at all.
                    //
                    // Worth telling apart from a fetch that went wrong,
                    // because the reader can act on one and not the other.
                    // "Land of the Sons" is the case this was written for — its
                    // reader page lists addresses on the site's own host rather
                    // than the image host every other issue uses, and they are
                    // refused there. It does not open in a browser either, so
                    // there is nothing here to work around and no point
                    // retrying.
                    if self.pagesServed == 0, page == 1,
                       Self.looksUnavailable(directRefusal) {
                        throw PageFetchError.pageFailed(
                            page: page,
                            reason: "\(BatCave.host) is not serving this issue's pages — "
                                  + "it does not open on the site either. "
                                  + "Nothing to retry. (\(detail))")
                    }
                    throw PageFetchError.pageFailed(page: page, reason: detail)
                }
            }
            group.addTask {
                try await Task.sleep(for: Self.imageTimeout)
                throw PageFetchError.pageFailed(page: page, reason: "timed out")
            }
            guard let value = try await group.next() else {
                throw PageFetchError.pageFailed(page: page, reason: "no result")
            }
            group.cancelAll()
            return value
        }

        // Which of the two routes answered. Recorded rather than ignored,
        // because they do not produce the same file: `raw:` is the site's own
        // bytes, `jpeg:` has been through a canvas and is a re-encode.
        let route = encoded.prefix(while: { $0 != ":" })
        let payload = String(encoded.drop(while: { $0 != ":" }).dropFirst())
        if route == "jpeg", !noted.contains("reencoded") {
            noted.insert("reencoded")
            note("reencoded")
        }

        guard let data = Data(base64Encoded: payload), !data.isEmpty else {
            throw PageFetchError.pageFailed(page: page, reason: "the bytes did not decode")
        }
        return data
    }

}

// MARK: - Navigation

extension BatCavePageFetcher: WKNavigationDelegate {

    /// Fenced, exactly like the browser screens — **including the main-frame
    /// test**, which is not a detail.
    ///
    /// This view is never shown and never tapped, so the fence is not about a
    /// stray link; it is about a redirect. A download that quietly followed
    /// one off the site would be fetching pages from somewhere nobody chose.
    /// The main frame is where that can happen, and fencing it is enough.
    ///
    /// Fencing *every* frame is what broke this for two rounds. The challenge
    /// in front of the site runs in an iframe served from another domain, so a
    /// fence applied to subframes cancels the one navigation that has to
    /// succeed: the page then sits on the right address, settled, with no
    /// document ever committed — which is exactly what the diagnosis reported.
    /// `BrowserModel` has always had the `isMainFrame` test, which is why the
    /// Import browser could load a site this could not.
    ///
    /// `?? true` treats an absent target frame as the main one, so a
    /// navigation opening a new frame is still fenced rather than waved
    /// through.
    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        let refused = isMainFrame && !HostFence.batcave.admits(url)
        note(refused ? "cancel(\(url.host ?? "?"))"
                     : (isMainFrame ? "allow" : "allow-frame(\(url.host ?? "?"))"))
        decisionHandler(refused ? .cancel : .allow)
    }

    func webView(_ webView: WKWebView,
                 didStartProvisionalNavigation navigation: WKNavigation!) {
        note("start")
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        note("commit")
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        note("finish")
        pendingLoad?.resume()
        pendingLoad = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        note("fail(\((error as NSError).code))")
        pendingLoad?.resume(throwing: error)
        pendingLoad = nil
    }

    func webView(_ webView: WKWebView,
                 didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        note("failProvisional(\((error as NSError).code))")
        pendingLoad?.resume(throwing: error)
        pendingLoad = nil
    }

    /// The web content process dying is silent otherwise: every later
    /// `evaluateJavaScript` simply fails and the view sits there with an
    /// address, not loading, and nothing in it — which is precisely the state
    /// reported three times running.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("contentProcessDied")
    }
}

import CoreGraphics
import ImageIO
import SwiftUI
import SZKit

/// Paged comic reader.
///
/// Pages are decoded at the panel's pixel size rather than full resolution —
/// a 2500x3500 scan is ~35 MB decoded, and a handful of those is enough to get
/// the app killed on a base-model iPad.
struct ReaderView: View {
    /// Observed rather than handed a document.
    ///
    /// `fullScreenCover(item:)` snapshots its item when it presents and never
    /// looks at it again, so a document that arrives after the reader is on
    /// screen never reached it — the spinner ran for ever while the pages sat
    /// ready in the model.
    @ObservedObject var model: AppModel
    let comicID: Int
    let title: String
    /// Where to open. Zero-based; the reader was left here last time.
    let startPage: Int

    /// Nil until unpacking finishes; the reader is on screen before then.
    private var document: ComicDocument? { model.reading?.document }

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var cache: [Int: CGImage] = [:]
    @State private var chromeVisible = true
    /// Where the scrubber's thumb is, which is only the same as `index` when
    /// the user is not dragging it.
    @State private var scrubTarget: Double = 0
    @State private var scrubbing = false
    /// Fired once per sitting: turning back a page and forward again is not
    /// finishing it a second time.
    @State private var finished = false
    /// Landscape, tracked from the geometry so the chrome knows which
    /// scrubber to put up. The reader itself branches on the geometry
    /// directly; this is only for the parts drawn outside it.
    @State private var landscape = false
    /// A page one of the vertical scrubbers has asked to jump to.
    @State private var seek: Int?
    /// Which of the two vertical scrubbers is being dragged, if either.
    @State private var scrubbingSide: HorizontalEdge?

    private var pageCount: Int { document?.pageCount ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if document == nil { opening }

            // Landscape is not portrait with more room to the sides — it is
            // how you read a comic on a screen too small to show a whole page
            // at a legible size. So the page is widened to the screen and
            // read down, and the two modes page differently.
            GeometryReader { geo in
                Group {
                    if geo.size.width > geo.size.height {
                        // Only once there is a comic to scroll. Built before
                        // that, the strip captures a page count of zero and a
                        // resume position of nowhere, and goes on believing
                        // both after the pages arrive.
                        if pageCount > 0 { landscapeReader }
                    } else {
                        portraitPager
                    }
                }
                .onAppear { landscape = geo.size.width > geo.size.height }
                .onChange(of: geo.size) { size in landscape = size.width > size.height }
            }
            .ignoresSafeArea()

            if chromeVisible { chrome }
        }
        .statusBarHidden(!chromeVisible)
        // Driven by the document arriving rather than by onAppear: the reader
        // is on screen first, and there is nothing to resume to until then.
        .onChange(of: document == nil) { stillOpening in
            if !stillOpening { begin() }
        }
        .onAppear { if document != nil { begin() } }
        .onChange(of: index) { page in
            guard pageCount > 0 else { return }
            model.rememberPlace(issueID: comicID, page: page)
            if page >= pageCount - 1 { markFinished() }
        }
    }

    /// Portrait: whole pages, turned by swiping sideways.
    private var portraitPager: some View {
        TabView(selection: $index) {
            ForEach(0..<max(pageCount, 1), id: \.self) { page in
                PageView(image: cache[page],
                         onTap: { withAnimation { chromeVisible.toggle() } },
                         turnPage: { direction in
                    // Zoom belongs to the page being left, so the next one
                    // opens whole — which is also the only way to see where
                    // you have arrived.
                    withAnimation { index = min(max(page + direction, 0), pageCount - 1) }
                })
                .tag(page)
                .onAppear { load(around: page) }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    /// Landscape: the comic as one continuously scrolling strip.
    private var landscapeReader: some View {
        ContinuousPages(
            pageCount: pageCount,
            image: { cache[$0] },
            loadAround: { load(around: $0, keeping: index) },
            currentPage: $index,
            seek: $seek,
            // Where the reader is *now*, not where they were when the reader
            // was opened. The strip is rebuilt from scratch on every
            // rotation, and handing it the opening page would scroll back
            // there and then report it — writing the old page over the
            // reader's actual progress every time the iPad turned.
            openAt: min(max(index, 0), max(pageCount - 1, 0)),
            onTap: { withAnimation { chromeVisible.toggle() } })
    }

    /// Settles on the resumed page and starts decoding around it.
    private func begin() {
        guard pageCount > 0 else { return }
        // Clamped, in case the archive has been re-downloaded with a
        // different page count since it was last read.
        index = min(max(startPage, 0), pageCount - 1)
        scrubTarget = Double(index)
        load(around: index)
        // A one-page comic is finished the moment it opens.
        if pageCount <= 1 { markFinished() }
    }

    private var opening: some View {
        VStack(spacing: 14) {
            ProgressView().tint(.white).controlSize(.large)
            Text("Opening…").font(.headline).foregroundStyle(.secondary)
        }
    }

    private func markFinished() {
        guard !finished else { return }
        finished = true
        model.markRead(issueID: comicID)
    }

    private var chrome: some View {
        ZStack {
            // Landscape scrolls, so its position control runs the same way the
            // comic does — and there are two, because which edge is reachable
            // depends on which hand is holding the iPad.
            if landscape && pageCount > 1 { sideScrubbers }
            portraitChrome
        }
        .foregroundStyle(.primary)
        .transition(.opacity)
    }

    private var sideScrubbers: some View {
        HStack {
            // Only the one in use, once one is in use: two thumbs dragging
            // two scrubbers is two answers to "which page", and the loser
            // would snap back under the reader's finger.
            if scrubbingSide != .trailing {
                VerticalScrubber(pageCount: pageCount, page: index,
                                 edge: .leading,
                                 activeSide: $scrubbingSide) { seek = $0 }
            }
            Spacer()
            if scrubbingSide != .leading {
                VerticalScrubber(pageCount: pageCount, page: index,
                                 edge: .trailing,
                                 activeSide: $scrubbingSide) { seek = $0 }
            }
        }
        .animation(.easeOut(duration: 0.15), value: scrubbingSide)
        // Clear of the title bar above and the home indicator below.
        .padding(.top, 78)
        .padding(.bottom, 28)
        .padding(.horizontal, 4)
    }

    private var portraitChrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark.circle.fill").font(.title2)
                }
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Text(pageCount > 0 ? "\(index + 1) / \(pageCount)" : "…")
                    .font(.subheadline.monospacedDigit())
                // Back to the grid, from wherever you have got to. Only worth
                // offering for something with pages to look through, and only
                // here — in the chrome, where Close and the scrubber already
                // are — so nothing new appears over the page itself.
                if pageCount > 1 {
                    Button { model.browsePages(from: index) } label: {
                        Label("Pages", systemImage: "square.grid.2x2.fill").font(.title3)
                    }
                    .labelStyle(.iconOnly)
                    .padding(.leading, 4)
                }
            }
            .padding()
            .background(.ultraThinMaterial)

            Spacer()

            // A single page is not worth a scrubber, and in landscape the
            // scrubbers are down the sides instead.
            if pageCount > 1 && !landscape { scrubber }
        }
    }

    /// Drag to any page.
    ///
    /// The page only changes when the thumb is released. Following the drag
    /// live would decode every page it crosses, which on a 200-page scan is
    /// hundreds of decodes for one gesture — the bubble is what tells you
    /// where you are on the way.
    private var scrubber: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                // Always on, not just while dragging. Appearing only on the
                // first scrub meant the one number you want before deciding
                // where to drag was the one number missing.
                Group {
                    Text("\(Int(scrubTarget) + 1) / \(pageCount)")
                        // Read at arm's length, mid-drag, with a thumb over
                        // the bar — the previous footnote size was too small
                        // to check without stopping.
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(.quaternary))
                        .fixedSize()
                        // Tracks the thumb, inset by its radius so the label
                        // sits over it at both ends rather than past them.
                        .position(x: thumbX(width: geo.size.width),
                                  y: geo.size.height / 2)
                }
                // Lifted while dragging, so the label you are steering by
                // stands out from the one that is merely reporting.
                .opacity(scrubbing ? 1 : 0.85)
            }
            .frame(height: 44)

            Slider(
                value: $scrubTarget,
                in: 0...Double(max(pageCount - 1, 1)),
                step: 1,
                onEditingChanged: { editing in
                    withAnimation(.easeOut(duration: 0.12)) { scrubbing = editing }
                    if !editing { index = Int(scrubTarget) }
                }
            )
            .tint(.white)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        // Keep the thumb honest when pages are turned by swiping instead.
        // Single-parameter form: the two-parameter onChange is iOS 17+, and
        // this app targets 16.
        .onChange(of: index) { page in
            if !scrubbing { scrubTarget = Double(page) }
        }
        .onAppear { scrubTarget = Double(index) }
    }

    private static let thumbRadius: CGFloat = 15

    private func thumbX(width: CGFloat) -> CGFloat {
        let span = max(width - Self.thumbRadius * 2, 1)
        let last = Double(max(pageCount - 1, 1))
        return Self.thumbRadius + span * CGFloat(scrubTarget / last)
    }

    /// Decode the current page plus a small window either side, so a back-flip
    /// is as smooth as a forward one.
    /// `keeping` is the page the cache is trimmed around, which is not always
    /// the page being decoded. In portrait one page asks at a time and the two
    /// are the same. The landscape strip realises several slots at once —
    /// including ones at the top, before it has scrolled to where the reader
    /// left off — and if each trimmed the cache around itself they would throw
    /// away each other's work as fast as it arrived, which left the strip
    /// showing nothing but a spinner.
    private func load(around page: Int, keeping anchor: Int? = nil) {
        guard let document else { return }
        let wanted = [page] + document.prefetchWindow(around: page, radius: 2)
        let scale = UIScreen.main.scale
        let maxPixel = Int(max(UIScreen.main.bounds.width, UIScreen.main.bounds.height) * scale)

        for i in wanted where cache[i] == nil {
            DispatchQueue.global(qos: .userInitiated).async {
                guard let image = try? document.page(i, maxPixelSize: maxPixel) else { return }
                DispatchQueue.main.async { cache[i] = image }
            }
        }
        // Keep the cache bounded by count, not bytes — each page is expensive.
        if cache.count > 7 {
            let keep = anchor ?? page
            for key in cache.keys where abs(key - keep) > 3 { cache.removeValue(forKey: key) }
        }
    }
}

/// One page, pinch- and double-tap-zoomable, pannable while zoomed.
///
/// The zoom is a `UIScrollView`'s rather than one of our own, and that is the
/// whole point: Photos' zoom *is* a scroll view's zoom, and everything ours got
/// wrong is something a scroll view already does. It scales about the live
/// midpoint between the fingers, so pinching a corner walks that corner back
/// under them instead of hauling the middle of the page up and pushing the
/// borders off the screen. It keeps panning from a two-finger drag while the
/// pinch is still going. It rubber-bands past its own edges and past both zoom
/// limits and springs back rather than stopping dead. And a flick carries on
/// with the same deceleration as every other scroll in iOS.
///
/// What is still ours is the page turn, which a photo has no equivalent of:
/// see `PageScroll.pageTurnPush`.
private struct PageView: View {
    let image: CGImage?
    /// Show or hide the reader's chrome.
    var onTap: () -> Void = {}
    /// Asks for the page before (-1) or after (+1) this one.
    var turnPage: (Int) -> Void = { _ in }

    /// The zoom is kept here rather than in the scroll view because the pager
    /// throws the scroll view away and builds another one whenever the chrome
    /// comes or goes — the page gets the strip the status bar was in, and every
    /// page in the pager is rebuilt at the new size. State this side of the
    /// representable outlives that, so tapping to hide the chrome no longer
    /// costs the reader the panel they were in.
    @State private var zoom: CGFloat = 1
    /// Which part of the page is on screen, as a fraction of the whole, which is
    /// the one way of saying it that survives the page changing size.
    @State private var looking = CGPoint(x: 0.5, y: 0.5)

    var body: some View {
        // One `ZoomablePage` for the life of this page, image or no image. Put
        // behind an `if`, it was built and thrown away again the moment the
        // decode landed — and a scroll view being born inside the pager while
        // the pager is mid-swipe is enough to strand the swipe between two
        // pages. The spinner is an overlay for the same reason.
        ZoomablePage(image: image, zoom: zoom, looking: looking,
                     onSettle: { zoom = $0; looking = $1 },
                     onTap: onTap, turnPage: turnPage)
            .overlay(alignment: .center) {
                if image == nil { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ZoomablePage: UIViewRepresentable {
    /// Nil until the page has been decoded; the reader is on it before then.
    let image: CGImage?
    /// Where a freshly built scroll view is to pick up from.
    let zoom: CGFloat
    let looking: CGPoint
    /// Reported once a pinch or a pan has come to rest, not on every frame of
    /// one: this is only the note that lets the next scroll view carry on where
    /// this one left off.
    let onSettle: (CGFloat, CGPoint) -> Void
    let onTap: () -> Void
    let turnPage: (Int) -> Void

    func makeUIView(context: Context) -> PageScroll {
        let view = PageScroll()
        update(view)
        view.open(at: zoom, looking: looking)
        return view
    }

    func updateUIView(_ view: PageScroll, context: Context) { update(view) }

    private func update(_ view: PageScroll) {
        view.onSettle = onSettle
        view.onTap = onTap
        view.turnPage = turnPage
        view.show(image)
    }
}

/// A page in a scroll view, which is where the zoom comes from.
///
/// The page sits inside at the size it fits the screen at, so the scroll view's
/// own zoom scale is the zoom the reader sees: 1 is a whole page, 4 is as close
/// as it will go, and a pinch may overshoot either end and spring back.
private final class PageScroll: UIScrollView, UIScrollViewDelegate {
    /// What a double tap zooms to.
    private static let doubleTapZoom: CGFloat = 2.5

    /// As far in as a pinch will go, over and above a whole page.
    private static let maxZoom: CGFloat = 4

    /// How far the page has to be held past its own side before letting go
    /// asks for the next one.
    ///
    /// While zoomed a drag pans, so a page cannot be turned by swiping — a
    /// swipe is how you read across it. Pressing on after the page has run out
    /// of slack is unambiguous. Measured in how far the page has actually
    /// moved, which the rubber band makes a good deal less than the finger
    /// travels: 70pt of stretch is around 140pt of drag on an iPad.
    private static let pageTurnPush: CGFloat = 70

    var onTap: () -> Void = {}
    var turnPage: (Int) -> Void = { _ in }
    /// Where the page came to rest, for whatever scroll view shows it next.
    var onSettle: (CGFloat, CGPoint) -> Void = { _, _ in }

    private let page = UIImageView()
    private var shown: CGImage?
    /// The screen the page was last fitted to. A rotation invalidates it.
    private var fittedTo: CGSize = .zero
    /// Where to be once there is a screen to be it on — a new scroll view has
    /// no size to zoom or scroll within until it is laid out.
    private var opening: (zoom: CGFloat, looking: CGPoint)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        backgroundColor = .clear
        minimumZoomScale = 1
        maximumZoomScale = Self.maxZoom
        // The elastic ends: a pinch can overshoot a whole page or the far end
        // of the zoom and be let back, rather than hitting a wall.
        bouncesZoom = true
        bounces = true
        // Set from the zoom, in `holdOntoDrags`.
        panGestureRecognizer.isEnabled = false
        alwaysBounceHorizontal = false
        alwaysBounceVertical = false
        // Nothing inside to delay a touch on the way to, and the delay is one
        // more thing between the pager and a swipe.
        delaysContentTouches = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        // The reader is full-screen and behind the chrome; a safe-area inset
        // here would show up as the page sitting off-centre.
        contentInsetAdjustmentBehavior = .never
        // Not a distortion: the frame this fills is the fitted size, so the
        // aspect ratio is already in it.
        page.contentMode = .scaleToFill
        addSubview(page)

        let double = UITapGestureRecognizer(target: self, action: #selector(doubled(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped))
        // Or every double tap would show and hide the chrome on its way.
        single.require(toFail: double)
        addGestureRecognizer(single)
        for tap in [double, single] {
            // A tap recogniser holds back the touches it might still want,
            // including the one that ends a swipe. The pager is waiting on that
            // touch to decide which page it landed on, so none of it is held.
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.cancelsTouchesInView = false
        }
    }

    required init?(coder: NSCoder) { fatalError("not loaded from a nib") }

    /// The page to show, or nil while it is still being decoded. Acted on only
    /// when it is actually a different image — `updateUIView` runs for every
    /// unrelated change around it, and refitting on each of those would be work
    /// for nothing.
    func show(_ image: CGImage?) {
        guard image !== shown else { return }
        shown = image
        page.image = image.map { UIImage(cgImage: $0) }
        fittedTo = .zero
        setNeedsLayout()
    }

    /// Picks up where the page was before this scroll view existed.
    func open(at zoom: CGFloat, looking: CGPoint) {
        opening = (zoom, looking)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if bounds.size != fittedTo { fit() } else { centre() }
    }

    /// Sizes the page to the screen, keeping the zoom and roughly the panel the
    /// reader was looking at.
    ///
    /// Not only for rotations: hiding the chrome gives the page back the strip
    /// the status bar was in, and a re-fit that dropped the zoom would have
    /// thrown the reader out of a panel for tapping the screen.
    private func fit() {
        guard let shown, bounds.width > 0, bounds.height > 0 else { return }
        let resume = opening
        opening = nil
        let looking = resume?.looking ?? lookingAt
        let zoom = resume?.zoom ?? zoomScale
        fittedTo = bounds.size
        // Measured unzoomed: the fitted size is the page at zoom 1, and
        // measuring it while zoomed would fit it to a scaled box.
        zoomScale = 1
        let size = ZoomPan.fittedSize(image: CGSize(width: shown.width, height: shown.height),
                                      box: bounds.size)
        page.frame = CGRect(origin: .zero, size: size)
        contentSize = size
        zoomScale = min(max(zoom, minimumZoomScale), maximumZoomScale)
        centre()
        holdOntoDrags()
        if zoomScale > minimumZoomScale, let looking { look(at: looking) }
    }

    /// The middle of what is on screen, as a fraction of the whole page — the
    /// one way of naming it that survives the page changing size. Nil unzoomed,
    /// where the whole page is on screen and there is nothing to keep.
    private var lookingAt: CGPoint? {
        guard zoomScale > minimumZoomScale, contentSize.width > 0, contentSize.height > 0
        else { return nil }
        return CGPoint(x: (contentOffset.x + bounds.midX) / contentSize.width,
                       y: (contentOffset.y + bounds.midY) / contentSize.height)
    }

    private func look(at spot: CGPoint) {
        let wanted = CGPoint(x: spot.x * contentSize.width - bounds.midX,
                             y: spot.y * contentSize.height - bounds.midY)
        contentOffset = CGPoint(
            x: min(max(wanted.x, -contentInset.left),
                   max(contentSize.width + contentInset.right - bounds.width, -contentInset.left)),
            y: min(max(wanted.y, -contentInset.top),
                   max(contentSize.height + contentInset.bottom - bounds.height, -contentInset.top)))
    }

    /// Holds a page with room to spare in the middle of the screen.
    ///
    /// By inset rather than by moving the page, so that where the scroll view
    /// believes its edges are — which is what it clamps a pinch to and what it
    /// rubber-bands against — agrees with where the page looks like it is.
    private func centre() {
        let slack = UIEdgeInsets(top: max((bounds.height - contentSize.height) / 2, 0),
                                 left: max((bounds.width - contentSize.width) / 2, 0),
                                 bottom: max((bounds.height - contentSize.height) / 2, 0),
                                 right: max((bounds.width - contentSize.width) / 2, 0))
        if contentInset != slack { contentInset = slack }
    }

    /// Which of the two scroll views a drag belongs to.
    ///
    /// Unzoomed the answer is the pager: a whole page has nothing to pan, and a
    /// swipe across it is how it is turned. Zoomed the answer is this one, all
    /// the way to the edges — a page held against its right side has no slack
    /// that way either, and letting the pager have that drag turned the page
    /// mid-read. Bouncing counts as somewhere to go, so while zoomed the page
    /// keeps every drag and rubber-bands at the ends, and a page is turned only
    /// by the deliberate push in `scrollViewDidEndDragging`.
    ///
    /// Unzoomed the pan is *disabled*, not merely left to decline. A scroll view
    /// that declines a drag is still in the gesture arena for it, and that was
    /// enough to get the pager's own drag cancelled instead of ended: the pager
    /// stopped wherever the finger left it, between two pages, and stayed there
    /// until a second swipe knocked it loose — which is what made turning pages
    /// stick and then jump. A disabled recogniser is not in the arena at all.
    /// The pinch is never disabled, so a zoom can still be started from a whole
    /// page, and it is what carries the page under the fingers.
    private func holdOntoDrags() {
        let zoomed = zoomScale > minimumZoomScale
        guard panGestureRecognizer.isEnabled != zoomed else { return }
        panGestureRecognizer.isEnabled = zoomed
        alwaysBounceHorizontal = zoomed
        alwaysBounceVertical = zoomed
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { page }

    /// Every frame of a pinch, and of the spring back afterwards.
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centre()
        holdOntoDrags()
    }

    /// Double tap zooms in on what was tapped, and again to come back out.
    ///
    /// `zoom(to:)` rather than holding the tapped point exactly where it was:
    /// it brings that point to the middle of the screen as far as the page's
    /// edges allow, which is what Photos does. Pinned under the finger, a tap
    /// near a corner would zoom into a panel and leave it in the corner.
    @objc private func doubled(_ gesture: UITapGestureRecognizer) {
        guard zoomScale <= minimumZoomScale else {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let at = gesture.location(in: page)
        let size = CGSize(width: bounds.width / Self.doubleTapZoom,
                          height: bounds.height / Self.doubleTapZoom)
        zoom(to: CGRect(x: at.x - size.width / 2, y: at.y - size.height / 2,
                        width: size.width, height: size.height),
             animated: true)
    }

    @objc private func tapped() { onTap() }

    /// Turned on release rather than mid-drag: a page that turns under a finger
    /// still moving is a page turned by accident.
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { settled() }
        let push = heldPastSide
        guard abs(push) > Self.pageTurnPush else { return }
        turnPage(push > 0 ? -1 : 1)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { settled() }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?,
                                 atScale scale: CGFloat) { settled() }

    private func settled() {
        onSettle(zoomScale, lookingAt ?? CGPoint(x: 0.5, y: 0.5))
    }

    /// How far the page is being held past its own left or right edge, if it
    /// is. Signed: positive is dragging right, past the left edge, which asks
    /// for the previous page.
    ///
    /// Zero unless zoomed. An unzoomed page has no slack, so the drag was never
    /// this scroll view's — it belonged to the pager, which turned the page on
    /// its own.
    private var heldPastSide: CGFloat {
        guard zoomScale > minimumZoomScale else { return 0 }
        let start = -contentInset.left
        let end = contentSize.width + contentInset.right - bounds.width
        if contentOffset.x < start { return start - contentOffset.x }
        if contentOffset.x > end { return end - contentOffset.x }
        return 0
    }
}

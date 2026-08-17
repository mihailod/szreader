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
/// Every gesture here is a UIKit recogniser, laid over the page by
/// `PageGestures`. That is not a preference: SwiftUI's `MagnificationGesture`
/// never says *where* a pinch is, so a page could only be scaled about its own
/// middle. Once one gesture has to come from UIKit they all do — a
/// representable laid over the page wins SwiftUI's hit-testing outright, and
/// the tap, double tap and drag attached to the image behind it simply stop
/// being offered the touch.
private struct PageView: View {
    let image: CGImage?
    /// Show or hide the reader's chrome.
    var onTap: () -> Void = {}
    /// Asks for the page before (-1) or after (+1) this one.
    var turnPage: (Int) -> Void = { _ in }

    /// How far a drag has to carry on past the edge of a zoomed page before it
    /// is taken as asking for the next one.
    ///
    /// While zoomed the drag pans, so a page cannot be turned by swiping — a
    /// swipe is how you read across it. Pressing on after the page has stopped
    /// moving is unambiguous, and far enough not to happen at the end of an
    /// ordinary pan.
    private static let pageTurnPush: CGFloat = 90

    /// What a double tap zooms to.
    private static let doubleTapZoom: CGFloat = 2.5

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    /// Where the fingers were when the pinch began, from the middle of the box.
    @State private var pinchPoint: CGSize = .zero
    @State private var pinching = false
    /// How far the current drag has gone beyond the edge it is pressed
    /// against, if it has. Signed: positive is dragging right, past the left
    /// edge, which asks for the previous page.
    @State private var pushedPast: CGFloat = 0

    private var imageSize: CGSize {
        guard let image else { return .zero }
        return CGSize(width: image.width, height: image.height)
    }

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .offset(offset)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .overlay(PageGestures(
                            zoomed: zoom > 1,
                            onPinch: { scale, at in pinch(scale, at: at, in: geo.size) },
                            onPinchEnd: { endPinch() },
                            onPan: { moved, ended in
                                panned(moved, ended: ended, in: geo.size)
                            },
                            onTap: onTap,
                            onDoubleTap: { at in toggleZoom(at: at, in: geo.size) }))
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    /// Zooms about the fingers rather than about the middle of the page.
    ///
    /// The point is read once, when the pinch starts. Following the midpoint
    /// as the fingers move would slide the page under a pinch that drifts,
    /// which feels like the page fighting back.
    private func pinch(_ scale: CGFloat, at point: CGPoint, in box: CGSize) {
        if !pinching {
            pinching = true
            pinchPoint = CGSize(width: point.x - box.width / 2,
                                height: point.y - box.height / 2)
        }
        let wanted = min(max(committedZoom * scale, 1), 4)
        // Re-clamped as it shrinks, so zooming out walks the page back to
        // centre rather than leaving it stranded off-screen.
        offset = ZoomPan.focused(committedOffset, pinch: pinchPoint,
                                 from: committedZoom, to: wanted,
                                 image: imageSize, box: box)
        zoom = wanted
    }

    private func endPinch() {
        pinching = false
        committedZoom = zoom
        committedOffset = offset
        if zoom == 1 { resetPan() }
    }

    /// Drag to move around a zoomed page — and, at an edge, to leave it.
    ///
    /// The page moves in whatever direction it has slack, which is what makes
    /// fine print readable. Turning a page while zoomed cannot also be a
    /// swipe, so it is a push: carry on past the edge by `pageTurnPush` after
    /// the page has stopped moving, and let go.
    private func panned(_ translation: CGSize, ended: Bool, in box: CGSize) {
        let moved = CGSize(width: committedOffset.width + translation.width,
                           height: committedOffset.height + translation.height)
        offset = ZoomPan.clamp(moved, image: imageSize, box: box, zoom: zoom)
        // Whatever the clamp refused is the reader pressing on.
        pushedPast = moved.width - offset.width
        guard ended else { return }
        committedOffset = offset
        // On release rather than mid-drag: a page that turns under a finger
        // still moving is a page turned by accident.
        if abs(pushedPast) > Self.pageTurnPush { turnPage(pushedPast > 0 ? -1 : 1) }
        pushedPast = 0
    }

    /// Double tap zooms in on what was tapped, and again to come back out.
    private func toggleZoom(at point: CGPoint, in box: CGSize) {
        let wanted: CGFloat = zoom > 1 ? 1 : Self.doubleTapZoom
        let at = CGSize(width: point.x - box.width / 2, height: point.y - box.height / 2)
        let landing = ZoomPan.focused(committedOffset, pinch: at,
                                      from: zoom, to: wanted,
                                      image: imageSize, box: box)
        withAnimation(.spring(duration: 0.25)) {
            zoom = wanted
            offset = landing
        }
        committedZoom = wanted
        committedOffset = landing
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}

/// Every touch on a page, in UIKit, so that a pinch can say where it is.
///
/// Laid over the page. Recognises simultaneously with everything around it,
/// and the pan only begins while the page is zoomed — so an unzoomed swipe
/// still belongs to the pager underneath, exactly as it did. While zoomed the
/// pager is made to wait on this pan instead, which is what lets a zoomed page
/// be read across without flicking to the next one.
private struct PageGestures: UIViewRepresentable {
    let zoomed: Bool
    let onPinch: (CGFloat, CGPoint) -> Void
    let onPinchEnd: () -> Void
    /// Translation since the drag began, and whether it has finished.
    let onPan: (CGSize, Bool) -> Void
    let onTap: () -> Void
    let onDoubleTap: (CGPoint) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let c = context.coordinator

        let pinch = UIPinchGestureRecognizer(target: c, action: #selector(Coordinator.pinched(_:)))
        let pan = UIPanGestureRecognizer(target: c, action: #selector(Coordinator.panned(_:)))
        let double = UITapGestureRecognizer(target: c, action: #selector(Coordinator.doubled(_:)))
        double.numberOfTapsRequired = 2
        let single = UITapGestureRecognizer(target: c, action: #selector(Coordinator.tapped(_:)))
        // Or every double tap would show and hide the chrome on its way.
        single.require(toFail: double)

        for gesture in [pinch, pan, double, single] as [UIGestureRecognizer] {
            gesture.delegate = c
            view.addGestureRecognizer(gesture)
        }
        c.pan = pan
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.zoomed = zoomed
        context.coordinator.onPinch = onPinch
        context.coordinator.onPinchEnd = onPinchEnd
        context.coordinator.onPan = onPan
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
        context.coordinator.deferPager(around: view)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(zoomed: zoomed, onPinch: onPinch, onPinchEnd: onPinchEnd,
                    onPan: onPan, onTap: onTap, onDoubleTap: onDoubleTap)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var zoomed: Bool
        var onPinch: (CGFloat, CGPoint) -> Void
        var onPinchEnd: () -> Void
        var onPan: (CGSize, Bool) -> Void
        var onTap: () -> Void
        var onDoubleTap: (CGPoint) -> Void
        weak var pan: UIPanGestureRecognizer?
        private var pagerDeferred = false

        init(zoomed: Bool, onPinch: @escaping (CGFloat, CGPoint) -> Void,
             onPinchEnd: @escaping () -> Void, onPan: @escaping (CGSize, Bool) -> Void,
             onTap: @escaping () -> Void, onDoubleTap: @escaping (CGPoint) -> Void) {
            self.zoomed = zoomed; self.onPinch = onPinch; self.onPinchEnd = onPinchEnd
            self.onPan = onPan; self.onTap = onTap; self.onDoubleTap = onDoubleTap
        }

        /// Makes the pager's own scrolling wait for this pan to fail.
        ///
        /// Once, when the view has a place in the hierarchy. Both gestures are
        /// drags across the same pixels, and without an order between them the
        /// winner is whichever recognised first — which is how a pan across a
        /// zoomed page turned the page instead of reading across it. The pan
        /// declines to begin unless the page is zoomed, so an ordinary swipe
        /// still reaches the pager untouched.
        func deferPager(around view: UIView) {
            guard !pagerDeferred, let pan else { return }
            var ancestor: UIView? = view.superview
            while let here = ancestor {
                if let scroll = here as? UIScrollView {
                    scroll.panGestureRecognizer.require(toFail: pan)
                    pagerDeferred = true
                    return
                }
                ancestor = here.superview
            }
        }

        @objc func pinched(_ gesture: UIPinchGestureRecognizer) {
            switch gesture.state {
            case .began, .changed:
                onPinch(gesture.scale, gesture.location(in: gesture.view))
            case .ended, .cancelled, .failed:
                onPinchEnd()
            default:
                break
            }
        }

        @objc func panned(_ gesture: UIPanGestureRecognizer) {
            let moved = gesture.translation(in: gesture.view)
            let ended = gesture.state == .ended || gesture.state == .cancelled
            onPan(CGSize(width: moved.x, height: moved.y), ended)
        }

        @objc func tapped(_ gesture: UITapGestureRecognizer) { onTap() }

        @objc func doubled(_ gesture: UITapGestureRecognizer) {
            onDoubleTap(gesture.location(in: gesture.view))
        }

        /// A page that is not zoomed has nowhere to pan, so the drag belongs
        /// to the pager.
        func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
            gesture === pan ? zoomed : true
        }

        func gestureRecognizer(_ gesture: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer)
            -> Bool { true }
    }
}

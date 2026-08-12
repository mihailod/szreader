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
                            .onTapGesture { withAnimation { chromeVisible.toggle() } }
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
                PageView(image: cache[page])
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
            VerticalScrubber(pageCount: pageCount, page: index,
                             edge: .leading) { seek = $0 }
            Spacer()
            VerticalScrubber(pageCount: pageCount, page: index,
                             edge: .trailing) { seek = $0 }
        }
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

/// One page, pinch- and double-tap-zoomable.
private struct PageView: View {
    let image: CGImage?

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

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
                        // High priority, so the pan starts tracking the moment
                        // the finger moves. As an ordinary gesture it lost the
                        // arbitration with the paging TabView underneath and
                        // only resolved on release — which is why the page sat
                        // still and then jumped.
                        //
                        // Still only while zoomed in: at zoom 1 the drag must
                        // reach the TabView, or a swipe would pan a page with
                        // nowhere to go instead of turning it.
                        .highPriorityGesture(pan(in: geo.size),
                                             including: zoom > 1 ? .all : .subviews)
                        .simultaneousGesture(magnify(in: geo.size))
                        .onTapGesture(count: 2) { toggleZoom(in: geo.size) }
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    private func magnify(in box: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoom = min(max(committedZoom * value, 1), 4)
                // Re-clamped as it shrinks, so zooming out walks the page back
                // to centre rather than leaving it stranded off-screen.
                offset = ZoomPan.clamp(committedOffset, image: imageSize, box: box, zoom: zoom)
            }
            .onEnded { _ in
                committedZoom = zoom
                committedOffset = offset
                if zoom == 1 { resetPan() }
            }
    }

    private func pan(in box: CGSize) -> some Gesture {
        // Zero minimum distance: waiting for the default 10pt threshold before
        // the first update is felt as the page lagging the finger.
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let moved = CGSize(width: committedOffset.width + value.translation.width,
                                   height: committedOffset.height + value.translation.height)
                offset = ZoomPan.clamp(moved, image: imageSize, box: box, zoom: zoom)
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func toggleZoom(in box: CGSize) {
        withAnimation(.spring(duration: 0.25)) {
            if zoom > 1 {
                zoom = 1
                committedZoom = 1
                resetPan()
            } else {
                zoom = 2.5
                committedZoom = 2.5
                offset = ZoomPan.clamp(offset, image: imageSize, box: box, zoom: zoom)
                committedOffset = offset
            }
        }
    }

    private func resetPan() {
        offset = .zero
        committedOffset = .zero
    }
}

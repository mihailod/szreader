import CoreGraphics
import SwiftUI
import SZKit

/// Landscape reading: the whole comic as one strip that scrolls continuously,
/// the way a long web page does.
///
/// Not a pager. Discrete page turns were the wrong shape for landscape — a
/// page is taller than the screen there, so every page needed panning *and*
/// a turn at the end of it, which meant one gesture doing two jobs and an
/// edge to fight at every page break. Scrolling has neither: pages simply run
/// into each other, with momentum, and the page number follows along.
struct ContinuousPages: View {
    let pageCount: Int
    /// The decoded page, when there is one. Owned by the reader's cache.
    let image: (Int) -> CGImage?
    /// Asks the reader to decode around this page.
    let loadAround: (Int) -> Void
    /// The page in the middle of the screen, reported back as it changes.
    @Binding var currentPage: Int
    /// A page the scrubbers have asked to jump to. Cleared once obeyed.
    @Binding var seek: Int?
    /// The page to open on. Read once, when the strip appears — which is
    /// also every time the device rotates, so this has to be the reader's
    /// current page rather than the one the comic was opened at.
    let openAt: Int
    let onTap: () -> Void

    @State private var zoom: CGFloat = 1
    @State private var committedZoom: CGFloat = 1
    /// The shape of a page, which fixes how tall every slot in the strip is.
    ///
    /// Uniform on purpose. Sizing each slot to its own page would mean
    /// knowing all 200 page sizes up front — every page read off disk before
    /// the first one appears — and leaving them to size themselves as they
    /// decode makes the strip grow and shrink under the reader's thumb. A
    /// scanned run is one shape throughout, so the first page to arrive
    /// settles it for all of them.
    @State private var aspect: CGFloat = 1.5
    @State private var aspectKnown = false
    /// Set once the strip has been scrolled to the resumed page. Until then
    /// the strip sits at the top and must not report page 1 as the place the
    /// reader has got to — that would overwrite where they actually were.
    @State private var ready = false

    var body: some View {
        GeometryReader { geo in
            let slotW = geo.size.width * zoom
            let slotH = geo.size.width * aspect * zoom

            ScrollViewReader { proxy in
                // Both axes: at zoom 1 the strip is exactly the width of the
                // screen and only scrolls down, and zooming in makes it wider
                // than the screen, which is what turns on sideways panning.
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(0..<max(pageCount, 1), id: \.self) { page in
                            slot(page, width: slotW, height: slotH)
                        }
                    }
                    .frame(width: slotW)
                    .onTapGesture(count: 2) { toggleZoom() }
                    .onTapGesture { onTap() }
                }
                .onPreferenceChange(CentrePageKey.self) { page in
                    report(page)
                }
                .onAppear { open(with: proxy) }
                .onChange(of: seek) { wanted in
                    guard let wanted else { return }
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(wanted, anchor: .top)
                    }
                    seek = nil
                }
            }
            .simultaneousGesture(magnify)
        }
    }

    private func slot(_ page: Int, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let decoded = image(page) {
                Image(decorative: decoded, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ProgressView().tint(.white)
            }
        }
        .frame(width: width, height: height)
        .background(centreMarker(page))
        .id(page)
        .onAppear {
            loadAround(page)
            if let decoded = image(page) { adopt(decoded) }
        }
        // The page usually decodes after its slot is already on screen, which
        // is the moment its shape becomes known.
        .onChange(of: image(page) == nil) { missing in
            if !missing, let decoded = image(page) { adopt(decoded) }
        }
    }

    /// Each slot says whether it is the one under the middle of the screen.
    ///
    /// Measured per slot, in global coordinates. Reading the strip's own
    /// offset instead — one geometry reader behind the whole stack — looked
    /// tidier and does not work: that background is measured once and never
    /// again while the scrolling happens, so the page number never moved. A
    /// slot's own frame does keep up, because the slot is what is moving.
    private func centreMarker(_ page: Int) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global)
            let middle = UIScreen.main.bounds.midY
            Color.clear.preference(
                key: CentrePageKey.self,
                value: frame.minY <= middle && frame.maxY > middle ? page : nil)
        }
    }

    /// Puts the reader back where they stopped.
    private func open(with proxy: ScrollViewProxy) {
        guard !ready, pageCount > 0 else { return }
        loadAround(openAt)
        // A frame later: the strip does not exist to be scrolled until it has
        // been laid out once.
        DispatchQueue.main.async {
            proxy.scrollTo(openAt, anchor: .top)
            ready = true
        }
    }

    private func adopt(_ decoded: CGImage) {
        guard !aspectKnown, decoded.width > 0, decoded.height > 0 else { return }
        aspectKnown = true
        aspect = CGFloat(decoded.height) / CGFloat(decoded.width)
        // Every slot just changed height, so the strip is no longer showing
        // what it was. Put it back on the same page.
        seek = currentPage
    }

    /// Whatever is halfway down the screen is what is being read.
    private func report(_ page: Int?) {
        guard ready, let page, page != currentPage else { return }
        currentPage = min(max(page, 0), max(pageCount - 1, 0))
    }

    private var magnify: some Gesture {
        MagnificationGesture()
            .onChanged { value in zoom = min(max(committedZoom * value, 1), 4) }
            .onEnded { _ in committedZoom = zoom }
    }

    private func toggleZoom() {
        withAnimation(.spring(duration: 0.25)) {
            zoom = zoom > 1 ? 1 : 2.5
            committedZoom = zoom
        }
    }
}

/// The page sitting under the middle of the screen, if a slot claims it.
private struct CentrePageKey: PreferenceKey {
    static var defaultValue: Int?
    static func reduce(value: inout Int?, nextValue: () -> Int?) {
        value = value ?? nextValue()
    }
}

/// A vertical position control, pinned down one edge of the screen.
///
/// There are two of these, one on each side, and they are the same control.
/// Which edge falls under a thumb depends on which hand the iPad is being
/// held in, and a reader should not have to change hands to move around the
/// comic.
struct VerticalScrubber: View {
    let pageCount: Int
    /// Where the reader currently is, when they are not dragging this.
    let page: Int
    /// Which side this one is on, so its readout sits inboard of the track
    /// rather than off the edge of the screen.
    let edge: HorizontalEdge
    let onSeek: (Int) -> Void

    @State private var dragging = false
    @State private var target = 0

    private static let trackWidth: CGFloat = 5
    private static let thumb: CGFloat = 26
    /// Wider than the track: a 5pt target is not something a thumb can find.
    private static let touchWidth: CGFloat = 44

    /// The page the readout is showing — the drag while there is one, and
    /// where the strip has reached otherwise.
    private var shown: Int { dragging ? target : page }

    var body: some View {
        GeometryReader { geo in
            let travel = max(geo.size.height - Self.thumb, 1)
            let y = Self.thumb / 2 + travel * fraction

            ZStack(alignment: .top) {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: Self.trackWidth)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Circle()
                    .fill(.white)
                    .shadow(radius: 2)
                    .frame(width: Self.thumb, height: Self.thumb)
                    .position(x: geo.size.width / 2, y: y)

                readout
                    .position(x: readoutX(in: geo.size.width), y: y)
            }
            .contentShape(Rectangle())
            .gesture(drag(travel: travel, height: geo.size.height))
        }
        .frame(width: Self.touchWidth)
    }

    private var fraction: CGFloat {
        guard pageCount > 1 else { return 0 }
        return CGFloat(shown) / CGFloat(pageCount - 1)
    }

    private var readout: some View {
        Text("\(shown + 1) / \(pageCount)")
            .font(.subheadline.weight(.semibold).monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(.quaternary))
            .fixedSize()
            .opacity(dragging ? 1 : 0.85)
    }

    /// Inboard of the track, so it is never half off the screen.
    private func readoutX(in width: CGFloat) -> CGFloat {
        edge == .leading ? width + 52 : -52
    }

    private func drag(travel: CGFloat, height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragging = true
                let along = (value.location.y - Self.thumb / 2) / travel
                target = min(max(Int((along * CGFloat(max(pageCount - 1, 1))).rounded()), 0),
                             max(pageCount - 1, 0))
            }
            .onEnded { _ in
                dragging = false
                // Seeking on release, not while dragging: following the drag
                // would decode every page it crossed, and on a 200-page comic
                // that is hundreds of decodes for one gesture. The readout is
                // what tells you where you are on the way.
                onSeek(target)
            }
    }
}

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
    let document: ComicDocument
    let title: String

    @Environment(\.dismiss) private var dismiss
    @State private var index = 0
    @State private var cache: [Int: CGImage] = [:]
    @State private var chromeVisible = true
    /// Where the scrubber's thumb is, which is only the same as `index` when
    /// the user is not dragging it.
    @State private var scrubTarget: Double = 0
    @State private var scrubbing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TabView(selection: $index) {
                ForEach(0..<max(document.pageCount, 1), id: \.self) { page in
                    PageView(image: cache[page])
                        .tag(page)
                        .onAppear { load(around: page) }
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
            .onTapGesture { withAnimation { chromeVisible.toggle() } }

            if chromeVisible { chrome }
        }
        .statusBarHidden(!chromeVisible)
        .onAppear { load(around: 0) }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark.circle.fill").font(.title2)
                }
                Spacer()
                Text(title).font(.headline)
                Spacer()
                Text("\(index + 1) / \(document.pageCount)")
                    .font(.subheadline.monospacedDigit())
            }
            .padding()
            .background(.ultraThinMaterial)

            Spacer()

            // A single page is not worth a scrubber.
            if document.pageCount > 1 { scrubber }
        }
        .foregroundStyle(.primary)
        .transition(.opacity)
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
                    Text("\(Int(scrubTarget) + 1) / \(document.pageCount)")
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
                in: 0...Double(max(document.pageCount - 1, 1)),
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
        let last = Double(max(document.pageCount - 1, 1))
        return Self.thumbRadius + span * CGFloat(scrubTarget / last)
    }

    /// Decode the current page plus a small window either side, so a back-flip
    /// is as smooth as a forward one.
    private func load(around page: Int) {
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
            for key in cache.keys where abs(key - page) > 3 { cache.removeValue(forKey: key) }
        }
    }
}

/// One page, pinch- and double-tap-zoomable.
private struct PageView: View {
    let image: CGImage?
    @State private var zoom: CGFloat = 1
    @State private var committed: CGFloat = 1

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(zoom)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { zoom = min(max(committed * $0, 1), 4) }
                                .onEnded { _ in committed = zoom }
                        )
                        .onTapGesture(count: 2) {
                            withAnimation(.spring(duration: 0.25)) {
                                zoom = zoom > 1 ? 1 : 2.5
                                committed = zoom
                            }
                        }
                } else {
                    ProgressView().tint(.white)
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }
}

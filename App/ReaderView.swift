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
        }
        .foregroundStyle(.primary)
        .transition(.opacity)
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

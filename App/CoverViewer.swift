import SwiftUI

/// The cover art, as large as the screen allows.
///
/// One control, and it gets out of the way. The reason to open this is to
/// look at the artwork, so a tap anywhere hides the Close button and a second
/// tap brings it back — the same gesture the reader uses for its chrome, so
/// there is one thing to learn rather than two.
struct CoverViewer: View {
    let url: String?
    /// Shown while the art loads, so the screen is not a blank black
    /// rectangle with nothing to say which issue it belongs to.
    let title: String
    /// The comic's own first page, when it is on disk.
    ///
    /// Preferred over the stored cover, which is a thumbnail either way — a
    /// 600px capture for downloaded issues, 150×200 from stripovi.com for the
    /// rest — and looks it at this size. Nil when there is nothing to open.
    var fullPage: (() async -> UIImage?)?

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var chromeShown = true

    var body: some View {
        ZStack {
            // Black rather than the system background: it is what a picture
            // is best looked at against, and it hides the letterboxing either
            // side of a page-shaped image on a wider screen.
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else if loaded {
                missing
            } else {
                ProgressView().tint(.white)
            }
        }
        // The whole screen takes the tap, including the black margins beside
        // the art — aiming at the picture itself to dismiss a control is a
        // needless bit of precision.
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.2)) { chromeShown.toggle() }
        }
        .overlay(alignment: .topLeading) {
            if chromeShown {
                Button { dismiss() } label: {
                    Label("Close", systemImage: "xmark.circle.fill")
                        .font(.title2)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .background(.ultraThinMaterial, in: Capsule())
                }
                .tint(.white)
                .padding(24)
                .transition(.opacity)
            }
        }
        .statusBarHidden()
        .task {
            // The cached thumbnail first, so there is something on screen
            // while the page is decoded — opening the archive and rendering a
            // full page is not instant on a 300MB comic.
            image = CoverStore.shared.cached(url, grayscale: false)
            if let fullPage, let page = await fullPage() {
                image = page
            } else if image == nil {
                image = await CoverStore.shared.image(url, grayscale: false)
            }
            loaded = true
        }
    }

    private var missing: some View {
        VStack(spacing: 12) {
            Image(systemName: "photo").font(.system(size: 64))
            Text(title).font(.title3)
            Text("No cover for this issue yet.").font(.callout)
        }
        .foregroundStyle(.white.opacity(0.7))
        .multilineTextAlignment(.center)
        .padding()
    }
}

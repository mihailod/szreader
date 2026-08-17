import SwiftUI
import SZKit
import UIKit

/// What the full-screen cover holds: the reader, or the grid of pages.
///
/// One view rather than two presentations, because `fullScreenCover(item:)`
/// snapshots its item once and never looks at it again — the same reason
/// `ReaderView` takes the model rather than a document. Switching stage inside
/// an observing view is what lets the reader hand over to the grid and back
/// without the screen being torn down and put up again.
///
/// Opening an issue always lands in the reader, exactly where it left off. The
/// grid was briefly offered first, behind a per-source switch and a "resume or
/// browse?" question, and both turned out to be answering a question nobody
/// had asked: the button in the reader's own chrome is where a reader looks
/// for it anyway, and it costs them nothing on the way in.
struct ReadingSurface: View {
    @ObservedObject var model: AppModel
    let comicID: Int
    let title: String

    private var stage: AppModel.OpenComic.Stage? { model.reading?.stage }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            switch stage {
            case .picking:
                PagePickerView(model: model, comicID: comicID, title: title)
            case .reading(let page):
                ReaderView(model: model, comicID: comicID, title: title, startPage: page)
            case .none:
                // Nothing open: the cover is on its way out.
                Color.clear
            }
        }
    }
}

/// Every page of an issue at a glance, to pick the one to start from.
///
/// A magazine is not read from the front: it is leafed through for the article
/// you remember, and neither a scrubber nor a page number tells you which of
/// eighty pages that is. The pictures do, which is exactly how the archive's
/// own index pages present them.
///
/// Thumbnails are rendered from the pages already on disk rather than fetched.
/// The obvious alternative was the archive's prerendered previews, and they
/// are real — but their URL is spelled differently for each of nineteen
/// series, and none of it is derivable from what a row holds. Rendering uses
/// what the app already does for covers, works for both sources, and works
/// with the iPad in a bag on a train.
struct PagePickerView: View {
    @ObservedObject var model: AppModel
    let comicID: Int
    let title: String

    @StateObject private var thumbnails = PageThumbnails()

    private var open: AppModel.OpenComic? { model.reading }
    private var document: ComicDocument? { open?.document }
    /// The catalogue's count until the archive is open, so the grid is laid
    /// out and scrolled to the right place before a single page is decoded.
    private var pageCount: Int { document?.pageCount ?? open?.pageCount ?? 0 }
    /// The page the reader stepped away from, when it is a real one.
    private var currentPage: Int? {
        guard let page = open?.atPage, page > 0, page < max(pageCount, 1) else { return nil }
        return page
    }

    /// Around 120pt a tile, which puts five across a 12.9" iPad in portrait
    /// and three across a phone — close to the archive's own five-up index.
    private let columns = [GridItem(.adaptive(minimum: 108, maximum: 190), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            bar
            if pageCount == 0 {
                Spacer()
                ProgressView().tint(.white).controlSize(.large)
                Spacer()
            } else {
                grid
            }
        }
        .background(Color.black)
        .onAppear {
            thumbnails.begin(issueID: comicID, library: model.library)
            thumbnails.use(document: document)
        }
        .onChange(of: document == nil) { _ in
            // The archive has finished opening: pages that could not be drawn
            // from the cache can be rendered now.
            thumbnails.use(document: document)
        }
    }

    /// Back to the page this was opened from, and nothing else.
    ///
    /// No way to close the issue from here: the grid is somewhere the reader
    /// stepped into from the reader, so the way out of it is back to what they
    /// were reading. Closing is still one tap further, where it has always
    /// been.
    private var bar: some View {
        HStack {
            Button { model.backToReading() } label: {
                Label("Back", systemImage: "chevron.left").font(.headline)
            }
            Spacer()
            VStack(spacing: 1) {
                Text(title).font(.headline).lineLimit(1)
                if pageCount > 0 {
                    Text("\(pageCount) pages").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            // Balances the leading button so the title sits in the middle.
            Label("Back", systemImage: "chevron.left").font(.headline).hidden()
        }
        .padding()
        .background(.ultraThinMaterial)
    }

    private var grid: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(0..<pageCount, id: \.self) { page in
                        PageTile(page: page,
                                 image: thumbnails.images[page],
                                 isCurrent: page == open?.atPage && page > 0)
                            .id(page)
                            .onAppear { thumbnails.want(page) }
                            .onTapGesture { model.read(page: page) }
                    }
                }
                .padding()
            }
            .onAppear {
                // Where you were, not the beginning: the page you stepped away
                // from is the one whose neighbours you came to look at.
                guard let currentPage else { return }
                scroll.scrollTo(currentPage, anchor: .center)
            }
        }
    }
}

/// One page in the grid: the picture, and the number under it.
private struct PageTile: View {
    let page: Int
    let image: UIImage?
    let isCurrent: Bool

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Rectangle()
                    .fill(Color(.secondarySystemBackground))
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            // A page is taller than it is wide, and the placeholder has to
            // hold that shape or the grid reflows under the reader's thumb as
            // the pictures arrive.
            .aspectRatio(0.72, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(isCurrent ? Color.accentColor : Color.white.opacity(0.15),
                              lineWidth: isCurrent ? 2.5 : 0.5))

            Text("\(page + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : .secondary)
        }
    }
}

/// Renders page thumbnails, one at a time, newest request first.
///
/// One at a time on purpose: a grid of three hundred tiles asks for everything
/// the moment it appears, and three hundred concurrent decodes is how an iPad
/// runs out of memory. Newest first because by the time a render finishes the
/// reader has usually scrolled somewhere else, and the tiles on screen are the
/// ones worth having.
@MainActor
final class PageThumbnails: ObservableObject {
    @Published private(set) var images: [Int: UIImage] = [:]

    private var issueID = 0
    private var library: Library?
    private var document: ComicDocument?
    private var wanted: [Int] = []
    private var asked: Set<Int> = []
    private var rendering = false

    func begin(issueID: Int, library: Library?) {
        guard self.library == nil else { return }
        self.issueID = issueID
        self.library = library
        drain()
    }

    /// The archive has opened; pages with no thumbnail yet can be made now.
    func use(document: ComicDocument?) {
        guard let document, self.document == nil else { return }
        self.document = document
        // Whatever the cache could not answer while it was opening.
        wanted = asked.filter { images[$0] == nil }.sorted()
        drain()
    }

    func want(_ page: Int) {
        guard images[page] == nil else { return }
        asked.insert(page)
        wanted.removeAll { $0 == page }
        wanted.append(page)
        drain()
    }

    private func drain() {
        guard !rendering, let library, let page = wanted.popLast() else { return }
        rendering = true
        let issueID = self.issueID
        let document = self.document
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { () -> UIImage? in
                guard let file = library.pageThumbnail(page, ofIssue: issueID,
                                                       renderingFrom: document),
                      let data = try? Data(contentsOf: file),
                      let decoded = UIImage(data: data) else { return nil }
                return decoded.preparingForDisplay() ?? decoded
            }.value
            guard let self else { return }
            if let image { self.images[page] = image }
            self.rendering = false
            self.drain()
        }
    }
}

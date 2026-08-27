import Foundation

/// What one PopBoks issue's fetch produced.
public struct PopBoksFetchResult: Equatable, Sendable {
    public let bytes: Int64
    /// The file the download is recorded against — the first page.
    public let file: URL
    public let pages: Int
    /// Pages the archive counts but does not actually hold.
    ///
    /// Said out loud rather than passed over: the issue really is short a
    /// page and a reader who counts will notice, and nothing here can fix it.
    public let missingFromSource: [Int]
    /// Tiles fetched. Only ever reported, never acted on — it is the number
    /// that explains why this download took minutes when a RetroSpec issue of
    /// the same length takes seconds.
    public let tiles: Int
    /// Tiles the archive does not hold, drawn blank inside a page it otherwise
    /// has in full.
    ///
    /// A corner of a scan that nobody can recover — Džuboks 88's page 35 is
    /// missing its top-right one. Said out loud rather than passed over,
    /// because the page really does have a white patch on it.
    public let blankTiles: Int
}

/// Fetches one PopBoks issue, a page at a time, a page being thirty-five
/// tiles.
///
/// The archive stores no page files — see `PopBoksPage` — so every page is
/// fetched as a grid of 256-pixel tiles and stitched before it is written.
/// What lands on disk is one JPEG per page in the layout
/// `ComicDocument(unpackedAt:)` already reads, so nothing downstream can tell
/// this source from a Stripovi or BatCave download.
///
/// **The cost is requests, not bytes.** A 68-page issue is about 42 MB, which
/// is smaller than plenty of single-file downloads elsewhere in this app, and
/// 2,380 requests, which is more than the rest of the app makes in a week.
/// That shapes everything below: the pacing, the bounded concurrency, and the
/// fact that a half-finished issue must survive being resumed.
public struct PopBoksFetcher: Sendable {

    /// How many tiles may be in flight at once.
    ///
    /// Four, and the ceiling is chosen against what the archive's own reader
    /// does rather than picked as a round number: opening a page there emits
    /// all thirty-five `<img>` tags at once and the browser fetches them six
    /// at a time. So this is slower than a person reading the same page in
    /// Safari, which is the standard worth meeting for a small archive.
    ///
    /// Serially it would be indefensible in the other direction: at one tile
    /// at a time with any courteous pause at all, a single issue runs past
    /// twenty minutes and nobody would ever finish one.
    public static let tilesAtOnce = 4

    /// How long to leave between pages.
    ///
    /// Between *pages* rather than between tiles: a page is the unit of work
    /// the archive's own reader requests in a burst, so pausing inside one
    /// would be slower than the site expects while pausing between them is a
    /// rhythm it already sees.
    public static let betweenPages: Duration = .milliseconds(250)

    private let transport: Transport
    private let interval: Duration
    private let concurrency: Int

    public init(transport: Transport,
                interval: Duration = PopBoksFetcher.betweenPages,
                concurrency: Int = PopBoksFetcher.tilesAtOnce) {
        self.transport = transport
        self.interval = interval
        self.concurrency = max(1, concurrency)
    }

    public func fetch(issue: PopBoksCatalog.Issue,
                      in catalogue: PopBoksCatalog,
                      into directory: URL,
                      progress: (@Sendable (Int, Int) -> Void)? = nil)
        async throws -> PopBoksFetchResult {

        guard let magazine = catalogue.kind else {
            throw PageFetchError.pageFailed(page: 1, reason: "the catalogue names no magazine")
        }
        // One address per page purely so `PageDownload` can name the file:
        // it takes the extension from the address, and every tile here is a
        // `.jpg`. Nothing is ever fetched from this list — the tile addresses
        // are built per page below.
        let naming = (1...max(issue.pages, 1)).map { position in
            catalogue.tileURL(issue, page: issue.sourcePage(at: position) ?? 1,
                              column: 0, row: 0) ?? "\(PopBoks.base)page.jpg"
        }
        let download = try PageDownload(directory: directory, images: naming)
        let total = download.pageCount
        guard total > 0 else { throw PageFetchError.noPages }

        // Pages already on disk from an interrupted attempt cost nothing the
        // second time. That matters more here than anywhere else in the app:
        // one interrupted issue is up to two thousand requests that must not
        // be spent again.
        var fetched = (1...total).filter { download.has(page: $0) }.count
        progress?(fetched, total)

        var absent: Set<Int> = []
        var tilesFetched = 0
        var blanked = 0
        var asked = false

        for position in 1...total {
            try Task.checkCancellation()
            guard !download.has(page: position) else { continue }
            guard let sourcePage = issue.sourcePage(at: position) else { continue }

            if asked { try await Task.sleep(for: interval) }
            asked = true

            // The top-left tile first and alone. Every page has one, so its
            // absence is the cheapest possible answer to "is this page here at
            // all" — one request rather than thirty-five, and it is the only
            // way to tell a page the archive never scanned from a page whose
            // tiles failed to arrive.
            let corner = PopBoksPage.Tile(column: 0, row: 0)
            var tiles: [PopBoksPage.Tile: Data] = [:]
            do {
                tiles[corner] = try await tile(corner, of: issue, in: catalogue,
                                               page: sourcePage, magazine: magazine)
                tilesFetched += 1
            } catch is TileMissing {
                absent.insert(position)
                progress?(fetched, total)
                continue
            }

            let rest = PopBoksPage.grid(columns: issue.columns, rows: issue.rows)
                .filter { !($0.column == 0 && $0.row == 0) }
                .map { PopBoksPage.Tile(column: $0.column, row: $0.row) }

            let got = try await self.tiles(rest, of: issue, in: catalogue,
                                           page: sourcePage, magazine: magazine)
            tiles.merge(got.found) { a, _ in a }
            tilesFetched += got.found.count

            // How tall this page actually is. The catalogue records a ceiling
            // for the issue, not a fact about every page — see
            // `PopBoksCatalog.Issue.rows`.
            let rows = try self.rows(given: got.missing, of: issue, page: position)

            // A ceiling that is too low would crop in silence, so every page
            // asks whether the archive has a row past the one we stopped at.
            // One request against thirty-five, and it is the only thing
            // standing between a rebuilt catalogue and a shelf full of pages
            // with their feet cut off.
            if rows == issue.rows {
                let beyond = PopBoksPage.Tile(column: 0, row: issue.rows)
                if try await exists(beyond, of: issue, in: catalogue,
                                    page: sourcePage, magazine: magazine) {
                    throw PageFetchError.pageFailed(
                        page: position,
                        reason: "the archive has more of this page than the index "
                              + "records (\(issue.rows) rows) — the catalogue needs "
                              + "rebuilding, and stitching it now would crop the page")
                }
                tilesFetched += 1
            }

            // The same question sideways. Asked at a middle row rather than
            // the top one because the top row is exactly where this archive's
            // known hole is — Džuboks 88's page 35 is missing its top-right
            // corner, and asking there would read a real column as absent.
            let sideways = PopBoksPage.Tile(column: issue.columns, row: rows / 2)
            if try await exists(sideways, of: issue, in: catalogue,
                                page: sourcePage, magazine: magazine) {
                throw PageFetchError.pageFailed(
                    page: position,
                    reason: "the archive has more of this page than the index "
                          + "records (\(issue.columns) columns) — the catalogue "
                          + "needs rebuilding, and stitching it now would crop "
                          + "the page")
            }
            tilesFetched += 1

            // Tiles below the real bottom were fetched and are not part of the
            // page. Dropped rather than passed on, so `stitch` is handed
            // exactly the rectangle it is told to draw.
            let rectangle = tiles.filter { $0.key.row < rows }

            let stitched: PopBoksPage.Stitched
            do {
                stitched = try await Task.detached(priority: .utility) {
                    try PopBoksPage.stitch(tiles: rectangle,
                                           columns: issue.columns, rows: rows)
                }.value
            } catch {
                throw PageFetchError.pageFailed(
                    page: position,
                    reason: "the page could not be put back together: "
                          + "\(Library.reason(error))")
            }
            if !stitched.blanks.isEmpty { blanked += stitched.blanks.count }

            try download.write(stitched.data, page: position)
            fetched += 1
            progress?(fetched, total)
        }

        return PopBoksFetchResult(
            bytes: try download.finish(absentFromSource: absent),
            file: download.recordedFile,
            pages: total - absent.count,
            missingFromSource: absent.sorted(),
            tiles: tilesFetched,
            blankTiles: blanked)
    }

    /// Whether the archive holds one particular tile.
    ///
    /// Only ever asked about a position just outside the recorded grid, to
    /// find out whether the recorded grid is too small. A failure that is not
    /// the archive saying "no such file" is left to propagate: it is not an
    /// answer to this question, and treating it as one would turn a timeout
    /// into permission to crop the page.
    private func exists(_ tile: PopBoksPage.Tile,
                        of issue: PopBoksCatalog.Issue,
                        in catalogue: PopBoksCatalog,
                        page: Int,
                        magazine: PopBoks.Magazine) async throws -> Bool {
        do {
            _ = try await self.tile(tile, of: issue, in: catalogue,
                                    page: page, magazine: magazine)
            return true
        } catch is TileMissing {
            return false
        }
    }

    // MARK: - Tiles

    /// The archive says there is no such tile.
    ///
    /// Its own type because on the top-left tile it means "this page was never
    /// scanned" and anywhere else it means the download failed — opposite
    /// responses to the same status.
    private struct TileMissing: Error {}

    /// One tile's outcome on its way back from a task group.
    ///
    /// A named struct rather than the `(Tile, Data?)` tuple this used to be,
    /// and that is a bug fix rather than a tidy-up. As a tuple, every result
    /// came back carrying the *same* tile — `0,0` — while the requests
    /// themselves went to the right thirty-five addresses and all answered
    /// 200. So the whole page collapsed into one dictionary entry and the
    /// stitcher, quite correctly, said column 1 was entirely missing.
    ///
    /// Named fields carry the tile back intact. Nothing else about the
    /// grouping changed.
    private struct Fetched: Sendable {
        let tile: PopBoksPage.Tile
        let data: Data?
    }

    /// How tall a page really is, given which of the expected tiles the
    /// archive said it does not have.
    ///
    /// Only one shape of absence is a shorter page: whole rows missing from
    /// the bottom, with everything above them complete.
    ///
    /// No page in either magazine has yet turned out to be that. Two looked
    /// like it and were not — Džuboks 34 and 60 are full seven-row pages each
    /// missing one tile — so this is a guard rather than a case that is known
    /// to fire, and it is written to shrink only on evidence that could not
    /// mean anything else.
    ///
    /// A hole that is *not* whole trailing rows is left to `stitch`, which
    /// draws it blank and says so. What neither of them will do is guess at a
    /// row or column with nothing in it at all, because its size is then
    /// unknowable and every tile past it would move.
    private func rows(given missing: Set<PopBoksPage.Tile>,
                      of issue: PopBoksCatalog.Issue,
                      page: Int) throws -> Int {
        guard !missing.isEmpty else { return issue.rows }

        // Whole rows absent from the bottom, and only those, are a shorter
        // page. Counted upward from the last row and stopping at the first row
        // that has anything in it — so a hole higher up does not shrink the
        // page, it stays a hole.
        var rows = issue.rows
        while rows > 0 {
            let row = rows - 1
            let empty = (0..<issue.columns).allSatisfy {
                missing.contains(PopBoksPage.Tile(column: $0, row: row))
            }
            if empty { rows -= 1 } else { break }
        }
        // Nothing left. The corner check before this should have caught it as
        // a page the archive does not have, so reaching here means the archive
        // answered for the corner and for nothing else.
        guard rows >= 1 else {
            throw PageFetchError.pageFailed(
                page: page, reason: "the archive holds no part of this page")
        }
        return rows
    }

    /// Several tiles at once, bounded.
    ///
    /// A task group rather than a serial loop, and bounded rather than
    /// unbounded: thirty-five tiles in flight would be six times what the
    /// archive's own reader asks for.
    ///
    /// A tile the archive says it does not have is reported rather than
    /// thrown, because at this level there is no way to tell "this page is
    /// shorter" from "this page has a hole in it" — that needs the whole set,
    /// and it is `rows(given:of:page:)` that decides. Every *other* failure
    /// still throws: a timeout or a 500 is not evidence about the page's
    /// shape, and treating it as such is how a scan quietly loses its last
    /// rows.
    private func tiles(_ wanted: [PopBoksPage.Tile],
                       of issue: PopBoksCatalog.Issue,
                       in catalogue: PopBoksCatalog,
                       page: Int,
                       magazine: PopBoks.Magazine)
        async throws -> (found: [PopBoksPage.Tile: Data], missing: Set<PopBoksPage.Tile>) {

        guard !wanted.isEmpty else { return ([:], []) }
        var found: [PopBoksPage.Tile: Data] = [:]
        var missing: Set<PopBoksPage.Tile> = []

        // A batch at a time, each group drained in full and its results
        // *returned* from the closure rather than written into variables
        // outside it.
        //
        // This was a rolling group — start four, and add another each time one
        // finished — which is better scheduling and was silently wrong: every
        // tile was fetched, all thirty-four came back 200, and one result
        // reached the caller. Draining `for try await` and returning the array
        // is the shape that cannot do that. The cost is that a batch waits for
        // its slowest member, which against four tiles of about 16 KB is
        // nothing worth having a subtle bug for.
        var index = 0
        while index < wanted.count {
            let batch = Array(wanted[index..<min(index + concurrency, wanted.count)])
            index += batch.count

            let results = try await withThrowingTaskGroup(of: Fetched.self) { group in
                for want in batch {
                    group.addTask {
                        do {
                            let data = try await self.tile(want, of: issue, in: catalogue,
                                                           page: page, magazine: magazine)
                            return Fetched(tile: want, data: data)
                        } catch is TileMissing {
                            return Fetched(tile: want, data: nil)
                        }
                    }
                }
                var out: [Fetched] = []
                for try await result in group { out.append(result) }
                return out
            }

            for result in results {
                if let data = result.data {
                    found[result.tile] = data
                } else {
                    missing.insert(result.tile)
                }
            }
        }
        return (found, missing)
    }

    /// One tile, checked before it is accepted.
    ///
    /// The archive is object storage behind a CDN, and it answers a request
    /// for something it does not have with **403 and a body of XML**, not 404.
    /// So "not there" has to be read off both statuses; treating only 404 as
    /// missing would turn every unscanned page into a hard failure and every
    /// issue containing one into an issue that can never be downloaded.
    private func tile(_ tile: PopBoksPage.Tile,
                      of issue: PopBoksCatalog.Issue,
                      in catalogue: PopBoksCatalog,
                      page: Int,
                      magazine: PopBoks.Magazine) async throws -> Data {

        guard let address = catalogue.tileURL(issue, page: page,
                                              column: tile.column, row: tile.row),
              let url = URL(string: address) else {
            throw PageFetchError.pageFailed(page: page, reason: "not an address")
        }

        var request = HTTPRequest(url: url)
        // The magazine's own reader, which is where a person fetching these
        // would be sitting.
        request.headers["Referer"] = magazine.readerURL
        request.headers["Accept"] = "image/jpeg,image/png,image/*,*/*;q=0.8"
        // The default is zero, meaning "do not read the body at all" — right
        // for a probe reading a header, and here it would stitch a page out of
        // thirty-five empty files. A tile is a few tens of KB; the ceiling is
        // generous rather than tight so a larger one is not silently cut.
        request.maxBodyBytes = 4 << 20

        let response = try await transport.send(request)
        if let refusal = RetryAfter.refusal(status: response.status,
                                            header: response.headers["retry-after"],
                                            host: url.host ?? PopBoks.host) {
            throw refusal
        }
        if response.status == 404 || response.status == 403 { throw TileMissing() }
        guard (200..<300).contains(response.status) else {
            throw PageFetchError.pageFailed(
                page: page,
                reason: "tile \(tile.column),\(tile.row): HTTP \(response.status)")
        }
        // Checked here as well as in `PopBoksPage`, so an error page arriving
        // with a 200 is refused as bytes rather than as a decode failure.
        guard ImageBytes.looksLikeImage(response.body) else {
            throw PageFetchError.pageFailed(
                page: page,
                reason: "tile \(tile.column),\(tile.row): "
                      + "the server sent something that is not an image")
        }
        return response.body
    }
}

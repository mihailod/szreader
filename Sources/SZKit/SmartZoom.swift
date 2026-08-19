import CoreGraphics
import Foundation

/// Finds the part of a scanned page that is actually the page.
///
/// Scans carry margins: the printed page's own white border, plus whatever the
/// scanner put around it. Fitted whole to a screen, a page can spend a fifth of
/// its height on nothing, and the panels are read smaller than they need to be.
///
/// The answer is a crop, not a zoom. Handing the reader a page with the margins
/// already gone means zoom 1 still is a whole page: the pager still owns an
/// unzoomed swipe, a pinch still starts from a page that fits, a rotation still
/// refits, and the landscape strip still letterboxes each slot. None of that
/// had to learn about this, which is the point — with the feature off, none of
/// it is even reached.
///
/// ## What counts as a margin
///
/// Two things together, and both are needed.
///
/// A margin line is one that is nearly all the colour the page's border already
/// is — not "nearly all white". The border colour is measured from the edge of
/// what is left and measured again after every layer comes off, so a scan
/// framed in black outside a white paper margin loses the frame in one pass and
/// the margin in the next, without either being written down as a special case.
///
/// And a margin is a *band*, never a line. That is what tells the rule across
/// the top of a panel from the paper above it: both are lines of a single
/// colour, and the only thing separating them is that one is two pixels deep
/// and the other is sixty. Without it the border colour becomes the rule's own
/// black on the second pass and the peel eats straight into the artwork —
/// which it did, and which reads as a page that has been cropped rather than
/// zoomed.
public enum SmartZoom {

    // MARK: - The setting

    /// Where the switch is stored.
    ///
    /// Named here rather than typed out in the two views that read it. They are
    /// a reader and a settings pane and they will never be edited together, so
    /// a key spelled twice is a key that will one day be spelled twice
    /// differently — and the symptom of that is a switch that does nothing.
    public static let settingKey = "smartZoom"

    /// And what it is before anyone touches it. On: a trimmed page is what a
    /// page is meant to look like, and the margins it removes are an artefact
    /// of scanning rather than anything the printer put there.
    public static let onByDefault = true

    /// Whether trimming this page would do anything worth seeing — which is
    /// the same question as whether it is worth doing at all.
    ///
    /// One threshold, not two. There was a second one here briefly, on the
    /// theory that a page could be worth cropping quietly and not worth a
    /// sentence about. It cannot: `leastToTrim` is the point below which a
    /// crop is invisible, so a page under it is not being helped either, and a
    /// page over it is. Two numbers only bought a band of pages where the
    /// feature plainly acted and the offer stayed silent — which reads as an
    /// offer that is broken, and did.
    public static func wouldHelp(_ image: CGImage) -> Bool {
        contentRect(of: image) != nil
    }

    // MARK: - Tuning

    /// The long edge the page is sampled down to before its margins are
    /// measured.
    ///
    /// Small on purpose, and not only for speed. Averaging a 2000px scan down
    /// to this is also what makes the measurement robust: the speckle and
    /// halftone dust that covers the margin of a 1970s scan disappears into the
    /// average, where at full size it is thousands of stray dark pixels sitting
    /// exactly where the question is being asked.
    static let sampleEdge = 320

    /// How far a pixel must sit from its line's own median to count as
    /// something rather than more of the same. Out of 255.
    ///
    /// Generous, because the things it must not count are JPEG ringing on a
    /// white margin and the grey cast of a page scanned under a lamp, and the
    /// thing it must count is ink.
    static let contrast = 40

    /// How much of a line must differ from the border colour before the line is
    /// content rather than more margin.
    ///
    /// The number that separates a panel edge from a page number. A rule across
    /// the top of a panel runs the width of the page; the "22" at the foot of
    /// one covers a fiftieth of it. Anything in between — a caption, a line of
    /// small print, a signature — is content and reads as content, so the
    /// threshold sits low enough to keep those and well clear of one stray
    /// mark in a margin. A page number set large — a twenty-fifth of the width
    /// — is what fixes how low it can go: below this it holds its whole margin
    /// on screen, which is the case the feature was asked to solve.
    static let lineInk = 0.08

    /// The shallowest band that can be a margin, as a fraction of the dimension
    /// it is measured along, with a floor in whole sample lines.
    ///
    /// What stops the peel from taking a panel's own rule for the next layer of
    /// border. At the sample size a rule is one or two lines and the shallowest
    /// real margin is tens of them, so this sits an order of magnitude clear of
    /// both. A genuine margin shallower than this is simply left alone, which
    /// costs a page a sliver of white and costs nobody a panel.
    static let leastBand = 0.025
    static let leastBandLines = 4

    /// Breathing room left around the content, as a fraction of the long edge.
    ///
    /// Deliberate, not slack in the measurement: a page cropped exactly to its
    /// ink looks like a page that has been cut, and the outermost rule of a
    /// panel is the first thing to go when a scan is a degree off square.
    static let sliver = 0.012

    /// The most that may come off any one dimension.
    ///
    /// A backstop, not a working limit. Set where it is because the deep cases
    /// are real: a scan framed in black *and* margined in white spends half its
    /// height on neither, and a page that ends a chapter halfway down is a page
    /// whose bottom half is margin by any reading. What it still refuses is the
    /// page that is mostly white by design — a title, a single small panel —
    /// where filling a screen with the little that is on it is a guess rather
    /// than a zoom.
    static let mostToTrim = 0.6

    /// The smallest trim that is worth anything: below it the page is handed
    /// back untouched, and it is also the line the offer speaks for.
    ///
    /// Set where a reader would notice. Four percent of a page is a finger's
    /// width of blank paper on an iPad — plain to see, and plainly better
    /// gone. Under that a crop is real arithmetic and no visible difference,
    /// so the page is left as it was rather than copied to save a hairline.
    static let leastToTrim = 0.04

    // MARK: - Cropping

    /// The page with its margins removed, or the page itself when there are
    /// none worth removing.
    ///
    /// Total: a caller can hand it anything and show what comes back. Every way
    /// this can decline — an image too small to measure, a blank page, a page
    /// already filled to its edges, a crop that would take too much — returns
    /// the original, so the reader's behaviour with the feature on is the
    /// behaviour with it off plus, at most, a smaller rectangle.
    public static func cropped(_ image: CGImage) -> CGImage {
        guard let rect = contentRect(of: image),
              let cut = image.cropping(to: rect) else { return image }
        return cut
    }

    /// The part of the page worth showing, in the image's own pixel
    /// coordinates, or nil when that is all of it.
    public static func contentRect(of image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        guard width > 8, height > 8, let sample = grey(image) else { return nil }
        guard let box = contentBox(in: sample) else { return nil }

        // Back to the page's own pixels. The sample is a scaled copy, so the
        // edges are scaled back rather than rounded off the same way: the top
        // and left round down and the far edges round up, which errs towards
        // keeping a row of content rather than shaving one.
        let sx = Double(width) / Double(sample.width)
        let sy = Double(height) / Double(sample.height)
        var minX = Int((Double(box.minX) * sx).rounded(.down))
        var minY = Int((Double(box.minY) * sy).rounded(.down))
        var maxX = Int((Double(box.maxX) * sx).rounded(.up))
        var maxY = Int((Double(box.maxY) * sy).rounded(.up))

        // The sliver, measured on the page rather than on what is left of it,
        // so a heavily cropped page is not given a proportionally huge margin.
        let room = Int((Double(max(width, height)) * sliver).rounded())
        minX = max(minX - room, 0); minY = max(minY - room, 0)
        maxX = min(maxX + room, width); maxY = min(maxY + room, height)

        let cut = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        guard cut.width > 0, cut.height > 0 else { return nil }

        // Nothing to gain, or too much to lose. Both are answered here rather
        // than while peeling, because it is the finished rectangle either
        // judgement is about.
        let keptX = cut.width / CGFloat(width), keptY = cut.height / CGFloat(height)
        guard min(keptX, keptY) <= 1 - leastToTrim else { return nil }
        guard min(keptX, keptY) >= 1 - mostToTrim else { return nil }
        return cut
    }

    // MARK: - The peel

    /// A sampled page: 8-bit grey, one byte per pixel, top row first.
    struct Sample {
        var pixels: [UInt8]
        var width: Int
        var height: Int

        subscript(x: Int, y: Int) -> UInt8 { pixels[y * width + x] }
    }

    /// A half-open box in sample coordinates.
    struct Box: Equatable {
        var minX: Int, minY: Int, maxX: Int, maxY: Int
        var width: Int { maxX - minX }
        var height: Int { maxY - minY }
    }

    /// Peels margin bands off all four edges until every edge is content.
    ///
    /// One layer per round, because the border colour is only true of the layer
    /// currently on the outside: a framed scan is black on the first round and
    /// white on the second. Four rounds is a cap rather than a count — the peel
    /// stops the moment a round takes nothing, which on an ordinary page is the
    /// second one.
    static func contentBox(in sample: Sample) -> Box? {
        var box = Box(minX: 0, minY: 0, maxX: sample.width, maxY: sample.height)
        for _ in 0..<4 {
            guard box.width > 1, box.height > 1 else { return nil }
            let border = background(of: box, in: sample)
            guard peel(&box, in: sample, border: border) else { break }
        }
        guard box.width > 1, box.height > 1 else { return nil }
        return box
    }

    /// One layer off each edge. Answers whether anything came off.
    ///
    /// Each edge measures inside the box the edges before it left, which is
    /// what gets a nested frame off: a black band down the side of a page is
    /// only uniform once the black bands across the top and bottom have gone.
    private static func peel(_ box: inout Box, in sample: Sample, border: Int) -> Bool {
        var moved = false

        var run = 0
        while box.minY + run < box.maxY - 1,
              isMargin(row: box.minY + run, in: sample, box: box, border: border) { run += 1 }
        if run >= leastBand(box.height) { box.minY += run; moved = true }

        run = 0
        while box.maxY - 1 - run > box.minY,
              isMargin(row: box.maxY - 1 - run, in: sample, box: box, border: border) { run += 1 }
        if run >= leastBand(box.height) { box.maxY -= run; moved = true }

        run = 0
        while box.minX + run < box.maxX - 1,
              isMargin(column: box.minX + run, in: sample, box: box, border: border) { run += 1 }
        if run >= leastBand(box.width) { box.minX += run; moved = true }

        run = 0
        while box.maxX - 1 - run > box.minX,
              isMargin(column: box.maxX - 1 - run, in: sample, box: box, border: border) { run += 1 }
        if run >= leastBand(box.width) { box.maxX -= run; moved = true }

        return moved
    }

    /// The shallowest band that counts as a margin along a dimension.
    static func leastBand(_ extent: Int) -> Int {
        max(Int((Double(extent) * leastBand).rounded()), leastBandLines)
    }

    /// The colour of the box's own border: the median of its outermost ring.
    ///
    /// The ring rather than the whole box, because the question is what the
    /// page is framed in, and on a page that is mostly artwork the box's median
    /// is the artwork. Re-measured every round — that is what makes the peel
    /// work down through a frame of one colour into a margin of another.
    static func background(of box: Box, in sample: Sample) -> Int {
        var counts = [Int](repeating: 0, count: 256)
        var total = 0
        for x in box.minX..<box.maxX {
            counts[Int(sample[x, box.minY])] += 1
            counts[Int(sample[x, box.maxY - 1])] += 1
            total += 2
        }
        for y in box.minY..<box.maxY {
            counts[Int(sample[box.minX, y])] += 1
            counts[Int(sample[box.maxX - 1, y])] += 1
            total += 2
        }
        return median(counts, of: total)
    }

    private static func isMargin(row y: Int, in sample: Sample, box: Box, border: Int) -> Bool {
        var different = 0
        for x in box.minX..<box.maxX where abs(Int(sample[x, y]) - border) > contrast {
            different += 1
        }
        return Double(different) / Double(box.width) < lineInk
    }

    private static func isMargin(column x: Int, in sample: Sample, box: Box, border: Int) -> Bool {
        var different = 0
        for y in box.minY..<box.maxY where abs(Int(sample[x, y]) - border) > contrast {
            different += 1
        }
        return Double(different) / Double(box.height) < lineInk
    }

    /// Whether a line is more of the border it sits against.
    ///
    /// Against the border colour, not against the line's own average. A line
    /// that is entirely one colour is not margin by that fact alone: the rule
    /// across the top of a panel is entirely black, and measured against itself
    /// it looks exactly as featureless as the paper above it.
    static func isMargin(_ line: [UInt8], border: Int) -> Bool {
        guard !line.isEmpty else { return true }
        var different = 0
        for value in line where abs(Int(value) - border) > contrast { different += 1 }
        return Double(different) / Double(line.count) < lineInk
    }

    /// By counting sort over the 256 possible values — this runs for every
    /// line of every round.
    private static func median(_ counts: [Int], of total: Int) -> Int {
        let half = total / 2
        var seen = 0
        for value in 0..<256 {
            seen += counts[value]
            if seen > half { return value }
        }
        return 255
    }

    // MARK: - Sampling

    /// The page as a small grey bitmap, top row first.
    ///
    /// Drawn straight, with no flip, and that is worth saying because a flip
    /// looks obviously right here and is obviously wrong. Core Graphics puts
    /// its user-space origin in the bottom-left, but a bitmap context's *buffer*
    /// starts at the top row, and drawing an image upright into it therefore
    /// lands the image's top row at buffer row 0 already. Flipping as well
    /// turns the sample upside down, and everything downstream then crops the
    /// wrong end of the page — a perfectly good crop of the wrong half, which
    /// on a symmetrical page shows no symptom at all.
    static func grey(_ image: CGImage) -> Sample? {
        let long = max(image.width, image.height)
        guard long > 0 else { return nil }
        let scale = min(Double(sampleEdge) / Double(long), 1)
        let width = max(Int((Double(image.width) * scale).rounded()), 1)
        let height = max(Int((Double(image.height) * scale).rounded()), 1)

        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }
        // A page with transparency composites onto this rather than onto
        // whatever the buffer happened to contain.
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let data = context.data else { return nil }
        let bytes = data.bindMemory(to: UInt8.self, capacity: width * height)
        return Sample(pixels: Array(UnsafeBufferPointer(start: bytes, count: width * height)),
                      width: width, height: height)
    }
}

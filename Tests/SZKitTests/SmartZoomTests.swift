import CoreGraphics
import XCTest
@testable import SZKit

/// Finding the page inside the scan.
final class SmartZoomTests: XCTestCase {

    // MARK: - Building pages to look at

    /// A page to draw on. White, with the origin at the top-left, so a test
    /// reads the same way the page does.
    private func page(_ width: Int, _ height: Int,
                      draw: (CGContext, CGFloat) -> Void) -> CGImage {
        let context = CGContext(data: nil, width: width, height: height,
                                bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        draw(context, CGFloat(height))
        return context.makeImage()!
    }

    /// A filled rectangle in top-left coordinates.
    private func ink(_ context: CGContext, _ rect: CGRect, grey: CGFloat = 0) {
        context.setFillColor(gray: grey, alpha: 1)
        context.fill(rect)
    }

    /// Something that reads as content rather than as a flat block: a panel
    /// with a rule around it and a little inside it, which is what an actual
    /// page's outermost rows and columns look like.
    private func panel(_ context: CGContext, _ rect: CGRect) {
        context.setStrokeColor(gray: 0, alpha: 1)
        context.setLineWidth(max(rect.width, rect.height) * 0.01)
        context.stroke(rect)
        ink(context, rect.insetBy(dx: rect.width * 0.2, dy: rect.height * 0.3), grey: 0.25)
    }

    /// How much of each dimension a crop kept.
    private func kept(_ rect: CGRect, of image: CGImage) -> (x: Double, y: Double) {
        (Double(rect.width) / Double(image.width), Double(rect.height) / Double(image.height))
    }

    // MARK: - Doing nothing

    /// The promise the whole feature rests on: anything it cannot improve
    /// comes back exactly as it went in, so a page is never made worse.
    func testAPageFilledToItsEdgesIsHandedBackUnchanged() {
        let full = page(600, 800) { context, _ in
            panel(context, CGRect(x: 2, y: 2, width: 596, height: 796))
        }
        XCTAssertNil(SmartZoom.contentRect(of: full))
        XCTAssertTrue(SmartZoom.cropped(full) === full, "an unimproved page must not be copied")
    }

    /// A blank page has no content to find, and must not be cropped to a
    /// speck of scanner noise.
    func testABlankPageIsLeftAlone() {
        let blank = page(600, 800) { _, _ in }
        XCTAssertNil(SmartZoom.contentRect(of: blank))
        XCTAssertTrue(SmartZoom.cropped(blank) === blank)
    }

    /// A margin worth a percent is not worth a crop.
    func testATrivialMarginIsNotWorthCropping() {
        let barely = page(600, 800) { context, _ in
            panel(context, CGRect(x: 4, y: 6, width: 592, height: 788))
        }
        XCTAssertNil(SmartZoom.contentRect(of: barely))
    }

    /// The backstop. A page that is mostly white by design — one small panel,
    /// a chapter title — is not blown up to fill a screen with the little
    /// that is on it.
    func testAMostlyEmptyPageIsNotBlownUp() {
        let sparse = page(600, 800) { context, _ in
            panel(context, CGRect(x: 250, y: 350, width: 100, height: 100))
        }
        XCTAssertNil(SmartZoom.contentRect(of: sparse),
                     "cropping to a tenth of the page is not a zoom, it is a guess")
    }

    // MARK: - The ordinary case

    /// The first screenshot: deep white bands above and below the panels, a
    /// modest margin at the sides. Both go.
    func testWhiteMarginsComeOff() {
        let scanned = page(600, 800) { context, _ in
            panel(context, CGRect(x: 40, y: 130, width: 520, height: 540))
        }
        let crop = try! XCTUnwrap(SmartZoom.contentRect(of: scanned))
        let left = kept(crop, of: scanned)
        XCTAssertLessThan(left.y, 0.8, "the deep bands should have gone")
        XCTAssertLessThan(left.x, 0.98, "the side margins should have gone too")
        // And the panel itself is still all there.
        XCTAssertLessThanOrEqual(crop.minY, 130)
        XCTAssertGreaterThanOrEqual(crop.maxY, 670)
        XCTAssertLessThanOrEqual(crop.minX, 40)
        XCTAssertGreaterThanOrEqual(crop.maxX, 560)
    }

    /// Nothing is stretched, because nothing is asked to be: the crop is a
    /// rectangle of the original's own pixels, and what the reader does with
    /// it afterwards fits it by the smaller scale. All this has to promise is
    /// that it stays inside the page.
    func testTheCropIsAlwaysInsideThePage() {
        let scanned = page(600, 800) { context, _ in
            panel(context, CGRect(x: 40, y: 130, width: 520, height: 540))
        }
        let crop = try! XCTUnwrap(SmartZoom.contentRect(of: scanned))
        XCTAssertTrue(CGRect(x: 0, y: 0, width: 600, height: 800).contains(crop))
        XCTAssertNotNil(scanned.cropping(to: crop))
    }

    /// A margin is left on purpose, so the outermost rule of a panel is not
    /// the first thing a slightly skewed scan loses.
    func testASliverOfMarginIsLeft() {
        let scanned = page(600, 800) { context, _ in
            panel(context, CGRect(x: 60, y: 200, width: 480, height: 400))
        }
        let crop = try! XCTUnwrap(SmartZoom.contentRect(of: scanned))
        XCTAssertLessThan(crop.minY, 200, "cropped flush to the ink")
        XCTAssertGreaterThan(crop.maxY, 600, "cropped flush to the ink")
    }

    // MARK: - The awkward ones

    /// The third screenshot: a tiny page number alone in a deep bottom
    /// margin. It is not content, and the band it sits in comes off with it.
    func testATinyPageNumberInTheMarginIsPeeledThrough() {
        let numbered = page(600, 800) { context, _ in
            panel(context, CGRect(x: 40, y: 40, width: 520, height: 600))
            // "22" — a fiftieth of the width, most of the way down the margin.
            ink(context, CGRect(x: 288, y: 730, width: 24, height: 26))
        }
        let crop = try! XCTUnwrap(SmartZoom.contentRect(of: numbered))
        XCTAssertLessThan(crop.maxY, 720,
                          "the page number kept the whole bottom margin on screen")
        XCTAssertGreaterThanOrEqual(crop.maxY, 640, "and the panel below it was cut")
    }

    /// A scan photographed against something dark: black frame, white margin,
    /// then the page. Neither band is uniform across the full width of the
    /// image — each crosses the other — so both only come off because the
    /// peeling interleaves the four edges.
    func testADarkScannerFrameOutsideAWhiteMarginComesOffToo() {
        let framed = page(600, 800) { context, height in
            ink(context, CGRect(x: 0, y: 0, width: 600, height: height))   // black all over
            ink(context, CGRect(x: 30, y: 40, width: 540, height: 720), grey: 1)  // the paper
            panel(context, CGRect(x: 90, y: 190, width: 420, height: 420))
        }
        let crop = try! XCTUnwrap(SmartZoom.contentRect(of: framed))
        let left = kept(crop, of: framed)
        XCTAssertLessThan(left.y, 0.75, "the frame and the margin both had to go")
        XCTAssertLessThan(left.x, 0.85)
        XCTAssertLessThanOrEqual(crop.minY, 190)
        XCTAssertGreaterThanOrEqual(crop.maxY, 610)
    }

    /// Which way is up.
    ///
    /// Core Graphics counts from the bottom and `CGImage.cropping` counts from
    /// the top, so a box measured in one and applied in the other crops the
    /// wrong end of the page. On a page with a header and no footer that is
    /// not a subtle wrong, but it is a silent one — the reader gets a
    /// perfectly good crop of the wrong half.
    func testTheCropIsTakenFromTheEndOfThePageTheContentIsOn() {
        let topHeavy = page(600, 800) { context, _ in
            panel(context, CGRect(x: 60, y: 30, width: 480, height: 300))
        }
        let crop = try! XCTUnwrap(SmartZoom.contentRect(of: topHeavy))
        XCTAssertLessThan(crop.minY, 40, "the content starts near the top of the page")
        XCTAssertLessThan(crop.maxY, 420, "and the empty bottom half should be gone")
    }

    // MARK: - The setting, and the offer

    /// On unless someone says otherwise, and both views that read the switch
    /// take the default from here rather than each writing `true` themselves.
    func testSmartZoomIsOnByDefault() {
        XCTAssertTrue(SmartZoom.onByDefault)
        XCTAssertEqual(SmartZoom.settingKey, "smartZoom")
    }

    /// Offering and doing are one question, asked once.
    ///
    /// They were briefly two, with a higher bar for the offer, and the gap
    /// between them was a band of pages the feature visibly acted on while the
    /// offer said nothing — which from the outside is an offer that does not
    /// work. Whatever the crop would touch is what the sentence speaks for.
    func testTheOfferSpeaksForExactlyWhatTheCropWouldTouch() {
        let pages = [
            // Filled to the edges, a hairline margin, a middling one, and a
            // deep one. The middling page is the one that matters: it is the
            // only shape that can tell one threshold from two, and without it
            // this test agrees with itself no matter where the bars are put.
            page(600, 800) { context, _ in panel(context, CGRect(x: 2, y: 2, width: 596, height: 796)) },
            page(600, 800) { context, _ in panel(context, CGRect(x: 8, y: 10, width: 584, height: 780)) },
            page(600, 800) { context, _ in panel(context, CGRect(x: 30, y: 36, width: 540, height: 728)) },
            page(600, 800) { context, _ in panel(context, CGRect(x: 40, y: 130, width: 520, height: 540)) },
        ]
        for (index, sheet) in pages.enumerated() {
            XCTAssertEqual(SmartZoom.wouldHelp(sheet),
                           SmartZoom.contentRect(of: sheet) != nil,
                           "page \(index): the offer and the crop disagree")
        }
    }

    /// And the one threshold is set where a reader would see the difference,
    /// not where the arithmetic stops being free.
    func testAHairlineMarginIsWorthNeither() {
        let hairline = page(600, 800) { context, _ in
            panel(context, CGRect(x: 8, y: 10, width: 584, height: 780))
        }
        XCTAssertNil(SmartZoom.contentRect(of: hairline))
        XCTAssertFalse(SmartZoom.wouldHelp(hairline))
    }

    /// The margins from the first screenshot are.
    func testADeepMarginIsWorthMentioning() {
        let deep = page(600, 800) { context, _ in
            panel(context, CGRect(x: 40, y: 130, width: 520, height: 540))
        }
        XCTAssertTrue(SmartZoom.wouldHelp(deep))
    }

    /// And a page there is nothing to do to is never offered.
    func testAPageWithNoMarginsIsNeverOffered() {
        let full = page(600, 800) { context, _ in
            panel(context, CGRect(x: 2, y: 2, width: 596, height: 796))
        }
        XCTAssertFalse(SmartZoom.wouldHelp(full))
    }

    // MARK: - The line test underneath it all

    /// A line of the border's own colour is margin, whatever that colour is.
    func testALineOfTheBorderColourIsMargin() {
        XCTAssertTrue(SmartZoom.isMargin([UInt8](repeating: 255, count: 200), border: 255))
        XCTAssertTrue(SmartZoom.isMargin([UInt8](repeating: 0, count: 200), border: 0))
        XCTAssertTrue(SmartZoom.isMargin([UInt8](repeating: 128, count: 200), border: 128))
    }

    /// And a line of one colour is *not* margin merely for being one colour.
    ///
    /// The rule across the top of a panel is solid black and perfectly
    /// featureless, exactly like the paper above it. Measured against itself it
    /// is indistinguishable from margin, and the peel walks straight through it
    /// into the artwork. Measured against the white it sits on, it is the edge
    /// of the page — which is the whole reason there is a border colour here at
    /// all.
    func testASolidRuleIsNotMarginAgainstThePaperItSitsOn() {
        let rule = [UInt8](repeating: 10, count: 200)
        XCTAssertFalse(SmartZoom.isMargin(rule, border: 250))
    }

    /// One mark in a wide line is not enough to hold the line — this is the
    /// page number, and the margin it sits in has to come off around it.
    func testOneSmallMarkDoesNotHoldTheLine() {
        var line = [UInt8](repeating: 250, count: 200)
        for x in 98..<102 { line[x] = 0 }          // 2% of the width
        XCTAssertTrue(SmartZoom.isMargin(line, border: 250))
    }

    /// A rule across a panel does.
    func testALineWithRealInkAcrossItIsContent() {
        var line = [UInt8](repeating: 250, count: 200)
        for x in 20..<180 { line[x] = 10 }
        XCTAssertFalse(SmartZoom.isMargin(line, border: 250))
    }

    /// And so does a line of small print, which is content that happens to be
    /// sparse — the case that fixes how low the threshold can go.
    func testALineOfSmallPrintIsContent() {
        var line = [UInt8](repeating: 250, count: 200)
        for x in stride(from: 30, to: 170, by: 4) { line[x] = 20; line[x + 1] = 20 }
        XCTAssertFalse(SmartZoom.isMargin(line, border: 250))
    }

    /// Scanner dust in a margin is still margin.
    func testSpeckleIsStillMargin() {
        var line = [UInt8](repeating: 252, count: 200)
        for x in [7, 61, 143] { line[x] = 90 }
        XCTAssertTrue(SmartZoom.isMargin(line, border: 252))
    }

    /// A band has to be deep to be a margin. Two lines is a rule.
    func testAMarginHasToBeDeeperThanARule() {
        XCTAssertGreaterThan(SmartZoom.leastBand(320), 2,
                             "a two-pixel panel rule would be peeled as a border layer")
        XCTAssertLessThan(SmartZoom.leastBand(320), 20,
                          "and a real margin has to still qualify")
    }

    // MARK: - The peel, on a page built pixel by pixel

    /// A page with no interpolation in the way: white margins, a solid rule
    /// across the full width of the box, then artwork.
    private func ruledPage() -> SmartZoom.Sample {
        let width = 100, height = 200
        var pixels = [UInt8](repeating: 250, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let value: UInt8
                switch y {
                case 50...52, 147...149: value = 10                 // the rules
                case 53...146:           value = x % 2 == 0 ? 20 : 240  // artwork
                default:                 value = 250                // margin
                }
                pixels[y * width + x] = value
            }
        }
        return SmartZoom.Sample(pixels: pixels, width: width, height: height)
    }

    /// The peel stops *at* the rule, not after it.
    ///
    /// The rule spans the whole width of the box by the time the top edge is
    /// measured, so every pixel in it matches every other. Judged against
    /// itself it is as featureless as the paper above it and comes off; judged
    /// against the white it sits on it is the first line of the page. Three
    /// rows of difference, and they are the outermost three rows of the
    /// artwork.
    func testThePeelStopsAtARuleRatherThanEatingIt() {
        let box = try! XCTUnwrap(SmartZoom.contentBox(in: ruledPage()))
        XCTAssertEqual(box.minY, 50, "the top rule was peeled as if it were margin")
        XCTAssertEqual(box.maxY, 150, "the bottom rule was peeled as if it were margin")
    }

    /// The border colour is what the box is framed in, not what fills it.
    func testTheBorderColourIsTakenFromTheRing() {
        let page = ruledPage()
        let whole = SmartZoom.Box(minX: 0, minY: 0, maxX: page.width, maxY: page.height)
        XCTAssertGreaterThan(SmartZoom.background(of: whole, in: page), 200,
                             "the page is framed in white")
        // Once the margins are off, the frame is the rule.
        let inner = SmartZoom.Box(minX: 0, minY: 50, maxX: 100, maxY: 150)
        XCTAssertLessThan(SmartZoom.background(of: inner, in: page), 100)
    }

    // MARK: - Sampling

    /// Row zero of the sample is the top of the page. Everything downstream
    /// is measured in these coordinates.
    func testTheSampleIsTopRowFirst() {
        let topHeavy = page(200, 400) { context, _ in
            ink(context, CGRect(x: 0, y: 0, width: 200, height: 40))
        }
        let sample = try! XCTUnwrap(SmartZoom.grey(topHeavy))
        XCTAssertLessThan(sample[sample.width / 2, 1], 60, "the top row should be the ink")
        XCTAssertGreaterThan(sample[sample.width / 2, sample.height - 2], 200,
                             "and the bottom row the paper")
    }

    /// A page smaller than the sample size is measured at its own size rather
    /// than blown up to it.
    func testASmallPageIsNotUpsampled() {
        let small = page(80, 100) { context, _ in
            panel(context, CGRect(x: 10, y: 20, width: 60, height: 40))
        }
        let sample = try! XCTUnwrap(SmartZoom.grey(small))
        XCTAssertEqual(sample.width, 80)
        XCTAssertEqual(sample.height, 100)
    }
}

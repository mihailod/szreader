import XCTest
@testable import SZKit

/// Panning limits for a zoomed page.
final class ZoomPanTests: XCTestCase {

    /// A tall scan on a landscape-ish screen: it fits by height, leaving bars
    /// at the sides.
    private let page = CGSize(width: 1000, height: 1500)
    private let screen = CGSize(width: 800, height: 1000)

    func testFittedByTheTighterAxis() {
        let fitted = ZoomPan.fittedSize(image: page, box: screen)
        XCTAssertEqual(fitted.height, 1000, accuracy: 0.001)
        XCTAssertEqual(fitted.width, 666.667, accuracy: 0.01)
    }

    /// Unzoomed, the page has nowhere to go — otherwise it could be dragged
    /// out from under the reader.
    func testNoPanningAtZoomOne() {
        let limit = ZoomPan.maxOffset(image: page, box: screen, zoom: 1)
        XCTAssertEqual(limit.width, 0)
        XCTAssertEqual(limit.height, 0)
        XCTAssertEqual(ZoomPan.clamp(CGSize(width: 500, height: 500),
                                     image: page, box: screen, zoom: 1), .zero)
    }

    /// Zoomed, the slack is half the overflow on each axis.
    func testLimitIsHalfTheOverflow() {
        let limit = ZoomPan.maxOffset(image: page, box: screen, zoom: 2)
        // 666.67 * 2 = 1333.3 wide against an 800 screen -> 266.67 either way.
        XCTAssertEqual(limit.width, 266.667, accuracy: 0.01)
        XCTAssertEqual(limit.height, 500, accuracy: 0.001)
    }

    func testClampHoldsTheEdge() {
        let far = CGSize(width: 9_000, height: -9_000)
        let held = ZoomPan.clamp(far, image: page, box: screen, zoom: 2)
        XCTAssertEqual(held.width, 266.667, accuracy: 0.01)
        XCTAssertEqual(held.height, -500, accuracy: 0.001)
    }

    func testSmallMovesArePassedThrough() {
        let nudge = CGSize(width: 40, height: -30)
        XCTAssertEqual(ZoomPan.clamp(nudge, image: page, box: screen, zoom: 2), nudge)
    }

    /// An axis with no overflow stays pinned even when the other one moves —
    /// a wide page zoomed a little can slide sideways but not up and down.
    func testAxesAreIndependent() {
        let wide = CGSize(width: 2000, height: 1000)     // fits by width
        let limit = ZoomPan.maxOffset(image: wide, box: screen, zoom: 1.2)
        XCTAssertGreaterThan(limit.width, 0)
        XCTAssertEqual(limit.height, 0, accuracy: 0.001)

        let held = ZoomPan.clamp(CGSize(width: 30, height: 400),
                                 image: wide, box: screen, zoom: 1.2)
        XCTAssertEqual(held.width, 30, accuracy: 0.001)
        XCTAssertEqual(held.height, 0, accuracy: 0.001)
    }

    /// Degenerate inputs must not produce NaN offsets.
    func testEmptyInputsAreSafe() {
        XCTAssertEqual(ZoomPan.fittedSize(image: .zero, box: screen), .zero)
        XCTAssertEqual(ZoomPan.maxOffset(image: .zero, box: screen, zoom: 3), .zero)
        XCTAssertEqual(ZoomPan.clamp(CGSize(width: 10, height: 10),
                                     image: page, box: .zero, zoom: 3), .zero)
    }

    // MARK: - Filling the width in landscape

    private static let page = CGSize(width: 1988, height: 3056)   // a real scan
    private static let landscape = CGSize(width: 1194, height: 834)

    func testLandscapeWidensThePageToTheScreen() {
        let zoom = ZoomPan.widthFillZoom(image: Self.page, box: Self.landscape)
        XCTAssertGreaterThan(zoom, 1)
        let fitted = ZoomPan.fittedSize(image: Self.page, box: Self.landscape)
        XCTAssertEqual(fitted.width * zoom, Self.landscape.width, accuracy: 0.5)
    }

    /// Widening the page is only worth it if what runs off the screen can be
    /// reached again.
    func testTheWidenedPageCanBePannedToItsEnds() {
        let zoom = ZoomPan.widthFillZoom(image: Self.page, box: Self.landscape)
        let limit = ZoomPan.maxOffset(image: Self.page, box: Self.landscape, zoom: zoom)
        XCTAssertGreaterThan(limit.height, 0, "the overflow could not be panned to")
        XCTAssertEqual(limit.width, 0, accuracy: 0.5, "it should not pan sideways")
    }

    /// A page shaped wider than the box already meets both sides; widening
    /// it further would only crop it.
    func testPageWiderThanTheBoxIsLeftAlone() {
        let panorama = CGSize(width: 4000, height: 1000)
        XCTAssertEqual(ZoomPan.widthFillZoom(image: panorama, box: Self.landscape), 1,
                       accuracy: 0.001)
    }

    /// A double-page spread is still narrower than a landscape screen, so it
    /// is widened like any other page.
    func testWideSpreadStillFillsTheWidth() {
        let spread = CGSize(width: 3976, height: 3056)
        let zoom = ZoomPan.widthFillZoom(image: spread, box: Self.landscape)
        let fitted = ZoomPan.fittedSize(image: spread, box: Self.landscape)
        XCTAssertEqual(fitted.width * zoom, Self.landscape.width, accuracy: 0.5)
    }

    func testNoImageIsNotZoomed() {
        XCTAssertEqual(ZoomPan.widthFillZoom(image: .zero, box: Self.landscape), 1)
    }
}

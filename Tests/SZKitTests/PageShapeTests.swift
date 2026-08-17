import XCTest
@testable import SZKit

/// Which images in an archive are pages of the comic, by shape alone.
///
/// Every size here was measured off a real download on the iPad.
final class PageShapeTests: XCTestCase {

    /// Alan Ford "Grupa TNT": the pages, and the cover, which is scanned
    /// larger than the rest.
    func testTheOrdinaryPagesOfAScanArePages() {
        XCTAssertTrue(PageRenderer.isPageShaped(width: 1400, height: 2050))
        XCTAssertTrue(PageRenderer.isPageShaped(width: 2700, height: 3700))
        // Udar munje, the issue that never showed the fault.
        XCTAssertTrue(PageRenderer.isPageShaped(width: 1510, height: 2090))
    }

    /// The fourth image in that same archive is the book's spine. Read as the
    /// shape of the run it made the landscape strip's slots forty-two thousand
    /// points tall, and the reader was left looking at the empty part of one.
    func testTheSpineIsNotAPage() {
        XCTAssertFalse(PageRenderer.isPageShaped(width: 69, height: 2107))
    }

    /// A double-page spread is short and wide and is still a page.
    func testADoublePageSpreadIsAPage() {
        XCTAssertTrue(PageRenderer.isPageShaped(width: 2400, height: 1700))
    }

    /// A scanner's colour strip along the bottom of a sheet is not.
    func testALongThinStripIsNotAPage() {
        XCTAssertFalse(PageRenderer.isPageShaped(width: 3000, height: 200))
    }

    /// An image with no size at all cannot be measured, so it is not a page —
    /// dividing by that width is the other way this goes wrong.
    func testNothingIsNotAPage() {
        XCTAssertFalse(PageRenderer.isPageShaped(width: 0, height: 2050))
        XCTAssertFalse(PageRenderer.isPageShaped(width: 1400, height: 0))
    }
}

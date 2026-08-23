import XCTest
import CoreGraphics
@testable import SZKit

/// Telling artwork that is already grey from artwork that is not.
///
/// The shelf's only sign for "downloaded" is that the cover is in colour, so
/// this decides which covers need a different sign. Getting it wrong in either
/// direction is visible: a colour cover badged as grey gains a border it does
/// not need, and a grey one missed keeps saying nothing at all.
final class CoverColourTests: XCTestCase {

    /// A picture built pixel by pixel, so every test states exactly what it is
    /// judging rather than depending on a fixture.
    private func image(_ side: Int = 64,
                       _ pixel: (Int, Int) -> (UInt8, UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let (r, g, b, a) = pixel(x, y)
                let i = (y * side + x) * 4
                bytes[i] = r; bytes[i+1] = g; bytes[i+2] = b; bytes[i+3] = a
            }
        }
        let context = CGContext(data: &bytes, width: side, height: side,
                                bitsPerComponent: 8, bytesPerRow: side * 4,
                                space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }

    // MARK: - Plainly one or the other

    func testAGreyGradientIsMonochrome() {
        let grey = image { x, _ in (UInt8(x * 4 % 256), UInt8(x * 4 % 256), UInt8(x * 4 % 256), 255) }
        XCTAssertTrue(CoverColour.isMonochrome(grey))
    }

    func testPureBlackAndWhiteIsMonochrome() {
        let lineArt = image { x, y in
            let on: UInt8 = ((x / 4) + (y / 4)) % 2 == 0 ? 255 : 0
            return (on, on, on, 255)
        }
        XCTAssertTrue(CoverColour.isMonochrome(lineArt))
    }

    func testAColourCoverIsNot() {
        let colour = image { x, y in (UInt8(x * 4 % 256), UInt8(y * 4 % 256), 200, 255) }
        XCTAssertFalse(CoverColour.isMonochrome(colour))
    }

    /// A cover with one strong colour over most of it is the ordinary case,
    /// and must keep the ordinary treatment.
    func testAMostlyRedCoverIsNot() {
        let red = image { _, _ in (200, 30, 40, 255) }
        XCTAssertFalse(CoverColour.isMonochrome(red))
    }

    // MARK: - The awkward middle

    /// The reason this is a proportion and not a test for any colour at all.
    /// A black and white scan saved as JPEG comes back with coloured fringes
    /// along every hard edge, and a page of line art is nothing but edges.
    func testAGreyScanWithJPEGFringingIsStillMonochrome() {
        let fringed = image { x, y in
            let on: UInt8 = (x / 8) % 2 == 0 ? 240 : 20
            // A scattering of coloured pixels, well under the allowance.
            if (x * 7 + y * 13) % 101 == 0 { return (200, 90, 90, 255) }
            return (on, on, on, 255)
        }
        XCTAssertTrue(CoverColour.isMonochrome(fringed))
    }

    /// A grey cover with a colour title band is *not* colourless — the shelf's
    /// own signal still works on it, so it must not be given a second one.
    func testAGreyCoverWithARealSplashOfColourIsNot() {
        let banner = image { _, y in
            y < 24 ? (220, 40, 60, 255) : (128, 128, 128, 255)
        }
        XCTAssertFalse(CoverColour.isMonochrome(banner))
    }

    /// A faint colour cast — an aged paper scan — reads as grey, because it
    /// does: showing it "in colour" tells the reader nothing.
    func testAFaintlyTintedScanIsMonochrome() {
        let sepia = image { x, _ in
            let v = UInt8(120 + (x % 40))
            return (v, v &- 6, v &- 12, 255)
        }
        XCTAssertTrue(CoverColour.isMonochrome(sepia))
    }

    // MARK: - Nothing to judge

    /// Transparent pixels are not evidence either way, and a cover with a
    /// cut-out must not be judged on its hole.
    func testTransparencyIsIgnoredRatherThanCountedAsGrey() {
        let colourWithHole = image { x, y in
            x < 32 ? (0, 0, 0, 0) : (220, 40, 60, 255)
        }
        XCTAssertFalse(CoverColour.isMonochrome(colourWithHole))
    }

    /// A fully transparent picture says nothing, and the safe answer is the
    /// ordinary treatment rather than a badge about artwork nobody has seen.
    func testAnEmptyPictureIsNotClaimedToBeGrey() {
        XCTAssertFalse(CoverColour.isMonochrome(image { _, _ in (0, 0, 0, 0) }))
    }
}

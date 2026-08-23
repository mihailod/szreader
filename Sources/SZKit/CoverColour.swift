import CoreGraphics
import Foundation

/// Whether a cover carries any colour.
///
/// The shelf says "downloaded" by showing a cover in colour and "not yet" by
/// showing it grey. That is a good sign for most artwork and no sign at all
/// for artwork which is *already* grey: a scanned newspaper strip, an
/// archive.org index card, every one of the thirty-one Stripovi.com tiles.
/// Downloaded or not, they look identical, and the one thing the shelf is
/// trying to tell you is the thing it cannot say.
///
/// So the covers that cannot use that signal are found here, and given a
/// different one. Measured rather than guessed per source, because "this
/// source is black and white" is not true of any source for long — StripZona
/// carries both, and a colour cover can appear in any catalogue tomorrow.
public enum CoverColour {

    /// How far apart a pixel's channels must be before it counts as coloured.
    ///
    /// Out of 255, so this is about a 9% spread. Well above the tint left by
    /// JPEG chroma subsampling on a grey scan, and well below any colour a
    /// person would call colour.
    static let chromaThreshold = 24

    /// How many coloured pixels a picture may have and still read as grey.
    ///
    /// Not zero, and that is the whole reason this is a proportion rather than
    /// a test for "any colour at all". A black and white scan saved as JPEG
    /// comes back with coloured fringes along every hard edge, and a page of
    /// line art is nothing but hard edges — so a strict test calls the most
    /// obviously grey artwork in the library colourful.
    static let colouredShare = 0.02

    /// The size the picture is sampled at.
    ///
    /// Small on purpose: this runs once per cover, and a 32x32 average is a
    /// better judge of overall colour than a scattering of full-size pixels
    /// would be — downsampling averages the fringing away rather than landing
    /// on it.
    static let sampleSide = 32

    /// Whether this artwork is grey enough that showing it in colour would say
    /// nothing.
    ///
    /// False when the picture cannot be read at all, which is the safe
    /// direction: an unreadable cover gets the ordinary treatment rather than
    /// a badge claiming something about artwork nobody has seen.
    public static func isMonochrome(_ image: CGImage) -> Bool {
        let side = sampleSide
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let bitmap = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &pixels,
                                      width: side, height: side,
                                      bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: bitmap)
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))

        var coloured = 0, counted = 0
        for pixel in stride(from: 0, to: pixels.count, by: 4) {
            // Transparent pixels are not evidence either way, and a cover
            // with a cut-out corner should not be judged on its hole.
            guard pixels[pixel + 3] > 8 else { continue }
            counted += 1
            let r = Int(pixels[pixel]), g = Int(pixels[pixel + 1]), b = Int(pixels[pixel + 2])
            if max(r, g, b) - min(r, g, b) > chromaThreshold { coloured += 1 }
        }
        // Nothing opaque to judge.
        guard counted > 0 else { return false }
        return Double(coloured) / Double(counted) <= colouredShare
    }
}

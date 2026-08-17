import CoreGraphics

/// Panning limits for a zoomed page.
///
/// Pure arithmetic, kept out of the view so the edge cases can be tested: the
/// awkward ones are a page narrower than the screen, a zoom of exactly 1, and
/// the axis that has no slack because the image already fits it.
public enum ZoomPan {

    /// The size the page occupies at zoom 1, fitted inside `box`.
    public static func fittedSize(image: CGSize, box: CGSize) -> CGSize {
        guard image.width > 0, image.height > 0, box.width > 0, box.height > 0 else { return .zero }
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }

    /// The zoom at which the page meets both sides of the box.
    ///
    /// The reader applies this in landscape only, where fitting a comic page
    /// by its height leaves it stranded in wide margins. Widening it to the
    /// screen runs it off the top and bottom, which is what panning is for.
    ///
    /// Not applied in portrait, though it would be greater than one there
    /// too: a scan is a little narrower than an iPad, so filling the width
    /// would crop the top and bottom of a page that currently fits whole.
    /// Never below one, so a page already wider than the box is not shrunk.
    public static func widthFillZoom(image: CGSize, box: CGSize) -> CGFloat {
        let fitted = fittedSize(image: image, box: box)
        guard fitted.width > 0 else { return 1 }
        return max(box.width / fitted.width, 1)
    }

    /// How far the page may be dragged from centre before its edge would come
    /// inside the screen. Zero on an axis with no overflow, which is what stops
    /// a page sliding away from under the reader.
    public static func maxOffset(image: CGSize, box: CGSize, zoom: CGFloat) -> CGSize {
        let fitted = fittedSize(image: image, box: box)
        return CGSize(width: max((fitted.width * zoom - box.width) / 2, 0),
                      height: max((fitted.height * zoom - box.height) / 2, 0))
    }

    /// `offset` held within those limits.
    public static func clamp(_ offset: CGSize, image: CGSize, box: CGSize,
                             zoom: CGFloat) -> CGSize {
        let limit = maxOffset(image: image, box: box, zoom: zoom)
        return CGSize(width: min(max(offset.width, -limit.width), limit.width),
                      height: min(max(offset.height, -limit.height), limit.height))
    }

    /// Where the page must sit for the point under a pinch to stay under it.
    ///
    /// The page is scaled about its own middle, so a zoom on its own always
    /// pulls the middle of the page towards the reader — pinch a panel in the
    /// corner and the corner runs away off the screen, which is what made
    /// zooming feel like it was ignoring where your fingers were.
    ///
    /// `pinch` is where the fingers are, measured from the middle of the box.
    /// A point sits on screen at `middle + content × zoom + offset`, so
    /// holding it still across a change of zoom means
    ///
    ///     offset' = offset × k + pinch × (1 − k),  k = new ÷ old
    ///
    /// which is a pan towards whatever is being pulled apart. Clamped like any
    /// other pan, so the page still cannot be dragged away from its own edges.
    public static func focused(_ offset: CGSize, pinch: CGSize,
                               from: CGFloat, to: CGFloat,
                               image: CGSize, box: CGSize) -> CGSize {
        guard from > 0 else { return clamp(offset, image: image, box: box, zoom: to) }
        let k = to / from
        let moved = CGSize(width: offset.width * k + pinch.width * (1 - k),
                           height: offset.height * k + pinch.height * (1 - k))
        return clamp(moved, image: image, box: box, zoom: to)
    }
}

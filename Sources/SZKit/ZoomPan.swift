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
}

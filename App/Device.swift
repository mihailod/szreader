import UIKit

/// Which kind of device this is.
///
/// The chrome was laid out for an iPad and assumes a screen about a thousand
/// points wide: one row holding the search field, a segmented control, two
/// menus and the Import button. On a phone the fixed parts of that row come to
/// more than the whole screen, so the search field — the only flexible one —
/// is squeezed to nothing and everything after it runs off the edge.
///
/// The phone gets its own arrangement in those few places. Gated on the idiom
/// rather than the horizontal size class deliberately: an iPad is `.compact`
/// in Slide Over and in a narrow split, so a size-class test would change how
/// the iPad behaves. This one is false on every iPad, in every window size, so
/// the iPad keeps exactly the layout that was built and tested for it.
enum Device {
    static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
}

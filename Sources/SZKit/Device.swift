import Foundation

/// What to call the machine the reader is holding, in front of the reader.
///
/// Written into any sentence about where a file physically is. "Removed from
/// this iPhone", reaching somebody holding an iPad, is wrong in the most
/// alarming possible way, because the sentences that name the device are the
/// ones asking permission to delete things.
///
/// Not a general-purpose "device": that word is right when several are meant,
/// or when the sentence is about the *other* machines an iCloud account
/// reaches, and those sentences should go on saying it. This is for the one
/// being held.
///
/// Told rather than detected, which is the whole shape of this type. Asking
/// UIKit is a main-actor call and this is read from copy that is not on the
/// main actor; more to the point, the kit has no business importing UIKit to
/// answer a question the app layer already knows. `Device.isPhone` in the app
/// is the one place that looks, and it says so here at launch.
public enum DeviceName {

    /// Deliberately a word that is true everywhere.
    ///
    /// The default is what a sentence reads if the app never gets round to
    /// saying which machine this is — off-device in a test, or because
    /// somebody removed the call. "Removed from this device" is vague; it is
    /// not *wrong*, which is the property that matters for a default nobody
    /// will notice is in force.
    nonisolated(unsafe) public private(set) static var current = "device"

    /// Said once, at launch, by the app layer.
    public static func declare(_ name: String) { current = name }
}

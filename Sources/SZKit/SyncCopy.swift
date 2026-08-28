import Foundation

/// What the app says about a library that arrived from iCloud.
///
/// In the kit for the reason `DeleteCopy` is: copy that lives in the app
/// target cannot be called by a test, and the only thing anybody could do with
/// it was read the source and guess. The singular and plural of a sentence
/// with three agreements in it is exactly the thing that breaks quietly.
public enum SyncCopy {

    /// The title over the notice.
    public static let restoredLibraryTitle = "Library restored"

    /// Said once per device, when the shelf is full and nothing is on it.
    ///
    /// The state it explains is specific and genuinely puzzling: every issue
    /// present, every cover grey, nothing opening. It happens two ways — a new
    /// device taking the whole library over the account, and a restored one
    /// whose shelf came back inside the iCloud backup while the files did not,
    /// the folder they live in being excluded from backup on purpose.
    ///
    /// One sentence for both, because the reader is looking at the same thing
    /// either way and does not care which road it came down.
    ///
    /// "Links", never "comics" or even "issues" here: what was restored is
    /// genuinely the pointers and not the reading material, and saying so is
    /// what makes the next clause make sense.
    public static func restoredLibraryMessage(count: Int) -> String {
        let subject = count == 1
            ? "Your 1 library link was"
            : "Your \(count) library links were"
        let ready = count == 1 ? "is" : "are"
        return "\(subject) restored from iCloud and \(ready) ready for "
             + "individual re-download."
    }
}

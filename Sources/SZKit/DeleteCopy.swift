import Foundation

/// What the app says before it destroys something.
///
/// In the kit rather than beside the alerts that show it, and moved here after
/// the second time a lint over the source text failed on its own formatting
/// rather than on the copy. The app target has no tests of its own, so this
/// wording could only ever be checked by reading the file it lived in and
/// guessing — which called a sentence missing because it was wrapped across
/// two lines, and called a conditional one unconditional because the `?` sat
/// after a newline. Here the sentences can simply be asked for and read.
///
/// Every one of these has to be exact about **scope**, which is the whole
/// reason they are worth testing. Since the library syncs, three of them
/// destroy things on devices that are not in the room; the rest — downloads,
/// and the reader's own files — do not. An alert that gets that backwards
/// either loses somebody's library or frightens them out of tidying up.
public enum DeleteCopy {

    /// The sentence that says a deletion is not local.
    ///
    /// One constant, so the singular and plural forms cannot drift apart and
    /// so there is one place to change what it promises.
    static let reachesOtherDevices =
        " deleted from StreamZine apps on all other devices "
        + "logged into this iCloud account."

    /// The name goes in only when there is one.
    ///
    /// A magazine listed as "Alef - SF magazin 01" has neither title nor code,
    /// and `name` is nil for it — which read as `Optional("…")` on screen
    /// when it was interpolated straight into the sentence. Unquoted "this
    /// issue" is what a nameless one is called instead: quoting it, as the
    /// old placeholder did, read as though the issue were actually titled
    /// that.
    /// - Parameter bytes: what the download weighs, where that is known.
    ///
    /// Said because it is the question being asked. "Remove the downloaded
    /// files" is a decision about space, and a reader making it without the
    /// number has to cancel, find the size somewhere else, and come back.
    ///
    /// Optional because the figure genuinely can be unknown: a download
    /// recorded with no size is left out of the shelf's sizes rather than
    /// reported as zero, precisely so nothing can read "not measured" as
    /// "nothing". Where it is unknown the sentence simply does not mention
    /// it — better than "(0KB)", which is a wrong number, or "(unknown size)",
    /// which is a caveat nobody can act on.
    public static func removeDownloadMessage(_ name: String?,
                                             bytes: Int64? = nil) -> String {
        let size = bytes.map { " (\(ByteSize.short($0)))" } ?? ""
        let subject = name.map { "the downloaded files for “\($0)”\(size)" }
            ?? "the downloaded files for this issue\(size)"
        return "Remove \(subject). It stays in your library and can be "
            + "downloaded again."
    }

    /// - Parameter synced: whether this device is signed into iCloud and
    ///   syncing. Deleting is not a local act when it is — the issue goes from
    ///   the reader's other devices as well, and a confirmation that does not
    ///   say so is asking them to agree to something it has not told them.
    public static func deleteMessage(_ name: String?, synced: Bool = false) -> String {
        let subject = name.map { "“\($0)”" } ?? "this issue"
        let elsewhere = synced ? " It will be also" + reachesOtherDevices : ""
        return "Delete \(subject) from the library, including any download."
            + elsewhere
            + " Getting it back means importing its page again."
    }

    /// Why Delete refused, and what is still on offer.
    ///
    /// The second half only when there is a download to remove: telling a
    /// reader they may free space they are not using explains nothing.
    public static func undeletableMessage(downloaded: Bool,
                                          on device: String = DeviceName.current) -> String {
        let refusal = "This item's location is shipped in the application's index "
            + "and cannot be deleted since there would be no way to recover it "
            + "(there is no Import for it)."
        guard downloaded else { return refusal }
        return refusal + " You can remove the download for it to free the space "
            + "on your \(device) but you cannot delete the entry."
    }

    public static func removeVisibleTitle(_ count: Int) -> String {
        "Remove \(count) download\(count == 1 ? "" : "s")?"
    }

    public static func removeVisibleMessage(_ count: Int, touchesASet: Bool,
                                            on device: String = DeviceName.current) -> String {
        // Says what is being counted, because it is not the shelf. Most of
        // what is shown is usually not downloaded — 572 issues on screen and
        // one of them on disk — and "the issue shown" read as though the
        // shelf held a single row.
        let subject = count == 1
            ? "One downloaded issue is currently shown."
            : "\(count) downloaded issues are currently shown."
        // The set caveat only when one is actually involved: warning about
        // something that cannot happen here teaches a reader to stop reading
        // these at all.
        let sets: String
        switch (touchesASet, count) {
        case (false, _): sets = ""
        case (true, 1):  sets = " It belongs to a set published as one download, "
                              + "so issues not shown here are removed too."
        default:         sets = " Some belong to sets published as one download, "
                              + "so issues not shown here are removed too."
        }
        return "\(subject) Remove \(count == 1 ? "its" : "their") files from this "
            + "\(device).\(sets) Every title stays in your library and can be "
            + "downloaded again."
    }

    /// "Item" rather than "issue" through the two delete warnings, and only
    /// them: what a delete acts on is an entry in the library — a row that may
    /// stand for a whole set — and the pair reads as one alert only if its
    /// title and its sentence use one word.
    public static func deleteVisibleTitle(_ count: Int) -> String {
        "Delete \(count) item\(count == 1 ? "" : "s")?"
    }

    /// `shipped` is how many of the issues on screen a delete will pass over.
    /// The count has to account for them: a warning that says "the 653 issues
    /// shown" and then deletes four of them is worse than no warning at all.
    ///
    /// What it does not do is explain where those issues came from. The
    /// distinction that matters to a reader is whether an Import can bring a
    /// thing back, and that is all these say.
    public static func deleteVisibleMessage(_ count: Int, shipped: Int, wholeLibrary: Bool,
                                     synced: Bool = false) -> String {
        let items: String
        if shipped == 0 {
            items = count == 1 ? "the item shown" : "the \(count) items shown"
        } else {
            items = count == 1 ? "the one imported item shown"
                               : "the \(count) imported items shown"
        }
        // Worth saying plainly: with no search and no filters the shelf is the
        // whole library, and "delete the ones shown" is then not the narrower
        // thing it sounds like.
        let scope: String
        switch (wholeLibrary, shipped) {
        case (false, _): scope = ""
        case (true, 0):  scope = " That is everything in the library."
        default:         scope = " That is every imported item in the library."
        }
        // Said only when something is actually being passed over. A caveat
        // about what cannot happen here teaches a reader to stop reading
        // these at all.
        let kept = shipped == 0 ? "" : " Items that cannot be imported again stay."
        let back = count == 1 ? "it back means importing its page"
                              : "them back means importing their pages"
        let elsewhere = synced
            ? (count == 1 ? " It will be also" + reachesOtherDevices
                          : " They will be also" + reachesOtherDevices)
            : ""
        return "Delete \(items) from the library, including any "
            + "downloads.\(scope)\(kept)\(elsewhere) Getting \(back) again."
    }

    /// Delete Library, which reaches everything an Import can bring back and
    /// nothing else.
    ///
    /// `local` is how many of the reader's own files are on the shelf. They
    /// are not deleted here — the question about them is put separately, once
    /// this one has been answered — and saying so is what stops "resetting
    /// the app to empty" being a promise this does not keep.
    public static func deleteAllMessage(_ count: Int, shipped: Int, local: Int = 0,
                                 synced: Bool = false) -> String {
        // Before the question about local files, which are this device's
        // alone and go nowhere — two different scopes in one alert, so the
        // wider one is said while the reader is still reading about it.
        let elsewhere = synced
            ? " This will also delete libraries from StreamZine apps on all "
              + "other devices logged into this iCloud account."
            : ""
        let asked = local == 0 ? ""
            : (local == 1 ? " Your one local file is asked about next."
                          : " Your \(local) local files are asked about next.")
        guard shipped > 0 else {
            let items = count == 1 ? "the one item" : "all \(count) items"
            let scope = local == 0 ? ", resetting the app to empty" : ""
            return "Delete \(items) and every download\(scope). "
                + "This cannot be undone.\(elsewhere)\(asked)"
        }
        let items = count == 1 ? "the one imported item" : "all \(count) imported items"
        return "Delete \(items) and every download of them. Items that "
            + "cannot be imported again stay. This cannot be undone.\(elsewhere)\(asked)"
    }

    /// The question the reader asked for by name: how many of their own files
    /// there are, what they weigh, and whether to remove them too.
    /// - Parameter device: what the machine in the reader's hands is called.
    ///
    /// Named rather than assumed. This said "iPad" outright, which is the one
    /// place a wrong word does real harm: somebody on an iPhone was told the
    /// files were about to leave a device they were not holding, in an alert
    /// asking them to confirm a deletion. A parameter with a default, so every
    /// call site reads as it did before and a test can ask for both.
    public static func deleteLocalFilesMessage(_ count: Int, bytes: Int64,
                                               on device: String = DeviceName.current) -> String {
        let size = ByteSize.short(bytes)
        let files = count == 1 ? "your one local file" : "all \(count) local files"
        return "Would you like to delete \(files) (\(size)) too? "
            + "They are removed from this \(device), and getting them back means "
            + "copying them over again."
    }

    /// One of them, deleted on its own from the shelf.
    public static func deleteLocalFileMessage(_ name: String?,
                                              on device: String = DeviceName.current) -> String {
        let subject = name.map { "“\($0)”" } ?? "this item"
        return "Delete \(subject) from the library and remove the file from "
            + "this \(device). Getting it back means copying it over again."
    }
}

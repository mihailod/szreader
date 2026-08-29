import Foundation

/// What the app says when a file the reader handed it does not arrive.
///
/// In the kit rather than beside the alerts, for the reason `DeleteCopy`
/// explains: the app target has no tests of its own, so wording that lives
/// there can only be checked by reading it and guessing.
///
/// These say **nothing is on the shelf**, which is the fact that makes them
/// worth interrupting for. Everything else the app refuses leaves a row
/// behind — a download that failed keeps its issue, its cover and a button to
/// try again. A file that is turned away here leaves no trace at all: no row,
/// no tile, nothing in the folder. A status line that has already scrolled
/// away is then the only evidence the reader ever handed it over, and the
/// shelf looks exactly as it did before they tried.
public enum ImportCopy {

    /// What the folder accepts, spelled for a reader rather than as
    /// extensions.
    ///
    /// Read off `LocalFiles.readableExtensions` rather than typed out, so a
    /// format added there cannot go unmentioned here — the sentence exists to
    /// tell somebody what to hand over instead, and a list that has quietly
    /// fallen a format behind sends them away from one that would have worked.
    public static var acceptedFormats: String {
        let spelled = LocalFiles.readableExtensions.map { $0.uppercased() }.sorted()
        guard let last = spelled.last else { return "" }
        return spelled.dropLast().joined(separator: ", ") + " or " + last
    }

    /// A file this app will not open, turned away before anything was copied.
    ///
    /// Named separately from the failures below because it is the one the
    /// reader can act on: nothing went wrong, the file is simply not an
    /// issue, and saying which formats are wanted is the whole of the answer.
    public static let unsupportedTitle = "Not a file this app can open"

    public static func unsupportedMessage(_ name: String) -> String {
        "“\(name)” was not taken in.\n\nIssues are \(acceptedFormats) files."
    }

    /// A file that should have worked and did not.
    public static let refusedTitle = "Could not take it in"

    /// - Parameter reason: what the system said, where the caller has it.
    ///
    /// Included when it is known and simply left out when it is not, rather
    /// than replaced with a phrase like "an unknown error": the two failures
    /// this covers are a copy that threw and a copy that returned nothing,
    /// and only the first has anything to report. A sentence promising a
    /// reason and then not giving one reads as the app having lost it.
    public static func refusedMessage(_ name: String, reason: String? = nil) -> String {
        let why = reason.map { "\n\n\($0)" } ?? ""
        return "“\(name)” could not be copied into your files, "
             + "so it is not on the shelf.\(why)"
    }

    /// Several at once, from Import ▸ From Device.
    ///
    /// The names are listed rather than counted. A reader who picked eleven
    /// files and is told that three did not arrive has to work out which
    /// three by comparing the shelf against the Files app; the app already
    /// knows, and the whole point of interrupting is to say the part they
    /// cannot see.
    ///
    /// Capped, because the picker will hand over as many files as the reader
    /// selects and an alert cannot hold a hundred names. The overflow is
    /// counted rather than dropped silently.
    public static func refusedMessage(_ names: [String], of total: Int,
                                      listing limit: Int = 8) -> String {
        guard names.count > 1 else {
            return refusedMessage(names.first ?? "")
        }
        let listed = names.prefix(limit).map { "• \($0)" }.joined(separator: "\n")
        let rest = names.count - min(names.count, limit)
        let more = rest > 0 ? "\n• and \(rest) more" : ""
        return "\(names.count) of \(total) files could not be taken in, "
             + "so they are not on the shelf.\n\n\(listed)\(more)"
    }

    /// The heading over that list.
    public static func refusedTitle(_ count: Int) -> String {
        count == 1 ? refusedTitle : "Some files were not taken in"
    }
}

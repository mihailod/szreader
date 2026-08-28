import Foundation

/// Bytes, in the short form the shelf and its alerts use.
///
/// Deliberately not `ByteCountFormatter`: that says "1.2 MB" with a space and
/// localises the unit, and every one of these numbers appears mid-sentence
/// beside a title where the compact form reads better and stays put.
///
/// Here rather than in the view that first needed it because `DeleteCopy` says
/// how much a delete would free, and copy that cannot be built without a view
/// cannot be tested without one.
public enum ByteSize {

    public static func mb(_ bytes: Int64) -> String {
        "\(Int((Double(bytes) / 1_000_000).rounded()))MB"
    }

    /// Kilobytes below a megabyte, and never "0KB": a file small enough to
    /// round to nothing is still a file, and reporting nothing reads as an
    /// error rather than as a small number.
    public static func short(_ bytes: Int64) -> String {
        bytes < 1_000_000
            ? "\(max(1, Int((Double(bytes) / 1_000).rounded())))KB"
            : mb(bytes)
    }
}

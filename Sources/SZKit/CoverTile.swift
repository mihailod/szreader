import Foundation

/// One cover inside a contact sheet.
///
/// Some topics illustrate a group of issues with a single image holding a
/// grid of their covers, then list the issues underneath. The image is not
/// any one issue's cover, so a cover URL alone cannot express what an issue
/// should show — it needs to say *which part* of the image.
///
/// The reference is the image's own URL with a fragment naming the tile:
///
///     https://i.imgur.com/jGPdAZ2.jpg#tile=3/6
///
/// A fragment because it stays a valid URL, so everything that only wants to
/// fetch, cache or compare it keeps working — only the decoder needs to know.
public struct CoverTile: Equatable, Sendable {
    /// The sheet to fetch.
    public let sheet: String
    /// Which tile, counting left to right and then down, from zero.
    public let index: Int
    /// How many covers the sheet holds.
    public let count: Int

    /// Sheets are three across; six means a second row.
    public var columns: Int { 3 }
    public var rows: Int { max(count / columns, 1) }
    public var column: Int { index % columns }
    public var row: Int { index / columns }

    private static let marker = "#tile="

    public static func reference(_ url: String, tile: Int, of count: Int) -> String {
        "\(url)\(marker)\(tile)/\(count)"
    }

    /// Reads a reference back, or nil for an ordinary cover URL.
    public init?(reference: String) {
        guard let range = reference.range(of: Self.marker) else { return nil }
        let parts = reference[range.upperBound...].split(separator: "/")
        guard parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]),
              count > 0, index >= 0, index < count else { return nil }
        self.sheet = String(reference[..<range.lowerBound])
        self.index = index
        self.count = count
    }
}

import Foundation
import SZKit

/// Joystik, whose ten issues sit on neither of the hosts the rest of the
/// catalogue comes from.
///
/// The bombjack page for it is a shop window: it shows the covers and links
/// out, and the scans themselves live on `arcarc.xmission.com`. So this run is
/// assembled from two places rather than walked, and it is written out by hand
/// because it is ten rows and the run is finished — the page states that nine
/// regular issues and one special edition were ever published.
///
/// Two of the ten are the older, lower-quality scans, marked on the filename
/// as awaiting replacement. They are listed anyway: a readable scan of a 1983
/// magazine is worth having, and the id stays the same when a better one
/// replaces it under the same name.
extension BombJackBuild {

    static let joystikCovers = "http://bombjack.org/arcade/joystik/"
    static let joystikFiles =
        "https://arcarc.xmission.com/Magazines%20and%20Books/Joystik%20Magazines%20(10%20Issues)/"

    /// In cover-date order, which is not the order the volumes number in: the
    /// special edition is dated October 1983, a month after volume two's first
    /// issue.
    static let joystikIssues: [(file: String, cover: String, title: String,
                                year: Int, month: Int)] = [
        ("Joystik_Vol1-1_82-Sep.pdf", "1-1.jpg", "Volume 1 No. 1", 1982, 9),
        ("Joystik_Vol1-2_82-Nov.pdf", "1-2.jpg", "Volume 1 No. 2", 1982, 11),
        ("Joystik_Vol1-3_82-Dec.pdf", "1-3.jpg", "Volume 1 No. 3", 1982, 12),
        ("Joystik_Vol1-4_83-Jan-missing_p69.pdf", "1-4.jpg", "Volume 1 No. 4", 1983, 1),
        ("Joystik_Vol1-5_83-Apr.pdf", "1-5.jpg", "Volume 1 No. 5", 1983, 4),
        ("Joystik_Vol1-6_83-Jul.pdf", "1-6.jpg", "Volume 1 No. 6", 1983, 7),
        ("Joystik_Vol2-1_83-Sep.pdf", "2-1.jpg", "Volume 2 No. 1", 1983, 9),
        ("Joystik_Vol2-SE_83_Oct_(replace_me).pdf", "1983-Oct_Special%20Edition.jpg",
         "Volume 2 Special Edition", 1983, 10),
        ("Joystik_Vol2-2_83_Nov_(replace_me).pdf", "2-2.jpg", "Volume 2 No. 2", 1983, 11),
        ("Joystik_Vol2-3_83-Dec.pdf", "2-3.jpg", "Volume 2 No. 3", 1983, 12),
    ]

    static func joystik() -> (ShippedCatalog.Series, [ShippedCatalog.Issue]) {
        let series = ShippedCatalog.Series(key: "joystik", name: "Joystik",
                                           code: "joystik", language: "en")
        let issues = joystikIssues.enumerated().map { index, row in
            ShippedCatalog.Issue(
                id: "joystik_\(row.file.replacingOccurrences(of: ".pdf", with: ""))",
                series: "joystik", number: index + 1,
                title: row.title, year: row.year, month: row.month,
                zip: joystikFiles + row.file,
                cover: joystikCovers + row.cover,
                thumb: nil, bytes: nil, pages: nil, dead: nil)
        }
        return (series, issues)
    }
}

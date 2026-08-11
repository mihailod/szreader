import Foundation

/// Archives split across several downloads.
///
/// MediaFire caps a file at 100 MB for some accounts, so a large scan is
/// posted as `….part1.rar`, `….part2.rar` and so on — two links under one
/// issue that are *pieces*, not alternatives. Downloading either alone yields
/// an archive that cannot be opened.
///
/// The names are the evidence: unrar joins volumes on its own, but only if
/// they sit in one directory under their real names, so the pieces have to be
/// recognised before anything is written to disk.
public enum MultiPartArchive {

    /// The forum splits archives three ways, all of them present on one page:
    ///
    ///     ….part1            ….part2          (and with .rar appended)
    ///     …_part_1           …_part_2
    ///     …_1_deo.7z         …_2_deo.7z       ("deo" is Serbian for part)
    ///
    /// Recognising only the first would download half of the other two and
    /// leave an archive that cannot be opened — the failure a reader sees is
    /// "not a comic", with nothing to suggest the other half exists.
    ///
    /// The extension is optional throughout because the host often does not
    /// report it: MediaFire answers "….part1" for a file that lands as
    /// "….part1.rar", and the decision has to be made before downloading,
    /// when the reported name is all there is.
    private static let partSuffix = Rx(
        #"(?i)[._\s-]*(?:part[._\s-]*(\d{1,3})|(\d{1,3})[._\s-]*deo)"#
        + #"(?:\.(?:rar|7z|zip|cbr|cbz))?$"#)

    /// The volume number a filename declares, or nil when it declares none.
    public static func partNumber(in filename: String) -> Int? {
        guard let groups = partSuffix.firstGroups(filename) else { return nil }
        // One branch or the other matched; the unused group is empty.
        return Int(groups[1]) ?? Int(groups[2])
    }

    /// The name with its volume marker removed, so pieces of one archive can
    /// be recognised as belonging together.
    public static func stem(of filename: String) -> String {
        partSuffix.replacing(filename, with: "")
    }

    /// The pieces of a single archive, in volume order.
    ///
    /// Nil unless at least two of the candidates share a stem and each
    /// declares a distinct volume — two links whose names differ in any other
    /// way are alternative sources for the same comic, and downloading both
    /// would waste the second transfer.
    public static func parts<Source>(_ candidates: [(source: Source, filename: String)])
        -> [(source: Source, filename: String, part: Int)]? {

        var byStem: [String: [(Source, String, Int)]] = [:]
        for candidate in candidates {
            guard let part = partNumber(in: candidate.filename) else { continue }
            byStem[stem(of: candidate.filename), default: []]
                .append((candidate.source, candidate.filename, part))
        }
        // The largest set wins; a page listing two different split archives
        // for one issue is not something the corpus does.
        guard let group = byStem.values.max(by: { $0.count < $1.count }),
              group.count > 1,
              Set(group.map(\.2)).count == group.count      // no repeated volume
        else { return nil }

        return group.sorted { $0.2 < $1.2 }
            .map { (source: $0.0, filename: $0.1, part: $0.2) }
    }
}

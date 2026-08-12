import Foundation

/// Thin NSRegularExpression wrapper. Patterns here are compile-time constants
/// covered by tests, so `try!` is honest rather than lazy.
struct Rx {
    let re: NSRegularExpression   // exposed for enumerateMatches

    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        self.re = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /// Groups of the first match anchored anywhere, or nil. Index 0 is the
    /// whole match; a group that did not participate comes back as "".
    func firstGroups(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    func matches(_ s: String) -> Bool { firstGroups(s) != nil }


    /// All matches of group `group` (default: whole match), in order.
    func allMatches(_ s: String, group: Int = 0) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).compactMap {
            let r = $0.range(at: group)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
    }

    func replacing(_ s: String, with template: String) -> String {
        let ns = s as NSString
        return re.stringByReplacingMatches(
            in: s, range: NSRange(location: 0, length: ns.length), withTemplate: template)
    }
}

extension [String] {
    /// A capture group that the pattern may not have.
    ///
    /// `firstGroups` sizes its result to the pattern, so indexing a group
    /// directly is only safe while that group exists. A trailing optional one
    /// — a title after a code, say — is exactly the kind that gets added and
    /// removed again, and indexing it blind turns a pattern edit into a crash
    /// rather than a failing test.
    func capture(_ index: Int) -> String {
        indices.contains(index) ? self[index] : ""
    }
}

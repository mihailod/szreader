import Foundation

/// Expands one ZXDB URL mask into the URL of one issue.
///
/// ZXDB does not record a URL per magazine issue. It records a *template* on
/// the magazine — `.../crash-magazine-{i2}{s}{u-}/Crash_{i2}_{M3}_{y4}.pdf` —
/// and expands it against each issue's own numbers. Eleven thousand issues
/// are reachable through 272 of these, so the templates are the whole source:
/// a token read wrongly does not fail loudly, it produces eleven thousand
/// plausible URLs that 404.
///
/// In SZKit rather than beside the build tool, for the reason `RetroSpecCatalog`
/// is: the catalogue that ships has to be produced by code the tests cover.
///
/// The token vocabulary below is not the README's — it is what the published
/// dump actually uses, all nineteen of them, counted across every mask in the
/// `magazines` and `issues` tables.
public enum ZXDBMask {

    /// The fields a mask is allowed to reference.
    public struct Issue: Equatable, Sendable {
        public let number: Int?
        public let volume: Int?
        public let year: Int?
        public let month: Int?
        public let day: Int?
        /// A named issue — "Spring", "Yearbook" — where the run has one.
        public let special: String?
        /// A supplement bound into the issue, named the same way.
        public let supplement: String?

        public init(number: Int? = nil, volume: Int? = nil, year: Int? = nil,
                    month: Int? = nil, day: Int? = nil,
                    special: String? = nil, supplement: String? = nil) {
            self.number = number; self.volume = volume; self.year = year
            self.month = month; self.day = day
            self.special = special; self.supplement = supplement
        }
    }

    /// Why a mask could not be expanded.
    public enum Unresolved: Error, Equatable, Sendable {
        /// The mask asks for a field this issue does not have — `{i2}` on an
        /// issue with no number. Such an issue is unreachable through this
        /// mask, and saying so is the point: the alternative is emitting a URL
        /// with a hole in it.
        case missing(field: Character)
        /// A `{...}` this expander does not know. New tokens are how ZXDB
        /// would break this quietly, so an unknown one is an error rather
        /// than a passthrough.
        case unknownToken(String)
    }

    // MARK: - Expanding

    /// The mask with every token replaced, or why it could not be.
    public static func expand(_ mask: String, for issue: Issue)
        -> Result<String, Unresolved>
    {
        var out = ""
        var rest = Substring(mask)

        while let open = rest.firstIndex(of: "{") {
            out += rest[rest.startIndex..<open]
            guard let close = rest[open...].firstIndex(of: "}") else {
                // An unbalanced brace is literal text, not a token.
                out += rest[open...]
                return .success(out)
            }
            let token = String(rest[rest.index(after: open)..<close])
            switch substitute(token, for: issue) {
            case .success(let text): out += text
            case .failure(let why):  return .failure(why)
            }
            rest = rest[rest.index(after: close)...]
        }
        out += rest
        return .success(out)
    }

    /// One token's replacement.
    private static func substitute(_ token: String, for issue: Issue)
        -> Result<String, Unresolved>
    {
        guard let kind = token.first else { return .failure(.unknownToken(token)) }
        let argument = String(token.dropFirst())

        switch kind {
        // Numbers, zero-padded to *at least* the given width. `{i3}` on issue
        // 7 is "007"; on issue 1234 it is "1234", not a truncation.
        case "i": return pad(issue.number, argument, field: "i")
        case "v": return pad(issue.volume, argument, field: "v")
        case "m": return pad(issue.month,  argument, field: "m")
        case "d": return pad(issue.day,    argument, field: "d")

        // The year is the one number that is *not* simply padded. `{y4}` is
        // 1984 and `{y2}` is 84 — read as a minimum width, the two would be
        // identical for every four-digit year in the database, and `{y2}`
        // would be a token nobody had a reason to write. It appears 54 times.
        case "y": return year(issue.year, argument)

        // Month name in English, cut to exactly the given number of letters:
        // `{M3}` is "Apr", bare `{M}` is "April".
        case "M": return monthName(issue.month, argument)

        // The two optional strings. Unlike every token above, a missing value
        // is not a failure — it expands to nothing, *including* the separator
        // the token carries. `crash-magazine-{i2}{s}{u-}` is how an ordinary
        // numbered issue becomes `crash-magazine-01`.
        case "s": return .success(decorate(issue.special, with: argument))
        case "u": return .success(decorate(issue.supplement, with: argument))

        default: return .failure(.unknownToken(token))
        }
    }

    // MARK: - Token kinds

    private static func pad(_ value: Int?, _ argument: String, field: Character)
        -> Result<String, Unresolved>
    {
        guard let value else { return .failure(.missing(field: field)) }
        let width = Int(argument) ?? 1
        var text = String(value)
        while text.count < width { text = "0" + text }
        return .success(text)
    }

    private static func year(_ value: Int?, _ argument: String)
        -> Result<String, Unresolved>
    {
        guard let value else { return .failure(.missing(field: "y")) }
        guard argument == "2" else { return .success(String(value)) }
        return .success(String(format: "%02d", value % 100))
    }

    /// English month names. Hard-coded rather than taken from `DateFormatter`
    /// because these become URLs on an American server: they must not follow
    /// the reader's locale, or the same catalogue built in Belgrade and in
    /// London would name different files.
    public static let months = ["January", "February", "March", "April", "May", "June",
                         "July", "August", "September", "October", "November",
                         "December"]

    private static func monthName(_ value: Int?, _ argument: String)
        -> Result<String, Unresolved>
    {
        guard let value, (1...12).contains(value) else {
            return .failure(.missing(field: "M"))
        }
        let name = months[value - 1]
        guard let letters = Int(argument), letters < name.count else {
            return .success(name)
        }
        return .success(String(name.prefix(letters)))
    }

    /// An optional string, with the separator the token names.
    ///
    /// `{u-}` is "the supplement, preceded by a hyphen"; `{u}` is the
    /// supplement with nothing in front. The argument is a literal character,
    /// not a width — the one place ZXDB's `{x#}` shape means something other
    /// than a number, and the easiest token in the set to misread.
    private static func decorate(_ value: String?, with separator: String) -> String {
        guard let value, !value.isEmpty else { return "" }
        return separator + value
    }

    // MARK: - URLs

    /// The expanded mask as a URL, percent-encoding anything the substituted
    /// values introduced.
    ///
    /// Masks arrive already encoded — they contain literal `%20` — so only the
    /// values are a risk, and only `special`/`supplement` can carry a space.
    /// Encoding the whole string would double-encode those existing `%`s.
    public static func url(_ mask: String, for issue: Issue) -> Result<URL, Unresolved> {
        expand(mask, for: issue).flatMap { text in
            let escaped = text.replacingOccurrences(of: " ", with: "%20")
            guard let url = URL(string: escaped) else {
                return .failure(.unknownToken(text))
            }
            return .success(url)
        }
    }
}

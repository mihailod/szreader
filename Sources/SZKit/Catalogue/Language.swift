import Foundation

/// What language an issue was published in.
///
/// Worth carrying because on RetroSpec it is the only thing separating two of
/// the series: Moj Mikro ran in Slovenian and in Serbo-Croatian, and the site
/// files them as two independent runs, each numbering from one. Every shipped
/// catalogue records it per series, so nothing here is specific to one source.
public enum Language: String, Equatable, Sendable, CaseIterable {
    case serbian, croatian, slovenian, bosnian

    /// The word RetroSpec prints on `magshow.php`, which is what a parse of
    /// that page has to match. Bosnian is absent on purpose: the site files
    /// nothing under it, and a word it never prints cannot be matched.
    init?(siteWord: String) {
        switch siteWord.trimmingCharacters(in: .whitespaces).lowercased() {
        case "srpski":                 self = .serbian
        case "hrvatski", "srbohrvaški": self = .croatian
        case "slovenski", "slovenščina": self = .slovenian
        default: return nil
        }
    }

    public var display: String {
        switch self {
        case .serbian:   return "Serbian"
        case .croatian:  return "Croatian"
        case .slovenian: return "Slovenian"
        case .bosnian:   return "Bosnian"
        }
    }
}

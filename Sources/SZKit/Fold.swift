import Foundation

/// Search-key normalisation.
///
/// Titles arrive with and without diacritics from different uploaders —
/// `Kuca uzasa` and `Kuća užasa` are the same comic — and nobody types
/// diacritics into an iPad search field. Folding both the stored key and the
/// query makes the distinction disappear.
public enum Fold {

    private static let punctuation = Rx(#"[^\p{L}\p{N}\s]"#)
    private static let whitespaceRun = Rx(#"\s+"#)

    public static func fold(_ s: String) -> String {
        // đ/Đ are distinct letters, not decomposable diacritics, so
        // .diacriticInsensitive leaves them alone. Map them explicitly.
        var t = s.replacingOccurrences(of: "đ", with: "d")
                 .replacingOccurrences(of: "Đ", with: "D")
        t = t.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        t = punctuation.replacing(t, with: " ")
        t = whitespaceRun.replacing(t, with: " ")
        return t.trimmingCharacters(in: .whitespaces)
    }
}

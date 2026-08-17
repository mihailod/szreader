import Foundation

/// The label conventions observed across the corpus.
///
/// Five uploader communities on the same forum, five ways of naming an issue.
/// Each was found by surveying real topic pages; none can be assumed away.
public enum LabelStyle: String, Sendable {
    /// `MN_LMS_511` alone on a line, URLs on following lines. (Mister No)
    case labeledBlock
    /// `MM_LMS_031 - <url>` — code and URL on one line. (Martin Mystere)
    case labeledInline
    /// `013-Nasilje u Darkvudu`, URL on the next line. (Zagor)
    case inlinePrevLine
    /// `001 (SSB 089/001) - Grupa TNT - <url>`. (Alan Ford)
    case inlineSameLine
    /// `Kolorka 2 Title (Author) (Date)` — name before number. (FIBRA, Alef, Asteriks)
    case nameFirst
}

enum Labels {

    // "013-Title" / "ZS 0418 - ZAGOR - Title" / "001 (SSB 089/001) - Title"
    //
    // The optional run before the separator is a hero name and the story's
    // own number, which some reprint topics carry between the collection
    // number and the title: "01 (SS 173) Johnny Logan 001 - Crni tigrovi".
    // It has to end in digits — a bare name there would swallow the first
    // half of any title written "05 (drzeko) Neki naslov - nastavak".
    static let num = Rx(
        #"^(?:[A-ZČĆŠŽĐ]{2,5}\s+)?(\d{1,4})\s*(?:\([^)]*\))?"#
        + #"(?:\s*[A-Za-zČĆŠŽĐčćšžđ][A-Za-zČĆŠŽĐčćšžđ\s]{1,30}?\s+\d{1,4})?"#
        + #"\s*[-–.]\s*(.+?)\s*$"#)

    /// A label that is nothing but the issue's number: "01 <url>".
    ///
    /// Ken Parker's topic is a bare list — a padded number, a space, the link,
    /// and no title anywhere on the page. Every other style here needs a
    /// separator and something after it, so all 79 of its links went
    /// unattributed.
    ///
    /// Safe because of where it is applied rather than what it matches: the
    /// classifier has already discarded every URL on a `noise` host, and the
    /// only other thing in the corpus shaped like this is the forum's own
    /// pagination — "2 …showtopic=933&page=2" — which is a stripzona.com link
    /// and so never reaches here. Measured across the corpus: this fires on
    /// one page.
    ///
    /// `\s` rather than a trimmed string: the classifier trims plain spaces,
    /// and what sits after the number here is the non-breaking space IPB
    /// writes as `&nbsp;`. ICU's `\s` covers it; the trim set did not, so the
    /// label arrived as "01\u{00A0}" and matched nothing.
    static let bareNumber = Rx(#"^\s*0*(\d{1,4})\s*$"#)

    // "MN_LMS_511", and "ZS_85 - Komadant Mark" where the code is followed by
    // the title. TN_* are cover thumbnails hotlinked from stripovi.com, not
    // labels. The title is group 3; the code and number keep their positions,
    // because callers that only want the number index by them.
    static let code = Rx(
        #"^(?!TN_)([A-ZČĆŠŽĐ][A-Z0-9ČĆŠŽĐ_]*_(\d{1,5}))(?:\s*[-–]\s*(.+?))?\s*$"#)

    // Name before number, optional title, trailing (author) (date) groups.
    private static let letter = "A-Za-zČĆŠŽĐčćšžđ"
    // Words may be joined by a dash as well as a space: Alef lists its issues
    // as "Alef - SF magazin 01 (scanners)", and a name that allows only spaces
    // stops at the first hyphen and matches nothing.
    static let nameNum = Rx(
        "^([\(letter)][\(letter)]{1,14}(?:(?:\\s+|\\s*[-–]\\s*)[\(letter)]{2,14}){0,3})"
        // The number may be introduced by a dash as well as a space: Korto
        // Malteze writes "Corto Maltese - 01 - Mladost", and a separator that
        // allows only whitespace stops at the dash and matches nothing.
        + "(?:\\s+|\\s*[-–]\\s*)(\\d{1,4})\\s*[-–_.:]?\\s*(.*)$")
    static let trailingParens = Rx(#"(?:\s*[\(\[][^)\]]*[\)\]])+\s*$"#)

    /// A trailing archive extension or a size, which describe the file rather
    /// than the comic: "… 24Mb", "… 77.43 MB", "….cbr".
    /// A trailing extension or size, and the volume marker of a split
    /// archive: these describe the file rather than the comic.
    ///
    /// ".part1" matters as much as ".rar" — Galaksija posts its halves as
    /// "Galaksija 213 (1990) (with levels) (Tvinsi).part1", and leaving the
    /// marker on made each half a comic of its own, so one issue arrived as
    /// three rows sharing a number.
    static let fileNoise = Rx(
        #"(?i)(?:\s*\.part\s*\d{1,3})?"#
        + #"(?:\s*\.(?:cbr|cbz|rar|zip|7z|pdf))?"#
        + #"(?:\s*\.part\s*\d{1,3})?"#
        + #"(?:\s*[\(\[]?\s*\d+(?:[.,]\d+)?\s*[MG]B?\s*[\)\]]?)?\s*$"#)

    /// Lines that look like labels but are forum chrome. Without this,
    /// "Posted 06 March 2011 - 09:26 PM" becomes a label and claims every
    /// link that follows it.
    static let furniture: Set<String> = [
        "posted", "edited", "brojevi", "broj", "hvala", "format", "izlazilo",
        "popular", "attached", "quote", "report", "download", "novo",
        "update", "edit", "uploader", "scan", "str", "strana", "page",
        // Notes the posters leave between the links, which read as a series
        // followed by a number: "Fali stranica 37." (a page is missing),
        // "Linkovi za Galaksiju 101" (links for…), "Ne mislim na broj 105"
        // (I don't mean issue…). Each of them otherwise becomes an issue and
        // claims the next link posted.
        "fali", "linkovi", "ne", "stranica",
    ]

    struct NameNum { let number: String; let title: String?; let name: String }

    static func matchNameFirst(_ line: String) -> NameNum? {
        guard line.count <= 120, !line.lowercased().contains("http"),
              let g = nameNum.firstGroups(line),
              let head = g[1].split(separator: " ").first,
              !furniture.contains(head.lowercased())
        else { return nil }
        // Size and filename first, then trailing parentheses.
        //
        // Order matters: "Etiopljani (boja preklop by fantom).cbr" only has a
        // trailing bracket once the extension is gone. Without this the same
        // comic arrives twice — once plain, once with a size or filename stuck
        // to it — and the two land as separate issues because the title is
        // part of the natural key.
        // Trailing punctuation first: these lists introduce their link with a
        // colon — "Galaksija 091 (stvarni izgled) (drazen23) [217 MB]:" — and
        // both the size and the bracket strippers anchor to the end, so one
        // stray character leaves the whole tail sitting there as a title.
        let tail = g[3].trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:;,"))
        let title = trailingParens
            .replacing(fileNoise.replacing(tail, with: ""), with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:"))
        guard title.isEmpty || readsAsATitle(title) else { return nil }
        // A month and a year is a caption, not an issue: "januar 1982." reads
        // as issue 1982 of a series called "januar". No run in this corpus
        // reaches four figures, so a year-shaped number with nothing after it
        // is a date every time.
        if title.isEmpty, let n = Int(g[2]), (1900...2099).contains(n) { return nil }
        return NameNum(number: g[2], title: title.isEmpty ? nil : title, name: g[1])
    }

    /// Whether what follows a number is a title or the rest of a sentence.
    ///
    /// Forum prose reads as a label all too easily: "Ne mislim na broj 105
    /// (stvarni izgled), nego na obradu broja 105" parses as issue 105 of a
    /// series called "Ne mislim na broj", and then claims every link after
    /// it. So does a caption — "Stranica 37 iz Galaksije broj 297".
    ///
    /// A title starts where a sentence continues: with a capital or a number,
    /// never mid-clause in lower case. Digits are allowed to lead because
    /// "900 Baka" is a real title, but something with no letters at all is a
    /// list of poster numbers rather than a name.
    /// A sub-volume suffix belongs to the number, not the title: Corto
    /// Maltese numbers two of its books "03a" and "03b", which the number
    /// parse leaves at the front as "a - Karipska svita".
    private static let volumeSuffix = Rx(#"^[a-z]\s*[-–_.:]\s*"#)

    static func readsAsATitle(_ title: String) -> Bool {
        let body = volumeSuffix.replacing(title, with: "")
        guard body.filter(\.isLetter).count >= 2 else { return false }
        guard let first = body.first(where: { $0.isLetter || $0.isNumber })
        else { return false }
        return !first.isLowercase
    }

    /// A range of issues rather than one: "Sirius 001-116 (pdf)".
    ///
    /// The same topics that label a link after it also post collected
    /// volumes — every issue as one PDF — and those read as an issue with a
    /// title beginning in digits.
    ///
    /// No spaces around the dash, which is what separates a range from a
    /// title that starts with a number: the bundles are written
    /// "Sirius 001-116 (pdf)", while issue 99 is "Sirius 099 - 900 Baka" and
    /// is a real comic that a looser rule throws away.
    private static let numericRange = Rx(#"\d+[-–]\d+"#)

    /// A whole line that is nothing but a range of issue numbers:
    /// "151.-160.", "181.,182.,183.,184.".
    ///
    /// Posts on long topics end with one of these summarising what the post
    /// contained. It is not a label, and left as one it becomes a pending
    /// label that claims whatever link comes next.
    ///
    /// Distinct from `numericRange`, which asks whether a *label* contains a
    /// range; this asks whether the line has anything else in it at all. A
    /// line with a title in it — "Sirius 099 - 900 Baka" — has letters and is
    /// not this.
    private static let onlyNumbers = Rx(#"^[\s\d.,;:()\[\]/–-]+$"#)

    static func isNumericRange(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        // Two numbers minimum, so a bare "151." pending label still works.
        guard t.count >= 4, onlyNumbers.matches(t) else { return false }
        return Rx(#"\d"#).allMatches(t).count >= 2
    }

    /// One issue printed as two: "Sirius 121/122 - Euroconski dvoboj".
    ///
    /// Consecutive by definition — that is what tells a double issue from a
    /// collected volume covering a hundred of them.
    static let doubleNumber = Rx(#"^(\d{1,4})\s*[/–-]\s*(\d{1,4})\b"#)

    /// The pair of numbers a double issue carries, if that is what this is.
    static func doubleIssue(in text: String) -> (first: Int, second: Int)? {
        guard let g = doubleNumber.firstGroups(text),
              let first = Int(g[1]), let second = Int(g[2]),
              second == first + 1 else { return nil }
        return (first, second)
    }

    /// A number in another edition's numbering, given in passing:
    /// "01 (SS 173) Johnny Logan 001 - Crni tigrovi",
    /// "Timothy Tatcher 02 Hollywood protiv mene (SS 305)".
    ///
    /// Shouted letters, a number, and nothing else inside the bracket. That is
    /// deliberately narrow, because these posts bracket a great deal else —
    /// dates "(02.01.1980.)", scanner credits "(enwil-rescan 2014)", sizes —
    /// and a looser reading would file artwork under one of those. Measured
    /// across the corpus it fires on two topics, Johnny Logan's reprints and
    /// Timothy Tatcher, which are precisely the ones whose covers are named
    /// after the other number.
    ///
    /// The space is optional, and that is not a loosening for its own sake:
    /// the two Timothy Tatcher topics are written by different hands, one
    /// "(SS 305)" and the other "(SS301)(Sabko-BDS)", and requiring the space
    /// resolved the first and left the second showing no artwork. Checked
    /// against every saved page: making it optional matches nothing the strict
    /// form did not already match.
    ///
    /// No slash inside, so a compound reference "(SSB 089/001)" is refused: it
    /// names no single cover and its leading number would pick one at random.
    /// This is the same rule `Catalog.crossReference` reads within a page.
    static let catalogueReference = Rx(#"\(\s*([A-ZČĆŠŽĐ]{2,5})\s*(\d{1,5})\s*\)"#)

    static func catalogueRef(in text: String) -> CatalogueRef? {
        guard let g = catalogueReference.firstGroups(text),
              let number = Int(g[2]), number > 0 else { return nil }
        return CatalogueRef(code: g[1], number: number)
    }

    /// A label written after its link.
    ///
    /// Nil for anything that is not clearly one issue: a bundle covering a
    /// range, or text with no number in it at all.
    static func trailingLabel(_ text: String) -> IssueLabel? {
        trailingLabelText(text)?.reading(text)
    }

    private static func trailingLabelText(_ text: String) -> IssueLabel? {
        if let label = doubleTrailingLabel(text) { return label }
        guard !numericRange.matches(text) else { return nil }
        if let g = code.firstGroups(text) {
            let named = g.capture(3).isEmpty ? nil : TitleCleaner.tidyInline(g.capture(3))
            return IssueLabel(code: g[1], number: Int(g[2]), title: named)
        }
        if let g = num.firstGroups(text), g[2].count > 2, !g[2].lowercased().hasPrefix("http") {
            return IssueLabel(number: Int(g[1]), title: TitleCleaner.tidyInline(g[2]))
        }
        if let nn = matchNameFirst(text) {
            return IssueLabel(number: Int(nn.number), title: nn.title, series: nn.name)
        }
        // A special with no number of its own: "YU SIRIUS". Kept only when it
        // reads as a name, so the assorted notes that follow a link — sizes,
        // formats, remarks — do not each become an issue.
        let named = TitleCleaner.tidyInline(text)
        if TitleCleaner.isPlausible(named), named.count <= 40,
           !named.contains(where: \.isNumber), !furniture.contains(Fold.fold(named)) {
            return IssueLabel(title: named)
        }
        return nil
    }

    /// "Sirius 121/122 - Euroconski dvoboj" — the series, both numbers, then
    /// the title.
    ///
    /// The ordinary parse stops at the first number and leaves "/122 - …" as
    /// the title, which is how these arrived: numbered 121, named "/122 -
    /// Euroconski dvoboj", and with no cover, because the catalogue files
    /// them under both numbers at once.
    private static let secondOfPair = Rx(#"^[/–-]\s*(\d{1,4})\b"#)

    private static func doubleTrailingLabel(_ text: String) -> IssueLabel? {
        guard let nn = matchNameFirst(text), let first = Int(nn.number),
              let rest = nn.title,
              let g = secondOfPair.firstGroups(rest), let second = Int(g[1]),
              second == first + 1 else { return nil }

        let title = TitleCleaner.tidyInline(
            secondOfPair.replacing(rest, with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–_.:")))
        return IssueLabel(number: first, numberTo: second,
                          title: title.isEmpty ? nil : title, series: nn.name)
    }
}

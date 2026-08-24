import Foundation
import SZKit

/// Everything the app says about a source, in one place.
///
/// Each source is described twice — once under its switch, once in
/// Acknowledgements — and the two had begun to drift: Comic Book Plus listed
/// what it holds in both, in two slightly different phrasings, so correcting
/// one left the other wrong. This is the file to edit.
///
/// In the app layer rather than beside `IssueSite` in SZKit, deliberately.
/// `UIWordingTests` lints this layer for the word "comic", and copy moved into
/// the framework would quietly leave that rule behind — which is the one thing
/// stopping the shelf's vocabulary drifting back. `IssueSite.display` and
/// `settingsName` stay where they are: those are names, not prose.
struct SourceCopy {

    /// The switch label. Says when an account is needed, because that is the
    /// one thing that decides whether switching a source on achieves anything.
    let switchTitle: String
    /// One line under the switch: what the reader is turning on.
    let detail: String
    /// How the source is named in the one sentence the empty shelf uses to
    /// list what the app can draw from.
    ///
    /// A fragment, not a sentence: it is read as "…or switch on RetroSpec for
    /// <phrase>". Short on purpose — that screen names every source in one
    /// breath, and the switches with their fuller descriptions are directly
    /// below it.
    let shelfPhrase: String
    /// What the source is called in Acknowledgements. Not always the switch's
    /// name — Archive.org's entry credits the Internet Archive, the
    /// institution, rather than the domain the shelf files issues under.
    let creditHeading: String
    /// What this app is, and is not, in relation to that source.
    let credit: String

    static func of(_ site: IssueSite) -> SourceCopy {
        switch site {
        case .stripzona:     return stripzona
        case .retrospec:     return retrospec
        case .archive:       return archive
        case .comicbookplus: return comicBookPlus
        case .batcave:       return batcave
        case .stripovi:      return stripovi
        case .spectrumMagazines, .spectrumFanzines, .spectrumBooks:
            return spectrum(site)
        case .atarimania:    return atarimania
        case .vintageAppleMagazines, .vintageAppleBooks:
            return vintageApple(site)
        default:             return bombJack(site)
        }
    }

    /// One acknowledgement, as the screen shows it.
    struct Credit: Identifiable {
        let heading: String
        let body: String
        /// Both halves, so two entries count as one only when they are
        /// genuinely the same block. Keying on the heading alone would hide a
        /// real difference the day two sources share a name.
        var id: String { heading + "\u{0}" + body }
    }

    /// The acknowledgements, each said once, in the order the switches are.
    ///
    /// Iterating the sources directly printed the BombJack paragraph seven
    /// times. The seven catalogues are one archive split for seeding — they
    /// differ in what they hold and in nothing else, so `bombJack(_:)` returns
    /// the same heading and the same credit for all of them, and the
    /// Acknowledgements screen faithfully showed all seven.
    ///
    /// Deduplicated here rather than in the view because this is the file that
    /// owns the copy: the view should not have to know which sources happen to
    /// share a credit, and the answer changes whenever one is added.
    static var credits: [Credit] {
        var seen: Set<String> = []
        var out: [Credit] = []
        for site in IssueSite.allCases {
            let copy = of(site)
            let credit = Credit(heading: copy.creditHeading, body: copy.credit)
            // First occurrence wins, which puts the shared block where the
            // first source carrying it sits.
            if seen.insert(credit.id).inserted { out.append(credit) }
        }
        return out
    }

    // MARK: - The sources

    private static let stripzona = SourceCopy(
        switchTitle: "\(IssueSite.stripzona.settingsName) (free account needed)",
        detail: "Ex-Yugoslav comics and magazines you Import from the StripZona forum.",
        shelfPhrase: "the StripZona forum",
        creditHeading: "StripZona (free account needed)",
        credit: "This is an independent reader. It is not affiliated "
              + "with, endorsed by, or connected to stripzona.com, "
              + "and it hosts no StripZona content of its own. A stripzona.com "
              + "approved account is needed to access any content.")

    private static let retrospec = SourceCopy(
        switchTitle: IssueSite.retrospec.settingsName,
        detail: "Ex-Yugoslav computer magazines and books — Svet Kompjutera, "
              + "Računari, Moj Mikro and more.",
        shelfPhrase: "ex-Yugoslav computer magazines and books",
        creditHeading: "RetroSpec",
        // Credited by name, unlike the others: this one is one person's work
        // rather than an institution, and the whole ex-Yugoslav computer press
        // survives in readable form because he scanned it.
        credit: "The RetroSpec source is Tomaž Kac's archive of "
              + "scanned ex-Yugoslav (1972=2001) computer magazines and books at "
              + "retrospec.elite.org/users/tomcat/yu. "
              + "The app ships the index and only downloads each "
              + "issue from the archive on demand. This is "
              + "an independent reader, not affiliated with or "
              + "endorsed by RetroSpec, and it hosts none of its scans.")

    private static let archive = SourceCopy(
        switchTitle: IssueSite.archive.settingsName,
        // Named rather than counted: four issues is a number that dates the
        // sentence the moment a fifth is added, and the two runs are what
        // someone would recognise.
        //
        // The second sentence is why this switch is worth more than the
        // fanzines it started as: with it on, Import gains an entry and
        // anything scanned on the Internet Archive can be brought in.
        detail: "Scanned Ex-Yugoslav Amiga fanzines - "
              + "A-Profy and Amiga Bilten. Also search and "
              + "Import public Internet Archive content.",
        shelfPhrase: "ex-Yugoslav Amiga fanzines and more",
        creditHeading: "Internet Archive",
        credit: "The Archive.org source lists items hosted by the "
              + "Internet Archive, which are downloaded from "
              + "archive.org on demand. This reader is "
              + "not affiliated with or endorsed by the Internet "
              + "Archive, and hosts none of their material. Only "
              + "ex-YU Amiga fanzines are currently indexed.")

    /// What the site holds, written once.
    ///
    /// This sentence is the reason this file exists: it belongs in both the
    /// switch and the credit, and when it was typed into each they disagreed
    /// about whether fanzines were included.
    ///
    /// "pulp magazines" rather than "pulps" names both kinds in one breath —
    /// the house rule's one exception, and here also the more accurate word,
    /// since the site files pulps, fanzines and story papers alongside the
    /// comics.
    private static let comicBookPlusHolds =
        "public-domain Golden Age comics, pulp magazines, story papers and fanzines"

    private static let comicBookPlus = SourceCopy(
        switchTitle: "\(IssueSite.comicbookplus.settingsName) (free account needed)",
        // No count, because there is no catalogue to count — switching this on
        // adds nothing to the shelf and puts an entry in the Import menu,
        // which is what the second sentence says.
        detail: "\(comicBookPlusHolds.prefix(1).uppercased())\(comicBookPlusHolds.dropFirst()). "
              + "Browse a title and Import brings its issues onto the shelf.",
        shelfPhrase: "public-domain Golden Age comics and pulp magazines",
        creditHeading: "\(IssueSite.comicbookplus.settingsName) (free account needed)",
        // The same disclaimer as the other three, plus the fact specific to
        // this source and worth stating plainly: what it holds is public
        // domain, which is the site's own stated basis for offering it.
        credit: "The \(IssueSite.comicbookplus.settingsName) source indexes "
              + "\(comicBookPlusHolds) hosted at \(ComicBookPlus.host), "
              + "which are downloaded from that site on demand. "
              + "Reading online is open to everyone; a free account "
              + "there is needed to download. This is an independent "
              + "reader, not affiliated with or endorsed by "
              + "\(IssueSite.comicbookplus.settingsName), and it hosts "
              + "none of their scans.")

    /// BatCave.
    ///
    /// "comics and magazines" rather than "comics" alone throughout, which is
    /// the same exception the Comic Book Plus entry above takes and the only
    /// one the house rule allows: `UIWordingTests` fails any literal in this
    /// layer that says "comic" without naming magazines beside it, and the
    /// site does carry both — Zagor and its stablemates are magazine-format
    /// serials, not comic books.
    ///
    /// No count and no shelf claim, because switching this on adds nothing:
    /// there is no index to seed. What it adds is an entry in the Import menu,
    /// which is what the second sentence says.
    private static let batcave = SourceCopy(
        switchTitle: IssueSite.batcave.settingsName,
        detail: "A large open repository of comics and magazines. "
              + "Browse the site and Import brings one issue onto the shelf.",
        shelfPhrase: "a large open repository of comics and magazines",
        creditHeading: "BatCave",
        // The same disclaimer the other four carry. It is the sentence doing
        // the protective work, so it is not abbreviated here.
        credit: "BatCave is a public repository of various comics and magazines "
              + "at \(BatCave.host). The app ships no index of it: you browse "
              + "the site, Import records one issue's details, and it is "
              + "fetched from there only when you ask for it. This is an "
              + "independent reader, not affiliated with or endorsed by "
              + "BatCave, and it hosts none of its content.")

    /// Stripovi.com.
    ///
    /// "strips" throughout rather than the other word, and not to dodge the
    /// house rule: these are newspaper-style strips and web strips, with not a
    /// magazine among them, so the rule's one exception — naming both kinds
    /// together — would be a claim about the shelf that is not true here.
    /// "Strip" is also the word the site itself uses, and the word its readers
    /// use.
    ///
    /// The count is stated because unlike the browse-and-import sources this
    /// one puts every one of them on the shelf the moment it is switched on,
    /// and thirty-one is a number that will not quietly date: the site has
    /// added roughly one a year.
    private static let stripovi = SourceCopy(
        switchTitle: IssueSite.stripovi.settingsName,
        // "strips", matching the two fields below it. The house rule bars
        // "comic" in this layer unless magazines are named alongside, and
        // there is not a magazine among these thirty-one — so the rule's one
        // exception would be a claim about the shelf that is not true here.
        detail: "Web graphic novels (in ex-YU languages) published for free by their authors.",
        shelfPhrase: "free Croatian web strips",
        creditHeading: "Stripovi.com",
        credit: "The Stripovi.com source indexes the web strips published "
              + "free at stripovi.com, together with the artwork the site "
              + "made for them. The app ships that index and fetches a strip "
              + "from the site only when you ask for it. This is an "
              + "independent reader, not affiliated with or endorsed by "
              + "Stripovi.com, and it hosts none of their work.")

    /// The seven BombJack catalogues, described from their category.
    ///
    /// One shape rather than seven near-identical blocks: they differ in what
    /// they hold and in nothing else, and seven copies of the same disclaimer
    /// is seven chances for one of them to drift.
    private static func bombJack(_ site: IssueSite) -> SourceCopy {
        let what = site.bombjackCategory?.display ?? "BombJack"
        return SourceCopy(
            switchTitle: what,
            detail: detail(for: site.bombjackCategory),
            shelfPhrase: "scanned computer magazines and books",
            creditHeading: "BombJack / DLH's Commodore Archive",
            // One person's archive, like RetroSpec, and credited the same way
            // for the same reason: this material is readable today because he
            // scanned it. Joystik is called out because its scans are hosted
            // elsewhere again, and that host deserves saying.
            credit: "The BombJack source indexes DLH's archive of scanned computer "
                  + "magazines and books at commodore.bombjack.org, and the Joystik "
                  + "arcade magazine hosted at arcarc.xmission.com. The app ships "
                  + "the index and downloads each issue from those sites on demand. "
                  + "This is an independent reader, not affiliated with or endorsed "
                  + "by either, and it hosts none of their scans.")
    }

    private static let atarimania = SourceCopy(
        switchTitle: IssueSite.atarimania.settingsName,
        detail: "Scanned Atari magazines — Antic, ANALOG, Page 6, STart, "
              + "Atari User, the ST press and US user-group newsletters.",
        shelfPhrase: "scanned Atari magazines",
        creditHeading: "Atarimania",
        credit: "The Atarimania source indexes the scanned Atari magazine "
              + "archive at atarimania.com. The app ships the index and "
              + "downloads each issue from the site on demand. This is an "
              + "independent reader, not affiliated with or endorsed by "
              + "Atarimania, and it hosts none of their scans.")

    /// The two Vintage Apple shelves, described from their group.
    private static func vintageApple(_ site: IssueSite) -> SourceCopy {
        let books = site.vintageAppleGroup == .books
        return SourceCopy(
            switchTitle: site.vintageAppleGroup?.display ?? "Vintage Apple",
            detail: books
                ? "Scanned Apple and Mac books, programming guides, manuals and "
                + "catalogues, including the Inside Macintosh series."
                : "Scanned Apple-world magazines — Byte, Macworld, MacUser, "
                + "PC World, Softalk and Apple's develop.",
            shelfPhrase: "scanned Apple magazines and books",
            creditHeading: "Vintage Apple",
            credit: "The Vintage Apple sources index the scanned Apple magazine "
                  + "and book archive at vintageapple.org. The app ships the "
                  + "index and downloads each file from the site on demand. "
                  + "This is an independent reader, not affiliated with or "
                  + "endorsed by Vintage Apple, and it hosts none of their scans.")
    }

    /// The three Sinclair shelves, described from their group.
    ///
    /// One shape rather than three near-identical blocks, for the reason the
    /// BombJack seven are written once below: they differ in what they hold
    /// and in nothing else, and a second copy of the disclaimer is a second
    /// chance for one of them to drift.
    private static func spectrum(_ site: IssueSite) -> SourceCopy {
        SourceCopy(
            switchTitle: site.spectrumGroup?.display ?? "Spectrum Computing",
            detail: detail(for: site.spectrumGroup),
            shelfPhrase: "scanned Sinclair magazines and books",
            creditHeading: "Spectrum Computing / ZXDB",
            // Two parties to credit, not one, and the split is the whole point
            // of how this source works: ZXDB says where a scan is, and the
            // Internet Archive is where it actually lives. Naming only the
            // first would credit an index for someone else's hosting.
            credit: "The Sinclair sources are built from ZXDB, the open database "
                  + "behind Spectrum Computing, which is licensed under the Open "
                  + "Database License and records where each issue is archived. "
                  + "The scans themselves are held by the Internet Archive and are "
                  + "downloaded from there when you ask for one. The app ships the "
                  + "index only. This is an independent reader, not affiliated with "
                  + "or endorsed by either, and it hosts no scans.")
    }

    /// What one Sinclair shelf holds, in the terms someone choosing would use.
    private static func detail(for group: Spectrum.Group?) -> String {
        switch group {
        case .fanzines:
            return "User-group newsletters and fanzines for the Sinclair "
                 + "machines, scanned from paper."
        case .books:
            return "The Sinclair programming library by imprint — Usborne, "
                 + "Interface, Melbourne House and more."
        case .magazines, .none:
            return "English-language Sinclair magazines — Crash, Your Sinclair, "
                 + "Sinclair User, ZX Computing and the wider 8-bit press."
        }
    }

    /// What one category holds, in the terms someone choosing would use.
    private static func detail(for category: BombJack.Category?) -> String {
        switch category {
        case .commodoreMagazines:
            return "Commodore 8-bit magazines — Ahoy, Compute's Gazette, RUN, "
                 + "Transactor and more."
        case .amigaMagazines:
            return "Amiga magazines — Amazing Computing, Amiga Format and others."
        case .otherMagazines:
            return "Magazines for every other machine, and the cross-platform "
                 + "computing press."
        case .books:
            return "Scanned computer books, by platform — programming, reference "
                 + "and beginners' guides."
        case .hardware:
            return "Manuals and reference cards for machines, drives and "
                 + "peripherals."
        case .games:
            return "Printed matter that came with games — manuals, box art, "
                 + "reference cards and keyboard overlays. Not the games."
        case .other, .none:
            return "Newsletters, user-group bulletins, software manuals, "
                 + "advertising and catalogues."
        }
    }
}

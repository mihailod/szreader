import SwiftUI
import SZKit

/// One switch for one archive.
///
/// Shared by Settings and the empty shelf rather than written twice. The empty
/// shelf is where a first-time reader meets these — it is the only screen that
/// says the app has a second library in it — and Settings is where they go
/// looking afterwards, once the shelf has something on it and the empty screen
/// is gone for good. The same control in both places means the second visit
/// looks like the first.
struct SourceToggle: View {
    /// The sources this switch moves.
    ///
    /// One, except where an archive ships as several catalogues and is shown
    /// as the one archive it is: PopBoks is Džuboks and Ritam, split for
    /// seeding and for nothing a reader can see. Two switches asked them to
    /// decide something that was never a question.
    let sites: [IssueSite]
    let title: String
    let detail: String
    @ObservedObject var model: AppModel

    /// One source, said in the words `SourceCopy` holds — that is the file to
    /// edit, and it used to be edited here and in Acknowledgements both.
    init(site: IssueSite, model: AppModel) {
        let copy = SourceCopy.of(site)
        self.init(sites: [site], title: copy.switchTitle,
                  detail: copy.detail, model: model)
    }

    /// Several sources under one label, which is then the caller's to supply:
    /// the archive's name and what it holds, not either catalogue's.
    init(sites: [IssueSite], title: String, detail: String, model: AppModel) {
        self.sites = sites
        self.title = title
        self.detail = detail
        self._model = ObservedObject(wrappedValue: model)
    }

    var body: some View {
        Toggle(isOn: Binding(
            // On when any of them is: a reader who had one half of PopBoks on
            // before this became one switch sees it on, and their shelf and
            // the switch agree.
            get: { sites.contains { model.isEnabled($0) } },
            set: { model.setSources(sites, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                    // The same reason the detail below has it: on a narrow
                    // phone the stack offers one line's height and the label
                    // truncates instead of wrapping, so "StripZona (free
                    // account needed)" arrives as "StripZona (free account
                    // nee…". Costs the iPad nothing — its titles already fit.
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// One switch for a whole language of archives.
///
/// Built like `SourceToggle` and sitting directly above the list of them,
/// because that is what it is: a switch that moves those switches. It stores
/// nothing itself — what it shows is read back off the sources it moves — so
/// a reader who turns a language on and then one source of it off sees
/// exactly that, rather than a group switch insisting otherwise.
struct LanguageToggle: View {
    let language: SourceLanguage
    @ObservedObject var model: AppModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { model.isEnabled(language) },
            set: { model.setLanguage(language, enabled: $0) }
        )) {
            VStack(alignment: .leading, spacing: 3) {
                Text(language.display)
                    .font(.headline)
                    // As on the source rows below: on a narrow phone the stack
                    // offers one line's height and the label truncates rather
                    // than wrapping.
                    .fixedSize(horizontal: false, vertical: true)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Which sources this moves, said plainly. In the app layer with the rest
    /// of the prose — see `SourceCopy` for why copy does not live beside
    /// `SourceLanguage` in the framework.
    private var detail: String {
        switch language {
        case .exYU:
            return "StripZona, Stripovi.com, RetroSpec and PopBoks, and Archive.org."
        case .english:
            return "All other sources and Archive.org."
        }
    }
}

/// The languages, in the order Settings shows them.
struct LanguageList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(SourceLanguage.allCases.enumerated()), id: \.element) { index, language in
                LanguageToggle(language: language, model: model)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                if index < SourceLanguage.allCases.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
}

/// One band of the Settings list, under its own heading.
///
/// The switches are read in three passes rather than one: a reader who reads
/// Serbian and Croatian wants the top band and nothing else, and a reader who
/// does not wants it skipped. Which sources fall where is `SourceLanguage`'s
/// answer, not a second list kept here — archive.org sits between the two
/// because it carries both, which is exactly what `sharedSites` already says.
enum SourceSegment: CaseIterable {
    case exYU
    case multilingual
    case english

    /// The heading above the band. All three say INDIVIDUAL SOURCES: they are
    /// one list split for reading, not three different kinds of setting.
    var heading: String {
        switch self {
        case .exYU:         return "INDIVIDUAL SOURCES (ex-YU)"
        case .multilingual: return "INDIVIDUAL SOURCES (MULTILINGUAL)"
        case .english:      return "INDIVIDUAL SOURCES (English)"
        }
    }

    /// Which sources belong to this band. Order is not decided here — the
    /// list walks `IssueSite.allCases` and asks each site whether it is in.
    func contains(_ site: IssueSite) -> Bool {
        switch self {
        case .exYU:         return SourceLanguage.exYU.sites.contains(site)
        case .multilingual: return SourceLanguage.sharedSites.contains(site)
        case .english:      return SourceLanguage.english.sites.contains(site)
        }
    }
}

/// The list of sources, wherever it is shown.
///
/// Shared by Settings and the empty shelf, which have always carried the same
/// switches — and now have to carry them in the same *shape*, because
/// BombJack is seven of them. Flat, that reads as seven peers of StripZona;
/// grouped under one heading with its description, it reads as one archive
/// with parts, which is what it is.
struct SourceList: View {
    @ObservedObject var model: AppModel
    /// Which band this is. One card per segment in Settings.
    let segment: SourceSegment

    /// One line of the list: either a source on its own, or an archive that
    /// ships as several catalogues shown under one heading.
    private enum Entry: Identifiable {
        case single(IssueSite)
        case family(Family)

        var id: String {
            switch self {
            case .single(let site):  return site.rawValue
            case .family(let group): return group.title
            }
        }
    }

    /// An archive with parts: what to call it, what it is, and its switches.
    private struct Family {
        let title: String
        let blurb: String
        let sites: [IssueSite]
        /// One switch for the lot, rather than a heading with its catalogues
        /// indented under it.
        ///
        /// True where the split is the seeder's business and not the
        /// reader's. BombJack's seven and the Sinclair three hold different
        /// material and a reader takes the parts they want; PopBoks's two are
        /// one society's scanning of one shelf, and asking which of them to
        /// have was a question with no wrong answer and no right one.
        var oneSwitch = false
    }

    /// The list, in `IssueSite.allCases` order.
    ///
    /// The order lives in the enum and only there. It used to be half here —
    /// the standalone switches in enum order, then four groups in whatever
    /// order this file happened to name them — so this list and the shelf's
    /// source filter, which walks the same cases, could disagree about where
    /// an archive belongs. A multi-catalogue archive appears where its first
    /// case sits, and its remaining cases are folded into that one entry.
    ///
    /// Switchable sources only. Local Files has no switch — the folder on the
    /// device is not something to be turned off — and Settings shows it as a
    /// plain row underneath this list instead.
    private var entries: [Entry] {
        var out: [Entry] = []
        var placed: Set<String> = []
        for site in IssueSite.allCases
        where site.isSwitchable && segment.contains(site) {
            guard let group = Self.families.first(where: { $0.sites.contains(site) }) else {
                out.append(.single(site))
                continue
            }
            if placed.insert(group.title).inserted { out.append(.family(group)) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            let rows = entries
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                switch entry {
                case .single(let site):
                    SourceToggle(site: site, model: model)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                case .family(let group) where group.oneSwitch:
                    SourceToggle(sites: group.sites, title: group.title,
                                 detail: group.blurb, model: model)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                case .family(let group):
                    grouped(group)
                }
                if index < rows.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }

    /// The four archives that ship as more than one catalogue.
    ///
    /// Where each of them lands in the list is not decided here — that is
    /// `IssueSite`'s declaration order, through `entries` above. This is only
    /// what they are called and what they hold.
    private static let families: [Family] = [
        Family(title: "PopBoks",
               blurb: "ex-YU music magazines Džuboks and Ritam.",
               sites: IssueSite.popboksSites,
               oneSwitch: true),
        Family(title: "Spectrum Computing",
               blurb: "Scanned magazines, fanzines and books for the Sinclair "
                    + "machines — ZX Spectrum, ZX81 and QL.",
               sites: IssueSite.spectrumSites),
        Family(title: "BombJack",
               blurb: "Scanned computer magazines and books for many platforms — "
                    + "Commodore 8bit, Amiga, Atari, Sinclair, MSX, etc.",
               sites: IssueSite.bombjackSites),
        Family(title: "Vintage Apple",
               blurb: "Scanned magazines, books and manuals from the Apple world "
                    + "— Byte, Macworld, MacUser and the Mac bookshelf.",
               sites: IssueSite.vintageAppleSites),
    ]

    /// One archive with parts: a heading, a line saying what it is, and its
    /// switches indented under it.
    ///
    /// Written once and called for each. It began as four near-identical
    /// blocks and they had already started to drift in their padding.
    private func grouped(_ group: Family) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.title).font(.headline)
                Text(group.blurb)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 4)

            ForEach(Array(group.sites.enumerated()), id: \.element) { index, site in
                SourceToggle(site: site, model: model)
                    .padding(.leading, 32)
                    .padding(.trailing, 16)
                    .padding(.vertical, 8)
                if index < group.sites.count - 1 {
                    Divider().padding(.leading, 32)
                }
            }
        }
        .padding(.bottom, 4)
    }
}

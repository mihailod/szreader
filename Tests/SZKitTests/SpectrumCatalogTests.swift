import XCTest
@testable import SZKit

/// The Sinclair sources: which ZXDB material ships, and what the three
/// catalogues built from it contain.
final class SpectrumCatalogTests: XCTestCase {

    // MARK: - Which shelf a title lands on

    func testEnglishPeriodicalsSplitByType() {
        XCTAssertEqual(Spectrum.Group.of(magtype: "P", language: "en"), .magazines)
        XCTAssertEqual(Spectrum.Group.of(magtype: "Z", language: "en"), .fanzines)
    }

    /// The other twenty-odd languages were built and then dropped. The
    /// language test is the only thing keeping them out, so it is worth one
    /// that fails loudly if it is ever loosened by accident.
    func testOtherLanguagesDoNotShip() {
        for language in ["es", "pt", "it", "fr", "de", "sr", "sl", "sh", "19"] {
            XCTAssertNil(Spectrum.Group.of(magtype: "P", language: language),
                         "\(language) should not be on the shelf")
            XCTAssertNil(Spectrum.Group.of(magtype: "Z", language: language))
        }
    }

    /// ZXDB's `E` is an electronic magazine — a disk image meant to be run on
    /// a Spectrum, not a scan of anything. There is nothing in one to open.
    func testElectronicMagazinesDoNotShip() {
        XCTAssertNil(Spectrum.Group.of(magtype: "E", language: "en"))
    }

    /// Books are not periodicals and have no `magtype`, so they must never
    /// arrive through the periodical route — they come from `entries` and
    /// `downloads` instead.
    func testBooksNeverComeThroughTheMagazineRoute() {
        XCTAssertNil(Spectrum.Group.books.magtype)
        for magtype in ["P", "Z", "E"] {
            XCTAssertNotEqual(Spectrum.Group.of(magtype: magtype, language: "en"), .books)
        }
    }

    func testMissingFieldsDoNotShip() {
        XCTAssertNil(Spectrum.Group.of(magtype: nil, language: "en"))
        XCTAssertNil(Spectrum.Group.of(magtype: "P", language: nil))
    }

    // MARK: - Which book scans can actually be fetched

    /// ZXDB's `/pub/` and `/nvg/` prefixes resolve to a path *inside* a zip on
    /// archive.org, which is served by extracting on demand — and that ignores
    /// `Range`. Measured: a 1 KB range request for one such book returned HTTP
    /// 200 and all 34 MB, where the same request against an ordinary item
    /// returned 206 and 1,024 bytes. No range means no resume, so they are
    /// left out.
    func testZipInteriorBooksAreExcluded() {
        XCTAssertFalse(Spectrum.canFetchBook(link: "/pub/sinclair/books/c/X.pdf"))
        XCTAssertFalse(Spectrum.canFetchBook(link: "/nvg/sinclair/books/c/X.pdf"))
    }

    func testOrdinaryBookScansAreKept() {
        XCTAssertTrue(Spectrum.canFetchBook(
            link: "https://archive.org/download/some-item/SomeBook.pdf"))
        XCTAssertTrue(Spectrum.canFetchBook(link: "/zxdb/sinclair/books/X.pdf"))
    }

    // MARK: - How the sources are wired

    func testEveryGroupHasExactlyOneSite() {
        XCTAssertEqual(IssueSite.spectrumSites.count, Spectrum.Group.allCases.count)
        XCTAssertEqual(IssueSite.spectrumSites.compactMap(\.spectrumGroup),
                       Spectrum.Group.inMenuOrder)
    }

    /// The publisher column and the search index of every seeded row carry
    /// this string, so it has to say which archive the row came from.
    /// "Books" on its own in a filter names nothing — and BombJack ships a
    /// category by that name too.
    func testDisplayNamesTheArchive() {
        for site in IssueSite.spectrumSites {
            XCTAssertTrue(site.display.hasPrefix("Spectrum Computing: "),
                          "\(site) displays as \(site.display)")
        }
        XCTAssertNotEqual(IssueSite.spectrumBooks.display, IssueSite.bombjackBooks.display)
    }

    /// A Spectrum source is not a BombJack one. Both are grouped archives and
    /// the settings list asks every site which it is.
    func testSpectrumSitesAreNotBombJackSites() {
        for site in IssueSite.spectrumSites { XCTAssertNil(site.bombjackCategory) }
        for site in IssueSite.bombjackSites { XCTAssertNil(site.spectrumGroup) }
    }

    /// No two sources may seed from the same file.
    func testCatalogueResourcesAreDistinct() {
        let resources = IssueSite.allCases.compactMap(\.catalogueResource)
        XCTAssertEqual(Set(resources).count, resources.count)
    }

    // MARK: - The shipped catalogues

    private func catalogue(_ site: IssueSite) throws -> ShippedCatalog {
        let name = try XCTUnwrap(site.catalogueResource)
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json"),
            "\(name).json is not in the bundle — run "
            + "`swift run spectrum-build --build \(site.spectrumGroup?.rawValue ?? "")`")
        return try ShippedCatalog.decode(try Data(contentsOf: url))
    }

    func testEveryCatalogueDecodes() throws {
        for site in IssueSite.spectrumSites {
            let file = try catalogue(site)
            XCTAssertEqual(file.version, ShippedCatalog.currentVersion, "\(site)")
            XCTAssertEqual(file.base, ArchiveOrg.base, "\(site)")
            XCTAssertFalse(file.issues.isEmpty, "\(site) is empty")
            XCTAssertFalse(file.series.isEmpty, "\(site) has no series")
        }
    }

    /// Every row has to be addressable: a unique id, a series that exists, a
    /// title to show and a file to fetch.
    func testEveryRowIsAddressable() throws {
        for site in IssueSite.spectrumSites {
            let file = try catalogue(site)
            let keys = Set(file.series.map(\.key))
            var ids: Set<String> = []
            for issue in file.issues {
                XCTAssertTrue(ids.insert(issue.id).inserted, "\(site): duplicate \(issue.id)")
                XCTAssertTrue(keys.contains(issue.series),
                              "\(site): \(issue.id) has unknown series \(issue.series)")
                XCTAssertFalse(issue.title.isEmpty, "\(site): \(issue.id) has no title")
                XCTAssertFalse(issue.zip.isEmpty, "\(site): \(issue.id) has no file")
                XCTAssertFalse(issue.zip.hasPrefix("http"),
                               "\(site): \(issue.id) carries an absolute URL")
            }
        }
    }

    /// Two rows must not point at one download.
    ///
    /// The way that happens is specific: several rows can share one
    /// archive.org item, and when a mask's filename is stale for all of them
    /// the build falls back to the item's best readable file — the same file
    /// each time. Two shelf entries, one scan, and nothing else would notice.
    func testNoTwoRowsShareAFile() throws {
        for site in IssueSite.spectrumSites {
            var owner: [String: String] = [:]
            for issue in try catalogue(site).issues {
                if let first = owner[issue.zip] {
                    XCTFail("\(site): \(issue.id) and \(first) both point at \(issue.zip)")
                }
                owner[issue.zip] = issue.id
            }
        }
    }

    /// Sizes come from archive.org's own metadata rather than a HEAD on each
    /// scan. Missing sizes mean those lookups silently failed, and the shelf
    /// could not say how large a download is before starting it.
    func testRowsCarryRealSizes() throws {
        for site in IssueSite.spectrumSites {
            let file = try catalogue(site)
            let sized = file.issues.filter { ($0.bytes ?? 0) > 0 }
            XCTAssertGreaterThan(sized.count * 10, file.issues.count * 9,
                                 "\(site): only \(sized.count) of \(file.issues.count) sized")
        }
    }

    /// Every run counts from one and climbs without repeating. Unlike
    /// RetroSpec's catalogue this does *not* have to be gapless — ZXDB lists
    /// issues whose scans were never uploaded, so a run legitimately arrives
    /// with holes — but two rows sharing a number would break the ordering.
    func testEachSeriesIsNumberedFromOne() throws {
        for site in IssueSite.spectrumSites {
            var numbers: [String: [Int]] = [:]
            for issue in try catalogue(site).issues {
                numbers[issue.series, default: []].append(issue.number)
            }
            for (series, found) in numbers {
                let sorted = found.sorted()
                XCTAssertEqual(sorted, Array(1...sorted.count),
                               "\(site): \(series) is not 1...\(sorted.count)")
            }
        }
    }

    /// The Sinclair core is the reason the magazine shelf ships at all. If a
    /// rebuild loses these, something upstream changed and it should not go
    /// out unnoticed.
    func testTheSinclairCoreIsPresent() throws {
        let names = Set(try catalogue(.spectrumMagazines).series.map(\.name))
        for title in ["Crash", "Your Sinclair", "Sinclair User", "ZX Computing"] {
            XCTAssertTrue(names.contains(title), "\(title) is missing from the shelf")
        }
    }

    /// Books shelve by imprint, which is how they are actually known.
    func testBooksAreShelvedByImprint() throws {
        let file = try catalogue(.spectrumBooks)
        let names = Set(file.series.map(\.name))
        XCTAssertTrue(names.contains { $0.contains("Usborne") }, "no Usborne shelf")
        XCTAssertTrue(names.contains { $0.contains("Melbourne House") },
                      "no Melbourne House shelf")
    }

    /// Seeding is what a switch does: one row per entry on a store that had
    /// none, and nothing new on the second pass — which is what happens every
    /// time the switch is turned off and on again.
    func testSeedingLoadsEveryRowOnce() throws {
        for site in IssueSite.spectrumSites {
            let store = try Store()
            let file = try catalogue(site)
            XCTAssertEqual(try store.seed(file, site: site).inserted, file.issues.count,
                           "\(site)")
            XCTAssertEqual(try store.seed(file, site: site).inserted, 0, "\(site)")
            XCTAssertEqual(store.issueCount, file.issues.count, "\(site)")
        }
    }

    /// The magazine shelf is the largest catalogue the app ships — larger than
    /// BombJack's biggest, and BombJack was split because 18,219 rows took
    /// fifteen seconds and iOS killed the app for it. So the seed is timed
    /// rather than assumed: what matters is what it costs on the device, and
    /// this is the only place it is ever measured.
    func testSeedingIsFastEnoughToShip() throws {
        for site in IssueSite.spectrumSites {
            let store = try Store()
            let file = try catalogue(site)
            let started = Date()
            _ = try store.seed(file, site: site)
            let took = Date().timeIntervalSince(started)
            XCTAssertLessThan(took, 5,
                              "\(site): seeding \(file.issues.count) rows took \(took)s")
            print("\(site.display): seeded \(file.issues.count) rows in "
                  + "\(String(format: "%.2f", took))s")
        }
    }
}

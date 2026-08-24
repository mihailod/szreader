import XCTest
@testable import SZKit

/// Every shipped catalogue must point at a host the downloader will accept.
///
/// This is the test that should have existed three catalogues ago. `DirectHost`
/// is scoped to a named allowlist — deliberately, so an unrecognised forum link
/// fails loudly instead of downloading an error page — and the consequence is
/// that shipping a catalogue whose host is not on that list produces
/// `noHostFor` on *every issue in it*. Nothing else notices: the catalogue
/// decodes, seeds, and fills the shelf with rows that cannot be downloaded.
///
/// `DirectHost`'s own documentation says this is how the BombJack catalogue
/// shipped the first time. It is also how the Atarimania catalogue shipped the
/// first time. The fix for a mistake made twice is a test, not more care.
final class ShippedCatalogHostTests: XCTestCase {

    /// The catalogues that name files to download.
    ///
    /// Stripovi is excluded and is not an oversight: it ships loose page
    /// images rather than archives, its file has its own shape (`comics`, not
    /// `issues`), and it never goes through `FileHost` at all.
    private var fileCatalogues: [(IssueSite, ShippedCatalog)] {
        IssueSite.allCases.compactMap { site in
            guard site != .stripovi, let name = site.catalogueResource,
                  let url = Bundle.module.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? ShippedCatalog.decode(data)
            else { return nil }
            return (site, file)
        }
    }

    /// Sanity check on the check: if this ever finds nothing, the test above
    /// is passing vacuously and guarding nothing at all.
    func testThereAreCataloguesToTest() {
        XCTAssertGreaterThanOrEqual(fileCatalogues.count, 10,
                                    "found only \(fileCatalogues.count) shipped catalogues")
    }

    /// Every issue of every shipped catalogue resolves to a URL the default
    /// downloader can actually fetch.
    func testEveryShippedIssueHasAHost() throws {
        let host = DirectHost()
        for (site, file) in fileCatalogues {
            // One issue proves the host, but a catalogue can mix hosts in
            // principle, so every distinct host in it is checked.
            var seen: Set<String> = []
            for issue in file.issues {
                let url = try XCTUnwrap(URL(string: file.base + issue.zip),
                                        "\(site): \(file.base + issue.zip) is not a URL")
                let name = try XCTUnwrap(url.host, "\(site): \(url) has no host")
                guard seen.insert(name).inserted else { continue }
                XCTAssertTrue(host.canHandle(url),
                              "\(site.display) downloads from \(name), which is not in "
                              + "DirectHost's allowlist — every issue in that catalogue "
                              + "would fail with noHostFor")
            }
        }
    }

    /// The same for cover art, which is fetched by URL just as the scans are.
    func testEveryShippedCoverIsAWellFormedURL() throws {
        for (site, file) in fileCatalogues {
            for issue in file.issues {
                guard let cover = issue.cover else { continue }
                XCTAssertNotNil(URL(string: file.base + cover),
                                "\(site): \(file.base + cover) is not a URL")
            }
        }
    }
}

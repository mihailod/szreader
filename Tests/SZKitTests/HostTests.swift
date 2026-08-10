import XCTest
@testable import SZKit

/// Canned HTTP so every host is testable without touching the network.
/// Responses mirror shapes actually observed against the live services.
final class StubTransport: Transport, @unchecked Sendable {
    private let handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    private(set) var requests: [HTTPRequest] = []

    init(_ handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

final class MediaFireHostTests: XCTestCase {

    private let host = MediaFireHost()

    /// Five URL shapes across a decade of posts, all keyed the same way.
    func testKeyExtractionAcrossAllObservedShapes() {
        let cases = [
            "http://www.mediafire.com/?x0mrij299kyr947",
            "http://www.mediafire.com/download.php?qejncheza6q1dsp",
            "http://www.mediafire.com/download/g72uncf1ie7u1ul",
            "http://www.mediafire.com/view/h9o2630guz17be8/033_Rusilacki_um.cbr",
            "http://www.mediafire.com/file/aalzvzvhx7sv82u/aspz01_SZupload.rar",
        ]
        let keys = cases.compactMap { MediaFireHost.key(from: URL(string: $0)!) }
        XCTAssertEqual(keys, ["x0mrij299kyr947", "qejncheza6q1dsp", "g72uncf1ie7u1ul",
                              "h9o2630guz17be8", "aalzvzvhx7sv82u"])
    }

    /// /view/ and /file/ links already carry the filename, so a probe of those
    /// costs no request at all.
    func testEmbeddedFilenameNeedsNoNetwork() async throws {
        let transport = StubTransport { _ in XCTFail("should not hit network"); return .init(status: 500) }
        let url = URL(string: "http://www.mediafire.com/file/x0m/LMS+518+-+Mister+No+-+Bubnjevi+u+dzungli.cbr")!
        let meta = try await host.probe(url, via: transport)
        XCTAssertEqual(meta.filename, "LMS 518 - Mister No - Bubnjevi u dzungli.cbr")
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// The common case: one request, no body, filename from the redirect.
    func testProbeReadsFilenameFromRedirect() async throws {
        let transport = StubTransport { req in
            HTTPResponse(status: 302, headers: [
                "Location": "http://www.mediafire.com/file/x0mrij299kyr947/"
                          + "LMS+518+-+Mister+No+-+Bubnjevi+u+dzungli+%28drzeko%29.cbr/file"
            ])
        }
        let meta = try await host.probe(URL(string: "http://www.mediafire.com/?x0mrij299kyr947")!,
                                        via: transport)
        XCTAssertEqual(meta.filename, "LMS 518 - Mister No - Bubnjevi u dzungli (drzeko).cbr")
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.maxBodyBytes, 0, "probe must not read a body")
    }

    func testProbeTreats404AsDeadLink() async throws {
        let transport = StubTransport { _ in HTTPResponse(status: 404) }
        do {
            _ = try await host.probe(URL(string: "http://www.mediafire.com/?deadkey00000000")!,
                                     via: transport)
            XCTFail("expected notFound")
        } catch HostError.notFound {
            // expected
        }
    }

    func testDirectLinkExtractedFromStaticHTML() async throws {
        let html = """
            <div id="download_link"><a href="https://download937.mediafire.com/y8arbc63zssg/\
            x0mrij299kyr947/LMS+518.cbr">Download (87.84MB)</a></div>
            """
        let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data(html.utf8)) }
        let link = try await host.directLink(
            URL(string: "http://www.mediafire.com/?x0mrij299kyr947")!, via: transport)
        XCTAssertEqual(link.url.host, "download937.mediafire.com")
        XCTAssertNil(link.postProcess)
    }
}

final class MegaHostTests: XCTestCase {

    private let host = MegaHost()

    /// Both URL forms appear in the corpus; older posts predate the change.
    func testParsesModernAndLegacyLinkForms() {
        let modern = MegaHost.parse(URL(string: "https://mega.nz/file/dMoiVBZY#fp5fbU7tBM5lTOq")!)
        XCTAssertEqual(modern?.id, "dMoiVBZY")
        XCTAssertEqual(modern?.fragment, "fp5fbU7tBM5lTOq")

        let legacy = MegaHost.parse(URL(string: "https://mega.co.nz/#!isQRgJ5R!XN7yUmyDq9jh")!)
        XCTAssertEqual(legacy?.id, "isQRgJ5R")
        XCTAssertEqual(legacy?.fragment, "XN7yUmyDq9jh")
    }

    /// Vector produced by the Python implementation that was verified against
    /// six live links. This ties the Swift port to something known-correct
    /// rather than merely self-consistent.
    func testKeyDerivationMatchesVerifiedImplementation() throws {
        let fragment = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789-_ABCDEFGH"
        let (key, nonce) = try MegaHost.derive(fragment: fragment)
        XCTAssertEqual(key.map { String(format: "%02x", $0) }.joined(),
                       "5587e286caf6f70d586d646cdfaf608e")
        XCTAssertEqual(nonce.map { String(format: "%02x", $0) }.joined(),
                       "559761969b71d79f")
    }

    /// Attribute blob encrypted by the same verified implementation.
    func testDecryptsFilenameFromAttributes() throws {
        let fragment = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789-_ABCDEFGH"
        let at = "rS98Ol3r3jAcOvCyqplSstH_9IVU8jS4iTP_QLThiZ-u1XyRJykGqUT3Uejb5XUu"
        let (key, _) = try MegaHost.derive(fragment: fragment)
        XCTAssertEqual(try MegaHost.filename(fromAttributes: at, key: key),
                       "ZS 0425 Zagor - Neravna Borba.cbr")
    }

    /// Garbage out of the decrypt means a wrong key, not a dead link — the
    /// error must say so, or a derivation bug looks like bad data forever.
    func testWrongKeyIsReportedAsDecryptionFailure() throws {
        let at = "rS98Ol3r3jAcOvCyqplSstH_9IVU8jS4iTP_QLThiZ-u1XyRJykGqUT3Uejb5XUu"
        let wrongKey = Data(repeating: 0xAB, count: 16)
        XCTAssertThrowsError(try MegaHost.filename(fromAttributes: at, key: wrongKey)) { error in
            guard case HostError.decryptionFailed = error else {
                return XCTFail("expected decryptionFailed, got \(error)")
            }
        }
    }

    func testProbeUsesAPIAndReturnsSize() async throws {
        let at = "rS98Ol3r3jAcOvCyqplSstH_9IVU8jS4iTP_QLThiZ-u1XyRJykGqUT3Uejb5XUu"
        let transport = StubTransport { req in
            XCTAssertEqual(req.method, "POST")
            XCTAssertTrue(req.url.absoluteString.hasPrefix("https://g.api.mega.co.nz/cs?id="))
            let json = #"[{"s":92111421,"at":"\#(at)"}]"#
            return HTTPResponse(status: 200, body: Data(json.utf8))
        }
        let url = URL(string: "https://mega.nz/file/dMoiVBZY#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789-_ABCDEFGH")!
        let meta = try await host.probe(url, via: transport)
        XCTAssertEqual(meta.filename, "ZS 0425 Zagor - Neravna Borba.cbr")
        XCTAssertEqual(meta.size, 92111421)
    }

    /// -9 is Mega's "no such file"; it must surface as a dead link, and -3 as
    /// rate limiting, so the caller can back off rather than retry hard.
    func testAPIErrorCodesAreMapped() async throws {
        for (code, expectDead) in [(-9, true), (-3, false)] {
            let transport = StubTransport { _ in HTTPResponse(status: 200, body: Data("[\(code)]".utf8)) }
            let url = URL(string: "https://mega.nz/file/x#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789-_ABCDEFGH")!
            do {
                _ = try await host.probe(url, via: transport)
                XCTFail("expected an error for \(code)")
            } catch let error as HostError {
                if expectDead {
                    guard case .notFound = error else { return XCTFail("expected notFound") }
                } else {
                    XCTAssertTrue("\(error)".contains("rate limited"))
                }
            }
        }
    }

    /// Mega's temp URL serves encrypted bytes; the CTR material must ride along
    /// so a background download can be decrypted after it lands.
    func testDirectLinkCarriesDecryptionMaterial() async throws {
        let transport = StubTransport { _ in
            HTTPResponse(status: 200,
                         body: Data(#"[{"g":"https://gfs1.userstorage.mega.co.nz/dl/abc","s":123}]"#.utf8))
        }
        let url = URL(string: "https://mega.nz/file/dMoiVBZY#ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef0123456789-_ABCDEFGH")!
        let link = try await host.directLink(url, via: transport)
        XCTAssertEqual(link.url.host, "gfs1.userstorage.mega.co.nz")
        guard case .aesCTR(let key, let nonce)? = link.postProcess else {
            return XCTFail("expected AES-CTR post-processing")
        }
        XCTAssertEqual(key.count, 16)
        XCTAssertEqual(nonce.count, 8)
    }
}

final class HostRegistryTests: XCTestCase {

    func testRoutesEachURLToItsHost() {
        let registry = HostRegistry()
        let cases: [(String, String?)] = [
            ("http://www.mediafire.com/?abc12345", "mediafire"),
            ("https://mega.nz/file/abc#key", "mega"),
            ("https://mega.co.nz/#!abc!key", "mega"),
            ("https://pixeldrain.com/u/AbCd1234", "pixeldrain"),
            ("https://ifile.it/xyz", nil),          // dead service, no implementation
        ]
        for (raw, expected) in cases {
            XCTAssertEqual(registry.host(for: URL(string: raw)!)?.name, expected, raw)
        }
    }

    func testUnknownHostRaisesRatherThanGuessing() async {
        let registry = HostRegistry()
        let transport = StubTransport { _ in HTTPResponse(status: 200) }
        do {
            _ = try await registry.probe(URL(string: "https://4shared.com/x/y")!, via: transport)
            XCTFail("expected noHostFor")
        } catch let error as HostError {
            XCTAssertTrue("\(error)".contains("no host implementation"))
        } catch { XCTFail("wrong error: \(error)") }
    }
}

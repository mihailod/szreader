import XCTest
@testable import SZKit

final class ScratchBundle: XCTestCase {
    func testBundleFilenames() async throws {
        let transport = ThrottledTransport(URLSessionTransport(), minInterval: 1.5)
        let registry = HostRegistry()
        for (label, url) in [
            ("001-116", "http://www.mediafire.com/?0cru00rdbu991ye"),
            ("117-142", "http://www.mediafire.com/?8j1az67uckv1vtt"),
            ("143-164", "http://www.mediafire.com/?dcgnigb6zsid13b"),
            ("issue 001 (individual)", "http://www.mediafire.com/?7wdyuue40r8h170"),
        ] {
            do {
                let meta = try await registry.probe(URL(string: url)!, via: transport)
                print("B \(label): \(meta.filename ?? "— none —")  size=\(meta.size.map(String.init) ?? "?")")
            } catch {
                print("B \(label): FAILED \(error)")
            }
        }
    }
}

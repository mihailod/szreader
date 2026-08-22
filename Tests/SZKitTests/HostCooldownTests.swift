import XCTest
@testable import SZKit

/// Waiting when a host asks to be left alone.
///
/// The behaviour these pin is the one the feature exists for: after a refusal,
/// asking again must be refused *by this app*, without a request going out.
final class HostCooldownTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suite: String!
    private var cooldown: HostCooldown!

    private let now = Date(timeIntervalSince1970: 1_000_000)

    override func setUpWithError() throws {
        suite = "cooldown-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        cooldown = HostCooldown(defaults: defaults)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    // MARK: - The rule

    func testAHostThatHasNotRefusedMayBeAsked() {
        XCTAssertNil(cooldown.remaining(forHost: "batcave.biz", now: now))
    }

    /// The whole point: immediately after a refusal, asking again is refused
    /// here rather than at the server.
    func testAskingAgainImmediatelyIsRefused() {
        cooldown.begin(forHost: "batcave.biz", wait: 600, now: now)
        let left = cooldown.remaining(forHost: "batcave.biz", now: now)
        XCTAssertEqual(try XCTUnwrap(left), 600, accuracy: 1)
    }

    func testTheWaitRunsOut() {
        cooldown.begin(forHost: "batcave.biz", wait: 600, now: now)
        XCTAssertNil(cooldown.remaining(forHost: "batcave.biz",
                                        now: now.addingTimeInterval(601)))
    }

    /// A server that refuses without naming a duration still gets a real
    /// pause, because "wait a bit" enforced by nothing is not a pause.
    func testARefusalWithNoStatedWaitStillWaits() {
        cooldown.begin(forHost: "batcave.biz", wait: nil, now: now)
        let left = try? XCTUnwrap(cooldown.remaining(forHost: "batcave.biz", now: now))
        XCTAssertEqual(left ?? 0, HostCooldown.unstatedWait, accuracy: 1)
    }

    /// Two refusals mean the server is more annoyed, not less. A second,
    /// shorter wait must not let a run talk its way back in early.
    func testASecondRefusalNeverShortensTheWait() {
        cooldown.begin(forHost: "batcave.biz", wait: 3600, now: now)
        cooldown.begin(forHost: "batcave.biz", wait: 60, now: now)
        let left = try? XCTUnwrap(cooldown.remaining(forHost: "batcave.biz", now: now))
        XCTAssertEqual(left ?? 0, 3600, accuracy: 1)
    }

    /// The refusal is about the address making the requests, so it cannot be
    /// escaped by starting a different issue — but it must not silence an
    /// unrelated source either.
    func testTheWaitIsPerHost() {
        cooldown.begin(forHost: "batcave.biz", wait: 600, now: now)
        XCTAssertNotNil(cooldown.remaining(forHost: "batcave.biz", now: now))
        XCTAssertNil(cooldown.remaining(forHost: "comicbookplus.com", now: now))
    }

    func testHostsAreMatchedWhateverTheirCase() {
        cooldown.begin(forHost: "IMG.BatCave.biz", wait: 600, now: now)
        XCTAssertNotNil(cooldown.remaining(forHost: "img.batcave.biz", now: now))
    }

    // MARK: - Which machine answered is not the point

    /// The refusal names whichever machine served the request, and the mirror
    /// is stored under the site's own domain. Keyed literally the two never
    /// meet, and the wait would be recorded against a name nothing asks about
    /// again — a pause that never once applies.
    func testARefusalFromOneMachinePausesTheWholeService() {
        cooldown.begin(forHost: "download1234.mediafire.com", wait: 600, now: now)
        XCTAssertNotNil(cooldown.remaining(forHost: "mediafire.com", now: now))
        XCTAssertNotNil(cooldown.remaining(forHost: "www.mediafire.com", now: now))
    }

    func testTheSameHoldsForTheHostsThisAppActuallyTalksTo() {
        cooldown.begin(forHost: "ia601403.us.archive.org", wait: 600, now: now)
        XCTAssertNotNil(cooldown.remaining(forHost: "archive.org", now: now))

        cooldown.begin(forHost: "img.batcave.biz", wait: 600, now: now)
        XCTAssertNotNil(cooldown.remaining(forHost: "batcave.biz", now: now))
    }

    /// Collapsing must not reach across services. One refusing host pausing an
    /// unrelated one would be worse than no pause at all.
    func testItDoesNotReachAcrossServices() {
        cooldown.begin(forHost: "download1234.mediafire.com", wait: 600, now: now)
        XCTAssertNil(cooldown.remaining(forHost: "archive.org", now: now))
        XCTAssertNil(cooldown.remaining(forHost: "batcave.biz", now: now))
        XCTAssertNil(cooldown.remaining(forHost: "mega.nz", now: now))
    }

    func testAShortHostIsLeftAlone() {
        XCTAssertEqual(HostCooldown.site(of: "archive.org"), "archive.org")
        XCTAssertEqual(HostCooldown.site(of: "localhost"), "localhost")
    }

    /// Quitting the app is not what the server asked for.
    func testTheWaitOutlivesTheObject() {
        cooldown.begin(forHost: "batcave.biz", wait: 600, now: now)
        let reopened = HostCooldown(defaults: defaults)
        XCTAssertNotNil(reopened.remaining(forHost: "batcave.biz", now: now))
    }

    /// The reader can overrule it, but it has to be a decision.
    func testItCanBeCleared() {
        cooldown.begin(forHost: "batcave.biz", wait: 600, now: now)
        cooldown.clear(forHost: "batcave.biz")
        XCTAssertNil(cooldown.remaining(forHost: "batcave.biz", now: now))
    }
}

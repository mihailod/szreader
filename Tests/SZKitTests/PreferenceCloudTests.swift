import XCTest
@testable import SZKit

/// Stands in for `NSUbiquitousKeyValueStore`, which needs an iCloud account
/// and a signed build to do anything at all.
final class FakeCloud: KeyValueCloud {
    private(set) var storage: [String: Any] = [:]
    private(set) var writes = 0
    private(set) var synchronises = 0

    init(_ initial: [String: Any] = [:]) { storage = initial }

    func object(forKey key: String) -> Any? { storage[key] }

    func set(_ value: Any?, forKey key: String) {
        writes += 1
        if let value { storage[key] = value } else { storage.removeValue(forKey: key) }
    }

    var dictionaryRepresentation: [String: Any] { storage }

    @discardableResult func synchronize() -> Bool { synchronises += 1; return true }

    /// What another device changing a key looks like from here.
    @MainActor
    func arrive(_ values: [String: Any], at mirror: PreferenceCloud) {
        for (key, value) in values { storage[key] = value }
        mirror.arrived(Array(values.keys))
    }
}

/// The preferences mirror: which sources are showing, how the shelf is
/// filtered and sorted, kept the same on every device on one account.
@MainActor
final class PreferenceCloudTests: XCTestCase {

    private let keys = ["showStripZona", "shelfSort", "heroFilter", "downloadedOnly"]
    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "preference-cloud-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    private func mirror(_ cloud: FakeCloud) -> PreferenceCloud {
        PreferenceCloud(keys: keys, defaults: defaults, cloud: cloud)
    }

    // MARK: - The first meeting

    /// An account nobody has published to takes this device's settings. This
    /// is the upgrade path: a reader who has had the app for months has all of
    /// this set up already, and it must not be reset to defaults by the build
    /// that adds syncing.
    func testAnEmptyAccountTakesThisDevicesSettings() throws {
        defaults.set(true, forKey: "showStripZona")
        defaults.set("title", forKey: "shelfSort")
        let cloud = FakeCloud()

        mirror(cloud).start()

        XCTAssertEqual(cloud.storage["shelfSort"] as? String, "title")
        XCTAssertEqual(cloud.storage["showStripZona"] as? Bool, true)
        XCTAssertNotNil(cloud.storage[PreferenceCloud.stampKey], "nothing marked the account")
    }

    /// The case the stamp exists for. A reader who has deliberately switched
    /// everything off has an account full of `false`, which by value alone is
    /// indistinguishable from an account nobody has written to — and taking it
    /// for empty would republish this device over their choices.
    func testAnAccountOfDeliberateDefaultsIsNotMistakenForAnEmptyOne() throws {
        defaults.set(true, forKey: "showStripZona")
        let cloud = FakeCloud([PreferenceCloud.stampKey: true, "showStripZona": false])

        mirror(cloud).start()

        XCTAssertEqual(defaults.bool(forKey: "showStripZona"), false,
                       "the reader's switched-off shelf was overwritten by this device")
    }

    /// A published account is believed over local state — the store's own
    /// cache is what this device last wrote, so there is no fresher local
    /// answer for these keys.
    func testAPublishedAccountIsAdoptedOnFirstRun() throws {
        defaults.set("title", forKey: "shelfSort")
        let cloud = FakeCloud([PreferenceCloud.stampKey: true, "shelfSort": "hero"])

        mirror(cloud).start()

        XCTAssertEqual(defaults.string(forKey: "shelfSort"), "hero")
    }

    /// A preference the account has never carried — one added by a later build
    /// than the one that first published — goes up rather than being taken as
    /// an instruction to forget it.
    func testAKeyTheAccountHasNeverCarriedIsPushedNotErased() throws {
        defaults.set(true, forKey: "downloadedOnly")
        let cloud = FakeCloud([PreferenceCloud.stampKey: true, "shelfSort": "hero"])

        mirror(cloud).start()

        XCTAssertEqual(defaults.bool(forKey: "downloadedOnly"), true, "a local preference was lost")
        XCTAssertEqual(cloud.storage["downloadedOnly"] as? Bool, true)
    }

    // MARK: - Changes from another device

    func testAChangeFromAnotherDeviceLandsInDefaults() throws {
        defaults.set("title", forKey: "shelfSort")
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        mirror.start()

        cloud.arrive(["shelfSort": "number"], at: mirror)

        XCTAssertEqual(defaults.string(forKey: "shelfSort"), "number")
    }

    /// The callback is the whole reason this class reports anything: a filter
    /// arriving from the iPad has to re-run the shelf query, and a source
    /// switch coming on has to seed its catalogue. `@AppStorage` republishing
    /// does neither — a `didSet` only fires on assignment through the
    /// property, and nothing assigns here.
    func testAdoptingReportsWhichKeysMoved() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        var reported: [[String]] = []
        mirror.didAdopt = { reported.append($0.sorted()) }
        mirror.start()

        cloud.arrive(["heroFilter": "Zagor", "downloadedOnly": true], at: mirror)

        XCTAssertEqual(reported, [["downloadedOnly", "heroFilter"]])
    }

    /// A store that re-announces a value this device already has should not
    /// send the app off to re-seed catalogues and re-run the shelf query.
    func testAnUnchangedArrivalReportsNothing() throws {
        defaults.set("hero", forKey: "shelfSort")
        let cloud = FakeCloud([PreferenceCloud.stampKey: true, "shelfSort": "hero"])
        let mirror = self.mirror(cloud)
        var reported = 0
        mirror.didAdopt = { _ in reported += 1 }
        mirror.start()

        cloud.arrive(["shelfSort": "hero"], at: mirror)

        XCTAssertEqual(reported, 0)
    }

    /// Keys this app does not sync are none of its business, whoever sends
    /// them.
    func testAnArrivalOfAKeyWeDoNotSyncIsIgnored() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        var reported = 0
        mirror.didAdopt = { _ in reported += 1 }
        mirror.start()

        cloud.arrive(["pageRenderStamp": "600-v4"], at: mirror)

        XCTAssertEqual(reported, 0)
        XCTAssertNil(defaults.object(forKey: "pageRenderStamp"),
                     "a key outside the synced set was written into defaults")
    }

    // MARK: - Changes made here

    func testALocalChangeIsPushed() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        mirror.start()

        defaults.set("series", forKey: "shelfSort")
        mirror.pushLocalChanges()

        XCTAssertEqual(cloud.storage["shelfSort"] as? String, "series")
    }

    /// The echo. Adopting writes into `UserDefaults`, which raises the same
    /// notification a reader's own change does — so without a guard the
    /// arriving value is pushed straight back as though this device had
    /// chosen it, and two devices can trade one change for ever.
    func testAdoptedValuesAreNotPushedBack() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        mirror.start()
        let before = cloud.writes

        cloud.arrive(["shelfSort": "number"], at: mirror)
        mirror.pushLocalChanges()

        XCTAssertEqual(cloud.writes, before, "the adopted value was echoed back to the account")
    }

    /// `UserDefaults.didChangeNotification` fires for every write anywhere in
    /// the app — thumbnail stamps, one-time markers, the lot. None of that
    /// should reach the account.
    func testAnUnrelatedDefaultsWritePushesNothing() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        mirror.start()
        let before = cloud.writes

        defaults.set("600-v4", forKey: "pageRenderStamp")
        mirror.pushLocalChanges()

        XCTAssertEqual(cloud.writes, before)
    }

    func testPushingTwiceSendsOneChangeOnce() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let mirror = self.mirror(cloud)
        mirror.start()

        defaults.set(true, forKey: "downloadedOnly")
        mirror.pushLocalChanges()
        let after = cloud.writes
        mirror.pushLocalChanges()

        XCTAssertEqual(cloud.writes, after, "an unchanged preference was written again")
    }

    // MARK: - Degrading

    /// No account, no entitlement: the store answers empty and swallows
    /// writes. Every preference has to go on working, on this device.
    func testWithoutAnAccountEverythingStillWorksLocally() throws {
        final class DeafCloud: KeyValueCloud {
            func object(forKey key: String) -> Any? { nil }
            func set(_ value: Any?, forKey key: String) {}
            var dictionaryRepresentation: [String: Any] { [:] }
            @discardableResult func synchronize() -> Bool { false }
        }
        defaults.set("title", forKey: "shelfSort")
        let mirror = PreferenceCloud(keys: keys, defaults: defaults, cloud: DeafCloud())

        mirror.start()
        defaults.set("number", forKey: "shelfSort")
        mirror.pushLocalChanges()

        XCTAssertEqual(defaults.string(forKey: "shelfSort"), "number")
    }
}

/// Two devices on one account, doing what a reader does.
///
/// Written after the iPad and the iPhone disagreed in the field: changes went
/// one way, and the moment the second device changed anything it stopped
/// hearing the first. These model that sequence against the logic alone, so
/// the answer says whether the merge rules are at fault or whether it is the
/// plumbing around them.
@MainActor
final class TwoDevicePreferenceTests: XCTestCase {

    private let keys = ["shelfSort", "downloadedOnly"]
    private var suites: [String] = []

    override func tearDownWithError() throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private func device(_ cloud: FakeCloud) throws -> (PreferenceCloud, UserDefaults) {
        let suite = "two-device-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (PreferenceCloud(keys: keys, defaults: defaults, cloud: cloud), defaults)
    }

    /// The reported sequence, end to end.
    func testTheSecondDeviceKeepsFollowingAfterItChangesSomething() throws {
        let cloud = FakeCloud()
        let (pad, padDefaults) = try device(cloud)
        let (phone, phoneDefaults) = try device(cloud)
        pad.start()
        phone.start()

        // iPad → iPhone. This is the half that worked.
        padDefaults.set("title", forKey: "shelfSort")
        pad.pushLocalChanges()
        phone.arrived(["shelfSort"])
        XCTAssertEqual(phoneDefaults.string(forKey: "shelfSort"), "title")

        // The iPhone now changes something of its own.
        phoneDefaults.set(true, forKey: "downloadedOnly")
        phone.pushLocalChanges()
        pad.arrived(["downloadedOnly"])
        XCTAssertEqual(padDefaults.bool(forKey: "downloadedOnly"), true,
                       "the phone's change never reached the iPad")

        // And the iPad changes something again. This is what stopped arriving.
        padDefaults.set("hero", forKey: "shelfSort")
        pad.pushLocalChanges()
        phone.arrived(["shelfSort"])
        XCTAssertEqual(phoneDefaults.string(forKey: "shelfSort"), "hero",
                       "the phone stopped following the iPad after changing something itself")
    }

    /// The same thing with no restart anywhere in it, in case the fix is
    /// hiding behind `start()` being called again.
    func testAChangeEachWayInBothDirectionsRepeatedly() throws {
        let cloud = FakeCloud()
        let (pad, padDefaults) = try device(cloud)
        let (phone, phoneDefaults) = try device(cloud)
        pad.start()
        phone.start()

        for round in 1...3 {
            padDefaults.set("pad-\(round)", forKey: "shelfSort")
            pad.pushLocalChanges()
            phone.arrived(["shelfSort"])
            XCTAssertEqual(phoneDefaults.string(forKey: "shelfSort"), "pad-\(round)",
                           "round \(round): iPad → iPhone")

            phoneDefaults.set("phone-\(round)", forKey: "shelfSort")
            phone.pushLocalChanges()
            pad.arrived(["shelfSort"])
            XCTAssertEqual(padDefaults.string(forKey: "shelfSort"), "phone-\(round)",
                           "round \(round): iPhone → iPad")
        }
    }
}

/// Convergence when nobody is told anything.
///
/// The field failure was not a merge bug — the rules were right both ways —
/// it was that the store's notification never reached a running app, so the
/// only thing that ever synced was launch. These pin the behaviour with the
/// notification removed entirely, which is the pessimistic case and close to
/// what a backgrounded device actually experiences.
@MainActor
final class PreferenceRefreshTests: XCTestCase {

    private let keys = ["shelfSort", "downloadedOnly"]
    private var suites: [String] = []

    override func tearDownWithError() throws {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
    }

    private func device(_ cloud: FakeCloud) throws -> (PreferenceCloud, UserDefaults) {
        let suite = "refresh-\(UUID().uuidString)"
        suites.append(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        return (PreferenceCloud(keys: keys, defaults: defaults, cloud: cloud), defaults)
    }

    /// Coming back to the front is enough, on its own.
    func testRefreshAdoptsAChangeNobodyAnnounced() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let (mirror, defaults) = try device(cloud)
        mirror.start()

        // Another device wrote this and no notification was ever delivered.
        cloud.set("number", forKey: "shelfSort")
        mirror.refresh()

        XCTAssertEqual(defaults.string(forKey: "shelfSort"), "number")
    }

    func testRefreshReportsWhatItAdopted() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true])
        let (mirror, _) = try device(cloud)
        var reported: [[String]] = []
        mirror.didAdopt = { reported.append($0.sorted()) }
        mirror.start()

        cloud.set(true, forKey: "downloadedOnly")
        mirror.refresh()

        XCTAssertEqual(reported, [["downloadedOnly"]])
    }

    /// The common case: the app is opened, nothing has moved. Coming back to
    /// the front must not look like a change and send the shelf off to re-seed
    /// catalogues and re-run its query.
    func testRefreshWithNothingNewReportsNothing() throws {
        let cloud = FakeCloud([PreferenceCloud.stampKey: true, "shelfSort": "hero"])
        let (mirror, _) = try device(cloud)
        var reported = 0
        mirror.didAdopt = { _ in reported += 1 }
        mirror.start()
        // Starting up on an account this device has never met does adopt, and
        // should: that is the reader's settings arriving. Counted from here so
        // this measures the foreground pass and not the launch.
        XCTAssertEqual(reported, 1, "the account's settings should arrive at launch")
        reported = 0

        mirror.refresh()
        mirror.refresh()

        XCTAssertEqual(reported, 0)
    }

    /// The reported sequence again, with the notification taken away
    /// altogether: both devices only ever come back to the front. This is the
    /// test that would have caught it.
    func testTwoDevicesConvergeOnForegroundAloneInBothDirections() throws {
        let cloud = FakeCloud()
        let (pad, padDefaults) = try device(cloud)
        let (phone, phoneDefaults) = try device(cloud)
        pad.start()
        phone.start()

        for round in 1...3 {
            padDefaults.set("pad-\(round)", forKey: "shelfSort")
            pad.pushLocalChanges()
            phone.refresh()
            XCTAssertEqual(phoneDefaults.string(forKey: "shelfSort"), "pad-\(round)",
                           "round \(round): the iPhone did not pick up the iPad on foreground")

            phoneDefaults.set("phone-\(round)", forKey: "shelfSort")
            phone.pushLocalChanges()
            pad.refresh()
            XCTAssertEqual(padDefaults.string(forKey: "shelfSort"), "phone-\(round)",
                           "round \(round): the iPad did not pick up the iPhone on foreground")
        }
    }

    /// A device that changed something and then went away must still take the
    /// other one's later change when it comes back — the exact shape of the
    /// report, where the second device stopped following the first.
    func testADeviceThatChangedSomethingStillFollowsTheOtherOnItsReturn() throws {
        let cloud = FakeCloud()
        let (pad, padDefaults) = try device(cloud)
        let (phone, phoneDefaults) = try device(cloud)
        pad.start()
        phone.start()

        phoneDefaults.set(true, forKey: "downloadedOnly")
        phone.pushLocalChanges()

        padDefaults.set("hero", forKey: "shelfSort")
        pad.pushLocalChanges()

        phone.refresh()

        XCTAssertEqual(phoneDefaults.string(forKey: "shelfSort"), "hero")
        XCTAssertEqual(phoneDefaults.bool(forKey: "downloadedOnly"), true,
                       "the phone's own change was rolled back by the refresh")
    }
}

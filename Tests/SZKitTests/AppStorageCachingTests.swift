import XCTest
import SwiftUI

/// What `@AppStorage` actually does on an `ObservableObject`, pinned.
///
/// `AppModel` holds the sort, the filters and the source switches as
/// `@AppStorage` on a class rather than in a view, and `PreferenceCloud`
/// writes the reader's other device's values straight into `UserDefaults`
/// underneath them. Whether the model then *sees* those writes is the entire
/// question, and the answer is: only until the first write through the
/// property.
///
/// A test about the platform rather than about this app, which is exactly why
/// it is worth having. It cost a deployed build and a round of "sync still
/// does not work" to find, the failure is silent, and if a later SwiftUI
/// changes this behaviour then `AppModel.applyRemotePreferences` is doing
/// unnecessary work and this is what will say so.
@MainActor
final class AppStorageCachingTests: XCTestCase {

    /// Stands in for `AppModel`: `@AppStorage` on a class, not in a view.
    private final class Model: ObservableObject {
        @AppStorage("cachingProbe") var sort = "opened"
        init(_ store: UserDefaults) {
            _sort = AppStorage(wrappedValue: "opened", "cachingProbe", store: store)
        }
    }

    private var suite: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        suite = "app-storage-caching-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suite)
    }

    /// Before the model has ever written, it reads the store. This is why the
    /// first sync onto a device appears to work.
    func testAnExternalWriteIsSeenBeforeTheModelHasWrittenAnything() throws {
        let model = Model(defaults)
        defaults.set("hero", forKey: "cachingProbe")
        XCTAssertEqual(model.sort, "hero")
    }

    /// After the model has written once, it stops reading the store — for
    /// good, until it is rebuilt.
    ///
    /// This is the whole of the field bug: sync worked in one direction until
    /// the reader touched the setting on the receiving device, and from then
    /// on that device ignored the other one until the app was restarted.
    func testAnExternalWriteIsIgnoredOnceTheModelHasWrittenOnce() throws {
        let model = Model(defaults)
        model.sort = "title"

        defaults.set("number", forKey: "cachingProbe")

        XCTAssertEqual(defaults.string(forKey: "cachingProbe"), "number",
                       "the store itself is correct — it is the model that is stale")
        XCTAssertEqual(model.sort, "title",
                       "if this now reports \"number\", @AppStorage has started reading "
                     + "the store again and applyRemotePreferences can stop assigning by hand")
    }

    /// And assigning through the property is what mends it, which is what
    /// `applyRemotePreferences` does for every key it adopts.
    func testAssigningThroughThePropertyRefreshesIt() throws {
        let model = Model(defaults)
        model.sort = "title"
        defaults.set("number", forKey: "cachingProbe")

        model.sort = try XCTUnwrap(defaults.string(forKey: "cachingProbe"))

        XCTAssertEqual(model.sort, "number")
    }

    /// Rebuilding the model reads the store afresh, which is why restarting
    /// the app always appeared to fix it.
    func testARebuiltModelReadsTheStoreAgain() throws {
        let first = Model(defaults)
        first.sort = "title"
        defaults.set("number", forKey: "cachingProbe")

        XCTAssertEqual(Model(defaults).sort, "number")
    }
}

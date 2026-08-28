import Foundation

/// The part of `NSUbiquitousKeyValueStore` this app uses.
///
/// A protocol so the mirror below can be tested without an iCloud account,
/// which no test machine is guaranteed to have and no CI machine has. The
/// real store already has every one of these, so its conformance is empty.
public protocol KeyValueCloud: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: KeyValueCloud {}

/// Keeps a handful of `UserDefaults` keys the same on every device signed into
/// one iCloud account.
///
/// What the reader set up — which sources are showing, how the shelf is
/// filtered and sorted — should not have to be set up again on a second
/// device, or after a restore onto a new one. That state is small, flat and
/// entirely made of strings and booleans, which is exactly what the key-value
/// store is for: no schema, no records, no account plumbing beyond an
/// entitlement, and a 1 MB ceiling that this could not approach if it tried.
///
/// **The downloads themselves are emphatically not here.** They are files, and
/// they are excluded from backup on purpose. Bringing them back is a different
/// job with a different shape — see `Library.reconcileDownloads`, which is
/// what keeps the shelf honest about them in the meantime.
///
/// Degrades to doing nothing. With no iCloud account, or on a build without
/// the entitlement, the store answers empty and accepts writes that go
/// nowhere: every preference still works, it simply stays on this device.
///
/// Main-actor isolated, and not as a formality. Everything it moves ends up in
/// `@AppStorage`, which publishes into SwiftUI, and `didAdopt` re-runs the
/// shelf query — all of that is main-actor work already. The one thing that
/// genuinely arrives from elsewhere is the store's change notification, which
/// is why that observer asks for the main queue by name.
@MainActor
public final class PreferenceCloud {

    /// Marks an account as having been written to by this app.
    ///
    /// Needed because "no preferences in the cloud" and "every preference at
    /// its default" are not distinguishable by value — a fresh account and one
    /// belonging to a reader who has deliberately switched everything off look
    /// identical. Without it, the second reader's blank shelf would be taken
    /// for an empty account and overwritten by whichever device opened next.
    static let stampKey = "preferenceCloudPublished"

    private let keys: [String]
    private let defaults: UserDefaults
    private let cloud: KeyValueCloud

    /// Written once by `start()` on the main actor and read once by `deinit`,
    /// which is nonisolated and so cannot reach isolated state. There is no
    /// third access and no concurrency between those two, which is what the
    /// annotation is asserting.
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// What this device last agreed with the cloud about, so an unrelated
    /// `UserDefaults` write — and there are many, from every corner of the app
    /// — costs a dictionary lookup rather than a round trip to the store.
    private var mirrored: [String: NSObject] = [:]

    /// Set while cloud values are being written into `UserDefaults`.
    ///
    /// Those writes raise `didChangeNotification` like any other, so without
    /// care an adoption is pushed straight back as though the reader had made
    /// it, and two devices trade one change for ever.
    ///
    /// `mirrored` is what actually stops that, because the notification is
    /// delivered on the main queue and may well arrive after this flag is
    /// down: by then the adopted value is already recorded as agreed with the
    /// account, so there is nothing to push. This closes the synchronous half
    /// of the same hole and costs a boolean.
    private var adopting = false

    /// The keys that just arrived from another device, on the main thread and
    /// after they have been written into `UserDefaults`.
    ///
    /// `@AppStorage` republishes on its own, so anything that merely displays
    /// a preference is already correct by the time this runs. It exists for
    /// the work a `didSet` would have done and cannot: seeding a catalogue
    /// whose switch has just come on somewhere else, and re-running the shelf
    /// query when a filter moves.
    public var didAdopt: (([String]) -> Void)?

    public init(keys: [String],
                defaults: UserDefaults = .standard,
                cloud: KeyValueCloud = NSUbiquitousKeyValueStore.default) {
        self.keys = keys
        self.defaults = defaults
        self.cloud = cloud
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// Reconciles with the account, then follows both sides.
    public func start() {
        cloud.synchronize()
        reconcile()
        observe()
    }

    /// The first meeting between this device and the account.
    ///
    /// An account nobody has published to takes this device's settings; any
    /// other account is believed over local state.
    ///
    /// Believing the cloud looks aggressive and is not. The store keeps its
    /// own local cache, written synchronously and uploaded when it can be, so
    /// what it answers here is already the newest value *this* device knows —
    /// including changes made on this device while offline. There is no
    /// version of "the cloud is stale but UserDefaults is fresh" for these
    /// keys, because every local change went through both.
    private func reconcile() {
        guard cloud.object(forKey: Self.stampKey) != nil else {
            publishEverything()
            return
        }
        let adopted = adopt(keys)
        if !adopted.isEmpty { announce(adopted) }
        // Anything the account has never heard of — a preference added by a
        // later build than the one that first published — still goes up.
        pushLocalChanges()
    }

    private func publishEverything() {
        for key in keys { cloud.set(defaults.object(forKey: key), forKey: key) }
        cloud.set(true, forKey: Self.stampKey)
        cloud.synchronize()
        remember(keys)
    }

    /// Both queues are named rather than left to the poster's thread.
    ///
    /// The store's notification genuinely arrives from elsewhere, and
    /// everything downstream of it — `@AppStorage`, the shelf query, a
    /// catalogue seed — is main-actor work. Asking for the main queue is what
    /// makes `assumeIsolated` below a statement of fact rather than a hope.
    private func observe() {
        observers.append(NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            // No object filter. The documented sender is the store itself, but
            // there is exactly one of those in a process, so filtering buys
            // nothing and costs the whole feature if the posted object is ever
            // not the object expected — which is a silence, not an error, and
            // reads from outside as "sync works, sometimes".
            object: nil, queue: .main) { [weak self] note in
                // The store names the keys it changed; without that name we
                // would have to compare all of them, which is the same answer
                // for more work.
                let changed = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey]
                    as? [String]
                MainActor.assumeIsolated { self?.arrived(changed) }
            })
        observers.append(NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.pushLocalChanges() }
            })
    }

    /// Asks the account what it holds and adopts anything that has moved.
    ///
    /// The store's change notification is an optimisation, not a guarantee. It
    /// does not arrive while the app is in the background, and a device that
    /// was asleep or closed when the other one changed something is never told
    /// at all — so a mirror that only listens converges only for as long as
    /// both devices stay open, and needs restarting the rest of the time.
    /// That is exactly how this behaved on a real pair of devices: changes
    /// appeared to sync, and were in fact only ever arriving through `start`.
    ///
    /// Called every time the app comes back to the front, which costs one
    /// dictionary lookup per key and makes convergence a property of the app
    /// being opened rather than of a notification being delivered.
    public func refresh() {
        cloud.synchronize()
        let adopted = adopt(keys)
        guard !adopted.isEmpty else { return }
        announce(adopted)
    }

    /// A change from another device. Public so a test can deliver one without
    /// standing up a real store and a real account.
    public func arrived(_ changed: [String]?) {
        let interesting = (changed ?? keys).filter(keys.contains)
        guard !interesting.isEmpty else { return }
        let adopted = adopt(interesting)
        guard !adopted.isEmpty else { return }
        announce(adopted)
    }

    /// Writes the cloud's answer into `UserDefaults` for the keys where the
    /// two disagree, and reports which those were.
    @discardableResult
    private func adopt(_ candidates: [String]) -> [String] {
        adopting = true
        defer { adopting = false }

        var adopted: [String] = []
        for key in candidates {
            // A key the account does not carry is not an instruction to
            // delete: it is a preference this device has and the other has
            // never touched. Left alone here, and — because it is deliberately
            // *not* recorded as agreed below — pushed up by the next
            // `pushLocalChanges`. Recording it anyway is the bug this comment
            // is standing on: it marks a value as settled with an account that
            // has never seen it, and the preference then never leaves the
            // device it was set on.
            guard let value = cloud.object(forKey: key) else { continue }
            if Self.differs(value, defaults.object(forKey: key)) {
                defaults.set(value, forKey: key)
                adopted.append(key)
            }
            // Whether it moved or already matched, the two sides now agree.
            mirrored[key] = value as? NSObject
        }
        return adopted
    }

    /// Sends local values up for the keys where the two disagree.
    public func pushLocalChanges() {
        guard !adopting else { return }
        var pushed: [String] = []
        for key in keys {
            let local = defaults.object(forKey: key)
            guard Self.differs(local, mirrored[key]) else { continue }
            cloud.set(local, forKey: key)
            pushed.append(key)
        }
        guard !pushed.isEmpty else { return }
        remember(pushed)
        cloud.synchronize()
    }

    private func remember(_ changed: [String]) {
        for key in changed { mirrored[key] = defaults.object(forKey: key) as? NSObject }
    }

    private func announce(_ adopted: [String]) {
        didAdopt?(adopted)
    }

    /// Whether two stored values are different.
    ///
    /// Through `NSObject` because these arrive as `Any`: every value that can
    /// be in either store is a property-list type, and all of them bridge to
    /// something that knows how to compare itself. Two absent values are the
    /// same absence, which is what stops a key nobody has ever set from being
    /// written on every launch.
    static func differs(_ a: Any?, _ b: Any?) -> Bool {
        switch (a as? NSObject, b as? NSObject) {
        case (nil, nil):            return false
        case let (x?, y?):          return !x.isEqual(y)
        default:                    return true
        }
    }
}

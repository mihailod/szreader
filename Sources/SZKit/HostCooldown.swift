import Foundation

/// A host that has asked to be left alone, and until when.
///
/// A refusal used to end at the alert: the download stopped, the reader was
/// told to wait, and nothing at all prevented them tapping Download again a
/// second later — which is the one action that turns "slow down" into
/// "blocked". Telling someone to wait and then not waiting is not a pause.
///
/// So the wait is recorded here and checked before the next request. It
/// outlives a launch, because a refusal does: quitting the app is not what the
/// server was asking for.
///
/// Per host rather than per issue. The refusal is about the address making the
/// requests, so waiting on one issue and immediately starting another would be
/// the same client asking the same server the same question.
/// Not `Sendable`: `UserDefaults` is not, and this is only ever touched where
/// a download is started, on the main actor.
public struct HostCooldown {

    /// How long to wait when the server refuses without saying.
    ///
    /// The site this was written for answers 403 and names no duration, so
    /// there is nothing to read and this stands in. A chosen number, not the
    /// site's — long enough to be a real pause rather than a formality, short
    /// enough that a reader who hit it by accident is not locked out for the
    /// evening.
    ///
    /// One number, deliberately. A refusal that names a wait uses that wait;
    /// everything else uses this. A second tuning knob here would be two
    /// numbers for what a reader experiences as one rule.
    public static let unstatedWait: TimeInterval = 5 * 60

    private let defaults: UserDefaults
    private static let key = "hostCooldownUntil"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// How much of the wait is left, or nil when the host may be asked again.
    ///
    /// Nil rather than zero for "go ahead", so a caller reads it as a question
    /// with a yes/no answer rather than comparing against a number.
    public func remaining(forHost host: String, now: Date = Date()) -> TimeInterval? {
        let stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        guard let until = stored[Self.site(of: host)] else { return nil }
        let left = until - now.timeIntervalSince1970
        return left > 0 ? left : nil
    }

    /// The service a host belongs to: its last two labels.
    ///
    /// Recording and checking have to agree, and left alone they do not. A
    /// refusal names whichever machine actually answered — MediaFire hands out
    /// `download1234.mediafire.com`, archive.org answers from
    /// `ia601403.us.archive.org`, BatCave serves pages from
    /// `img.batcave.biz` — while a mirror is stored under the site's own
    /// domain. Keyed literally, the wait would be written against a name
    /// nothing ever asks about again, and the pause would never once apply.
    ///
    /// Collapsing to the last two labels is the rough rule that makes both
    /// sides agree. It is wrong for a `.co.uk`-shaped domain, which would
    /// collapse too far — none of the hosts here have that shape, and erring
    /// that way pauses slightly more rather than slightly less, which is the
    /// safe direction for a guard whose whole job is to hold back.
    static func site(of host: String) -> String {
        let labels = host.lowercased()
            .split(separator: ".").filter { !$0.isEmpty }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Records that this host refused, and for how long to leave it.
    ///
    /// A wait already running is never shortened. Two refusals in a row mean
    /// the server is more annoyed, not less, and taking the second one's
    /// shorter number would let a run talk its way back in early.
    public func begin(forHost host: String, wait: TimeInterval?, now: Date = Date()) {
        let seconds = (wait.map { max($0, 0) } ?? Self.unstatedWait)
        let until = now.timeIntervalSince1970 + seconds
        var stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        let key = Self.site(of: host)
        stored[key] = max(stored[key] ?? 0, until)
        defaults.set(stored, forKey: Self.key)
    }

    /// Forgets a wait. For a reader who decides the app is being too careful —
    /// the decision is theirs, but it has to be a decision.
    public func clear(forHost host: String) {
        var stored = defaults.dictionary(forKey: Self.key) as? [String: Double] ?? [:]
        stored.removeValue(forKey: Self.site(of: host))
        defaults.set(stored, forKey: Self.key)
    }
}

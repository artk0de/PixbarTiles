import Foundation

/// What the last launch knew about the battery, and has to hand the next one.
///
/// Durable for the reason `BorrowedOverlayStore` is durable, and the reason is
/// the same shape: what the app learned is not recoverable by looking at the
/// device afterwards. `/api/stats` answers a percentage and a raw count, never
/// which way either is going — the direction is inferred from a series of
/// readings, and a series takes twenty minutes of watching to earn. Held in
/// memory alone, every launch threw that away and spent those twenty minutes
/// again with a bare percentage on the panel, which is what the user reported.
///
/// The readings are what is kept rather than the verdict they produced. A
/// stored verdict cannot be checked against anything — it would have to be
/// trusted or dropped — while stored readings go back through the same
/// invalidation rules a live one does, and a series that fails them is
/// discarded exactly as a mid-session reboot is.
public protocol BatteryHistoryStore: Sendable {
    /// What the last launch left behind, or nil when there is nothing to
    /// resume from.
    func storedHistory() -> BatteryHistory?
    /// Replaces the record. One clock at a time, so one series: a second one
    /// does not stack, and the uid inside it is what says whether the readings
    /// belong to the clock now answering.
    func save(_ history: BatteryHistory)
}

public final class InMemoryBatteryHistoryStore: BatteryHistoryStore, @unchecked Sendable {
    private var storage: BatteryHistory?
    private let lock = NSLock()

    public init() {}

    public func storedHistory() -> BatteryHistory? {
        lock.withLock { storage }
    }

    public func save(_ history: BatteryHistory) {
        lock.withLock { storage = history }
    }
}

public final class UserDefaultsBatteryHistoryStore: BatteryHistoryStore, @unchecked Sendable {
    /// One key per clock, under the name the clock gives itself, so two
    /// clocks' trends never mix and a clock that moves address keeps its own.
    /// The uid stays inside the series as well: samples without it beside them
    /// cannot be checked against the device now answering, which is the one
    /// thing that makes resuming safe.
    public static func key(forHardwareIdentity identity: String) -> String {
        "batteryHistory.\(identity)"
    }

    /// No lock, for the reason `UserDefaultsBorrowedOverlayStore` has none:
    /// both members write the whole value or read it, and `UserDefaults` is
    /// safe for that on its own. It is the read-modify-write stores that need
    /// one.
    private let defaults: UserDefaults
    /// The clock this store resumes for, or nil while it has never answered —
    /// and so has nothing of its own to resume.
    private let hardwareIdentity: String?

    public init(defaults: UserDefaults = .standard, hardwareIdentity: String?) {
        self.defaults = defaults
        self.hardwareIdentity = hardwareIdentity
    }

    /// A key holding something that will not decode reads as a first launch,
    /// not as a failure: whatever is in there, it is not a series this app
    /// wrote, and starting cold is what the discard rules produce anyway.
    public func storedHistory() -> BatteryHistory? {
        guard let hardwareIdentity,
            let data = defaults.data(forKey: Self.key(forHardwareIdentity: hardwareIdentity))
        else { return nil }
        return try? JSONDecoder().decode(BatteryHistory.self, from: data)
    }

    /// Written on every poll rather than at quit, and that is the whole point
    /// of choosing a store over a teardown hook: a force quit, a crash, or a
    /// logout that outruns the quit budget each end a launch with nothing
    /// written down, and those are exactly the exits after which somebody
    /// reopens the app and wants to know what the battery is doing.
    ///
    /// The cost is a few kilobytes of JSON per minute — ninety samples of two
    /// small fields — against a `UserDefaults` that coalesces its own writes
    /// to disk. Writing every tenth poll was the alternative, and it buys
    /// nothing measurable while making what survives a crash depend on where
    /// in the cycle it happened.
    ///
    /// Under the clock the series itself names, so a clock that learns its
    /// name on this very poll still lands its first series where the next
    /// launch, which reads the name off the clock record, will look.
    public func save(_ history: BatteryHistory) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: Self.key(forHardwareIdentity: history.uid))
    }
}

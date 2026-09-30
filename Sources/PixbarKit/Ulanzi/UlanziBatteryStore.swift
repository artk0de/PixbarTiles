import Foundation

/// A TC002's last battery sample, handed from one launch to the next.
///
/// The TC002 half of what `BatteryHistoryStore` is for an AWTRIX clock, and
/// smaller on purpose: the direction here is read off the charging flag, not
/// fitted from a series, so a single sample already says which way the cell
/// was going. What it buys is the clock that is off when the app starts — it
/// never answers a poll, and without this its card has no battery at all, so
/// the refresh cannot say a clock last seen running down may have run out.
public protocol UlanziBatteryStore: Sendable {
    /// The last sample read from this clock, or nil when none ever was.
    func storedSample() -> UlanziBatterySample?
    /// Replaces the record with a fresher sample.
    func save(_ sample: UlanziBatterySample)
}

public final class InMemoryUlanziBatteryStore: UlanziBatteryStore, @unchecked Sendable {
    private var storage: UlanziBatterySample?
    private let lock = NSLock()

    public init() {}

    public func storedSample() -> UlanziBatterySample? {
        lock.withLock { storage }
    }

    public func save(_ sample: UlanziBatterySample) {
        lock.withLock { storage = sample }
    }
}

public final class UserDefaultsUlanziBatteryStore: UlanziBatteryStore, @unchecked Sendable {
    /// One key per clock record: the TC002 has no hardware name the app keeps
    /// the way an AWTRIX uid is kept, and the record id already survives a
    /// change of address.
    public static func key(for clockId: UUID) -> String {
        "ulanziBattery.\(clockId.uuidString)"
    }

    /// No lock: both members write or read the whole value, which
    /// `UserDefaults` is safe for on its own.
    private let defaults: UserDefaults
    private let clockId: UUID

    public init(defaults: UserDefaults = .standard, clockId: UUID) {
        self.defaults = defaults
        self.clockId = clockId
    }

    /// A key that will not decode reads as a clock never read.
    public func storedSample() -> UlanziBatterySample? {
        guard let data = defaults.data(forKey: Self.key(for: clockId)) else { return nil }
        return try? JSONDecoder().decode(UlanziBatterySample.self, from: data)
    }

    /// Written on every read rather than at quit, for the reason
    /// `UserDefaultsBatteryHistoryStore` gives: a force quit or a crash ends
    /// a launch with nothing written down.
    public func save(_ sample: UlanziBatterySample) {
        guard let data = try? JSONEncoder().encode(sample) else { return }
        defaults.set(data, forKey: Self.key(for: clockId))
    }
}

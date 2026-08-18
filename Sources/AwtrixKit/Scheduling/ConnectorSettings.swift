import Foundation

/// What the user decided about one connector: whether it runs, and how often.
///
/// The interval is stored as a scale position rather than a duration, because
/// the position is what the slider in the menu binds to. Storing seconds would
/// let a value be saved that the scale cannot represent, and the slider would
/// then snap somewhere the user never chose.
public struct ConnectorSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var intervalPosition: Int

    /// Position 5 on the scale is thirty minutes.
    public init(isEnabled: Bool = true, intervalPosition: Int = 5) {
        self.isEnabled = isEnabled
        self.intervalPosition = intervalPosition
    }

    public var interval: TimeInterval {
        IntervalScale.duration(atPosition: intervalPosition)
    }
}

public protocol SettingsStore: Sendable {
    /// What the user actually chose for this connector, or nil when they never
    /// chose anything.
    ///
    /// The nil is the whole point. A connector nobody has configured has to fall
    /// back to its OWN `defaultInterval`, and `settings(for:)` cannot say
    /// whether the thirty minutes it hands back were chosen or invented — so a
    /// connector whose default is five minutes would be silently rescheduled to
    /// half an hour by the store that is only supposed to remember decisions.
    func storedSettings(for id: String) -> ConnectorSettings?
    func save(_ settings: ConnectorSettings, for id: String)
}

extension SettingsStore {
    /// For callers with no connector in hand — the host reads enablement by id
    /// long before it has looked one up, and "never configured" and "configured
    /// as the defaults" are the same answer to that question.
    ///
    /// An extension rather than a requirement: there is one way to fold an
    /// absent choice into a present one, and a conformer that overrode it would
    /// be answering a question it was not asked.
    public func settings(for id: String) -> ConnectorSettings {
        storedSettings(for: id) ?? ConnectorSettings()
    }
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var storage: [String: ConnectorSettings] = [:]
    private let lock = NSLock()

    public init() {}

    public func storedSettings(for id: String) -> ConnectorSettings? {
        lock.withLock { storage[id] }
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        lock.withLock { storage[id] = settings }
    }
}

public final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// One key per connector. A shared key would have switching one connector
    /// off switch every other one off with it.
    private func key(_ id: String) -> String { "connector.\(id)" }

    /// A key holding something that will not decode reads as never configured,
    /// not as a failure: whatever is in there, the user did not choose it, and
    /// the connector's own default is a better answer than a stale shape.
    public func storedSettings(for id: String) -> ConnectorSettings? {
        guard let data = defaults.data(forKey: key(id)) else { return nil }
        return try? JSONDecoder().decode(ConnectorSettings.self, from: data)
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(id))
    }
}

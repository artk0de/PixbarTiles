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
    func settings(for id: String) -> ConnectorSettings
    func save(_ settings: ConnectorSettings, for id: String)
}

public final class InMemorySettingsStore: SettingsStore, @unchecked Sendable {
    private var storage: [String: ConnectorSettings] = [:]
    private let lock = NSLock()

    public init() {}

    public func settings(for id: String) -> ConnectorSettings {
        lock.withLock { storage[id] ?? ConnectorSettings() }
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

    public func settings(for id: String) -> ConnectorSettings {
        guard
            let data = defaults.data(forKey: key(id)),
            let decoded = try? JSONDecoder().decode(ConnectorSettings.self, from: data)
        else { return ConnectorSettings() }
        return decoded
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(id))
    }
}

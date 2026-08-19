import Foundation

/// What the user decided about one connector — whether it runs, and how often —
/// and the one thing the user did not decide that the cadence is meaningless
/// without.
///
/// The interval is stored as a scale position rather than a duration, because
/// the position is what the slider in the menu binds to. Storing seconds would
/// let a value be saved that the scale cannot represent, and the slider would
/// then snap somewhere the user never chose.
public struct ConnectorSettings: Sendable, Codable, Equatable {
    public var isEnabled: Bool
    public var intervalPosition: Int
    /// When this connector last put something on the clock, or nil while it
    /// never has.
    ///
    /// Not a decision, and it is here anyway. "Every half hour" is a claim
    /// about the gaps BETWEEN deliveries, and a cadence with no last delivery
    /// behind it can only be measured from the launch — which is the defect
    /// this field exists for: five relaunches inside an hour, each one starting
    /// the hour again, and an hourly connector that is never heard from. The
    /// instant is what the interval is measured from, so the two travel
    /// together or the pair is only ever half true.
    ///
    /// A record of its own — a second `UserDefaults` key, its own store — was
    /// the alternative, and it buys a struct that is purely the user's choices
    /// at the cost of two keys per connector that must be written, migrated and
    /// deleted in step. `SettingsStore` already answers "what is true of this
    /// connector, across launches", and a second store answering half of the
    /// same question is the thing that drifts.
    ///
    /// Optional rather than defaulted to the epoch or to the launch. Both of
    /// those are instants, so both would read as a delivery that happened, and
    /// the distance from either one decides how long the first sleep is — the
    /// epoch makes every fresh connector overdue and the launch makes the
    /// remembering pointless. Never delivered is not an instant, so it is not
    /// stored as one.
    ///
    /// Decoded with `decodeIfPresent`, which is what a synthesized `Codable`
    /// does for an optional: a key written before this field existed still
    /// decodes, and the connector reads as one that has never delivered.
    /// Anything else would fail the decode, and a failed decode is folded into
    /// "never configured" — resetting every interval the user had chosen, on
    /// the launch that introduced the field.
    public var lastDeliveredAt: Date?

    /// Position 5 on the scale is thirty minutes.
    public init(
        isEnabled: Bool = true, intervalPosition: Int = 5, lastDeliveredAt: Date? = nil
    ) {
        self.isEnabled = isEnabled
        self.intervalPosition = intervalPosition
        self.lastDeliveredAt = lastDeliveredAt
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

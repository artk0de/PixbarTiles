import Foundation

/// One clock's tiles, in the shape the schedule and the host already read.
///
/// The seam that lets tiles replace `connector.<id>` without either reader
/// changing: `ConnectorHost` and `AppModel` ask a `SettingsStore`, and this
/// one answers from the tiles on the clock the app drives.
public final class TileSettingsStore: SettingsStore, @unchecked Sendable {
    private let tiles: TileStore
    private let clockId: UUID

    public init(defaults: UserDefaults, clockId: UUID) {
        self.tiles = TileStore(defaults: defaults)
        self.clockId = clockId
    }

    /// Nil when the clock carries no tile for this connector, which is what
    /// sends `AppModel` to the connector's own default.
    public func storedSettings(for id: String) -> ConnectorSettings? {
        let key = TileKey(clockId: clockId, connectorId: id)
        guard let tile = tiles.all().first(where: { $0.key == key }) else { return nil }
        return ConnectorSettings(
            isEnabled: !tile.policy.isPaused,
            intervalPosition: IntervalScale.position(
                for: TimeInterval(tile.policy.refreshSeconds)
            ),
            lastDeliveredAt: tile.lastDeliveredAt
        )
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        let seconds = Int(settings.interval)
        let fresh = TileRecord(
            key: TileKey(clockId: clockId, connectorId: id),
            policy: TilePolicyRecord(isPaused: !settings.isEnabled, refreshSeconds: seconds)
        )
        tiles.update(fresh) { tile in
            tile.policy.isPaused = !settings.isEnabled
            // Rewritten only when the slider moved. Every delivery saves
            // too, and the position is a snapped reading of the seconds:
            // writing the snap back would turn a refresh the scale cannot
            // show into the nearest one it can, one delivery after it was set.
            let shown = IntervalScale.position(for: TimeInterval(tile.policy.refreshSeconds))
            if shown != settings.intervalPosition {
                tile.policy.refreshSeconds = seconds
            }
            tile.lastDeliveredAt = settings.lastDeliveredAt
        }
    }
}

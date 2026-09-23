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
    ///
    /// - Parameter id: the tile id the session keys everything by — the
    ///   connector id alone for a single tile, so every tile stored before
    ///   instancing reads exactly as it did.
    public func storedSettings(for id: String) -> ConnectorSettings? {
        tile(named: id).map { Self.settings(of: $0) }
    }

    /// The settings of the tile with this key, instance included.
    public func storedSettings(for key: TileKey) -> ConnectorSettings? {
        tiles.all().first { $0.key == key }.map { Self.settings(of: $0) }
    }

    /// This clock's tile whose tile id is `id`. Matched on the tile id rather
    /// than parsed out of it: an instance may itself contain a dot.
    private func tile(named id: String) -> TileRecord? {
        tiles.all().first { $0.key.clockId == clockId && $0.key.tileId == id }
    }

    private static func settings(of tile: TileRecord) -> ConnectorSettings {
        ConnectorSettings(
            isEnabled: !tile.policy.isPaused,
            intervalPosition: IntervalScale.position(
                for: TimeInterval(tile.policy.refreshSeconds)
            ),
            lastDeliveredAt: tile.lastDeliveredAt
        )
    }

    public func save(_ settings: ConnectorSettings, for id: String) {
        let seconds = Int(settings.interval)
        // An instance's tile is made by the store before it ever runs, so a
        // tile id with no tile behind it is a single connector's first save.
        let fresh = TileRecord(
            key: tile(named: id)?.key ?? TileKey(clockId: clockId, connectorId: id),
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

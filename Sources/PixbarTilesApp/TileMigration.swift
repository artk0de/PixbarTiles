import Foundation
import PixbarKit

/// Turns each connector's `connector.<id>` settings into its tile on the clock
/// the app drives.
///
/// Runs once, marker last, old keys only read — the same terms as
/// `ClockMigration`. A connector with no stored settings gets a tile from its
/// own defaults, because before tiles every registered connector ran on the
/// one clock whether or not anybody had touched its switch.
struct TileMigration {
    static let markerKey = "migration.tiles"

    let defaults: UserDefaults
    let clockId: UUID
    /// In registration order, which is the order the tiles are stored in.
    let connectors: [(id: String, defaultInterval: TimeInterval)]

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        // Read through the store that wrote them, so a key that does not
        // decode means what it has always meant: never configured.
        let legacy = UserDefaultsSettingsStore(defaults: defaults)
        let tiles = connectors.map { connector in
            let chosen = legacy.storedSettings(for: connector.id)
            return TileRecord(
                key: TileKey(clockId: clockId, connectorId: connector.id),
                policy: TilePolicyRecord(
                    isPaused: chosen.map { $0.isEnabled == false } ?? false,
                    // Position to duration to seconds. `interval` clamps a
                    // position past either end of the scale onto it.
                    refreshSeconds: Int(chosen?.interval ?? connector.defaultInterval)
                ),
                lastDeliveredAt: chosen?.lastDeliveredAt
            )
        }
        try TileStore(defaults: defaults).replaceAll(tiles)
        defaults.set(true, forKey: Self.markerKey)
    }
}

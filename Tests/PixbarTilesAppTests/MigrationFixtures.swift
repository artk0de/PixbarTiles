import Foundation
import PixbarKit
import Testing

/// Runs `body` against a defaults domain of its own, which is gone afterwards.
func withFreshDefaults(_ body: (RecordingDefaults) throws -> Void) throws {
    let suite = "migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

/// The clock `ClockMigration` leaves behind, stored.
@discardableResult
func storeAClock(
    _ model: ClockModel = .awtrix3, in defaults: UserDefaults
) throws -> ClockRecord {
    let clock = ClockRecord(name: "Clock", model: model, address: "10.0.0.9")
    try ClockStore(defaults: defaults).replaceAll([clock])
    return clock
}

/// The tiles `TileMigration` leaves behind on that clock: the three shipped
/// connectors, as Phase 1 stores them — no Focus, no hours, no config.
func storeTheMigratedTiles(on clock: ClockRecord, in defaults: UserDefaults) throws {
    try TileStore(defaults: defaults).replaceAll([
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: "anecdotes"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 1_800)
        ),
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: "weather"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
        ),
        TileRecord(
            key: TileKey(clockId: clock.id, connectorId: "claude"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 300)
        ),
    ])
}

func tile(_ connectorId: String, in defaults: UserDefaults) -> TileRecord? {
    TileStore(defaults: defaults).all().first { $0.key.connectorId == connectorId }
}

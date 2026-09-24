import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

private let clock = UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11")!
private let delivered = Date(timeIntervalSinceReferenceDate: 777_000_000)

/// What `AppModel.live()` registers, in its order and with its defaults.
private let shipped: [(id: String, defaultInterval: TimeInterval)] = [
    (id: "anecdotes", defaultInterval: 1800),
    (id: "weather", defaultInterval: 600),
    (id: "claude", defaultInterval: 300),
]

/// Writes a connector's settings the way every build before tiles did.
private func saveTheOldWay(_ settings: ConnectorSettings, for id: String, in defaults: UserDefaults) {
    UserDefaultsSettingsStore(defaults: defaults).save(settings, for: id)
}

private func tile(
    _ connector: String, paused: Bool = false, every seconds: Int, deliveredAt: Date? = nil
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: seconds),
        lastDeliveredAt: deliveredAt
    )
}

// Index → duration → seconds, the switch inverted into a pause, the last
// delivery kept — and a connector nobody configured gets its own defaults,
// because it was running on the one clock all along.
@Test func everyConnectorBecomesATileOnTheClockInRegistrationOrder() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    saveTheOldWay(
        ConnectorSettings(isEnabled: false, intervalPosition: 11, lastDeliveredAt: delivered),
        for: "anecdotes", in: defaults
    )

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(
        TileStore(defaults: defaults).all() == [
            tile("anecdotes", paused: true, every: 3600, deliveredAt: delivered),
            tile("weather", every: 600),
            tile("claude", every: 300),
        ]
    )
}

@Test func anOldKeyThatDoesNotDecodeIsANeverConfiguredConnector() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(Data("not settings".utf8), forKey: "connector.weather")

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(TileStore(defaults: defaults).all().dropFirst().first == tile("weather", every: 600))
}

@Test func aPositionPastTheEndOfTheScaleBecomesTheLongestRefresh() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    saveTheOldWay(ConnectorSettings(intervalPosition: 99), for: "claude", in: defaults)

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(TileStore(defaults: defaults).all().last?.policy.refreshSeconds == 12 * 3600)
}

@Test func theTileMigrationLeavesTheOldKeysAsTheyWere() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    saveTheOldWay(ConnectorSettings(isEnabled: false, intervalPosition: 11), for: "anecdotes", in: defaults)
    let before = defaults.data(forKey: "connector.anecdotes")

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(defaults.data(forKey: "connector.anecdotes") == before)
    #expect(defaults.data(forKey: "connector.weather") == nil)
}

@Test func theTileMigrationWritesItsMarkerLast() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(defaults.writes.contains(TileStore.key))
    #expect(defaults.writes.last == TileMigration.markerKey)
}

@Test func aSecondTileMigrationChangesNothing() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let migration = TileMigration(defaults: defaults, clockId: clock, connectors: shipped)
    try migration.run()
    let first = defaults.data(forKey: TileStore.key)
    saveTheOldWay(ConnectorSettings(isEnabled: false, intervalPosition: 11), for: "weather", in: defaults)

    try migration.run()

    #expect(defaults.data(forKey: TileStore.key) == first)
}

@Test func aTileMigrationCutShortStartsAgainFromTheOldKeys() throws {
    let suite = "tile-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([tile("weather", paused: true, every: 60)])

    try TileMigration(defaults: defaults, clockId: clock, connectors: shipped).run()

    #expect(TileStore(defaults: defaults).all().map(\.policy.refreshSeconds) == [1800, 600, 300])
}

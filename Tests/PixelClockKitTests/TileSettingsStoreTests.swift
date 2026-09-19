import Foundation
import Testing
@testable import PixelClockKit

private let desk = UUID(uuidString: "6F1C1B6E-3B0A-4C8E-9C5A-2D1B7A9E0F11")!
private let kitchen = UUID(uuidString: "0B3E2A51-7D44-4E0F-A1C2-5E6F7A8B9C0D")!
private let delivered = Date(timeIntervalSinceReferenceDate: 777_000_000)

private func stored(
    on clock: UUID = desk, _ connector: String, paused: Bool = false, every seconds: Int,
    deliveredAt: Date? = nil
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock, connectorId: connector),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: seconds),
        lastDeliveredAt: deliveredAt
    )
}

// The nil `AppModel.resolved` turns into the connector's OWN default. A store
// that answered with `ConnectorSettings()` here would reschedule a five-minute
// connector to thirty, which is what `storedSettings` exists to prevent.
@Test func aConnectorWithNoTileOnTheClockHasNoStoredSettings() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "weather") == nil)
}

@Test func aTileOnAnotherClockIsNotThisClocksSettings() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([stored(on: kitchen, "weather", every: 600)])

    #expect(TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "weather") == nil)
}

@Test func aTileReadsAsTheSettingsTheScheduleAlreadyUnderstands() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([
        stored("anecdotes", paused: true, every: 3600, deliveredAt: delivered),
    ])

    #expect(
        TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "anecdotes")
            == ConnectorSettings(isEnabled: false, intervalPosition: 11, lastDeliveredAt: delivered)
    )
}

// Seconds the slider has no step for read as the nearest step it has. 700 s is
// nearer ten minutes than fifteen; 30 s is below the slider's floor.
@Test func secondsBetweenStepsReadAsTheNearestStep() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([
        stored("weather", every: 700), stored("claude", every: 30),
    ])
    let store = TileSettingsStore(defaults: defaults, clockId: desk)

    #expect(store.storedSettings(for: "weather")?.intervalPosition == 1)
    #expect(store.storedSettings(for: "claude")?.intervalPosition == 0)
}

@Test func savingWritesTheChoiceIntoTheTile() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([stored("anecdotes", every: 1800)])

    TileSettingsStore(defaults: defaults, clockId: desk).save(
        ConnectorSettings(isEnabled: false, intervalPosition: 11, lastDeliveredAt: delivered),
        for: "anecdotes"
    )

    #expect(
        TileStore(defaults: defaults).all()
            == [stored("anecdotes", paused: true, every: 3600, deliveredAt: delivered)]
    )
}

// A connector registered after the migration ran has no tile, and its first
// saved choice is what gives it one.
@Test func savingGivesAConnectorWithNoTileOne() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    TileSettingsStore(defaults: defaults, clockId: desk).save(
        ConnectorSettings(isEnabled: true, intervalPosition: 0), for: "claude"
    )

    #expect(TileStore(defaults: defaults).all() == [stored("claude", every: 300)])
}

// Every delivery saves the whole settings value back, and the position in it
// is a snapped reading of the seconds. Written back, the snap would turn 700 s
// into 600 s one delivery after it was set — and in Phase 4 a 30 s refresh
// into five minutes.
@Test func aDeliveryDoesNotRoundTheRefreshOntoTheScale() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try TileStore(defaults: defaults).replaceAll([stored("weather", every: 700)])
    let store = TileSettingsStore(defaults: defaults, clockId: desk)
    var settings = try #require(store.storedSettings(for: "weather"))

    settings.lastDeliveredAt = delivered
    store.save(settings, for: "weather")

    #expect(TileStore(defaults: defaults).all().first?.policy.refreshSeconds == 700)
    #expect(TileStore(defaults: defaults).all().first?.lastDeliveredAt == delivered)
}

@Test func aChoiceSurvivesARelaunch() throws {
    let suite = "tile-settings-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let chosen = ConnectorSettings(isEnabled: false, intervalPosition: 3, lastDeliveredAt: delivered)

    TileSettingsStore(defaults: defaults, clockId: desk).save(chosen, for: "anecdotes")

    #expect(
        TileSettingsStore(defaults: defaults, clockId: desk).storedSettings(for: "anecdotes")
            == chosen
    )
}

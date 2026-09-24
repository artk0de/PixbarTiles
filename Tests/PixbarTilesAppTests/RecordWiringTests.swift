import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// A queue file of its own per launch: `AnecdoteQueue.init` reads whatever
/// file it is handed, and a test has no business opening the user's.
private func scratchStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("records-\(UUID().uuidString).json")
}

/// An install with one stored clock — the shape every launch poses now that
/// the store invents nothing on a fresh domain (D6).
@MainActor
private func seedClock(in defaults: UserDefaults) throws {
    try ClockStore(defaults: defaults).replaceAll([
        ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    ])
    defaults.set(true, forKey: ClockMigration.markerKey)
}

// The phase's first claim. The first launch migrates; after that the record
// is what is read, so an address changed on the record is the one the next
// launch talks to.
@Test @MainActor func theLaunchReadsItsClockFromTheClockRecords() async throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // An upgraded install: the old key is what the first launch migrates.
    defaults.set("10.0.0.5", forKey: AppModel.deviceHostKey)
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    let clocks = ClockStore(defaults: defaults)
    let clock = try #require(clocks.all().first)
    #expect(clock.address == "10.0.0.5")
    clocks.update(clock) { $0.address = "10.0.0.7" }
    let transport = StubTransport(body: onlineStats)

    let relaunched = AppModel.live(
        defaults: defaults, transport: transport, anecdoteStore: scratchStore()
    )

    #expect(relaunched.deviceHost == "10.0.0.7")
    // And the device, which is what actually talks. The model is handed the
    // record and the device is built beside it, so a device built from anything
    // else would still leave the line above reporting the record's address.
    _ = await relaunched.monitor.refresh()
    #expect(transport.requests.map { $0.url?.host } == ["10.0.0.7"])
}

// Migrated, and then the list is emptied by hand — nothing the app does, and
// exactly the state the user reaches through removal. The launch drives
// nothing and invents nothing (D6).
@Test @MainActor func aLaunchWithNoClockStoredDrivesNothing() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(true, forKey: ClockMigration.markerKey)

    let launched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(launched.hasNoClocks)
    #expect(ClockStore(defaults: defaults).all().isEmpty)
}

/// The tile `TileMigration` gave a connector on the launch's clock, changed
/// the way a later phase's editor would change it.
private func editTile(
    _ connectorId: String, in defaults: UserDefaults, _ change: (inout TileRecord) -> Void
) throws {
    let clock = try #require(ClockStore(defaults: defaults).all().first)
    let key = TileKey(clockId: clock.id, connectorId: connectorId)
    let tile = try #require(TileStore(defaults: defaults).all().first(where: { $0.key == key }))
    TileStore(defaults: defaults).update(tile, change)
}

// The phase's second claim, for the schedule's half: the switch and the
// interval the panel shows are the tile's.
@Test @MainActor func theLaunchReadsEachConnectorsCadenceFromItsTile() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try seedClock(in: defaults)
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    try editTile("anecdotes", in: defaults) {
        $0.policy.isPaused = true
        $0.policy.refreshSeconds = 3600
    }

    let relaunched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    let anecdotes = try #require(relaunched.registry.connector(id: "anecdotes"))
    #expect(
        relaunched.settings(for: anecdotes)
            == ConnectorSettings(isEnabled: false, intervalPosition: 11)
    )
}

// And the host's half. `live()` builds the host and the model separately, and
// a host still reading `connector.<id>` would run a paused connector on
// "Run now" — its enablement guard answers `.skipped` only from the store it
// was given.
@Test @MainActor func aPausedTileIsOffForTheHostAsWell() async throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try seedClock(in: defaults)
    _ = AppModel.live(defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore())
    try editTile("weather", in: defaults) { $0.policy.isPaused = true }
    let relaunched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    relaunched.runNow("weather")

    #expect(await waitUntil { relaunched.lastResults["weather"] == "off" })
    await relaunched.teardown()
}

// The upgrade, end to end. Green before this task as well — the old store
// read the old key directly — and kept because from here on it is the only
// thing proving the step runs at launch, on the clock the launch drives, after
// every connector is registered.
@Test @MainActor func anUpgradedInstallationKeepsEachConnectorsChoice() throws {
    let suite = "records-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // An upgraded install: the old address key is what the clock migration
    // has to find.
    defaults.set("10.0.0.5", forKey: AppModel.deviceHostKey)
    UserDefaultsSettingsStore(defaults: defaults).save(
        ConnectorSettings(isEnabled: false, intervalPosition: 11), for: "anecdotes"
    )

    let launched = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    let anecdotes = try #require(launched.registry.connector(id: "anecdotes"))
    #expect(
        launched.settings(for: anecdotes)
            == ConnectorSettings(isEnabled: false, intervalPosition: 11)
    )
}

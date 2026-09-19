import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

@Test @MainActor func theOldAddressBecomesOneAwtrixClockNamedClock() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    defaults.set("awtrix_a07f9c", forKey: AppModel.deviceUIDKey)

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    let clocks = ClockStore(defaults: defaults).all()
    #expect(clocks.count == 1)
    #expect(clocks.first?.name == "Clock")
    #expect(clocks.first?.model == .awtrix3)
    #expect(clocks.first?.address == "10.0.0.9")
    #expect(clocks.first?.hardwareIdentity == "awtrix_a07f9c")
}

// An installation that never saved an address was talking to the default one,
// so that is the clock it has.
@Test @MainActor func anInstallationThatNeverSavedAnAddressGetsTheOneItWasUsing() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    let clock = try #require(ClockStore(defaults: defaults).all().first)
    #expect(clock.address == AppModel.defaultDeviceHost)
    #expect(clock.hardwareIdentity == nil)
}

@Test @MainActor func theClockMigrationLeavesTheOldKeysAsTheyWere() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    defaults.set("awtrix_a07f9c", forKey: AppModel.deviceUIDKey)

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
    #expect(defaults.string(forKey: AppModel.deviceUIDKey) == "awtrix_a07f9c")
}

// Last, so a run the process did not survive has no marker and runs again.
@Test @MainActor func theClockMigrationWritesItsMarkerLast() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    #expect(defaults.writes.contains(ClockStore.key))
    #expect(defaults.writes.last == ClockMigration.markerKey)
}

// The old key changes between the runs, so a second run that migrated again
// would show.
@Test @MainActor func aSecondClockMigrationChangesNothing() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    let migration = ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost)
    try migration.run()
    let first = defaults.data(forKey: ClockStore.key)
    defaults.set("10.0.0.7", forKey: AppModel.deviceHostKey)

    try migration.run()

    #expect(defaults.data(forKey: ClockStore.key) == first)
}

// A run cut short after the records and before the marker. What it left is
// not trusted: the step starts again from the old keys.
@Test @MainActor func aClockMigrationCutShortStartsAgainFromTheOldKeys() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)
    try ClockStore(defaults: defaults).replaceAll([
        ClockRecord(name: "Half", model: .ulanziTC002, address: "10.0.0.1"),
    ])

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    let clocks = ClockStore(defaults: defaults).all()
    #expect(clocks.map(\.address) == ["10.0.0.9"])
    #expect(clocks.map(\.name) == ["Clock"])
}

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

// A fresh install is left alone — the empty state is the user's to answer,
// and the new pin lives with the rest of it in NoClocksTests. Here, the
// install that DID save an address: the marker is the last write, so a run
// the process did not survive starts again from the old keys.
@Test @MainActor func theClockMigrationWritesItsMarkerLast() throws {
    let suite = "clock-migration-\(UUID().uuidString)"
    let defaults = try #require(RecordingDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)

    try ClockMigration(defaults: defaults, fallbackHost: AppModel.defaultDeviceHost).run()

    #expect(defaults.writes.contains(ClockStore.key))
    #expect(defaults.writes.last == ClockMigration.markerKey)
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

import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

private let series = Data(#"{"uid":"awtrix_a07f9c","uptime":9000,"samples":[]}"#.utf8)

@Test func theSeriesMovesUnderTheNameOfItsClockByteForByte() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: "batteryHistory.awtrix_a07f9c") == series)
    }
}

@Test func aSeriesThatNamesNoClockIsLeftWhereItIs() throws {
    try withFreshDefaults { defaults in
        defaults.set(Data("not a series".utf8), forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.dictionaryRepresentation().keys.contains { $0.hasPrefix("batteryHistory.") } == false)
        #expect(defaults.bool(forKey: BatteryHistoryMigration.markerKey))
    }
}

@Test func theBatteryHistoryMigrationLeavesTheOldKeyAsItWas() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: BatteryHistoryMigration.legacyKey) == series)
    }
}

@Test func theBatteryHistoryMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.writes.last == BatteryHistoryMigration.markerKey)
    }
}

// The per-clock series has moved on since; the old one must not come back
// over it.
@Test func aSecondBatteryHistoryMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        defaults.set(series, forKey: BatteryHistoryMigration.legacyKey)
        BatteryHistoryMigration(defaults: defaults).run()
        let newer = Data(#"{"uid":"awtrix_a07f9c","uptime":9600,"samples":[]}"#.utf8)
        defaults.set(newer, forKey: "batteryHistory.awtrix_a07f9c")

        BatteryHistoryMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: "batteryHistory.awtrix_a07f9c") == newer)
    }
}

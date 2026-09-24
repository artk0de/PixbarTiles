import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

private let audible: Set<String> = ["anecdotes"]

private func savedTheOldWay(from start: Int, to end: Int, in defaults: UserDefaults) {
    defaults.set(start, forKey: QuietHoursMigration.startKey)
    defaults.set(end, forKey: QuietHoursMigration.endKey)
}

@Test func theQuietHoursBecomeTheWindowOfEveryAudibleTile() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 22, to: 7, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .quiet(HourWindow(startHour: 22, endHour: 7)))
    }
}

// The window only ever held what could be heard. The weather and the Claude
// figure drew straight through it, and still do.
@Test func aSilentTileKeepsItsHours() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 22, to: 7, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("weather", in: defaults)?.policy.window == nil)
        #expect(tile("claude", in: defaults)?.policy.window == nil)
    }
}

// Midnight is an hour somebody can choose, and `integer(forKey:)` answers 0 for
// a key never written.
@Test func aWindowStartingAtMidnightIsNotMistakenForNone() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 0, to: 6, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .quiet(HourWindow(startHour: 0, endHour: 6)))
    }
}

@Test func hoursNeverSavedAreTheWindowTheAppKept() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .quiet(HourWindow(startHour: 23, endHour: 8)))
    }
}

// Only the hours move. The Focus rule is the anecdote row's, which is what the
// app did with Focuses before tiles.
@Test func theQuietHoursMigrationLeavesTheFocusRuleToTheDefaults() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.focus == nil)
    }
}

@Test func theQuietHoursMigrationLeavesTheOldKeysAsTheyWere() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        savedTheOldWay(from: 22, to: 7, in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(defaults.object(forKey: QuietHoursMigration.startKey) as? Int == 22)
        #expect(defaults.object(forKey: QuietHoursMigration.endKey) as? Int == 7)
    }
}

@Test func theQuietHoursMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(defaults.writes.last == QuietHoursMigration.markerKey)
    }
}

@Test func aSecondQuietHoursMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try QuietHoursMigration(defaults: defaults, audible: audible).run()
        let edited = try #require(tile("anecdotes", in: defaults))
        TileStore(defaults: defaults).update(edited) { $0.policy.window = .always }

        try QuietHoursMigration(defaults: defaults, audible: audible).run()

        #expect(tile("anecdotes", in: defaults)?.policy.window == .always)
    }
}

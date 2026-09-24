import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

private let tbilisi = Coordinates(latitude: 41.7151, longitude: 44.8271)

private func savedTheOldWay(_ place: Coordinates, in defaults: UserDefaults) throws {
    defaults.set(try JSONEncoder().encode(place), forKey: WeatherLocationMigration.legacyKey)
}

@Test func theSavedPlaceBecomesTheWeatherTilesConfig() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try savedTheOldWay(tbilisi, in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("weather", in: defaults)?.config == .weather(tbilisi))
    }
}

// Never saved is the place the app was reading for all along.
@Test func aPlaceNeverSavedIsThePlaceTheAppWasUsing() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("weather", in: defaults)?.config == .weather(.default))
    }
}

@Test func noOtherTileGainsAPlace() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try savedTheOldWay(tbilisi, in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("anecdotes", in: defaults)?.config == nil)
        #expect(tile("claude", in: defaults)?.config == nil)
    }
}

@Test func theWeatherLocationMigrationLeavesTheOldKeyAsItWas() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try savedTheOldWay(tbilisi, in: defaults)
        let before = defaults.data(forKey: WeatherLocationMigration.legacyKey)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(defaults.data(forKey: WeatherLocationMigration.legacyKey) == before)
    }
}

@Test func theWeatherLocationMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(defaults.writes.last == WeatherLocationMigration.markerKey)
    }
}

// Run again after the user moved the tile somewhere else: the tile keeps the
// place the user gave it.
@Test func aSecondWeatherLocationMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        try storeTheMigratedTiles(on: try storeAClock(in: defaults), in: defaults)
        try WeatherLocationMigration(defaults: defaults).run()
        let moved = try #require(tile("weather", in: defaults))
        TileStore(defaults: defaults).update(moved) { $0.config = .weather(tbilisi) }

        try WeatherLocationMigration(defaults: defaults).run()

        #expect(tile("weather", in: defaults)?.config == .weather(tbilisi))
    }
}

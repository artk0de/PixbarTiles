import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let berlin = Coordinates(latitude: 52.52, longitude: 13.405)

@Test func theWeatherReadsThePlaceOnItsClocksWeatherTile() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)
        let tile = try #require(tile("weather", in: defaults))
        TileStore(defaults: defaults).update(tile) { $0.config = .weather(berlin) }

        #expect(StoredLocation(defaults: defaults, clockId: clock.id).current == berlin)
    }
}

@Test func aWeatherTileWithNoPlaceReadsTheDefaultOne() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)

        #expect(StoredLocation(defaults: defaults, clockId: clock.id).current == .default)
    }
}

@Test func aTypedPlaceIsSavedOnTheWeatherTileAndNowhereElse() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)

        StoredLocation(defaults: defaults, clockId: clock.id).save(berlin)

        #expect(tile("weather", in: defaults)?.config == .weather(berlin))
        #expect(defaults.data(forKey: WeatherLocationMigration.legacyKey) == nil)
    }
}

// Saving a place must not bring back a weather tile the user removed.
@Test func savingAPlaceOnAClockWithNoWeatherTileAddsNone() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)

        StoredLocation(defaults: defaults, clockId: clock.id).save(berlin)

        #expect(TileStore(defaults: defaults).all().isEmpty)
    }
}

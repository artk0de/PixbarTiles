// Sources/PixbarTilesApp/WeatherLocationMigration.swift
import Foundation
import PixbarKit

/// Puts the one place the weather was read for onto the weather tiles.
///
/// Runs once, marker last, old key only read — the terms of `ClockMigration`.
/// A key never written, or one that does not decode, is the place the app was
/// using all along, `Coordinates.default`, and that is what is copied.
struct WeatherLocationMigration {
    static let markerKey = "migration.weatherLocation"
    static let legacyKey = "weatherLocation"

    let defaults: UserDefaults

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        let place = defaults.data(forKey: Self.legacyKey)
            .flatMap { try? JSONDecoder().decode(Coordinates.self, from: $0) } ?? .default
        let store = TileStore(defaults: defaults)
        try store.replaceAll(store.all().map { tile in
            guard tile.key.connectorId == "weather" else { return tile }
            var placed = tile
            placed.config = .weather(place)
            return placed
        })
        defaults.set(true, forKey: Self.markerKey)
    }
}

// Sources/PixelClockTilesApp/QuietHoursMigration.swift
import Foundation
import PixelClockKit

/// Turns the app-wide quiet hours into the window of every audible tile.
///
/// Audible tiles only, because the window only ever held those: the weather and
/// the Claude figure drew through it. Hours never written are the window the
/// app kept anyway, 23:00–08:00, and that is what is written — read through
/// `object(forKey:)`, so a window starting at midnight is not mistaken for
/// none.
struct QuietHoursMigration {
    static let markerKey = "migration.quietHours"
    static let startKey = "quietStartHour"
    static let endKey = "quietEndHour"

    let defaults: UserDefaults
    /// The connectors that can be heard, by id.
    let audible: Set<String>

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        let hours: HourWindow
        if let start = defaults.object(forKey: Self.startKey) as? Int,
            let end = defaults.object(forKey: Self.endKey) as? Int {
            hours = HourWindow(startHour: start, endHour: end)
        } else {
            hours = HourWindow(startHour: 23, endHour: 8)
        }
        let store = TileStore(defaults: defaults)
        try store.replaceAll(store.all().map { tile in
            guard audible.contains(tile.key.connectorId) else { return tile }
            var quiet = tile
            quiet.policy.window = .quiet(hours)
            return quiet
        })
        defaults.set(true, forKey: Self.markerKey)
    }
}

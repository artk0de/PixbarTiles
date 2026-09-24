// Sources/PixbarTilesApp/BatteryHistoryMigration.swift
import Foundation
import PixbarKit

/// Moves the one stored battery series under the name of the clock it came
/// off, so the clock's own trend resumes on the first launch that keys health
/// by clock.
///
/// The bytes are copied as they are. The series names its clock itself
/// (`BatteryHistory.uid`), so nothing about it has to be decoded beyond that
/// name, and nothing about its readings can be lost in a re-encode. A series
/// that does not name one is not a series this app can trust, and is left.
struct BatteryHistoryMigration {
    static let markerKey = "migration.batteryHistory"
    static let legacyKey = "batteryHistory"

    let defaults: UserDefaults

    func run() {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        if let data = defaults.data(forKey: Self.legacyKey),
            let owner = try? JSONDecoder().decode(Owner.self, from: data) {
            defaults.set(
                data, forKey: UserDefaultsBatteryHistoryStore.key(forHardwareIdentity: owner.uid)
            )
        }
        defaults.set(true, forKey: Self.markerKey)
    }

    private struct Owner: Decodable {
        let uid: String
    }
}

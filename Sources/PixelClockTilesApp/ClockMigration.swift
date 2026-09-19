import Foundation
import PixelClockKit

/// Turns the one address an installation had into its one clock record.
///
/// Runs once: its marker is written after the record, so a run cut short
/// before the marker runs again from the old keys at the next launch rather
/// than trusting half of what it wrote. The old keys are only read, never
/// written or removed.
@MainActor
struct ClockMigration {
    static let markerKey = "migration.clocks"

    let defaults: UserDefaults
    /// What an installation that never saved an address was talking to.
    let fallbackHost: String

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        let clock = ClockRecord(
            name: "Clock",
            model: .awtrix3,
            address: defaults.string(forKey: AppModel.deviceHostKey) ?? fallbackHost,
            hardwareIdentity: defaults.string(forKey: AppModel.deviceUIDKey)
        )
        try ClockStore(defaults: defaults).replaceAll([clock])
        defaults.set(true, forKey: Self.markerKey)
    }
}

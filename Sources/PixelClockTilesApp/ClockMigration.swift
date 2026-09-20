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
        // A fresh install has no address to turn into a clock: it writes
        // nothing and marks nothing, and the launch boots to "No clocks yet" —
        // a clock created at a guessed address for nobody was the bug the
        // fallback was (D6). The step stays reachable for the install that
        // does carry an old address, whose marker is still unwritten.
        guard let address = defaults.string(forKey: AppModel.deviceHostKey) else { return }
        let clock = ClockRecord(
            name: "Clock",
            model: .awtrix3,
            address: address,
            hardwareIdentity: defaults.string(forKey: AppModel.deviceUIDKey)
        )
        try ClockStore(defaults: defaults).replaceAll([clock])
        defaults.set(true, forKey: Self.markerKey)
    }
}

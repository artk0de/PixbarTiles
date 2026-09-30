import Foundation
import PixbarKit

/// What a clock's card says for a few seconds after its refresh.
///
/// Nothing when the clock answers: the status beside it already says
/// Connected. When it does not, the likeliest reason a person can act on —
/// a battery last seen running down is a clock to plug in, anything else is
/// a clock to switch on or bring back in range.
enum ClockRecheckNote {
    static let notAnswering = "The clock isn't answering — is it switched on?"
    static let batteryMayHaveRunOut = "The clock's battery may have run out"

    /// Under this share, a silent clock that was draining is read as flat.
    static let lowBatteryPercent = 20

    static func text(reachable: Bool, lastBattery: BatteryReading?) -> String? {
        guard !reachable else { return nil }
        if let battery = lastBattery, battery.direction == .discharging,
            battery.percent < lowBatteryPercent {
            return batteryMayHaveRunOut
        }
        return notAnswering
    }
}

/// The yellow lamp of a clock being checked blinks — switched on and off in
/// whole halves of a beat, the way a pixel lamp does, never faded.
enum CheckingBlink {
    /// Seconds the lamp stays lit, and then dark.
    static let halfBeat: TimeInterval = 0.4

    static func isLit(elapsed: TimeInterval) -> Bool {
        Int((elapsed / halfBeat).rounded(.down)) % 2 == 0
    }
}

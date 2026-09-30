import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// What a card says after its refresh: nothing when the clock answers — the
/// status says it — and why it may not have, when it does not.
@Suite struct ClockRecheckNoteTests {
    private func reading(_ percent: Int, _ direction: BatteryDirection) -> BatteryReading {
        BatteryReading(percent: percent, shownPercent: percent, direction: direction, timeRemaining: nil)
    }

    @Test func aClockThatAnswersNeedsNoNote() {
        #expect(ClockRecheckNote.text(reachable: true, lastBattery: reading(10, .discharging)) == nil)
    }

    @Test func aSilentClockLastSeenRunningLowMayHaveRunOut() {
        #expect(
            ClockRecheckNote.text(reachable: false, lastBattery: reading(19, .discharging))
                == ClockRecheckNote.batteryMayHaveRunOut
        )
    }

    @Test func twentyPercentOrChargingIsNotABatteryStory() {
        for battery in [reading(20, .discharging), reading(5, .charging), reading(5, .unknown)] {
            #expect(ClockRecheckNote.text(reachable: false, lastBattery: battery) == ClockRecheckNote.notAnswering)
        }
        #expect(ClockRecheckNote.text(reachable: false, lastBattery: nil) == ClockRecheckNote.notAnswering)
    }
}

import Foundation
import Testing
@testable import PixbarKit

private func sample(_ percent: Int, _ charging: Bool, _ minutes: Double) -> UlanziBatterySample {
    UlanziBatterySample(
        percent: percent, charging: charging, millivolts: 3800,
        at: Date(timeIntervalSince1970: minutes * 60)
    )
}

@Test func directionComesStraightOffTheFlag() {
    var t = UlanziBatteryTrajectory()
    t.accept(sample(90, true, 0))
    #expect(t.reading?.direction == .charging)
    #expect(t.reading?.percent == 90)
    #expect(t.reading?.shownPercent == 90)
    #expect(t.reading?.timeRemaining == nil)          // no countdown while charging
}

@Test func nothingWatchedYetIsNoReading() {
    let t = UlanziBatteryTrajectory()
    #expect(t.reading == nil)
}

@Test func dischargeUnderMinimumSpanHasNoEstimate() {
    var t = UlanziBatteryTrajectory()
    t.accept(sample(80, false, 0))
    t.accept(sample(79, false, 5))                     // 5 min < the minimum span
    #expect(t.reading?.direction == .discharging)
    #expect(t.reading?.timeRemaining == nil)
}

@Test func steadyDischargeEstimatesTimeToEmpty() throws {
    var t = UlanziBatteryTrajectory()
    // 2% lost per hour, watched for two hours: from 76% that is 38 h to empty.
    t.accept(sample(80, false, 0))
    t.accept(sample(78, false, 60))
    t.accept(sample(76, false, 120))
    let reading = try #require(t.reading)
    let remaining = try #require(reading.timeRemaining)
    #expect(abs(remaining - 38 * 3600) < 30 * 60)      // within half an hour
    #expect(reading.direction == .discharging)
    #expect(reading.shownPercent == 76)
}

@Test func plugInClearsTheEstimateAndTheDischargeRun() {
    var t = UlanziBatteryTrajectory()
    t.accept(sample(80, false, 0))
    t.accept(sample(78, false, 60))
    t.accept(sample(78, true, 120))                    // plugged in
    #expect(t.reading?.direction == .charging)
    #expect(t.reading?.timeRemaining == nil)
}

@Test func aRunThatIsNotFallingGetsNoEstimate() {
    var t = UlanziBatteryTrajectory()
    // Flat on the float: watched long enough, but going nowhere.
    t.accept(sample(80, false, 0))
    t.accept(sample(80, false, 60))
    t.accept(sample(80, false, 120))
    #expect(t.reading?.direction == .discharging)
    #expect(t.reading?.timeRemaining == nil)
}

@Test func theRunAfterAChargeIgnoresWhatCameBefore() throws {
    var t = UlanziBatteryTrajectory()
    // A charge, then a discharge: the fit must not be dragged through the rise.
    t.accept(sample(40, true, 0))
    t.accept(sample(90, true, 60))
    t.accept(sample(88, false, 120))
    t.accept(sample(86, false, 180))
    let remaining = try #require(t.reading?.timeRemaining)
    // 2% per hour from 86% is 43 h — not the gentle nothing a fit through the
    // charge would give.
    #expect(abs(remaining - 43 * 3600) < 60 * 60)
}

private func charged(_ percent: Int, _ charging: Bool, mv: Int) -> UlanziBatterySample {
    UlanziBatterySample(
        percent: percent, charging: charging, millivolts: mv,
        at: Date(timeIntervalSince1970: 0)
    )
}

// The firmware's percent scale stops at 90. Measured on appVer 1.1.1: with the
// charger's LED green — the charge terminated — the monitor read 90 at 4174 mV,
// and it still read 90 hours later. A panel that only repeats the firmware can
// therefore never say a charge finished, which is the one thing a glance is for.
@Test func aFinishedChargeIsShownAsFull() {
    var t = UlanziBatteryTrajectory()
    t.accept(charged(90, true, mv: 4174))

    #expect(t.reading?.shownPercent == 100)
    // The firmware's own figure is kept intact — the correction is about what
    // the panel draws, not about what the clock said.
    #expect(t.reading?.percent == 90)
}

// The top of the firmware's scale is not one number. Measured on the live clock
// 2026-09-24, charger LED green after a day on the charger, read by a FULL walk
// (fresh pid, base and monitor pointer — no cache involved): charging=1,
// percent=89, 4167 mV. A cell resting on the charger after termination sags a
// few millivolts and the firmware's voltage-tracking percent follows it down
// from 90 to 89; a rule keyed on exactly 90 left the panel on "89% · Charging".
@Test func aFinishedChargeTheFirmwareHasLetSagTo89IsStillFull() {
    var t = UlanziBatteryTrajectory()
    t.accept(charged(89, true, mv: 4167))

    #expect(t.reading?.shownPercent == 100)
    #expect(t.reading?.percent == 89)
}

@Test func aChargeStillClimbingIsNotFull() {
    var t = UlanziBatteryTrajectory()
    t.accept(charged(90, true, mv: 3900))
    #expect(t.reading?.shownPercent == 90)
}

@Test func offTheChargerNothingIsRoundedUp() {
    var t = UlanziBatteryTrajectory()
    t.accept(charged(90, false, mv: 4174))
    #expect(t.reading?.shownPercent == 90)
}

@Test func aPlateauVoltageBelowTheCeilingIsNotFull() {
    var t = UlanziBatteryTrajectory()
    t.accept(charged(80, true, mv: 4174))
    #expect(t.reading?.shownPercent == 80)
}

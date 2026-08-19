import Foundation
import Testing
@testable import AwtrixKit

// The firmware reports no charging or mains field — `/api/stats` carries `bat`,
// `bat_raw`, `uptime`, `uid` and a dozen things about the display, and nothing
// about power. So every claim below is about a trend inferred from readings,
// and the fixtures are written to keep the two apart: where a test is about the
// RAW reading, the integer percentage is held still, so an implementation that
// read `bat` instead would have nothing to go on.

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

/// How long is left, to the nearest second.
///
/// Rounded rather than compared exactly. The rate is a least-squares sum over a
/// window of samples now rather than one subtraction between two of them, so
/// the answer arrives with the last bits of a `Double` on it — and a second is
/// four orders below anything the panel renders.
private func secondsLeft(_ subject: BatteryTrajectory) -> TimeInterval? {
    subject.reading?.timeRemaining.map { $0.rounded() }
}

private func stats(
    percent: Int, raw: Int?, uptime: Int? = 9_000, uid: String = "awtrix_a07f9c"
) -> DeviceStats {
    DeviceStats(
        version: "0.98", uid: uid, bat: percent, batRaw: raw, uptime: uptime,
        ram: 139_112, ipAddress: "192.168.1.72"
    )
}

// MARK: - Which way it is going

@Test func aFallingRawReadingReadsAsDischarging() {
    var subject = BatteryTrajectory()

    // The percentage is held still while the raw figure moves, so an
    // implementation reading `bat` has nothing to go on and this test says
    // which of the two fields the trend is computed from. How many raw steps
    // the firmware actually spends on a percent is not assumed anywhere — the
    // clock on this desk answers 665 at 100% and 648 at 91%, which is about
    // two, and the map is undocumented and free to differ.
    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 50, raw: 396), at: at(20))

    #expect(subject.reading?.direction == .discharging)
}

@Test func aRisingRawReadingReadsAsCharging() {
    var subject = BatteryTrajectory()

    subject.record(stats(percent: 50, raw: 396), at: at(0))
    subject.record(stats(percent: 50, raw: 400), at: at(20))

    #expect(subject.reading?.direction == .charging)
}

@Test func aFlatReadingHoldsThePreviousVerdictRatherThanFlapping() {
    // Both directions, because "flat" answered with a constant would pass one
    // of these and fail the other. A raw reading that does not move between two
    // polls is the ordinary case at rest, not an edge.
    var falling = BatteryTrajectory()
    falling.record(stats(percent: 50, raw: 400), at: at(0))
    falling.record(stats(percent: 50, raw: 396), at: at(20))
    falling.record(stats(percent: 50, raw: 396), at: at(40))

    #expect(falling.reading?.direction == .discharging)

    var rising = BatteryTrajectory()
    rising.record(stats(percent: 50, raw: 396), at: at(0))
    rising.record(stats(percent: 50, raw: 400), at: at(20))
    rising.record(stats(percent: 50, raw: 400), at: at(40))

    #expect(rising.reading?.direction == .charging)
}

@Test func aTrajectoryWithNothingRecordedHasNothingToSay() {
    #expect(BatteryTrajectory().reading == nil)
}

@Test func oneReadingIsNotATrend() {
    var subject = BatteryTrajectory()

    subject.record(stats(percent: 50, raw: 400), at: at(0))

    // The percentage is known and the direction is not. Showing a verdict here
    // would be a guess dressed as a reading.
    #expect(subject.reading?.percent == 50)
    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.timeRemaining == nil)
}

@Test func theReadingCarriesTheLatestPercentage() {
    var subject = BatteryTrajectory()

    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 48, raw: 380), at: at(20))

    #expect(subject.reading?.percent == 48)
}

@Test func aFirmwareWithoutARawReadingStillReportsThePercentage() {
    var subject = BatteryTrajectory()

    // `bat_raw` is optional so that a firmware which omits it does not read as
    // an unreachable clock. What it costs is the verdict, not the percentage.
    subject.record(stats(percent: 42, raw: nil, uptime: nil), at: at(0))
    subject.record(stats(percent: 41, raw: nil, uptime: nil), at: at(20))

    #expect(subject.reading?.percent == 41)
    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.timeRemaining == nil)
}

// MARK: - What discards the history

@Test func aRebootDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400, uptime: 9_000), at: at(0))
    subject.record(stats(percent: 50, raw: 396, uptime: 9_020), at: at(20))
    #expect(subject.reading?.direction == .discharging)

    // The raw reading keeps falling, so a trajectory that kept its history
    // would still say discharging — which is the point. A reboot is exactly
    // when somebody unplugged the clock and plugged it in again, and the
    // readings either side of it describe two different situations.
    subject.record(stats(percent: 50, raw: 392, uptime: 5), at: at(40))

    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.percent == 50)
}

@Test func anUptimeThatKeepsClimbingKeepsTheHistory() {
    // The other half of the reboot rule: the ordinary case must survive it.
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400, uptime: 9_000), at: at(0))
    subject.record(stats(percent: 50, raw: 396, uptime: 9_020), at: at(20))
    subject.record(stats(percent: 50, raw: 392, uptime: 9_040), at: at(40))

    #expect(subject.reading?.direction == .discharging)
}

@Test func aDifferentDeviceDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400, uid: "awtrix_a07f9c"), at: at(0))
    subject.record(stats(percent: 50, raw: 396, uid: "awtrix_a07f9c"), at: at(20))
    #expect(subject.reading?.direction == .discharging)

    // A different clock entirely — the address in the defaults was repointed,
    // or two of them answer on the same address in turn. Its readings say
    // nothing about the first one's rate.
    subject.record(stats(percent: 50, raw: 392, uid: "awtrix_ffffff"), at: at(40))

    #expect(subject.reading?.direction == .unknown)
}

@Test func aGapLongerThanTheWindowDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 50, raw: 396), at: at(20))
    #expect(subject.reading?.direction == .discharging)

    // The Mac was asleep, or the app was quit. The two readings either side of
    // the gap say nothing about a rate: everything between them is unobserved.
    subject.record(stats(percent: 50, raw: 392), at: at(20 + BatteryTrajectory.window + 1))

    #expect(subject.reading?.direction == .unknown)
}

@Test func aGapInsideTheWindowKeepsTheHistory() {
    // The half that tells the rule apart from discarding everything always: a
    // poll that ran late is not a poll that did not run.
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 50, raw: 396), at: at(20))

    subject.record(stats(percent: 50, raw: 392), at: at(20 + BatteryTrajectory.window - 1))

    #expect(subject.reading?.direction == .discharging)
}

// MARK: - How long is left

@Test func noEtaIsShownBeforeTheMinimumSpanIsObserved() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 48, raw: 380), at: at(20))

    // Twenty seconds and a direction is not a rate. "4 h 20 m" here would mean
    // "I have two samples", and a number nobody can trust is worse than the
    // panel saying it is still working it out.
    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.timeRemaining == nil)

    subject.record(stats(percent: 46, raw: 360), at: at(BatteryTrajectory.minimumSpan))

    #expect(subject.reading?.timeRemaining != nil)
}

@Test func noEtaIsShownUntilTheRawReadingHasMovedEnough() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))

    // Fifteen minutes is span enough, and the raw reading has moved by two —
    // inside what the reading jitters by on its own.
    subject.record(stats(percent: 49, raw: 398), at: at(900))
    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.timeRemaining == nil)

    // Four is the line, and a longer window now clears it.
    subject.record(stats(percent: 49, raw: 396), at: at(1_200))
    #expect(subject.reading?.timeRemaining != nil)
}

@Test func theEtaIsPercentOverTheObservedRate() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 48, raw: 380), at: at(900))

    // Nine hundred seconds bought two percent, and forty-eight are left:
    // 48 × 900 ÷ 2 is six hours. Two samples are the case where the fit and the
    // endpoints agree by construction — a line through two points passes
    // through both — which is what makes this readable as arithmetic.
    #expect(secondsLeft(subject) == 21_600)
}

@Test func noEtaIsShownWhileTheBatteryIsCharging() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))
    subject.record(stats(percent: 48, raw: 380), at: at(900))
    #expect(subject.reading?.timeRemaining != nil)

    // The window still ends lower than it started, so every other gate is still
    // clear and only the direction has changed. Time to empty for something
    // filling up is not a number that means anything.
    subject.record(stats(percent: 48, raw: 385), at: at(920))

    #expect(subject.reading?.direction == .charging)
    #expect(subject.reading?.timeRemaining == nil)
}

@Test func noEtaIsShownWhileThePercentageHasNotMovedAtAll() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 50, raw: 400), at: at(0))

    // The raw reading has moved plenty and the span is long, but `bat` is where
    // it was: one distinct percentage is no slope to scale the raw figure by,
    // and the percentage arithmetic it falls back to divides by zero — which
    // reads as "forever".
    subject.record(stats(percent: 50, raw: 390), at: at(900))

    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.timeRemaining == nil)
}

@Test func theRateIsMeasuredOverTheWindowRatherThanTheWholeHistory() {
    var subject = BatteryTrajectory()
    // Two hours of readings whose first half hour fell two and a half times as
    // fast as the rest — the clock was showing something bright, or the room
    // was cold. Only the last ninety minutes are inside the window, and inside
    // it the readings are on one line.
    subject.record(stats(percent: 70, raw: 700), at: at(0))
    subject.record(stats(percent: 60, raw: 600), at: at(1_800))
    subject.record(stats(percent: 56, raw: 560), at: at(3_600))
    subject.record(stats(percent: 52, raw: 520), at: at(5_400))
    subject.record(stats(percent: 48, raw: 480), at: at(7_200))

    // 48% at the 120 raw steps the window watched go across its 5400 seconds,
    // ten of them to the percent: six hours. Reading right back to the start
    // would answer 15709 instead — an estimate carrying a rate that stopped
    // applying half an hour before the window opened.
    #expect(secondsLeft(subject) == 21_600)
}

// MARK: - What the rate is read off

@Test func theWindowAndTheSpanAreTheOnesTheCadenceCanFill() {
    // Ninety minutes is ninety samples at the shipped minute, and no rate is
    // read off less than fifteen of them. Both are used symbolically everywhere
    // else in this file, so lowering either one leaves the rest of it green.
    #expect(BatteryTrajectory.window == 90 * 60)
    #expect(BatteryTrajectory.minimumSpan == 15 * 60)
}

@Test func aCleanLinearDischargeAnswersTheRateThatGeneratedIt() {
    var subject = BatteryTrajectory()
    // Ninety minutes of readings from one rule: a percent every two minutes,
    // eight raw steps to the percent. Every sample is on the line, so the fit
    // has exactly one right answer, and 55% left at a percent per two minutes
    // is 110 minutes of it.
    for step in 0...45 {
        subject.record(
            stats(percent: 100 - step, raw: 800 - 8 * step), at: at(Double(step) * 120)
        )
    }

    #expect(secondsLeft(subject) == 6_600)
}

@Test func aWindowWhereOnePercentMovedIsReadOffTheRawFigureNotThatOnePercent() {
    var subject = BatteryTrajectory()
    // Ninety minutes in which `bat` steps exactly once, 50 to 49, while the raw
    // figure walks 407 down to 392 — eight steps to the percent, so what
    // actually went is one and seven eighths of a percent. The endpoints of an
    // integer percentage cannot see that: they answer "one percent in ninety
    // minutes", and 49 of them at that rate is 73 and a half hours. The fit
    // answers 39.2, which is what the readings say.
    for step in 0...15 {
        let raw = 407 - step
        subject.record(
            stats(percent: raw >= 400 ? 50 : 49, raw: raw), at: at(Double(step) * 360)
        )
    }

    #expect(secondsLeft(subject) == 141_120)
    // Named rather than left implicit, so a fixture cannot drift into agreeing
    // with the arithmetic this replaced.
    #expect(secondsLeft(subject) != 264_600)
}

@Test func aFitTheReadingsCannotSupportFallsBackToThePercentageRatherThanToNothing() {
    var subject = BatteryTrajectory()
    // A full clock. The firmware caps `bat` at 100, so the raw figure falls for
    // most of the window with the percentage pinned and the step to 99 lands at
    // the end of it. Fitted, that reads as 32 raw steps to the percent — the
    // map's slope is nothing of the sort, and an estimate divided by it would
    // be wrong by that factor.
    for step in 0...15 {
        let raw = 700 - 4 * step
        subject.record(
            stats(percent: raw >= 648 ? 100 : 99, raw: raw), at: at(Double(step) * 360)
        )
    }

    // Refused, and the coarse percentage arithmetic answers in its place: one
    // percent in ninety minutes, 99 of them left. A number nobody should plan
    // around, and still better than the panel saying it is working it out
    // ninety minutes into a discharge.
    #expect(secondsLeft(subject) == 534_600)
}

@Test func aRebootPartWayThroughTheWindowTakesTheEstimateWithTheHistory() {
    var subject = BatteryTrajectory()
    for step in 0...45 {
        subject.record(
            stats(percent: 100 - step, raw: 800 - 8 * step, uptime: 9_000 + step * 120),
            at: at(Double(step) * 120)
        )
    }
    #expect(secondsLeft(subject) == 6_600)

    // Somebody unplugged the clock and plugged it in again. Ninety minutes of
    // fitted history is exactly the thing that would carry the situation before
    // the reboot across into the one after it.
    subject.record(stats(percent: 55, raw: 440, uptime: 5), at: at(5_520))

    #expect(subject.reading?.timeRemaining == nil)
    #expect(subject.reading?.percent == 55)
}

// MARK: - Warnings

@Test func crossingTwentyPercentWarnsOnce() {
    var subject = BatteryTrajectory()

    // 25 to 19 falls through exactly one line. A fixture that jumped to 9 would
    // cross two at once and only ever exercise the first.
    #expect(subject.record(stats(percent: 25, raw: 250), at: at(0)) == nil)
    #expect(
        subject.record(stats(percent: 19, raw: 190), at: at(20))
            == BatteryWarning(threshold: 20, percent: 19)
    )
    #expect(subject.record(stats(percent: 18, raw: 180), at: at(40)) == nil)
}

@Test func eachThresholdFiresOnItsOwnCrossing() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 25, raw: 250), at: at(0))

    // One line per step: 19 clears 10, 9 clears 5, 4 clears 1. Nothing here
    // crosses two at a time, so all four are really exercised.
    let fired = [19, 9, 4, 1].enumerated().compactMap { step, percent in
        subject.record(
            stats(percent: percent, raw: percent * 10), at: at(Double(step + 1) * 20)
        )?.threshold
    }

    #expect(fired == [20, 10, 5, 1])
}

@Test func sittingBelowAThresholdDoesNotWarnAgain() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 25, raw: 250), at: at(0))
    #expect(subject.record(stats(percent: 19, raw: 190), at: at(20))?.threshold == 20)

    // A device resting at 19% is polled every twenty seconds. Warning on the
    // level rather than on the crossing is 180 dialogs an hour.
    let repeats = (1...5).compactMap { step in
        subject.record(stats(percent: 19, raw: 190), at: at(20 + Double(step) * 20))
    }

    #expect(repeats.isEmpty)
}

@Test func recoveringAboveAThresholdRearmsIt() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 25, raw: 250), at: at(0))
    #expect(subject.record(stats(percent: 19, raw: 190), at: at(20))?.threshold == 20)

    // Charged past the line and back down again: a second discharge is a second
    // piece of news, and a threshold that never re-arms is a warning the user
    // sees exactly once in the life of the app.
    #expect(subject.record(stats(percent: 23, raw: 230), at: at(40)) == nil)
    #expect(
        subject.record(stats(percent: 19, raw: 190), at: at(60))
            == BatteryWarning(threshold: 20, percent: 19)
    )
}

@Test func climbingBackOverAThresholdWithoutTheMarginDoesNotRearmIt() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 25, raw: 250), at: at(0))
    #expect(subject.record(stats(percent: 19, raw: 190), at: at(20))?.threshold == 20)

    // 21% is over the line and inside the margin. Without one, a battery
    // hovering either side of 20 warns on every wobble — which is the same
    // dialog storm the edge trigger exists to stop, arriving more slowly.
    #expect(subject.record(stats(percent: 21, raw: 210), at: at(40)) == nil)
    #expect(subject.record(stats(percent: 19, raw: 190), at: at(60)) == nil)
}

@Test func chargingThroughAThresholdDoesNotWarn() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 3, raw: 30), at: at(0))

    // Filling up through 4%. A clock that has just been plugged in and is on
    // its way back has no news for anybody.
    #expect(subject.record(stats(percent: 4, raw: 40), at: at(20)) == nil)
    #expect(subject.record(stats(percent: 6, raw: 60), at: at(40)) == nil)

    // And the half that says the crossing was skipped rather than spent: on the
    // way back down, the same 4% warns.
    #expect(
        subject.record(stats(percent: 4, raw: 40), at: at(60))
            == BatteryWarning(threshold: 5, percent: 4)
    )
}

@Test func aReadingWhoseDirectionIsNotEstablishedDoesNotWarn() {
    var subject = BatteryTrajectory()

    // The first poll of a launch, against a clock already down at 4%. One
    // reading cannot say whether it is draining or filling, and a dialog on a
    // charging clock is the thing the direction gate is for.
    #expect(subject.record(stats(percent: 4, raw: 40), at: at(0)) == nil)
}

@Test func oneCrossingFiresForTheLowestThresholdItPassed() {
    var subject = BatteryTrajectory()
    subject.record(stats(percent: 25, raw: 250), at: at(0))

    // A poll can find the battery a long way below where it left it — the Mac
    // slept, or the clock was off the network for an hour. Three dialogs at
    // once is not three times the information.
    #expect(
        subject.record(stats(percent: 4, raw: 40), at: at(20))
            == BatteryWarning(threshold: 5, percent: 4)
    )

    // The ones it fell past went with it, rather than queueing up to fire on
    // the next poll.
    #expect(subject.record(stats(percent: 4, raw: 40), at: at(40)) == nil)
}

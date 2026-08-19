import Foundation
import Testing
@testable import AwtrixKit

// The firmware reports no charging or mains field — `/api/stats` carries `bat`,
// `bat_raw`, `uptime`, `uid` and a dozen things about the display, and nothing
// about power. So every claim below is about a trend inferred from readings.
//
// Two windows in this file are REAL, taken off the clock on this desk twenty
// seconds apart: one climbing on mains, one settled on the charger's float.
// Neither may ever read as a discharge, and the settled one is the harder of
// the two, because the line fitted through it points downward.

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

private func at(_ seconds: TimeInterval) -> Date { origin.addingTimeInterval(seconds) }

/// How long is left, to the nearest second.
///
/// Rounded rather than compared exactly. The rate is a least-squares sum over a
/// window of samples rather than one subtraction between two of them, so the
/// answer arrives with the last bits of a `Double` on it — and a second is four
/// orders below anything the panel renders.
private func secondsLeft(_ subject: BatteryTrajectory) -> TimeInterval? {
    subject.reading?.timeRemaining.map { $0.rounded() }
}

/// What this firmware reports as `bat` for a given raw reading, and back again.
///
/// `map(raw, 475, 665, 0, 100)` — the firmware's own map, which reproduces both
/// live observations exactly: 648 reads 91 and 665 reads 100. Fixtures that
/// move the raw figure keep `bat` on this scale rather than inventing one, so
/// that a percentage and the reading it is derived from cannot describe two
/// different clocks.
private func percent(at raw: Int) -> Int { (raw - 475) * 100 / 190 }

private func raw(at percent: Int) -> Int { 475 + (190 * percent) / 100 }

private func stats(
    percent: Int, raw: Int?, uptime: Int? = 9_000, uid: String = "awtrix_a07f9c"
) -> DeviceStats {
    DeviceStats(
        version: "0.98", uid: uid, bat: percent, batRaw: raw, uptime: uptime,
        ram: 139_112, ipAddress: "192.168.1.72"
    )
}

/// Feeds a straight raw ramp at the shipped cadence — one reading a minute —
/// and answers the minute the last of them landed on.
///
/// A ramp rather than the pair of readings these fixtures used to be: the
/// direction is a line fitted across a window now, and two samples twenty
/// seconds apart are not a window. `percent` is held still through it unless a
/// test says otherwise, so an implementation that read `bat` rather than
/// `bat_raw` would have nothing to go on.
@discardableResult
private func ramp(
    _ subject: inout BatteryTrajectory, from raw: Int, by step: Int, minutes: Int,
    percent: Int, startingAt start: Int = 0
) -> Int {
    for minute in 0...minutes {
        subject.record(
            stats(percent: percent, raw: raw + step * minute),
            at: at(Double(start + minute) * 60)
        )
    }
    return start + minutes
}

/// Puts `subject` on an established discharge, and answers the minute it got
/// there.
///
/// Six readings with the raw figure falling one step a minute, which is the
/// rate a full discharge runs at — 190 steps over about three hours. The
/// warnings are gated on the direction, and the direction is now a fit, so the
/// crossings below need a real discharge underneath them rather than one
/// downward step.
@discardableResult
private func settleOnDischarge(
    _ subject: inout BatteryTrajectory, at percent: Int, raw: Int
) -> Int {
    ramp(&subject, from: raw, by: -1, minutes: 5, percent: percent)
}

// MARK: - Which way it is going

@Test func aFallingRawTrendReadsAsDischarging() {
    var subject = BatteryTrajectory()

    // The percentage is held still while the raw figure walks down, so this
    // says which of the two fields the trend is computed from.
    ramp(&subject, from: 570, by: -1, minutes: 6, percent: 50)

    #expect(subject.reading?.direction == .discharging)
}

@Test func aRisingRawTrendReadsAsCharging() {
    var subject = BatteryTrajectory()

    ramp(&subject, from: 560, by: 2, minutes: 6, percent: 50)

    #expect(subject.reading?.direction == .charging)
}

@Test func aFlatRawTrendReadsAsCharging() {
    var subject = BatteryTrajectory()

    // Steady is charging, and the physics is what says so: a charger holds a
    // float voltage, so a full battery on mains reads flat while a discharge
    // falls. Answering "unknown" to a flat reading would blank the glyph for as
    // long as the clock sat on the charger, which is most of its life.
    ramp(&subject, from: 667, by: 0, minutes: 6, percent: 100)

    #expect(subject.reading?.direction == .charging)
}

@Test func nothingIsCalledUntilThereIsEnoughWindowToCallItSteady() {
    var subject = BatteryTrajectory()

    // One minute of readings. Flat here means "nothing has been watched yet" as
    // readily as it means "on the float", and a verdict the readings cannot
    // support is worse than none.
    subject.record(stats(percent: 100, raw: 667), at: at(0))
    subject.record(stats(percent: 100, raw: 667), at: at(60))

    #expect(subject.reading?.direction == .unknown)

    // Two minutes is where it becomes a window rather than a wobble.
    subject.record(stats(percent: 100, raw: 667), at: at(120))

    #expect(subject.reading?.direction == .charging)
}

@Test func aTrajectoryWithNothingRecordedHasNothingToSay() {
    #expect(BatteryTrajectory().reading == nil)
}

@Test func oneReadingIsNotATrend() {
    var subject = BatteryTrajectory()

    subject.record(stats(percent: 50, raw: 570), at: at(0))

    // The percentage is known and the direction is not. Showing a verdict here
    // would be a guess dressed as a reading.
    #expect(subject.reading?.percent == 50)
    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.timeRemaining == nil)
}

@Test func theReadingCarriesTheLatestPercentage() {
    var subject = BatteryTrajectory()

    subject.record(stats(percent: 50, raw: 570), at: at(0))
    subject.record(stats(percent: 48, raw: 566), at: at(60))

    #expect(subject.reading?.percent == 48)
}

@Test func aFirmwareWithoutARawReadingStillReportsThePercentage() {
    var subject = BatteryTrajectory()

    // `bat_raw` is optional so that a firmware which omits it does not read as
    // an unreachable clock. What it costs is the verdict, not the percentage.
    subject.record(stats(percent: 42, raw: nil, uptime: nil), at: at(0))
    subject.record(stats(percent: 41, raw: nil, uptime: nil), at: at(60))

    #expect(subject.reading?.percent == 41)
    #expect(subject.reading?.shownPercent == 41)
    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.timeRemaining == nil)
}

// MARK: - The two measured windows

/// The clock on this desk, charging after a small discharge, sampled every
/// twenty seconds with the power state unchanged throughout. Real readings, and
/// the ones the reported defect was drawn from: consecutive samples change
/// direction four times across these four minutes, and the panel followed every
/// one of them.
private let climbingOnMains = [665, 665, 664, 664, 666, 667, 668, 669, 669, 669, 668, 668]

/// The percentage the same poll reported. It flickers on the same wander the
/// raw figure carries, with nothing changing behind it.
private let climbingPercent = [100, 100, 99, 99, 100, 100, 100, 100, 100, 100, 100, 100]

/// The same clock once the charge settled onto the float, same cadence, `bat`
/// pinned at 100 throughout. Real readings, and the harder of the two windows:
/// it wanders inside three steps and the line fitted through it points DOWN, so
/// a rule that reads any fall as a discharge fails here rather than on the
/// climbing one.
private let settledOnFloat = [
    668, 669, 668, 668, 668, 668, 667, 667, 667, 667,
    667, 667, 667, 667, 667, 668, 668, 668, 667, 667,
]

@Test func theMeasuredChargingWindowIsNeverReadAsADischarge() {
    var subject = BatteryTrajectory()
    var verdicts: [BatteryDirection] = []

    for (step, reading) in climbingOnMains.enumerated() {
        subject.record(
            stats(percent: climbingPercent[step], raw: reading), at: at(Double(step) * 20)
        )
        verdicts.append(subject.reading?.direction ?? .unknown)
    }

    // Every reading along the way, not just the last one. This is a charging
    // clock, and the defect was that the panel called it a discharge.
    #expect(!verdicts.contains(.discharging))
    #expect(subject.reading?.direction == .charging)
    // The percentage flickered 100 to 99 and back. What the panel prints did
    // not follow it.
    #expect(subject.reading?.shownPercent == 100)
}

@Test func theMeasuredFloatWindowIsNeverReadAsADischargeEither() {
    var subject = BatteryTrajectory()
    var verdicts: [BatteryDirection] = []

    for (step, reading) in settledOnFloat.enumerated() {
        subject.record(stats(percent: 100, raw: reading), at: at(Double(step) * 20))
        verdicts.append(subject.reading?.direction ?? .unknown)
    }

    // The fit through this one falls, by under two raw steps across the whole
    // of it, against the ten a real discharge spends over the same minutes. The
    // deadband is the thing that tells those two apart, and this is the window
    // it is sized against.
    #expect(!verdicts.contains(.discharging))
    #expect(subject.reading?.direction == .charging)
}

@Test func aRealDischargeIsStillCaughtWithinFiveReadings() {
    var subject = BatteryTrajectory()
    var caught: Int?

    // One raw step a minute at the shipped cadence: a full discharge is about
    // 190 steps over three hours, so this is the rate the app has to catch.
    for minute in 0...20 {
        subject.record(stats(percent: 50, raw: 570 - minute), at: at(Double(minute) * 60))
        if caught == nil, subject.reading?.direction == .discharging { caught = minute + 1 }
    }

    // Bounded rather than pinned, so the deadband can be re-tuned — but not so
    // far that a draining clock goes unnoticed for a quarter of an hour. This
    // is the assertion that stops a widening from silently blinding the app.
    #expect((caught ?? .max) <= 5)
}

@Test func aClockPluggedInPartWayThroughTheWindowFlipsWithoutWaitingItOut() {
    var subject = BatteryTrajectory()

    // Half an hour of discharge, a third of the ninety-minute window the RATE
    // is fitted over. The direction is read off a much shorter slice of it, or
    // a clock plugged in now would keep reading as discharging for the rest of
    // the hour and the glyph would be wrong for all of it.
    let unplugged = ramp(&subject, from: 600, by: -1, minutes: 30, percent: 65)
    #expect(subject.reading?.direction == .discharging)

    var flipped: Int?
    for minute in 1...12 {
        subject.record(
            stats(percent: 65, raw: 570 + 2 * minute),
            at: at(Double(unplugged + minute) * 60)
        )
        if flipped == nil, subject.reading?.direction == .charging { flipped = minute }
    }

    #expect((flipped ?? .max) <= 5)
    #expect(subject.reading?.timeRemaining == nil)
}

// MARK: - What the panel is given to print

@Test func aChargingFlickerDoesNotPullTheShownFigureDown() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 645, by: 2, minutes: 10, percent: 100)
    #expect(subject.reading?.direction == .charging)

    // 100 to 99 with nothing changing is what the measured window does. While
    // charging, the shown figure never goes down.
    subject.record(stats(percent: 99, raw: 664), at: at(Double(last + 1) * 60))

    #expect(subject.reading?.shownPercent == 100)
    // And the real figure is untouched underneath it: the warnings, the colour
    // and the glyph all read that one.
    #expect(subject.reading?.percent == 99)
}

@Test func aDischargingFlickerDoesNotPushTheShownFigureUp() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 570, by: -1, minutes: 10, percent: 50)
    #expect(subject.reading?.direction == .discharging)

    subject.record(stats(percent: 49, raw: 559), at: at(Double(last + 1) * 60))
    #expect(subject.reading?.shownPercent == 49)

    // Back up a percent on the same wander. A discharge does not go up, and a
    // figure that climbed and fell back would read as a clock nobody can
    // explain.
    subject.record(stats(percent: 50, raw: 560), at: at(Double(last + 2) * 60))

    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.shownPercent == 49)
    #expect(subject.reading?.percent == 50)
}

@Test func comingOffChargeReleasesTheRatchetRatherThanPinningTheFigure() {
    var subject = BatteryTrajectory()
    let unplugged = ramp(&subject, from: 645, by: 2, minutes: 10, percent: 100)
    #expect(subject.reading?.shownPercent == 100)

    // Off the charger at the top and draining a raw step a minute. Without a
    // release on the change of direction the panel would still read 100 an hour
    // into this — pinned by a charge the clock is no longer on, which is worse
    // than the flicker the ratchet exists to stop.
    for minute in 1...12 {
        let reading = 665 - minute
        subject.record(
            stats(percent: percent(at: reading), raw: reading),
            at: at(Double(unplugged + minute) * 60)
        )
    }

    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.shownPercent == subject.reading?.percent)
    #expect(subject.reading?.shownPercent != 100)
}

@Test func goingBackOnChargeReleasesItInTheOtherDirectionToo() {
    var subject = BatteryTrajectory()
    let plugged = ramp(&subject, from: 540, by: -1, minutes: 10, percent: 34)
    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.shownPercent == 34)

    // Both directions, because a ratchet released only on the way down would
    // hold a clock at the figure it bottomed out at for the whole of the charge
    // that follows.
    for minute in 1...12 {
        let reading = 530 + 2 * minute
        subject.record(
            stats(percent: percent(at: reading), raw: reading),
            at: at(Double(plugged + minute) * 60)
        )
    }

    #expect(subject.reading?.direction == .charging)
    #expect(subject.reading?.shownPercent == subject.reading?.percent)
    #expect((subject.reading?.shownPercent ?? 0) > 34)
}

// MARK: - What discards the history

@Test func aRebootDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    for minute in 0...5 {
        subject.record(
            stats(percent: 50, raw: 570 - minute, uptime: 9_000 + minute * 60),
            at: at(Double(minute) * 60)
        )
    }
    #expect(subject.reading?.direction == .discharging)

    // The raw reading keeps falling, so a trajectory that kept its history
    // would still say discharging — which is the point. A reboot is exactly
    // when somebody unplugged the clock and plugged it in again, and the
    // readings either side of it describe two different situations.
    subject.record(stats(percent: 50, raw: 564, uptime: 5), at: at(6 * 60))

    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.percent == 50)
}

@Test func anUptimeThatKeepsClimbingKeepsTheHistory() {
    // The other half of the reboot rule: the ordinary case must survive it.
    var subject = BatteryTrajectory()
    for minute in 0...6 {
        subject.record(
            stats(percent: 50, raw: 570 - minute, uptime: 9_000 + minute * 60),
            at: at(Double(minute) * 60)
        )
    }

    #expect(subject.reading?.direction == .discharging)
}

@Test func aDifferentDeviceDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    for minute in 0...5 {
        subject.record(
            stats(percent: 50, raw: 570 - minute, uid: "awtrix_a07f9c"),
            at: at(Double(minute) * 60)
        )
    }
    #expect(subject.reading?.direction == .discharging)

    // A different clock entirely — the address in the defaults was repointed,
    // or two of them answer on the same address in turn. Its readings say
    // nothing about the first one's rate.
    subject.record(stats(percent: 50, raw: 564, uid: "awtrix_ffffff"), at: at(6 * 60))

    #expect(subject.reading?.direction == .unknown)
}

@Test func aGapLongerThanTheWindowDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 570, by: -1, minutes: 5, percent: 50)
    #expect(subject.reading?.direction == .discharging)

    // The Mac was asleep, or the app was quit. The two readings either side of
    // the gap say nothing about a rate: everything between them is unobserved.
    subject.record(
        stats(percent: 50, raw: 564),
        at: at(Double(last) * 60 + BatteryTrajectory.window + 1)
    )

    #expect(subject.reading?.direction == .unknown)
}

@Test func aGapInsideTheWindowKeepsTheHistory() {
    // The half that tells the rule apart from discarding everything always: a
    // poll that ran late is not a poll that did not run. The verdict is held
    // across it rather than recomputed — one reading on its own is no trend,
    // and blanking the glyph because a poll was late is a worse answer than
    // carrying the last real one.
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 570, by: -1, minutes: 5, percent: 50)

    subject.record(
        stats(percent: 50, raw: 564),
        at: at(Double(last) * 60 + BatteryTrajectory.window - 1)
    )

    #expect(subject.reading?.direction == .discharging)
}

// MARK: - How long is left

@Test func theEstimateIsTheRawFigureAboveEmptyOverTheFittedRate() {
    var subject = BatteryTrajectory()

    // Half an hour of the raw figure falling one step a minute — the rate a
    // full discharge runs at. It ends at 570, which the firmware's map puts 95
    // steps above the 475 it calls empty, so 95 minutes are left.
    //
    // `bat` never moves through any of it. The percent-delta this replaced
    // answered nothing at all here, because an integer percentage that stood
    // still has no rate to give.
    ramp(&subject, from: 600, by: -1, minutes: 30, percent: 50)

    #expect(secondsLeft(subject) == 5_700)
}

@Test func theEstimateNeverTouchesThePercentage() {
    // The same raw ramp twice: once with `bat` tracking it, once with `bat`
    // flickering the way the measured window does. The percentage is derived
    // from the raw figure by the firmware and clamped at the top, so it is
    // unfit to reason from — and these two must therefore answer identically.
    var tracking = BatteryTrajectory()
    var flickering = BatteryTrajectory()

    for minute in 0...30 {
        let reading = 600 - minute
        tracking.record(
            stats(percent: percent(at: reading), raw: reading), at: at(Double(minute) * 60)
        )
        flickering.record(
            stats(percent: minute.isMultiple(of: 2) ? 100 : 99, raw: reading),
            at: at(Double(minute) * 60)
        )
    }

    #expect(secondsLeft(tracking) == 5_700)
    #expect(secondsLeft(flickering) == secondsLeft(tracking))
}

@Test func noEstimateIsShownBeforeTheMinimumSpanIsObserved() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 600, by: -1, minutes: 10, percent: 50)

    // Ten minutes and a direction is not a rate. "1 h 35 m" here would mean "I
    // have ten samples", and a number nobody can trust is worse than the panel
    // saying it is still working it out.
    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.timeRemaining == nil)

    ramp(&subject, from: 589, by: -1, minutes: 5, percent: 50, startingAt: last + 1)

    #expect(subject.reading?.timeRemaining != nil)
}

@Test func noEstimateIsShownWhileTheBatteryIsCharging() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 600, by: -1, minutes: 30, percent: 50)
    #expect(subject.reading?.timeRemaining != nil)

    // Back on the charger. The window still ends a long way below where it
    // started, so every other gate is clear and only the direction has changed.
    // Time to empty for something filling up is not a number that means
    // anything.
    ramp(&subject, from: 572, by: 2, minutes: 6, percent: 50, startingAt: last + 1)

    #expect(subject.reading?.direction == .charging)
    #expect(subject.reading?.timeRemaining == nil)
}

@Test func theRateIsMeasuredOverTheWindowRatherThanTheWholeHistory() {
    var subject = BatteryTrajectory()

    // Ten minutes falling five times as fast as the rest — the clock was
    // showing something bright, or the room was cold — then an hour and a half
    // at one step a minute. Only the last ninety minutes are inside the window,
    // and inside it every reading is on one line.
    for minute in 0...100 {
        let reading = minute <= 10 ? 665 - 5 * minute : 615 - (minute - 10)
        subject.record(
            stats(percent: percent(at: reading), raw: reading), at: at(Double(minute) * 60)
        )
    }

    // 525 is fifty steps above empty at a step a minute: fifty minutes. Reading
    // right back to the start would answer a steeper rate, and an estimate
    // carrying one that stopped applying an hour and a half ago.
    #expect(secondsLeft(subject) == 3_000)
}

@Test func aRebootPartWayThroughTheWindowTakesTheEstimateWithTheHistory() {
    var subject = BatteryTrajectory()
    for minute in 0...30 {
        subject.record(
            stats(percent: 50, raw: 600 - minute, uptime: 9_000 + minute * 60),
            at: at(Double(minute) * 60)
        )
    }
    #expect(secondsLeft(subject) == 5_700)

    // Somebody unplugged the clock and plugged it in again. Half an hour of
    // fitted history is exactly the thing that would carry the situation before
    // the reboot across into the one after it.
    subject.record(stats(percent: 50, raw: 569, uptime: 5), at: at(31 * 60))

    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.timeRemaining == nil)
    #expect(subject.reading?.percent == 50)
}

// MARK: - What the numbers are

@Test func theWindowsAreTheOnesTheCadenceAndTheReadingsCanFill() {
    // Ninety minutes is ninety samples at the shipped minute, and no rate is
    // read off fewer than fifteen of them. All four are used symbolically
    // everywhere else in this file, so lowering one leaves the rest of it green
    // and this is the test that notices.
    #expect(BatteryTrajectory.window == 90 * 60)
    #expect(BatteryTrajectory.minimumSpan == 15 * 60)
    // The direction is read off a tenth of the rate's window, which is what
    // lets a clock plugged in now be seen as plugged in now.
    #expect(BatteryTrajectory.trendWindow == 10 * 60)
    #expect(BatteryTrajectory.minimumTrendSpan == 2 * 60)
    // Three raw steps: the settled window above wanders inside three and its
    // fitted drift is under two, while a real discharge spends about ten across
    // a trend window.
    #expect(BatteryTrajectory.steadyBand == 3)
    // The firmware's own map, `map(raw, 475, 665, 0, 100)`.
    #expect(BatteryTrajectory.rawAtEmpty == 475)
}

// MARK: - Warnings

@Test func crossingTwentyPercentWarnsOnce() {
    var subject = BatteryTrajectory()
    let settled = settleOnDischarge(&subject, at: 25, raw: raw(at: 25))
    #expect(subject.reading?.direction == .discharging)

    // 25 to 19 falls through exactly one line. A fixture that jumped to 9 would
    // cross two at once and only ever exercise the first.
    #expect(
        subject.record(stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + 1) * 60))
            == BatteryWarning(threshold: 20, percent: 19)
    )
    #expect(
        subject.record(stats(percent: 18, raw: raw(at: 18)), at: at(Double(settled + 2) * 60))
            == nil
    )
}

@Test func eachThresholdFiresOnItsOwnCrossing() {
    var subject = BatteryTrajectory()
    let settled = settleOnDischarge(&subject, at: 25, raw: raw(at: 25))

    // One line per step: 19 clears 10, 9 clears 5, 4 clears 1. Nothing here
    // crosses two at a time, so all four are really exercised.
    let fired = [19, 9, 4, 1].enumerated().compactMap { step, percent in
        subject.record(
            stats(percent: percent, raw: raw(at: percent)),
            at: at(Double(settled + step + 1) * 60)
        )?.threshold
    }

    #expect(fired == [20, 10, 5, 1])
}

@Test func sittingBelowAThresholdDoesNotWarnAgain() {
    var subject = BatteryTrajectory()
    let settled = settleOnDischarge(&subject, at: 25, raw: raw(at: 25))
    #expect(
        subject.record(stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + 1) * 60))?
            .threshold == 20
    )

    // A device resting at 19% is polled every minute. Warning on the level
    // rather than on the crossing is sixty dialogs an hour.
    let repeats = (2...6).compactMap { step in
        subject.record(
            stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + step) * 60)
        )
    }

    #expect(repeats.isEmpty)
}

@Test func recoveringAboveAThresholdRearmsIt() {
    var subject = BatteryTrajectory()
    let settled = settleOnDischarge(&subject, at: 25, raw: raw(at: 25))
    #expect(
        subject.record(stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + 1) * 60))?
            .threshold == 20
    )

    // Charged past the line and back down again: a second discharge is a second
    // piece of news, and a threshold that never re-arms is a warning the user
    // sees exactly once in the life of the app.
    #expect(
        subject.record(stats(percent: 23, raw: raw(at: 23)), at: at(Double(settled + 2) * 60))
            == nil
    )
    #expect(
        subject.record(stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + 3) * 60))
            == BatteryWarning(threshold: 20, percent: 19)
    )
}

@Test func climbingBackOverAThresholdWithoutTheMarginDoesNotRearmIt() {
    var subject = BatteryTrajectory()
    let settled = settleOnDischarge(&subject, at: 25, raw: raw(at: 25))
    #expect(
        subject.record(stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + 1) * 60))?
            .threshold == 20
    )

    // 21% is over the line and inside the margin. Without one, a battery
    // hovering either side of 20 warns on every wobble — which is the same
    // dialog storm the edge trigger exists to stop, arriving more slowly.
    #expect(
        subject.record(stats(percent: 21, raw: raw(at: 21)), at: at(Double(settled + 2) * 60))
            == nil
    )
    #expect(
        subject.record(stats(percent: 19, raw: raw(at: 19)), at: at(Double(settled + 3) * 60))
            == nil
    )
}

/// A clock filling up through the bottom three thresholds: the raw figure
/// climbing two steps a minute for eleven of them, with `bat` stepping 3, 4, 6
/// on the way. Answers whatever those eleven readings warned about.
///
/// Split out because both fixtures below need the same eleven minutes
/// underneath them.
private func fillUpThroughFourPercent(_ subject: inout BatteryTrajectory) -> [BatteryWarning] {
    var fired: [BatteryWarning] = []
    for minute in 0...10 {
        let percent: Int
        if minute < 3 {
            percent = 3
        } else if minute < 6 {
            percent = 4
        } else {
            percent = 6
        }
        let warning = subject.record(
            stats(percent: percent, raw: 480 + 2 * minute), at: at(Double(minute) * 60)
        )
        if let warning { fired.append(warning) }
    }
    return fired
}

@Test func chargingThroughAThresholdDoesNotWarn() {
    var subject = BatteryTrajectory()

    // A clock that has just been plugged in and is on its way back has no news
    // for anybody, however low the number it passes through is.
    let fired = fillUpThroughFourPercent(&subject)

    #expect(subject.reading?.direction == .charging)
    #expect(fired.isEmpty)
}

@Test func aThresholdSkippedWhileChargingStillFiresOnTheWayBackDown() {
    var subject = BatteryTrajectory()
    #expect(fillUpThroughFourPercent(&subject).isEmpty)
    #expect(subject.reading?.direction == .charging)

    // Off the charger and back down through the same 4%. The crossing was
    // SKIPPED on the way up rather than spent, so it is still there to fire —
    // and it fires once the fit has caught up with the change of direction,
    // which is what the readings can actually support.
    var fired: [Int] = []
    for minute in 11...25 {
        let percent = minute >= 15 ? 4 : 6
        let warning = subject.record(
            stats(percent: percent, raw: 500 - 2 * (minute - 10)),
            at: at(Double(minute) * 60)
        )
        if let warning { fired.append(warning.threshold) }
    }

    #expect(fired == [5])
}

@Test func aReadingWhoseDirectionIsNotEstablishedDoesNotWarn() {
    var subject = BatteryTrajectory()

    // The first poll of a launch, against a clock already down at 4%. One
    // reading cannot say whether it is draining or filling, and a dialog on a
    // charging clock is the thing the direction gate is for.
    #expect(subject.record(stats(percent: 4, raw: raw(at: 4)), at: at(0)) == nil)
}

@Test func oneCrossingFiresForTheLowestThresholdItPassed() {
    var subject = BatteryTrajectory()
    let settled = settleOnDischarge(&subject, at: 25, raw: raw(at: 25))

    // A poll can find the battery a long way below where it left it — the Mac
    // slept, or the clock was off the network for an hour. Three dialogs at
    // once is not three times the information.
    #expect(
        subject.record(stats(percent: 4, raw: raw(at: 4)), at: at(Double(settled + 1) * 60))
            == BatteryWarning(threshold: 5, percent: 4)
    )

    // The ones it fell past went with it, rather than queueing up to fire on
    // the next poll.
    #expect(
        subject.record(stats(percent: 4, raw: raw(at: 4)), at: at(Double(settled + 2) * 60))
            == nil
    )
}

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

/// Puts `subject` on an established discharge ending at `raw`, and answers the
/// minute it got there.
///
/// Half an hour of it, spending four raw steps on the way — the rate this clock
/// was actually measured discharging at. The six readings this used to be
/// establish nothing now: a fall is a twentieth of the size of a charge, so it
/// cannot be told from the reading's own wander until it has run long enough to
/// spend more than that wander.
///
/// The percentage is held still throughout, as everywhere else in this file, so
/// that an implementation reading `bat` rather than `bat_raw` has nothing to go
/// on. The four steps land at minutes 8, 15, 23 and 30, which is what a real
/// discharge looks like at this cadence: flat for a while, then a step.
@discardableResult
private func settleOnDischarge(
    _ subject: inout BatteryTrajectory, at percent: Int, raw: Int
) -> Int {
    for minute in 0...30 {
        subject.record(
            stats(percent: percent, raw: raw + 4 - (4 * minute) / 30),
            at: at(Double(minute) * 60)
        )
    }
    return 30
}

// MARK: - Which way it is going

@Test func aFallingRawTrendReadsAsDischarging() {
    var subject = BatteryTrajectory()

    // Half an hour of the raw figure walking down at the measured rate, with
    // the percentage held still throughout, so this says which of the two
    // fields the trend is computed from. The six minutes it used to be say
    // nothing: over ten minutes this clock's discharge is smaller than its own
    // wander, which is the whole of the defect.
    settleOnDischarge(&subject, at: 50, raw: 566)

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

/// The same clock again, unplugged, sampled every two minutes for half an hour
/// while it ran on battery. Real readings, and the ones the reported defect was
/// drawn from: the panel drew the plug for the whole of this.
///
/// Four raw steps across 30.1 minutes — 1.33 steps per ten minutes, which puts
/// the whole 190-step range at about a day. And it is NOT monotonic: 644 holds
/// for nine consecutive samples, drops to 641 and rebounds to 643. Over any ten
/// minutes of it the wander is BIGGER than the fall, which is the whole reason
/// the fall cannot be read off a ten-minute window.
private let dischargingOnBattery = [
    646, 646, 645, 644, 644, 644, 644, 644,
    644, 644, 644, 641, 643, 643, 643, 642,
]

@Test func theMeasuredDischargeIsReadAsADischarge() {
    var subject = BatteryTrajectory()
    var caught: Int?

    for (step, reading) in dischargingOnBattery.enumerated() {
        subject.record(
            stats(percent: percent(at: reading), raw: reading), at: at(Double(step) * 120)
        )
        if caught == nil, subject.reading?.direction == .discharging { caught = step }
    }

    // The defect, exactly: this is a discharge, and the app called it a charge
    // for every one of these thirty minutes.
    #expect(subject.reading?.direction == .discharging)
    // Inside the half hour that was measured. Not sooner, and the float window
    // above is why: at this rate a fall worth believing takes twenty minutes to
    // accumulate, and anything quicker than that is the wander.
    #expect((caught ?? .max) <= 15)
}

@Test func theEstimateFromTheMeasuredDischargeIsAboutADay() {
    var subject = BatteryTrajectory()
    // The measured half hour, and then the same half hour again four raw steps
    // lower — the discharge continuing at the rate it was measured at.
    //
    // The extension is not padding. Thirty minutes near the top of the curve is
    // a fall of about one and a half points of charge, which is smaller than
    // three raw steps of load-sag is worth there, so the estimate is withheld —
    // deliberately. It was the old model's willingness to answer inside that
    // window that produced the numbers being complained about.
    let measured = dischargingOnBattery + dischargingOnBattery.map { $0 - 4 }
    for (step, reading) in measured.enumerated() {
        subject.record(
            stats(percent: percent(at: reading), raw: reading), at: at(Double(step) * 120)
        )
    }

    // An order, not a precision. Half a day to two days is what a 32x8 matrix
    // at brightness 3 should be expected to do, and it is what 167 raw steps
    // above empty at the measured rate works out to — the point of the
    // assertion is that the answer is a day and not the three hours the old
    // premise implied.
    let left = subject.reading?.timeRemaining ?? 0
    #expect(left > 12 * 3_600)
    #expect(left < 48 * 3_600)
}

@Test func aFastDischargeWaitsOnTheSpanRatherThanOnTheBand() {
    var subject = BatteryTrajectory()
    var caught: Int?

    // One raw step a minute — ten times what this clock was measured doing, and
    // what the old premise thought every discharge looked like. A clock running
    // something bright could do it.
    for minute in 0...30 {
        subject.record(stats(percent: 50, raw: 570 - minute), at: at(Double(minute) * 60))
        if caught == nil, subject.reading?.direction == .discharging { caught = minute }
    }

    // It clears the band inside four minutes and is still not believed until
    // twenty have been watched. That is the span floor doing its job: the
    // measured series' own three-step wobble fits to exactly the band, so the
    // band alone has no margin over it at a short span.
    // Bounded rather than pinned, so the constants can be re-tuned — but not so
    // far that a draining clock goes unnoticed for half an hour.
    #expect((caught ?? .max) <= 20)
    #expect(caught == Int(BatteryTrajectory.minimumFallSpan) / 60)
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
    let last = settleOnDischarge(&subject, at: 50, raw: 566)
    #expect(subject.reading?.direction == .discharging)

    subject.record(stats(percent: 49, raw: 565), at: at(Double(last + 1) * 60))
    #expect(subject.reading?.shownPercent == 49)

    // Back up a percent on the same wander. A discharge does not go up, and a
    // figure that climbed and fell back would read as a clock nobody can
    // explain.
    subject.record(stats(percent: 50, raw: 566), at: at(Double(last + 2) * 60))

    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.shownPercent == 49)
    #expect(subject.reading?.percent == 50)
}

@Test func comingOffChargeReleasesTheRatchetRatherThanPinningTheFigure() {
    var subject = BatteryTrajectory()
    let unplugged = ramp(&subject, from: 645, by: 2, minutes: 10, percent: 100)
    #expect(subject.reading?.shownPercent == 100)

    // Off the charger at the top and draining a raw step a minute. It takes
    // most of half an hour to be believed, and that is the charge's own doing:
    // the rise it just made is still inside the window the fall is fitted over.
    // Without a release on the change of direction the panel would still read
    // 100 an hour into this — pinned by a charge the clock is no longer on,
    // which is worse than the flicker the ratchet exists to stop.
    for minute in 1...25 {
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
    let plugged = settleOnDischarge(&subject, at: 34, raw: 540)
    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.shownPercent == 34)

    // Both directions, because a ratchet released only on the way down would
    // hold a clock at the figure it bottomed out at for the whole of the charge
    // that follows.
    for minute in 1...12 {
        let reading = 540 + 2 * minute
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
    // Twenty-five minutes of it, because a fall is not believed off less than
    // twenty. Faster than this clock discharges, which only makes the point
    // sharper: even a discharge ten times the measured one needs the span.
    for minute in 0...25 {
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
    subject.record(stats(percent: 50, raw: 544, uptime: 5), at: at(26 * 60))

    #expect(subject.reading?.direction == .unknown)
    #expect(subject.reading?.percent == 50)
}

@Test func anUptimeThatKeepsClimbingKeepsTheHistory() {
    // The other half of the reboot rule: the ordinary case must survive it.
    var subject = BatteryTrajectory()
    for minute in 0...25 {
        subject.record(
            stats(percent: 50, raw: 570 - minute, uptime: 9_000 + minute * 60),
            at: at(Double(minute) * 60)
        )
    }

    #expect(subject.reading?.direction == .discharging)
}

@Test func aDifferentDeviceDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    for minute in 0...25 {
        subject.record(
            stats(percent: 50, raw: 570 - minute, uid: "awtrix_a07f9c"),
            at: at(Double(minute) * 60)
        )
    }
    #expect(subject.reading?.direction == .discharging)

    // A different clock entirely — the address in the defaults was repointed,
    // or two of them answer on the same address in turn. Its readings say
    // nothing about the first one's rate.
    subject.record(stats(percent: 50, raw: 544, uid: "awtrix_ffffff"), at: at(26 * 60))

    #expect(subject.reading?.direction == .unknown)
}

@Test func aGapLongerThanTheWindowDiscardsTheHistory() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 570, by: -1, minutes: 25, percent: 50)
    #expect(subject.reading?.direction == .discharging)

    // The Mac was asleep, or the app was quit. The two readings either side of
    // the gap say nothing about a rate: everything between them is unobserved.
    subject.record(
        stats(percent: 50, raw: 544),
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
    let last = ramp(&subject, from: 570, by: -1, minutes: 25, percent: 50)

    subject.record(
        stats(percent: 50, raw: 544),
        at: at(Double(last) * 60 + BatteryTrajectory.window - 1)
    )

    #expect(subject.reading?.direction == .discharging)
}

// MARK: - What survives a relaunch

// The battery does not change while the app is closed; only the app's memory of
// it does. Held in memory alone, every launch started from no samples and could
// not name a direction until it had re-earned one — two minutes for a charge
// and twenty for a discharge — and what the user saw was a bare percentage 81
// seconds after opening the app.
//
// Sampling faster does not shorten that: charging moves the raw figure about
// 2.5 steps a minute against a wander of ±2, so half a minute of it is smaller
// than the noise it has to clear. The series is written down instead, and the
// window is not shortened but absent.

/// The series the launch before this one would have left behind: half an hour
/// of the discharge this clock was actually measured at, ending at raw 570.
private func lastLaunchWatchedADischarge() throws -> BatteryHistory {
    var previous = BatteryTrajectory()
    _ = settleOnDischarge(&previous, at: 50, raw: 570)
    // The precondition rather than the claim. Every test below is about what a
    // relaunch does with THIS, so a fixture that had not established a
    // discharge would have them all pass for the wrong reason.
    #expect(previous.reading?.direction == .discharging)
    return try #require(previous.history)
}

@Test func aStoredSeriesNamesItsDirectionOnTheFirstReadingAfterALaunch() throws {
    let stored = try lastLaunchWatchedADischarge()

    var subject = BatteryTrajectory(resuming: stored)
    // Nothing is claimed off the restored series on its own. A percentage read
    // before the relaunch is a reading nobody took now, and the panel must not
    // draw one until this launch has heard from the clock itself.
    #expect(subject.reading == nil)

    subject.record(stats(percent: 50, raw: 570), at: at(31 * 60))

    // One reading, and it is a discharge — where the same first reading with
    // nothing behind it says `.unknown` for the next twenty minutes.
    #expect(subject.reading?.direction == .discharging)
}

@Test func aStoredSeriesFromAnotherClockIsDiscarded() throws {
    let stored = try lastLaunchWatchedADischarge()
    var subject = BatteryTrajectory(resuming: stored)

    // The address in the settings was repointed while the app was closed, or
    // two clocks answer on it in turn. The raw figure is still falling, so a
    // restore that skipped the rule would answer discharging off another
    // clock's readings.
    subject.record(stats(percent: 50, raw: 570, uid: "awtrix_ffffff"), at: at(31 * 60))

    #expect(subject.reading?.direction == .unknown)
}

@Test func aStoredSeriesFromBeforeARebootIsDiscarded() throws {
    let stored = try lastLaunchWatchedADischarge()
    var subject = BatteryTrajectory(resuming: stored)

    // Uptime going backwards is a reboot, and a reboot is exactly when somebody
    // unplugged the clock and plugged it in again — which is the one event that
    // makes the readings either side of it describe two different situations.
    subject.record(stats(percent: 50, raw: 570, uptime: 5), at: at(31 * 60))

    #expect(subject.reading?.direction == .unknown)
}

@Test func aStoredSeriesOlderThanTheWindowIsDiscarded() throws {
    let stored = try lastLaunchWatchedADischarge()
    var subject = BatteryTrajectory(resuming: stored)

    // The app was closed for longer than the window, so everything between the
    // last stored reading and this one is unobserved. Persisting the samples
    // does not make the gap smaller.
    subject.record(
        stats(percent: 50, raw: 570), at: at(30 * 60 + BatteryTrajectory.window + 1)
    )

    #expect(subject.reading?.direction == .unknown)
}

@Test func aStoredSeriesInsideTheWindowSurvivesTheGapToTheRelaunch() throws {
    // The half that tells the rule apart from discarding on every launch, and
    // the ordinary case: quitting and reopening the app is a gap of minutes.
    let stored = try lastLaunchWatchedADischarge()
    var subject = BatteryTrajectory(resuming: stored)

    subject.record(
        stats(percent: 50, raw: 570), at: at(30 * 60 + BatteryTrajectory.window - 1)
    )

    #expect(subject.reading?.direction == .discharging)
}

@Test func aTrajectoryWithNothingRecordedHasNoSeriesToStore() {
    // Nothing to hand the next launch, and it must not be spelled as an empty
    // one: a stored series naming no clock would be compared against the first
    // reading and read as a different device.
    #expect(BatteryTrajectory().history == nil)
}

@Test func theStoredSeriesCarriesTheReadingsAndTheClockTheyCameOff() throws {
    var subject = BatteryTrajectory()
    _ = settleOnDischarge(&subject, at: 50, raw: 570)

    let stored = try #require(subject.history)

    #expect(stored.uid == "awtrix_a07f9c")
    // The uptime of the LAST report, which is what a reboot is measured
    // against. One reading a minute for half an hour, plus the one at zero.
    #expect(stored.uptime == 9_000)
    #expect(stored.samples.count == 31)
    #expect(stored.samples.first?.at == at(0))
    #expect(stored.samples.last?.at == at(30 * 60))
}

// MARK: - The store the series survives in

@Test func aStoredSeriesSurvivesTheUserDefaultsStore() throws {
    let suite = "battery-history-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let stored = BatteryHistory(
        uid: "awtrix_a07f9c", uptime: 9_000,
        samples: [BatterySample(raw: 574, at: at(0)), BatterySample(raw: 570, at: at(1_800))]
    )

    UserDefaultsBatteryHistoryStore(defaults: defaults).save(stored)

    // Read back through a second store on the same defaults, because the
    // question is what a LAUNCH finds rather than what one instance remembers.
    #expect(UserDefaultsBatteryHistoryStore(defaults: defaults).storedHistory() == stored)
}

@Test func aFirstLaunchFindsNothingInTheStoreRatherThanAnEmptySeries() throws {
    let suite = "battery-history-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(UserDefaultsBatteryHistoryStore(defaults: defaults).storedHistory() == nil)
}

@Test func aKeyHoldingSomethingElseReadsAsAFirstLaunch() throws {
    let suite = "battery-history-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // A shape from an older version of this app, or another key's value written
    // over it. Whatever it is, it is not a series — and a launch that starts
    // cold is exactly what the discard rules produce anyway.
    defaults.set(Data("not a series".utf8), forKey: "batteryHistory")

    #expect(UserDefaultsBatteryHistoryStore(defaults: defaults).storedHistory() == nil)
}

// MARK: - How long is left

@Test func theEstimateIsTheChargeLeftOverTheRateItIsBeingSpent() {
    var subject = BatteryTrajectory()

    // Half an hour of the raw figure falling one step a minute, ending at 570.
    //
    // This is the test that carried the defect, and the two answers are worth
    // reading side by side. The old expression divided the raw distance above
    // the firmware's empty — 95 steps — by the fitted raw rate, and answered 95
    // MINUTES. But 570 is 3.67 V, which is the bottom knee: eleven percent of
    // the charge, not fifty. The cell had about seven minutes in it, and the
    // panel was promising an hour and a half.
    //
    // `bat` never moves through any of it. The percent-delta this replaced
    // answered nothing at all here, because an integer percentage that stood
    // still has no rate to give.
    ramp(&subject, from: 600, by: -1, minutes: 30, percent: 50)

    let left = secondsLeft(subject) ?? 0
    // A band rather than a figure: the curve is the canonical shape, not a fit
    // to this cell, and a test asserting a number to the second would be
    // claiming a precision the model does not have.
    #expect(left > 5 * 60, "answered \(left / 60) minutes")
    #expect(left < 12 * 60, "answered \(left / 60) minutes")
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

    // The equality is the assertion; the figure beside it only says the two
    // agreed on something rather than on nothing.
    #expect(secondsLeft(tracking) != nil)
    #expect(secondsLeft(flickering) == secondsLeft(tracking))
}

@Test func noEstimateIsShownBeforeThereIsEnoughWatchedToFitOne() {
    var subject = BatteryTrajectory()
    let last = ramp(&subject, from: 600, by: -1, minutes: 10, percent: 50)

    // Ten minutes is not a rate, and since the fall was measured it is not a
    // direction either. "1 h 35 m" here would mean "I have ten samples", and a
    // number nobody can trust is worse than the panel saying it is still
    // working it out.
    #expect(subject.reading?.direction != .discharging)
    #expect(subject.reading?.timeRemaining == nil)

    ramp(&subject, from: 589, by: -1, minutes: 15, percent: 50, startingAt: last + 1)

    #expect(subject.reading?.direction == .discharging)
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

@Test func theRateIgnoresTheStretchBeforeTheFallWasEstablished() {
    var subject = BatteryTrajectory()

    // Ten minutes falling five times as fast as the rest — the clock was
    // showing something bright, or it had just come off the charger — then an
    // hour and a half at one step a minute.
    //
    // What keeps the steep opening out of the fit is no longer the retention
    // window, which now holds a whole day: it is that the rate reads only what
    // came after the battery was last seen going up, and a reading pinned at
    // the top of the scale IS "going up". The steep stretch is spent getting
    // clear of that, and the fit starts where the discharge was established.
    for minute in 0...100 {
        let reading = minute <= 10 ? 665 - 5 * minute : 615 - (minute - 10)
        subject.record(
            stats(percent: percent(at: reading), raw: reading), at: at(Double(minute) * 60)
        )
    }

    // 525 is 3.39 V — three percent of the charge, not the twenty-six the
    // firmware's linear map calls it. Minutes, not the fifty this used to
    // answer by dividing volts by volts.
    let left = secondsLeft(subject) ?? 0
    #expect(left > 60, "answered \(left / 60) minutes")
    #expect(left < 15 * 60, "answered \(left / 60) minutes")
}

@Test func aRebootPartWayThroughTheWindowTakesTheEstimateWithTheHistory() {
    var subject = BatteryTrajectory()
    for minute in 0...30 {
        subject.record(
            stats(percent: 50, raw: 600 - minute, uptime: 9_000 + minute * 60),
            at: at(Double(minute) * 60)
        )
    }
    #expect(secondsLeft(subject) != nil)

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
    // A rise is read off a tenth of the rate's window, which is what lets a
    // clock plugged in now be seen as plugged in now: it climbs twenty-five raw
    // steps in those ten minutes.
    #expect(BatteryTrajectory.riseWindow == 10 * 60)
    #expect(BatteryTrajectory.minimumTrendSpan == 2 * 60)
    // A fall is read off six times that, because it is a twentieth of the size:
    // 1.33 raw steps per ten minutes measured, so an hour is the shortest window
    // that carries the fall clear of the band.
    #expect(BatteryTrajectory.fallWindow == 60 * 60)
    // And no fall is believed off less than twenty minutes of it, whatever the
    // fit says: the measured series drops three steps in two minutes and takes
    // them back.
    #expect(BatteryTrajectory.minimumFallSpan == 20 * 60)
    // Three raw steps, either way. The float window above wanders inside three
    // and its worst fitted drift is 1.73; the slowest measured discharge loses
    // 4.2 steps an hour, so four would already be inside the noise of the thing
    // it has to catch.
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

@Test func aReadingAboveTheLastLineDoesNotWarnWithoutADirection() {
    var subject = BatteryTrajectory()

    // The first poll of a launch, against a clock already down at 4%. One
    // reading cannot say whether it is draining or filling, and a dialog on a
    // charging clock is the thing the direction gate is for.
    //
    // Named for the 4 rather than for the missing verdict, because the missing
    // verdict stopped being the whole rule: three points lower the same reading
    // fires. This is the tighter of the two guards on that — the last section
    // of this file makes the same claim at 15%, and 4% is the one a point of
    // slack in the comparison would break.
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

// MARK: - The last line, before there is a direction to gate on

// A verdict is not free any more. A fall is read over an hour, because on this
// clock it is smaller than the reading's own wander over anything shorter, so
// from a standing start — a launch, a reboot, a gap — the direction takes 22
// minutes on the measured series and up to 55 straight off a charge. The last
// line is ten to seventeen minutes of runtime. The four tests below are the
// whole of the exception that buys, and the middle two are what stop it
// spreading.

@Test func theLastLineFiresWithoutWaitingForADirection() throws {
    var subject = BatteryTrajectory()
    let lastLine = try #require(BatteryTrajectory.thresholds.min())

    // One poll, no trend, and a clock already on the last line. Holding this
    // back until the fit agrees is holding it back past the point the clock
    // has any runtime left to be warned about.
    #expect(
        subject.record(stats(percent: lastLine, raw: raw(at: lastLine)), at: at(0))
            == BatteryWarning(threshold: lastLine, percent: lastLine)
    )
    #expect(subject.reading?.direction == .unknown)
}

@Test func theTwentyPercentLineIsNotUrgentEnoughToFireUnverified() {
    var subject = BatteryTrajectory()

    // 15% is through the 20 line and hours clear of the last one, so there is
    // time to be sure and a reason to want to be: a clock that turns out to be
    // filling up would have warned for nothing. This is the test that fails if
    // the exception is ever read as "warn whenever we do not know".
    #expect(subject.record(stats(percent: 15, raw: raw(at: 15)), at: at(0)) == nil)
    #expect(subject.reading?.direction == .unknown)
}

@Test func theLastLineDoesNotFireWhileTheClockIsKnownToBeCharging() throws {
    var subject = BatteryTrajectory()
    let lastLine = try #require(BatteryTrajectory.thresholds.min())

    // Eleven minutes of the raw figure climbing two steps a minute, which is a
    // charge by the third of them. `bat` reads a point lower for the last five
    // — the same wander that has this clock reporting 100, 99, 100 with nothing
    // changing behind it — and lands on the last line while the trend is
    // unambiguous. Unproven is not the same as contradicted: the exception is
    // for the first case only, and this is the second.
    let fired = (0...10).compactMap { minute in
        subject.record(
            stats(percent: minute < 6 ? lastLine + 1 : lastLine, raw: 478 + 2 * minute),
            at: at(Double(minute) * 60)
        )
    }

    #expect(subject.reading?.direction == .charging)
    #expect(fired.isEmpty)
}

@Test func firingWithoutADirectionStillSpendsTheThreshold() throws {
    var subject = BatteryTrajectory()
    let lastLine = try #require(BatteryTrajectory.thresholds.min())
    #expect(
        subject.record(stats(percent: lastLine, raw: raw(at: lastLine)), at: at(0)) != nil
    )

    // A minute later, still on the last line and still with nothing to go on.
    // The threshold was spent by firing early, exactly as it would have been by
    // firing late; a warning that skipped the direction gate must not also skip
    // the edge trigger, or a clock sitting at 1% is a dialog a minute for as
    // long as it lasts.
    #expect(
        subject.record(stats(percent: lastLine, raw: raw(at: lastLine)), at: at(60)) == nil
    )
    #expect(subject.reading?.direction == .unknown)

    // And it stays spent once the fit does have something to say.
    let later = (2...5).compactMap { minute in
        subject.record(
            stats(percent: lastLine, raw: raw(at: lastLine)), at: at(Double(minute) * 60)
        )
    }

    #expect(later.isEmpty)
}

// MARK: - The zero a clock answers with before it has read the converter

// Sampled off the clock on this desk through a power-on:
//
//     uptime=25  bat=0   bat_raw=0
//     uptime=42  bat=98  bat_raw=662
//     uptime=50  bat=97  bat_raw=661
//
// A battery does not cross 98 points in seventeen seconds. The zero is the
// firmware answering before it has read the converter, and the poll is a minute
// against a window of twenty to forty seconds, so every reboot of the clock is
// a coin toss on catching one.
//
// These four are the whole of the guard, and they pull in opposite directions
// on purpose: the first two say a zero must leave nothing behind, the third says
// the guard stops exactly at the empty mark, and the last says a bad reading is
// not a new situation. The 1% warning is guarded by
// `theLastLineFiresWithoutWaitingForADirection` above, which fires at raw 476 —
// a guard reaching one step higher than the empty mark would kill it, and that
// warning is the reason this one has to be precise.

@Test func theZeroFromABootingClockIsNotAReading() {
    var subject = BatteryTrajectory()

    #expect(subject.record(stats(percent: 0, raw: 0, uptime: 25), at: at(25)) == nil)

    // Nothing was recorded at all, and that is the whole claim: `reading` is nil
    // only before a clock has answered, and as far as the trajectory is
    // concerned one has not. Without the guard this is a 0% reading, and 0% on
    // the first poll of a launch fires the last line — the one warning that does
    // not wait for a direction.
    #expect(subject.reading == nil)
    #expect(subject.history == nil)

    subject.record(stats(percent: 98, raw: 662, uptime: 42), at: at(42))
    subject.record(stats(percent: 97, raw: 661, uptime: 50), at: at(50))

    #expect(subject.reading?.percent == 97)
    #expect(subject.reading?.direction == .unknown)
    #expect(subject.history?.samples.map(\.raw) == [662, 661])
}

@Test func theBootZeroDoesNotReadAsAChargeAgainstTheReadingsThatFollowIt() {
    var subject = BatteryTrajectory()

    subject.record(stats(percent: 0, raw: 0, uptime: 25), at: at(25))

    // Half an hour of the measured discharge, from the reading the clock
    // answered with once it had sampled the converter. The verdict is the one
    // the readings actually support — and the zero left in would invert it: 662
    // steps of rise against a band of three swamps the four steps an hour of
    // this clock's discharge spends, so the fall never clears the band and a
    // draining clock reads as charging for the whole of the fall window.
    for minute in 0...30 {
        subject.record(
            stats(
                percent: percent(at: 662), raw: 662 - (4 * minute) / 30,
                uptime: 42 + minute * 60
            ),
            at: at(42 + Double(minute) * 60)
        )
    }

    #expect(subject.reading?.direction == .discharging)
}

@Test func aReadingAtTheEmptyMarkIsAReading() throws {
    var subject = BatteryTrajectory()
    let empty = BatteryTrajectory.rawAtEmpty
    let lastLine = try #require(BatteryTrajectory.thresholds.min())

    // 475 is where the firmware's map puts 0%, not where it stops answering.
    // The boundary belongs to the battery: a clock genuinely run down to nothing
    // reads this, and it is the last thing the app ever gets to warn about. A
    // guard written `<=` here would throw away the emergency it exists to
    // protect.
    let fired = subject.record(stats(percent: percent(at: empty), raw: empty), at: at(0))

    #expect(fired == BatteryWarning(threshold: lastLine, percent: 0))
    #expect(subject.reading?.percent == 0)
    #expect(subject.history?.samples.map(\.raw) == [empty])
}

@Test func aZeroArrivingMidSeriesLeavesTheTrendAndTheReadingsWhereTheyWere() {
    var subject = BatteryTrajectory()
    let last = settleOnDischarge(&subject, at: 50, raw: 566)
    #expect(subject.reading?.direction == .discharging)
    let established = subject.history?.samples

    // Same clock, uptime still climbing, no gap — none of the three rules that
    // discard a history is tripped, and none should be. This is one bad reading
    // from a clock whose history is still good, not a different situation, and
    // the difference is twenty minutes of established trend.
    #expect(subject.record(stats(percent: 0, raw: 0), at: at(Double(last) * 60 + 60)) == nil)

    #expect(subject.reading?.direction == .discharging)
    #expect(subject.reading?.percent == 50)
    #expect(subject.history?.samples == established)
}

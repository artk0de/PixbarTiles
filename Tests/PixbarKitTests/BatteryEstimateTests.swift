import Foundation
import Testing
@testable import PixbarKit

// How long is left, tested against a discharge rather than against an arithmetic
// identity.
//
// The estimate had a defect no unit test could see, because every test asserted
// the formula against itself: remaining raw over fitted raw rate. The formula
// was the defect. What catches it is a property of the whole discharge — the
// answer must shrink as the battery empties — and that needs a simulated
// discharge to assert against.

/// The raw reading a cell at this charge would show, by the same curve the app
/// reads charge back off.
///
/// A search rather than an inverse table, so the two cannot drift apart: if the
/// curve is edited, this follows it without anybody remembering to.
private func raw(atCharge percent: Double) -> Int {
    var best = BatteryChargeCurve.rawAtEmpty
    var bestGap = Double.infinity
    for candidate in BatteryChargeCurve.rawAtEmpty...BatteryChargeCurve.rawAtFull {
        let gap = abs(BatteryChargeCurve.percent(atRaw: candidate) - percent)
        if gap < bestGap { bestGap = gap; best = candidate }
    }
    return best
}

private func stats(raw: Int) -> DeviceStats {
    let percent = Int((Double(raw - 475) / 190 * 100).rounded())
    return DeviceStats(
        version: "0.98", uid: "awtrix_test", bat: max(0, min(100, percent)),
        batRaw: raw, uptime: 10_000, ram: 130_000, ipAddress: "192.168.1.72"
    )
}

/// A constant-current discharge from `from` percent to `to`, sampled every
/// minute, as the pairs the trajectory is fed.
private func discharge(
    from: Double, to: Double, overHours: Double, samplingEvery: TimeInterval = 60
) -> [(stats: DeviceStats, at: Date)] {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let steps = Int(overHours * 3_600 / samplingEvery)
    return (0...steps).map { step in
        let along = Double(step) / Double(steps)
        let charge = from + (to - from) * along
        return (stats(raw: raw(atCharge: charge)), start.addingTimeInterval(Double(step) * samplingEvery))
    }
}

// The defect, stated as the property it violated.
//
// A battery that is emptying has less time left than it did an hour ago. The old
// estimate did the opposite: it divided the remaining VOLTAGE by the rate the
// VOLTAGE was falling, and on the plateau that rate collapses, so the answer
// grew as the cell drained. Measured on the real clock, 88% charge answered 25
// hours and 82% answered 33.5 — the battery lost six points and the estimate
// gained eight hours.
@Test func theEstimateShrinksAsTheBatteryEmpties() {
    var subject = BatteryTrajectory()
    var estimates: [(charge: Double, left: TimeInterval)] = []

    for (reading, at) in discharge(from: 95, to: 5, overHours: 20) {
        _ = subject.record(reading, at: at)
        guard let left = subject.reading?.timeRemaining else { continue }
        estimates.append((BatteryChargeCurve.percent(atRaw: reading.batRaw ?? 0), left))
    }

    #expect(estimates.count > 100, "the estimate never appeared at all")

    // Compared an hour apart rather than sample to sample, and that is the
    // honest form of the property. `bat_raw` is an integer, so a simulated
    // discharge is a staircase and a least-squares fit over a staircase wobbles
    // by a few minutes as each step lands — asserting on neighbours would be
    // asserting about quantisation. What must hold is the trend: an hour of
    // draining always leaves less time than there was.
    let hourly = stride(from: 0, to: estimates.count - 60, by: 60)
    for index in hourly {
        let earlier = estimates[index]
        let later = estimates[index + 60]
        #expect(
            later.left < earlier.left,
            "an hour on, \(earlier.left / 3_600)h at \(earlier.charge)% became \(later.left / 3_600)h at \(later.charge)%"
        )
    }

    // And the whole trajectory falls: the last answer is a small fraction of
    // the first, rather than merely not rising.
    let first = estimates.first!.left
    let last = estimates.last!.left
    #expect(last < first / 4, "began at \(first / 3_600)h and ended at \(last / 3_600)h")
}

// And it is roughly RIGHT, not merely well-behaved.
//
// A constant-current discharge that will take twenty hours from 95% should be
// answered as about nineteen hours at the start of it. Asserted as a band,
// because the curve is the canonical shape rather than a fit to this cell — the
// tolerance is the honesty this design is built on.
@Test func theEstimateIsWithinABandOfTheDischargeItIsWatching() {
    var subject = BatteryTrajectory()
    var atOpening: TimeInterval?
    var chargeAtOpening = 0.0
    var elapsed = 0.0

    let series = discharge(from: 95, to: 5, overHours: 20)
    for (index, (reading, at)) in series.enumerated() {
        _ = subject.record(reading, at: at)
        guard let left = subject.reading?.timeRemaining, atOpening == nil else { continue }
        atOpening = left
        chargeAtOpening = BatteryChargeCurve.percent(atRaw: reading.batRaw ?? 0)
        elapsed = Double(index) * 60
    }

    let left = try! #require(atOpening)
    // Ninety points of charge over twenty hours, so what is left at the moment
    // the gate opens is (charge - 5) / 4.5 hours.
    let truth = (chargeAtOpening - 5) / 4.5 * 3_600
    let ratio = left / truth
    #expect(ratio > 0.65 && ratio < 1.5, "answered \(left / 3_600)h against \(truth / 3_600)h")
    // And it opened inside a couple of hours rather than after most of the day.
    #expect(elapsed < 3 * 3_600, "took \(elapsed / 3_600)h to say anything")
}

// Nothing is said until the fall is bigger than the noise it has to be seen
// through, and how long that takes depends on WHERE on the curve the battery is.
//
// The canonical shape predicted that the middle of the discharge would be the
// slow half — a flat plateau where three raw steps of load-sag hide hours. The
// MEASURED curve of this cell does not have that asymmetry: a raw step is worth
// roughly one to two points of charge across the whole logged run, so both ends
// settle inside the same hour or so. The prediction was wrong and the gate is
// unchanged by it, which is the useful thing to record.
//
// The top of the curve is walked at this clock's own pace: a full charge at
// rest is raw 655 and the log reached 631 three and three quarter hours later,
// about eight points an hour. At half that pace the top spends under three raw
// steps an hour, which the direction rule — in raw steps, by design — reads as
// a clock sitting still, and nothing is ever said.
@Test func nothingIsSaidUntilTheFallOutgrowsTheNoise() {
    var atKnee = BatteryTrajectory()
    var kneeOpenedAfter: TimeInterval?
    for (index, (reading, at)) in discharge(from: 92, to: 72, overHours: 3).enumerated() {
        _ = atKnee.record(reading, at: at)
        if atKnee.reading?.timeRemaining != nil, kneeOpenedAfter == nil {
            kneeOpenedAfter = Double(index) * 60
        }
    }

    var onPlateau = BatteryTrajectory()
    var plateauOpenedAfter: TimeInterval?
    for (index, (reading, at)) in discharge(from: 55, to: 45, overHours: 3).enumerated() {
        _ = onPlateau.record(reading, at: at)
        if onPlateau.reading?.timeRemaining != nil, plateauOpenedAfter == nil {
            plateauOpenedAfter = Double(index) * 60
        }
    }

    let knee = try! #require(kneeOpenedAfter)
    let plateau = try! #require(plateauOpenedAfter)

    // Neither speaks in the first quarter of an hour, which is the noise floor
    // doing its job…
    #expect(knee >= 15 * 60, "spoke after only \(knee / 60) minutes")
    #expect(plateau >= 15 * 60, "spoke after only \(plateau / 60) minutes")
    // …and neither takes more than a couple of hours, on a cell whose curve
    // turns out to be far more even than the canonical one.
    #expect(knee <= 2 * 3_600)
    #expect(plateau <= 2 * 3_600)
}

// A charge inside the buffer does not poison the rate that follows it.
//
// With samples kept for a whole day, a discharge fitted over "everything held"
// would be fitted across the charge that preceded it — a rise and a fall
// averaged into a gentle nothing, and an estimate of days. The fit starts after
// the last time the battery was seen going up.
@Test func theRateIgnoresWhatHappenedBeforeTheBatteryStartedFalling() {
    var subject = BatteryTrajectory()
    let start = Date(timeIntervalSince1970: 1_800_000_000)

    // An hour of charging, 60% up to 90%…
    for step in 0...60 {
        let charge = 60 + Double(step) / 60 * 30
        _ = subject.record(stats(raw: raw(atCharge: charge)), at: start.addingTimeInterval(Double(step) * 60))
    }
    // …then two and a half hours of discharge from it, at this clock's own pace
    // across the top of its curve — eight points an hour, raw 655 to 631 in
    // three and three quarter hours. Half that pace spends under three raw
    // steps an hour up here, which the direction rule reads as standing still.
    var last: TimeInterval?
    for (reading, at) in discharge(from: 90, to: 70, overHours: 2.5) {
        _ = subject.record(reading, at: at.addingTimeInterval(3_700))
        last = subject.reading?.timeRemaining
    }

    let left = try! #require(last)
    // Seventy points left at eight points an hour is about nine hours. A fit
    // dragged through the charging hour would answer several days.
    #expect(left < 40 * 3_600, "answered \(left / 3_600)h — the charge is still in the fit")
    #expect(left > 6 * 3_600)
}

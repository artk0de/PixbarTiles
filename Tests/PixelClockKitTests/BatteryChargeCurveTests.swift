import Foundation
import Testing
@testable import PixelClockKit

// How much charge is left, from a voltage — measured on this clock.
//
// `bat_raw` is an ADC reading of the cell's voltage. Voltage is not charge, and
// on THIS cell the gap between the two is not a subtlety: the firmware maps the
// pair linearly onto its own 475–665 and calls the moment the clock dies 47%.
//
// One discharge was logged once a minute from boot until it went silent, and
// the sample after the silence reported an uptime of seventy-two seconds — a
// power cycle at the end of an accelerating collapse. Charge here is how much of
// that measured runtime was still to come at each reading.

@Test func theCurveEndsWhereTheClockActuallyDies() {
    // 564, not the firmware's 475. The clock went silent on this reading.
    #expect(BatteryChargeCurve.percent(atRaw: 564) == 0)
    #expect(BatteryChargeCurve.percent(atRaw: 665) == 100)
}

@Test func aReadingOutsideTheScaleIsClampedRatherThanExtrapolated() {
    // Below where it dies there is no runtime left to describe, and the
    // firmware's own floor is deep inside that region.
    #expect(BatteryChargeCurve.percent(atRaw: 475) == 0)
    #expect(BatteryChargeCurve.percent(atRaw: 540) == 0)
    #expect(BatteryChargeCurve.percent(atRaw: 700) == 100)
}

@Test func theCurveNeverGoesBackwards() {
    // Monotone across the whole scale. A dip anywhere would let a falling
    // voltage report a rising charge, which is the one thing a trend fitted on
    // top of this must never see.
    var previous = -1.0
    for raw in 470...670 {
        let here = BatteryChargeCurve.percent(atRaw: raw)
        #expect(here >= previous, "curve fell at raw \(raw)")
        previous = here
    }
}

// The size of the firmware's error, as the measurement found it.
//
// This is the whole reason the app cannot reason from `bat`. The direction is
// the surprise: the firmware is not merely imprecise, it is optimistic by tens
// of points, and most so near the end where it matters.
@Test func theFirmwareIsOptimisticAndTheGapWidensTowardsTheEnd() {
    func firmware(_ raw: Int) -> Double { Double(raw - 475) / 190 * 100 }

    // At the top of the logged run: eighty-two against sixty-five.
    #expect(abs(firmware(631) - 82) < 1)
    #expect(BatteryChargeCurve.percent(atRaw: 631) == 65)

    // Two thirds of the way down: seventy-two against forty-four.
    #expect(abs(firmware(612) - 72) < 1)
    #expect(BatteryChargeCurve.percent(atRaw: 612) == 44)

    // And at the reading it died on: forty-seven against nothing at all.
    #expect(abs(firmware(564) - 47) < 1)
    #expect(BatteryChargeCurve.percent(atRaw: 564) == 0)

    // The gap widens as the battery empties — from seventeen points near the
    // top of the run to nearly fifty — which is what makes an estimate built on
    // the firmware's figure worst where somebody most needs it.
    let gaps = [631, 612, 596, 580].map { firmware($0) - BatteryChargeCurve.percent(atRaw: $0) }
    for (earlier, later) in zip(gaps, gaps.dropFirst()) {
        #expect(later > earlier, "gap narrowed: \(gaps)")
    }
    #expect(gaps.first! > 15)
    #expect(gaps.last! > 45)

    // It stops widening only because the firmware's own number has to come down
    // eventually: at the reading it died on, its remaining 47 points ARE the
    // whole error. Stated so that the peak is not mistaken for the worst case.
    #expect(firmware(564) - BatteryChargeCurve.percent(atRaw: 564) > 45)
}

// How much charge one raw step is worth HERE, which is what the trend gate
// needs in order to ask "is this fall bigger than the noise" in charge rather
// than in volts.
@Test func theCurveCanSayWhatARawStepIsWorthAtAGivenReading() {
    // The measured curve is steepest in charge terms around the middle of the
    // run, where a single raw step is worth the better part of two points…
    #expect(BatteryChargeCurve.percentPerRaw(atRaw: 600) > 1.5)
    // …and shallowest across the top, which is the stretch no measurement
    // stands behind and is drawn as a straight line.
    #expect(BatteryChargeCurve.percentPerRaw(atRaw: 645) < 1.2)
    // Never zero, or the gate built on it would divide by nothing.
    for raw in stride(from: 566, through: 663, by: 4) {
        #expect(BatteryChargeCurve.percentPerRaw(atRaw: raw) > 0, "flat at raw \(raw)")
    }
}

// The measured points, asserted as a table so that editing the curve is a
// decision rather than a drift.
//
// Every pair below came out of the log: charge is the fraction of the twelve
// and a half hours of runtime that was still ahead at that reading.
@Test func theCurvePassesThroughTheReadingsThatWereMeasured() {
    let measured: [(raw: Int, percent: Double)] = [
        (564, 0), (572, 3), (580, 6), (588, 10), (596, 17),
        (604, 32), (612, 44), (620, 51), (628, 61), (631, 65),
    ]

    for point in measured {
        #expect(
            BatteryChargeCurve.percent(atRaw: point.raw) == point.percent,
            "raw \(point.raw) drew \(BatteryChargeCurve.percent(atRaw: point.raw))"
        )
    }
}

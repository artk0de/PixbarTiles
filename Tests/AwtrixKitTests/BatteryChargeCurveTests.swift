import Foundation
import Testing
@testable import AwtrixKit

// How much charge is left, from a voltage.
//
// `bat_raw` is an ADC reading of the cell's voltage — GPIO34 through a divider,
// median-and-mean filtered by the firmware, ten bits, so one raw step is about
// 6.45 mV and the firmware's own ends are 475 ≈ 3.06 V and 665 ≈ 4.29 V. What
// makes this file necessary is that voltage is NOT charge: a lithium cell holds
// a long flat plateau through the middle of its discharge and falls steeply at
// both ends, so equal steps in voltage are wildly unequal steps in charge.
//
// The firmware maps the two linearly anyway, and so did this app — which is the
// defect this curve exists to remove.

@Test func theCurveIsPinnedToTheEndsTheFirmwareUses() {
    // Anchored rather than merely close, because everything downstream divides
    // by what is left: a curve that answered 4% at the firmware's own zero
    // would leave an estimate that never reaches the end of the battery.
    #expect(BatteryChargeCurve.percent(atRaw: 475) == 0)
    #expect(BatteryChargeCurve.percent(atRaw: 665) == 100)
}

@Test func aReadingOutsideTheScaleIsClampedRatherThanExtrapolated() {
    #expect(BatteryChargeCurve.percent(atRaw: 400) == 0)
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

// The whole point, stated as an inequality: the middle of the discharge is
// FLAT in volts, so a raw step there is worth several times what a raw step is
// worth near the top.
//
// This is what the linear map gets wrong, and the ratio is the size of the
// error it was making.
@Test func aVoltStepIsWorthFarMoreChargeOnThePlateauThanAtTheKnee() {
    let atKnee = BatteryChargeCurve.percent(atRaw: 640) - BatteryChargeCurve.percent(atRaw: 635)
    let onPlateau = BatteryChargeCurve.percent(atRaw: 600) - BatteryChargeCurve.percent(atRaw: 595)

    #expect(atKnee > 0)
    #expect(onPlateau > atKnee * 2, "plateau \(onPlateau) vs knee \(atKnee)")
}

// And the consequence for the number this app used to trust.
//
// At the reading taken from the live clock — raw 631, which the firmware calls
// 82% — the cell is still near the top of its curve and genuinely holds about
// nine tenths of its charge. The firmware's linear map understates it by most
// of ten points, and an estimate built on that map divides the wrong remainder
// by the wrong rate.
@Test func theLinearMapAndTheCurveDisagreeByEnoughToMatter() {
    let firmware = Double(631 - 475) / Double(665 - 475) * 100
    let curve = BatteryChargeCurve.percent(atRaw: 631)

    #expect(abs(firmware - 82) < 1, "firmware map drifted: \(firmware)")
    #expect(curve > firmware + 5, "curve \(curve) vs firmware \(firmware)")
    #expect(curve < 95)
}

// How much charge one raw step is worth HERE, which is what the trend gate
// needs in order to ask "is this fall bigger than the noise" in charge rather
// than in volts.
@Test func theCurveCanSayWhatARawStepIsWorthAtAGivenReading() {
    // On the plateau a single raw step moves several points of charge…
    #expect(BatteryChargeCurve.percentPerRaw(atRaw: 597) > 1.2)
    // …and near the top it moves a fraction of one.
    #expect(BatteryChargeCurve.percentPerRaw(atRaw: 640) < 0.7)
    // Never zero, or the gate built on it would divide by nothing.
    for raw in stride(from: 476, through: 664, by: 4) {
        #expect(BatteryChargeCurve.percentPerRaw(atRaw: raw) > 0, "flat at raw \(raw)")
    }
}

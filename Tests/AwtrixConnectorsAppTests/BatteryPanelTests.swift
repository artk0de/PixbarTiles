import AppKit
import AwtrixKit
import Foundation
import SwiftUI
import Testing
@testable import AwtrixConnectorsApp

// What the panel says about the battery, and that it says it on the panel.
//
// There is no "battery charging" emoji in Unicode: the family is U+1F50B and
// U+1FAAB, and neither has a charging variant. The plug is the closest thing
// that exists and the only one that reads unambiguously beside a percentage.

/// A reading whose shown figure is the real one unless a test separates them.
///
/// Defaulted here rather than on `BatteryReading`, which has two percentages on
/// purpose and should make every caller say which it means. The two only differ
/// while the ratchet is holding one against the other, and that is what the
/// tests naming `shown` are about.
private func reading(
    _ percent: Int, _ direction: BatteryDirection, shown: Int? = nil,
    remaining: TimeInterval? = nil
) -> BatteryReading {
    BatteryReading(
        percent: percent, shownPercent: shown ?? percent, direction: direction,
        timeRemaining: remaining
    )
}

// MARK: - The glyph

@Test func theGlyphFollowsTheStateNotThePercentageAlone() {
    // The same 4%, two glyphs. A clock on charge at 4% is good news and a clock
    // draining at 4% is not, and the percentage cannot tell them apart — which
    // is why the whole trajectory exists.
    #expect(BatteryLine.glyph(for: reading(4, .charging)) == "\u{1F50C}")
    #expect(BatteryLine.glyph(for: reading(4, .discharging)) == "\u{1FAAB}")

    // And the same at the top of the range, so this does not pass on the low
    // end alone.
    #expect(BatteryLine.glyph(for: reading(95, .charging)) == "\u{1F50C}")
    #expect(BatteryLine.glyph(for: reading(95, .discharging)) == "\u{1F50B}")
}

@Test func aStateThatIsNotEstablishedYetGetsNoGlyph() {
    // A glyph implying a verdict the readings have not reached is the same lie
    // as a confident estimate from two samples twenty seconds apart.
    #expect(BatteryLine.glyph(for: reading(83, .unknown)) == nil)
    #expect(BatteryLine.glyph(for: nil) == nil)
}

@Test func theDischargingGlyphChangesAtTwentyPercent() {
    // The line is at twenty, and both sides of it are checked: a rule written
    // with the comparison the wrong way round passes a test that only ever
    // looks below.
    #expect(BatteryLine.glyph(for: reading(20, .discharging)) == "\u{1F50B}")
    #expect(BatteryLine.glyph(for: reading(19, .discharging)) == "\u{1FAAB}")
}

// MARK: - The line

@Test func aLineWithNoReadingSaysNothingRatherThanZero() {
    #expect(BatteryLine.text(for: nil) == nil)
}

@Test func anUnestablishedStateShowsThePercentageAndNothingElse() {
    let line = BatteryLine.text(for: reading(83, .unknown))

    #expect(line == "83%")
}

@Test func aDischargeWithNoEstimateYetSaysSoRatherThanGuessing() {
    let line = BatteryLine.text(for: reading(83, .discharging))

    #expect(line?.contains("83%") == true)
    #expect(line?.contains("estimating") == true)
}

@Test func aDischargeWithAnEstimateNamesTheDuration() {
    let line = BatteryLine.text(for: reading(48, .discharging, remaining: 14_400))

    #expect(line?.contains("48%") == true)
    #expect(line?.contains("4 h") == true)
    // Seconds are what the trajectory answers in and nothing a person reads a
    // menu bar panel for.
    #expect(line?.contains("14400") == false)
}

@Test func aChargingLineIsThePlugAndThePercentageAndNothingElse() {
    let line = BatteryLine.text(for: reading(100, .charging, remaining: 14_400))

    // The plug already says what is happening, and any word beside it is noise.
    // How full the clock is is what a person reads this line for, so the
    // percentage stays and nothing else joins it.
    #expect(line == "\u{1F50C} 100%")
}

@Test func aChargingLineCarriesNoCountdownEvenWhenHandedOne() {
    // Time to empty for something filling up is a number that means nothing,
    // and the trajectory withholds it — but the line must not render one even
    // if it is handed one.
    let line = BatteryLine.text(for: reading(48, .charging, remaining: 14_400))

    #expect(line?.contains("4 h") == false)
    #expect(line?.contains("charging") == false)
}

@Test func theLinePrintsTheShownFigureRatherThanTheReadingBehindIt() {
    // The percentage flickers 100 to 99 on ADC noise with nothing changing, and
    // the ratchet holds it. The line prints what the ratchet holds.
    let held = reading(99, .charging, shown: 100)

    #expect(BatteryLine.text(for: held) == "\u{1F50C} 100%")
}

@Test func urgencyIsReadOffTheRealFigureRatherThanTheHeldOne() {
    // A battery through 20% while the ratchet still shows 21. The colour and
    // the glyph are the same line the first warning fires at, and a threshold
    // read off a ratcheted number is a warning that never arrives.
    let held = reading(19, .discharging, shown: 21)

    #expect(BatteryLine.colour(for: held) == BatteryLine.colour(for: reading(19, .discharging)))
    #expect(BatteryLine.glyph(for: held) == "\u{1FAAB}")
    #expect(BatteryLine.text(for: held)?.contains("21%") == true)
}

@Test func aDurationReadsAsHoursAndMinutes() {
    #expect(BatteryLine.duration(14_400) == "4 h")
    #expect(BatteryLine.duration(15_300) == "4 h 15 m")
    #expect(BatteryLine.duration(2_700) == "45 m")
    // Under a minute left reads as the smallest step the grid has rather than
    // "0 m", which looks like a broken estimate rather than an urgent one.
    #expect(BatteryLine.duration(20) == "5 m")
    #expect(BatteryLine.duration(0) == "5 m")
}

// The estimate extrapolates all the way to 0%, and lithium-ion stops being
// linear long before it gets there — so the number is least trustworthy exactly
// where somebody most wants it. "3 h 47 m" claims a minute of precision that
// nothing behind it can support, and a reader takes the claim at face value.
@Test func anEstimateUnderAnHourIsRoundedToFiveMinutes() {
    // Three readings that mean the same thing say the same thing.
    #expect(BatteryLine.duration(47 * 60) == "45 m")
    #expect(BatteryLine.duration(45 * 60) == "45 m")
    #expect(BatteryLine.duration(43 * 60) == "45 m")
    // Five and not ten: three quarters of an hour and two thirds of one are
    // different amounts of evening, and the grid must not merge them.
    #expect(BatteryLine.duration(41 * 60) == "40 m")
}

// Coarser above the hour, because the same relative claim costs more minutes
// there: five minutes on forty is a quarter of an hour on four.
@Test func anEstimateOverAnHourIsRoundedToAQuarterOfOne() {
    #expect(BatteryLine.duration(4 * 3_600 + 22 * 60) == "4 h 15 m")
    #expect(BatteryLine.duration(4 * 3_600 + 8 * 60) == "4 h 15 m")
    #expect(BatteryLine.duration(4 * 3_600 + 2 * 60) == "4 h")
}

// Which grid a reading lands on is decided by the reading, not by what it
// rounds to — otherwise the hour is a boundary the answer can round itself
// across and back.
@Test func theHourIsWhereTheGridChanges() {
    #expect(BatteryLine.duration(57 * 60) == "55 m")
    // A second under the hour, on the five-minute grid, rounding up to it.
    #expect(BatteryLine.duration(3_599) == "1 h")
    #expect(BatteryLine.duration(3_600 + 8 * 60) == "1 h 15 m")
}

@Test func urgencyIsCarriedByTheColourRatherThanASecondGlyph() {
    // There is no red variant of either battery emoji, and stacking a warning
    // sign beside one reads as clutter rather than as escalation.
    let comfortable = BatteryLine.colour(for: reading(83, .discharging))
    let low = BatteryLine.colour(for: reading(15, .discharging))
    let critical = BatteryLine.colour(for: reading(4, .discharging))

    #expect(comfortable != low)
    #expect(low != critical)
    // A clock filling up at 4% is not an emergency, however low the number is.
    #expect(BatteryLine.colour(for: reading(4, .charging)) == comfortable)
}

// MARK: - On the panel

/// The panel, drawn at the width it ships at, with the battery already read.
///
/// A ramp of polls rather than a pair, and a minute apart rather than twenty
/// seconds: the direction is a line fitted across a window now, so a pair
/// inside two minutes establishes nothing and both panels would draw the same
/// unknown state. The instants are supplied rather than taken, so nothing here
/// depends on how long a render took.
///
/// No window and no run loop: `cacheDisplay` renders the layer tree
/// synchronously, which is what keeps this deterministic rather than a wait on
/// something asynchronous to settle.
@MainActor
private func panelPixels(percent: Int, raw: [Int]) async -> Data? {
    let clock = ScriptedTransport(bodies: raw.map { statsBody(percent: percent, raw: $0) })
    let model = testModel(transport: clock)
    let origin = Date(timeIntervalSince1970: 1_700_000_000)
    for step in raw.indices {
        await model.monitor.refresh(at: origin.addingTimeInterval(Double(step) * 60))
    }
    let browsing = FakeBonjourBrowser()
    let browser = DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    browser.start()
    let host = NSHostingView(
        rootView: MenuPanel(model: model, monitor: model.monitor, discovery: browser)
    )
    host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

/// Twelve minutes of a raw figure climbing two steps a minute, and half an hour
/// of it falling one.
///
/// The two are not the same length because the two answers are not read off the
/// same window: a charge is twenty-five raw steps per ten minutes and is
/// believed almost at once, while a fall is a twentieth of that and is not
/// believed until twenty minutes of it have been watched.
private let climbing = (0..<12).map { 640 + 2 * $0 }
private let falling = (0..<31).map { 600 - $0 }

@Test @MainActor func whatTheTrajectorySaysIsDrawnOnThePanel() async {
    // The same percentage, drawn twice, differing only in which way the raw
    // reading trended. Deleting the battery line from `body` leaves every pure
    // test above green — this is the one that notices.
    let charging = await panelPixels(percent: 42, raw: climbing)
    let discharging = await panelPixels(percent: 42, raw: falling)

    #expect(charging != nil)
    #expect(charging != discharging)
}

@Test @MainActor func thePanelDrawsTheSameBatteryTwice() async {
    // Otherwise the expectation above passes on noise rather than on content.
    let once = await panelPixels(percent: 42, raw: falling)
    let again = await panelPixels(percent: 42, raw: falling)

    #expect(once == again)
}

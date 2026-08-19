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

private func reading(
    _ percent: Int, _ direction: BatteryDirection, remaining: TimeInterval? = nil
) -> BatteryReading {
    BatteryReading(percent: percent, direction: direction, timeRemaining: remaining)
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

@Test func aChargingLineSaysSoRatherThanCountingDownToEmpty() {
    let line = BatteryLine.text(for: reading(48, .charging, remaining: 14_400))

    #expect(line?.contains("charging") == true)
    // Time to empty for something filling up is a number that means nothing,
    // and the trajectory withholds it — but the line must not render one even
    // if it is handed one.
    #expect(line?.contains("4 h") == false)
}

@Test func aDurationReadsAsHoursAndMinutes() {
    #expect(BatteryLine.duration(14_400) == "4 h")
    #expect(BatteryLine.duration(15_600) == "4 h 20 m")
    #expect(BatteryLine.duration(2_700) == "45 m")
    // Under a minute left rounds up rather than reading "0 m", which looks like
    // a broken estimate rather than an urgent one.
    #expect(BatteryLine.duration(20) == "1 m")
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
/// Two polls rather than one, because one reading is not a trend: the direction
/// is what this is about and it takes a pair to establish. The instants are
/// supplied rather than taken, so nothing here depends on how long a render
/// took.
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
        await model.monitor.refresh(at: origin.addingTimeInterval(Double(step) * 20))
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

@Test @MainActor func whatTheTrajectorySaysIsDrawnOnThePanel() async {
    // The same percentage, drawn twice, differing only in which way the raw
    // reading moved. Deleting the battery line from `body` leaves every pure
    // test above green — this is the one that notices.
    let charging = await panelPixels(percent: 42, raw: [400, 404])
    let discharging = await panelPixels(percent: 42, raw: [400, 396])

    #expect(charging != nil)
    #expect(charging != discharging)
}

@Test @MainActor func thePanelDrawsTheSameBatteryTwice() async {
    // Otherwise the expectation above passes on noise rather than on content.
    let once = await panelPixels(percent: 42, raw: [400, 396])
    let again = await panelPixels(percent: 42, raw: [400, 396])

    #expect(once == again)
}

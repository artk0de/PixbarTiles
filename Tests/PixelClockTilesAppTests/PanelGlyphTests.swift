import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The panel's own marks, drawn in the app's pixel language rather than
// borrowed from the emoji or SF Symbols families: a map of characters, one art
// pixel per character, and a palette that is data. The same shape the menu
// bar's clock has, pinned the same way — a map and a palette are what these
// tests hold still.

private let everyMap: [(String, [String])] = [
    ("awtrix", PanelGlyph.awtrix),
    ("tc002", PanelGlyph.tc002),
    ("battery", PanelGlyph.battery),
    ("bolt", PanelGlyph.bolt),
    ("led", PanelGlyph.led),
    ("gear", PanelGlyph.gear),
    ("power", PanelGlyph.power),
]

private func reading(
    _ percent: Int, _ direction: BatteryDirection, left: TimeInterval? = nil
) -> BatteryReading {
    BatteryReading(
        percent: percent, shownPercent: percent, direction: direction, timeRemaining: left
    )
}

@Test func everyGlyphIsARectangleOfArtPixels() {
    for (name, map) in everyMap {
        #expect(!map.isEmpty, "\(name) has no rows")
        let widths = Set(map.map(\.count))
        #expect(widths.count == 1, "\(name) has ragged rows: \(widths.sorted())")
    }
}

// The TC001's case is FLAT on top — no buttons stand above the frame, which
// is what the user corrected. Every row above the frame is empty.
@Test func theAwtrixCaseIsFlatOnTop() {
    let frame = try! #require(PanelGlyph.awtrix.firstIndex { $0.contains("F") })
    #expect(PanelGlyph.awtrix[..<frame].allSatisfy { $0.allSatisfy { $0 == "." } })
}

// The AWTRIX clock stands on the same canvas as the user's own clock, so the
// two sit in a card's leading slot at one size — and it speaks the same
// palette keys, so the approved dark, light and offline palettes colour it
// without a second set.
@Test func theAwtrixSilhouetteSharesTheUserClocksCanvasAndPalette() {
    #expect(PanelGlyph.awtrix.count == UserClock.height)
    #expect(PanelGlyph.awtrix.allSatisfy { $0.count == UserClock.width })
    let keys = Set(UserClock.darkOnline.keys).union(["."])
    let used = Set(PanelGlyph.awtrix.joined())
    #expect(used.isSubset(of: keys), "unpaletted keys: \(used.subtracting(keys))")
}

// The two clocks are two devices, and the card draws each as itself: the
// AWTRIX 3 as the TC001's flat LED bar, the TC002 as its taller 52x16 screen
// under the yellow knob it is driven by. The user's own clock stays the app's
// mark in the header.
@Test func eachModelIsDrawnAsItsOwnDevice() {
    #expect(PanelGlyph.map(for: .ulanziTC002) == PanelGlyph.tc002)
    #expect(PanelGlyph.map(for: .awtrix3) == PanelGlyph.awtrix)
    #expect(PanelGlyph.tc002 != PanelGlyph.awtrix)
}

@Test func theTC002StandsOnTheSameCanvasInTheSamePaletteKeysPlusItsKnob() {
    #expect(PanelGlyph.tc002.count == UserClock.height)
    #expect(PanelGlyph.tc002.allSatisfy { $0.count == UserClock.width })
    let keys = Set(UserClock.darkOnline.keys).union([".", "k", "K"])
    let used = Set(PanelGlyph.tc002.joined())
    #expect(used.isSubset(of: keys), "unpaletted keys: \(used.subtracting(keys))")
}

// The knob is what tells a TC002 from a TC001 at a glance, and only the TC002
// has one. It sits on the LEFT of the case, where the clock carries it.
@Test func onlyTheTC002CarriesTheKnobAndItIsOnTheLeft() {
    #expect(PanelGlyph.tc002.joined().contains("k"))
    #expect(PanelGlyph.tc002.joined().contains("K"))
    #expect(!PanelGlyph.awtrix.joined().contains("k"))

    let columns = PanelGlyph.tc002.flatMap { row in
        row.enumerated().filter { $0.element == "k" || $0.element == "K" }.map(\.offset)
    }
    let rightmost = try! #require(columns.max())
    #expect(rightmost < UserClock.width / 2, "the knob sits left of centre")
}

// Orange, the colour of the clock's own knob — not the yellow first drawn.
@Test func theKnobIsOrange() {
    #expect(PanelGlyph.knobTop == 0xFF9F0A)
    #expect(PanelGlyph.knobSide == 0xC2610A)
}

// The knob is the case's plastic, not the screen: it stays yellow when the
// clock goes down and only the screen goes out.
@Test func theKnobStaysYellowWhenTheScreenGoesOut() {
    for dark in [true, false] {
        for live in [true, false] {
            let palette = PanelGlyph.devicePalette(for: .ulanziTC002, dark: dark, live: live)
            #expect(palette["k"] == PanelGlyph.knobTop)
            #expect(palette["K"] == PanelGlyph.knobSide)
            #expect(palette["w"] == PanelGlyph.devicePalette(dark: dark, live: live)["w"])
        }
    }
    #expect(
        PanelGlyph.devicePalette(for: .awtrix3, dark: true, live: true)
            == PanelGlyph.devicePalette(dark: true, live: true)
    )
}

@Test func theBatteryHasFiveCells() {
    let cells = Set(PanelGlyph.battery.joined()).filter(\.isNumber)
    #expect(cells == ["1", "2", "3", "4", "5"])
}

// One cell per fifth of the charge, rounded UP: a clock at 3% still shows a
// sliver, because an empty-looking battery that is not empty is the lie a
// glance acts on.
@Test func aCellLightsForEveryFifthOfTheCharge() {
    #expect(PanelGlyph.filledCells(for: 0) == 0)
    #expect(PanelGlyph.filledCells(for: 3) == 1)
    #expect(PanelGlyph.filledCells(for: 20) == 1)
    #expect(PanelGlyph.filledCells(for: 21) == 2)
    #expect(PanelGlyph.filledCells(for: 90) == 5)
    #expect(PanelGlyph.filledCells(for: 100) == 5)
    #expect(PanelGlyph.filledCells(for: 140) == 5)
}

@Test func onlyTheLitCellsCarryColour() {
    let palette = PanelGlyph.batteryPalette(for: reading(50, .discharging), ink: 0x111111, live: true)
    #expect(palette["1"] == PanelGlyph.normalTint)
    #expect(palette["3"] == PanelGlyph.normalTint)
    #expect(palette["4"] == .some(nil))
    #expect(palette["5"] == .some(nil))
    #expect(palette["F"] == 0x111111)
}

// Urgency reads off the same two lines the text and the warning use, and off
// the direction: a clock filling up at 4% is not an emergency.
@Test func theCellsWearTheUrgencyTheLineAlreadyNames() {
    #expect(PanelGlyph.batteryTint(for: reading(60, .discharging)) == PanelGlyph.normalTint)
    #expect(PanelGlyph.batteryTint(for: reading(15, .discharging)) == PanelGlyph.lowTint)
    #expect(PanelGlyph.batteryTint(for: reading(5, .discharging)) == PanelGlyph.criticalTint)
    #expect(PanelGlyph.batteryTint(for: reading(5, .charging)) == PanelGlyph.chargingTint)
    #expect(PanelGlyph.batteryTint(for: reading(60, .unknown)) == PanelGlyph.unknownTint)
}

// A clock that is not answering shows the charge it last had, greyed — the
// same treatment its own drawing gets when its screen goes out.
@Test func aLastKnownChargeIsDrawnGreyed() {
    let palette = PanelGlyph.batteryPalette(for: reading(50, .charging), ink: 0x111111, live: false)
    #expect(palette["1"] == PanelGlyph.staleTint)
    #expect(palette["4"] == .some(nil))
}

@Test func theBoltIsDrawnWhileChargingAndOnlyThen() {
    #expect(PanelGlyph.showsBolt(for: reading(40, .charging), live: true))
    #expect(!PanelGlyph.showsBolt(for: reading(40, .discharging), live: true))
    #expect(!PanelGlyph.showsBolt(for: reading(40, .unknown), live: true))
    #expect(!PanelGlyph.showsBolt(for: nil, live: true))
    // A charge that is only remembered does not claim a cable it cannot see.
    #expect(!PanelGlyph.showsBolt(for: reading(40, .charging), live: false))
}

@Test func theStatusLightIsTheDotsThreeAnswers() {
    #expect(PanelGlyph.ledPalette(for: .green)["L"] == PanelGlyph.onlineTint)
    #expect(PanelGlyph.ledPalette(for: .yellow)["L"] == PanelGlyph.checkingTint)
    #expect(PanelGlyph.ledPalette(for: .red)["L"] == PanelGlyph.offlineTint)
    // Each light carries a highlight, and it is not the body's colour —
    // the gloss is what makes it read as a lamp rather than a square.
    for dot: PanelModel.ClockDot in [.green, .yellow, .red] {
        let palette = PanelGlyph.ledPalette(for: dot)
        #expect(palette["h"] != nil)
        #expect(palette["h"] != palette["L"])
    }
}

// The device's own drawing follows its connection: lit while it answers,
// screen out while it does not — the menu bar clock's two palettes.
@Test func theDeviceDrawingPutsItsScreenOutWhenTheClockIsDown() {
    #expect(PanelGlyph.devicePalette(dark: true, live: true) == UserClock.darkOnline)
    #expect(PanelGlyph.devicePalette(dark: true, live: false) == UserClock.darkOffline)
    #expect(PanelGlyph.devicePalette(dark: false, live: true) == UserClock.lightOnline)
    #expect(PanelGlyph.devicePalette(dark: false, live: false) == UserClock.lightOffline)
}

// MARK: - Words set in the clock's own face

// The middle of the wordmark is not a picture of a word — it IS the word, set
// in a face the clock itself draws with. So the bridge is pinned to the shapes
// the kit's table actually carries: change a letter's bytes and this fails,
// which is the point of drawing it from the face rather than redrawing it here.
@Test func aWordIsSetInTheFacesOwnShapes() {
    #expect(
        PanelGlyph.text("Clock", in: PixelFont.tiny) == [
            ".WW.WW..........W..",
            "W....W..WWW.WWW.W..",
            "W....W..W.W.W...W.W",
            "W....W..W.W.W...WW.",
            ".WW..WW.WWW.WWW.W.W",
        ]
    )
}

// One gap column between letters and none after the last: a trailing gap is a
// word that sits a column left of where it measures.
@Test func lettersAreSeparatedByTheFacesOwnGapAndNothingTrails() {
    let rows = PanelGlyph.text("ll", in: PixelFont.tiny)
    #expect(rows.count == PixelFont.tiny.height)
    #expect(rows.allSatisfy { $0.count == 3 + PixelFont.tiny.gap + 3 })
    #expect(rows[1] == ".W...W.")
}

// A mark the face cannot spell draws the substitute rather than a hole: a
// skipped glyph that still advanced is the defect the kit's own face fixed.
@Test func aMarkTheFaceCannotSpellDrawsTheSubstitute() {
    #expect(
        PanelGlyph.text("\u{2603}", in: PixelFont.tiny)
            == PanelGlyph.text(String(PixelFont.substitute), in: PixelFont.tiny)
    )
}

@Test func anEmptyWordDrawsNothingButKeepsItsRows() {
    #expect(PanelGlyph.text("", in: PixelFont.tiny) == ["", "", "", "", ""])
}

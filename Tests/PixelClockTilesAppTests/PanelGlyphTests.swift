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

@Test func eachModelIsDrawnAsItsOwnDevice() {
    #expect(PanelGlyph.map(for: .ulanziTC002) == UserClock.map)
    #expect(PanelGlyph.map(for: .awtrix3) == PanelGlyph.awtrix)
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

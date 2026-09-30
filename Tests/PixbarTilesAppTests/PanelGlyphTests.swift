import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

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
    ("recheckArrow", PanelGlyph.recheckArrow),
    ("power", PanelGlyph.power),
]

// The refresh sits beside the gear on a clock's card: the same size, so the
// two read as a pair of controls.
@Test func theRecheckArrowIsTheGearsSize() {
    #expect(PanelGlyph.recheckArrow.count == PanelGlyph.gear.count)
    #expect(PanelGlyph.recheckArrow.first?.count == PanelGlyph.gear.first?.count)
}

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

// MARK: - The bin

// A wastebasket read head-on: a lid wider than the body, a handle above it,
// and a tapering body with staves down it. The lid's overhang is what makes
// the mark a bin rather than a cup — drawn flush it reads as a glass.
@Test func theBinHasALidWiderThanItsBodyAndAHandleAboveIt() {
    #expect(PanelGlyph.bin.count == 9)
    #expect(PanelGlyph.bin.allSatisfy { $0.count == 9 })
    let ink = { (row: String) in row.filter { $0 != "." }.count }
    // The handle is the narrowest thing, above the widest.
    #expect(ink(PanelGlyph.bin[0]) < ink(PanelGlyph.bin[1]))
    // The lid overhangs the body's first row.
    #expect(ink(PanelGlyph.bin[1]) > ink(PanelGlyph.bin[3]))
    // And the body tapers: it ends narrower than it starts.
    #expect(ink(PanelGlyph.bin[7]) < ink(PanelGlyph.bin[3]))
}

// MARK: - The pin

// A pushpin read side-on: a head, a narrowed neck, a flange wider than the
// head, and a needle under it. The flange is what makes it a pin rather than a
// key or a lamp — drawn without it the mark reads as a screw.
@Test func thePinIsAPushpinWithAFlangeAndANeedle() {
    #expect(PanelGlyph.pin.count == 9)
    #expect(PanelGlyph.pin.allSatisfy { $0.count == 9 })
    // The flange row is the widest run of ink, and it is wider than the head.
    let ink = { (row: String) in row.filter { $0 != "." }.count }
    #expect(ink(PanelGlyph.pin[3]) > ink(PanelGlyph.pin[0]))
    // The needle is one column, and it is the last thing drawn.
    #expect(ink(PanelGlyph.pin[8]) == 1)
}

// Pinned reads as ON — the app's own accent — and unpinned as an ordinary
// control in the card's ink. A pin that looks the same either way is a switch
// nobody can see the state of.
@Test func aPinnedPanelsMarkIsLitAndAnUnpinnedOnesIsNot() {
    let lit = PanelGlyph.pinPalette(pinned: true, ink: 0x112233)
    let dim = PanelGlyph.pinPalette(pinned: false, ink: 0x112233)
    #expect(lit != dim)
    #expect(lit["P"] == PanelGlyph.pinnedTint)
    #expect(dim["P"] == 0x112233)
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

// MARK: - A tile's own mark

// Every badge is a square of the same size, because they are drawn beside one
// another in a list: one mark a pixel taller than its neighbour shifts the
// name beside it.
@Test func everyTileBadgeIsTheSameElevenBySquare() {
    for id in ["weather", "claude", "zai", "anecdotes", VPNConnector.id, "nothing-at-all"] {
        let map = PanelGlyph.tile(forConnectorId: id)
        #expect(map.count == 11, "\(id)")
        #expect(map.allSatisfy { $0.count == 11 }, "\(id)")
    }
}

// Two chars and no others: the shelf's colour, and the mark knocked out of it.
@Test func aTileBadgeIsAFieldAndAMarkAndNothingElse() {
    for id in ["weather", "claude", "anecdotes", VPNConnector.id] {
        let ink = Set(PanelGlyph.tile(forConnectorId: id).joined())
        #expect(ink == ["B", "G"], "\(id)")
    }
}

// The two coding subscription tiles wear ONE mark. They answer the same
// question about different accounts, and the account is what their names say.
@Test func claudeAndZaiWearTheSameTerminal() {
    #expect(PanelGlyph.tile(forConnectorId: "claude") == PanelGlyph.terminalTile)
    #expect(PanelGlyph.tile(forConnectorId: "zai") == PanelGlyph.terminalTile)
}

// A tile the table has not heard of is still visibly a tile.
@Test func aConnectorTheTableDoesNotKnowWearsTheQuestionMark() {
    #expect(PanelGlyph.tile(forConnectorId: "not-a-connector") == PanelGlyph.unknownTile)
}

// Every mark is distinguishable from every other. Five badges that differ only
// by colour would make the colour do all the work.
@Test func noTwoMarksAreTheSameShape() {
    let marks = [
        PanelGlyph.weatherTile, PanelGlyph.terminalTile, PanelGlyph.anecdoteTile,
        PanelGlyph.vpnTile, PanelGlyph.unknownTile,
    ]
    #expect(Set(marks.map { $0.joined() }).count == marks.count)
}

// A mark has to actually be drawn on the field, and not fill it either.
@Test func everyMarkIsDrawnAndLeavesItsFieldVisible() {
    for map in [
        PanelGlyph.weatherTile, PanelGlyph.terminalTile, PanelGlyph.anecdoteTile,
        PanelGlyph.vpnTile, PanelGlyph.unknownTile,
    ] {
        let lit = map.joined().filter { $0 == "G" }.count
        #expect(lit >= 8)
        #expect(lit <= 11 * 11 - 30)
    }
}

// One hue per SHELF, and four shelves that can be told apart.
@Test func eachShelfHasATintOfItsOwn() {
    let tints = TileCategory.allCases.map(PanelGlyph.categoryTint)
    #expect(Set(tints).count == TileCategory.allCases.count)
}

// The mark is white on the shelf's colour. Grey on a colour is a mark nobody
// sees, which is what the SF Symbol in `.secondary` was.
@Test func aBadgesMarkIsWhiteOnItsShelfsColour() {
    let palette = PanelGlyph.tilePalette(.dev)

    #expect(palette["G"] == 0xFFFFFF)
    #expect(palette["B"] == PanelGlyph.categoryTint(.dev))
}

// MARK: - The eye

// The card's eye: open on the tile the clock is showing, closed on every
// other tile with a page. One canvas for both, so the card does not shift
// when an eye opens.
@Test func bothEyesShareOneRectangularCanvas() {
    #expect(PanelGlyph.eyeOpen.count == PanelGlyph.eyeClosed.count)
    for map in [PanelGlyph.eyeOpen, PanelGlyph.eyeClosed] {
        #expect(map.allSatisfy { $0.count == PanelGlyph.eyeOpen[0].count })
    }
}

// Open is an almond with a lit pupil in its middle; closed is a lid drawn
// in the lower half with nothing lit above it — the upper lid is gone.
@Test func theOpenEyeHasAPupilAndTheClosedOneOnlyALowerLid() {
    let open = PanelGlyph.eyeOpen
    let closed = PanelGlyph.eyeClosed
    let middle = open.count / 2
    let centre = open[middle].index(open[middle].startIndex, offsetBy: open[middle].count / 2)
    #expect(open[middle][centre] != ".")
    // Lit at the top and the bottom: both lids.
    #expect(open.first?.contains { $0 != "." } == true)
    #expect(open.last?.contains { $0 != "." } == true)
    // Closed: nothing lit above the middle row.
    #expect(closed[..<middle].allSatisfy { $0.allSatisfy { $0 == "." } })
    #expect(closed.contains { $0.contains { $0 != "." } })
}

// Two inks: the open eye light, the closed one the card's grey.
@Test func theOpenEyeIsLightAndTheClosedOneGrey() {
    #expect(PanelGlyph.eyeInk(open: true, dark: true) == PanelGlyph.eyeInk(open: true, dark: false))
    #expect(PanelGlyph.eyeInk(open: false, dark: true) == PixelInk.secondary(dark: true))
    #expect(PanelGlyph.eyeInk(open: false, dark: false) == PixelInk.secondary(dark: false))
    let light = PanelGlyph.eyeInk(open: true, dark: true)
    let grey = PanelGlyph.eyeInk(open: false, dark: true)
    #expect((light & 0xFF) > (grey & 0xFF))
}

// MARK: - The store's shelves

private let everyShelf: [TileCategory?] = [nil] + TileCategory.allCases.map(Optional.some)

// Every shelf row in the store's sidebar wears a mark of its own, all on one
// nine-by-nine canvas so the labels beside them line up.
@Test func everyShelfMarkIsTheSameNineBySquareInOneInk() {
    for shelf in everyShelf {
        let map = PanelGlyph.shelfMark(shelf)
        #expect(map.count == 9, "\(String(describing: shelf))")
        #expect(map.allSatisfy { $0.count == 9 }, "\(String(describing: shelf))")
        #expect(Set(map.joined()).isSubset(of: [".", "G"]), "\(String(describing: shelf))")
        let lit = map.joined().filter { $0 == "G" }.count
        #expect(lit >= 12 && lit <= 81 - 24, "\(String(describing: shelf)): \(lit) lit")
    }
}

// Five shelves, five shapes: the colour must not do all the work.
@Test func noTwoShelvesWearTheSameMark() {
    let marks = everyShelf.map { PanelGlyph.shelfMark($0).joined() }
    #expect(Set(marks).count == everyShelf.count)
}

// A shelf row is drawn in its shelf's own colour — the tint the badges on its
// cards already wear — and All in a neutral that is none of them.
@Test func aShelfRowWearsItsShelfsTintAndAllANeutralOne() {
    for category in TileCategory.allCases {
        #expect(PanelGlyph.shelfTint(category) == PanelGlyph.categoryTint(category))
    }
    let all = PanelGlyph.shelfTint(nil)
    #expect(TileCategory.allCases.map(PanelGlyph.categoryTint).contains(all) == false)
    // Neutral: a grey, red, green and blue within a few steps of each other.
    let channels = [(all >> 16) & 0xFF, (all >> 8) & 0xFF, all & 0xFF]
    #expect((channels.max() ?? 0) - (channels.min() ?? 0) <= 8)
}

// Added is the Add button's own green, darkened: the same family, clearly
// the state after the act rather than the act.
@Test func theAddedGreenIsTheAddGreenDarkened() {
    let add = PanelGlyph.addTint
    let added = PanelGlyph.addedTint
    #expect(added != add)
    for shift: UInt32 in [16, 8, 0] {
        #expect((added >> shift) & 0xFF <= (add >> shift) & 0xFF)
    }
    // Still green: its green channel leads.
    #expect((added >> 8) & 0xFF > (added >> 16) & 0xFF)
    #expect((added >> 8) & 0xFF > added & 0xFF)
}

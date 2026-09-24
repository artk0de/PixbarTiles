import Foundation
import Testing
@testable import PixbarTilesApp

// MARK: - The panel header's mark: the app icon's P and sparkle, no plate
//
// One point per character: a P cell is 2 x 2 points, a sparkle cell is one
// point (the icon draws the sparkle on half-cells), the sparkle one P cell
// clear of the P and hanging one P cell above it — the icon's arrangement.

@Test func thePanelMarkIsTheIconsPAndSparkleAtTwoPointsACell() {
    #expect(PanelMark.map == [
        "..................#.#..",
        "..................#.#..",
        "bbbbbbbbbbbb....##...##",
        "bbbbbbbbbbbb...........",
        "bbbbbbbbbbbbbb..##...##",
        "bbbbbbbbbbbbbb....#.#..",
        "bbbbbb....bbbb....#.#..",
        "bbbbbb....bbbb.........",
        "wwwwww....wwww.........",
        "wwwwww....wwww.........",
        "wwwwwwwwwwwwww.........",
        "wwwwwwwwwwwwww.........",
        "wwwwwwwwwwww...........",
        "wwwwwwwwwwww...........",
        "pppppp.................",
        "pppppp.................",
        "pppppp.................",
        "pppppp.................",
        "pppppp.................",
        "pppppp.................",
    ].map { $0.replacingOccurrences(of: "#", with: "*") })
}

/// The mark takes the panel's device palettes, so it lights and goes out the
/// way the device drawings do: every key it uses has a colour online, and
/// offline the sparkle is gone while the P stays, greyed.
@Test func thePanelMarkLightsOnlineAndGreysOffline() {
    let keys = Set(PanelMark.map.joined()).subtracting(["."])
    #expect(keys == ["b", "w", "p", "*"])
    for dark in [true, false] {
        let on = PanelGlyph.devicePalette(dark: dark, live: true)
        let off = PanelGlyph.devicePalette(dark: dark, live: false)
        for key in keys { #expect((on[key] ?? nil) != nil) }
        #expect((off["*"] ?? nil) == nil)
        #expect(Set(["b", "w", "p"].map { off[Character($0)] ?? nil }).count == 1)
    }
}

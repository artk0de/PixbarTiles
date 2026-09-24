import Foundation
import Testing
@testable import PixbarTilesApp

// MARK: - The pure map -> raster core behind the panel's header clock
//
// The user's clock was the menu bar glyph until the PixbarTiles brand; these
// pins moved with it to the panel, where the map and its palettes still draw.

/// The glyph as rows of `#`/`.`. Pins the transcription without pixel
/// arithmetic: one art pixel is one character, the same reading the approved
/// generator's map is written in.
private func goldenASCII(of raster: UserClock.Raster) -> [String] {
    (0..<raster.height).map { y in
        String((0..<raster.width).map { x in raster.pixel(x: x, y: y) == 0 ? "." : "#" })
    }
}

/// The canvas is the art grid times the scale, in both dimensions, at every
/// scale the generator writes — a size that disagrees with 21x18 per art pixel
/// is the glyph macOS will stretch or crop on the bar.
@Test func theUserClockRasterMeasuresTwentyOneByEighteenPointsTimesTheScale() {
    #expect(UserClock.raster(palette: UserClock.darkOnline, scale: 1).width == 21)
    #expect(UserClock.raster(palette: UserClock.darkOnline, scale: 1).height == 18)
    #expect(UserClock.raster(palette: UserClock.lightOnline, scale: 3).width == 63)
    #expect(UserClock.raster(palette: UserClock.lightOnline, scale: 3).height == 54)
}

// The transcription itself, against the bold reading of the map the user
// approved. Every non-empty art pixel is ink whatever its colour, so the
// silhouette is what survives — and a row gained, lost or shifted by one in
// the port shows up here as a visible hole or bar rather than as a wrong
// colour somewhere. The bold body is one row taller at the bottom (the second
// wall row) and the feet hang one row lower for it; the canvas absorbs both.
@Test func theUserClockTranscriptionMatchesTheApprovedMapBold() {
    let ascii = goldenASCII(of: UserClock.raster(palette: UserClock.darkOnline, scale: 1))

    #expect(ascii == [
        "................##...",
        "................##.#.",
        "..........#.......#..",
        "........#.#.#.......#",
        "...###############...",
        "..#################..",
        ".###################.",
        ".###################.",
        ".###################.",
        ".###################.",
        ".###################.",
        ".###################.",
        ".###################.",
        ".###################.",
        "..#################..",
        "..#################..",
        "....##.........##....",
        ".....................",
    ])
}

// One colour per character, sampled from the source the user supplied. The
// dark bar takes the clock as drawn; these eight are the whole palette, and
// each is checked at a pixel that character and only that character occupies.
@Test func theDarkOnlinePaletteIsTheSourceAsDrawn() {
    let raster = UserClock.raster(palette: UserClock.darkOnline, scale: 1)

    #expect(raster.pixel(x: 10, y: 4) == 0xD0D2DC)  // F frame
    #expect(raster.pixel(x: 10, y: 2) == 0xB3B6C3)  // T shaded blocks and feet
    #expect(raster.pixel(x: 3, y: 6) == 0x0C0D10)   // M screen margin
    #expect(raster.pixel(x: 3, y: 7) == 0x0C0D10)   // S screen LED area
    #expect(raster.pixel(x: 6, y: 7) == 0x4FBAF6)   // b blue slider
    #expect(raster.pixel(x: 10, y: 7) == 0xEDEEF2)  // w white slider
    #expect(raster.pixel(x: 14, y: 7) == 0xBE55F9)  // p purple slider
    #expect(raster.pixel(x: 16, y: 0) == 0x66D0FA)  // * sparkle
    #expect(raster.pixel(x: 0, y: 0) == 0)          // off the body: empty
}

// The bold treatment: every stroke that carried one art pixel carries two.
// The slider stems are the thinnest ink on the clock and the first thing the
// bar washes out — each stem is two columns wide now, its knob where it was.
@Test func theBoldTranscriptionDoublesTheSliderStems() {
    let raster = UserClock.raster(palette: UserClock.darkOnline, scale: 1)

    // Both columns of each stem, on a stem row away from the knobs.
    #expect(raster.pixel(x: 6, y: 8) == 0x4FBAF6)
    #expect(raster.pixel(x: 7, y: 8) == 0x4FBAF6)
    #expect(raster.pixel(x: 10, y: 8) == 0xEDEEF2)
    #expect(raster.pixel(x: 11, y: 8) == 0xEDEEF2)
    #expect(raster.pixel(x: 14, y: 8) == 0xBE55F9)
    #expect(raster.pixel(x: 15, y: 8) == 0xBE55F9)
    // The knobs keep their places: blue's on the fourth LED row, as drawn.
    #expect(raster.pixel(x: 6, y: 10) == 0x4FBAF6)
    #expect(raster.pixel(x: 10, y: 10) == 0xEDEEF2)
    #expect(raster.pixel(x: 14, y: 9) == 0xBE55F9)
}

// The bottom wall carries the same two-pixel weight the top bar and the side
// walls have always had, and the feet hang one row lower for it.
@Test func theBoldBodyClosesTheBottomWallAtFullWeight() {
    let raster = UserClock.raster(palette: UserClock.darkOnline, scale: 1)

    #expect(raster.pixel(x: 10, y: 14) == 0xD0D2DC)  // wall row one
    #expect(raster.pixel(x: 10, y: 15) == 0xD0D2DC)  // wall row two — the +1
    #expect(raster.pixel(x: 4, y: 16) == 0xB3B6C3)   // foot, one row lower
    #expect(raster.pixel(x: 10, y: 16) == 0)         // between the feet: out
}

// The no-clock treatment: the clock keeps its frame, bevel and feet, and its
// screen draws NOTHING — no sliders, no sparkles. The figure the bar shows
// when no clock has ever been configured is a clock with an empty screen.
@Test func theEmptyStateLeavesTheScreenBlankAndTheBodyWhole() {
    let raster = UserClock.raster(
        palette: UserClock.empty(UserClock.darkOnline), scale: 1
    )

    // The screen's glass is still there; nothing is drawn on it.
    #expect(raster.pixel(x: 3, y: 7) == 0x0C0D10)
    #expect(raster.pixel(x: 10, y: 8) == 0)   // blue slider column: gone
    #expect(raster.pixel(x: 10, y: 7) == 0)   // white slider column: gone
    #expect(raster.pixel(x: 14, y: 8) == 0)   // purple slider column: gone
    #expect(raster.pixel(x: 16, y: 0) == 0)   // sparkle: gone
    #expect(raster.pixel(x: 10, y: 4) == 0xD0D2DC)  // frame, whole
    #expect(raster.pixel(x: 4, y: 16) == 0xB3B6C3)  // feet, whole
}

// Offline keeps the clock and puts its screen out: the three sliders go grey
// and dim, the sparkles go, and the body — frame, shading, screen — does not
// move. A state that changed the body would redraw the device, not its power.
@Test func theDarkOfflineGreysTheSlidersAndDropsTheSparkles() {
    let raster = UserClock.raster(palette: UserClock.darkOffline, scale: 1)

    #expect(raster.pixel(x: 6, y: 7) == 0x5C5E66)
    #expect(raster.pixel(x: 10, y: 7) == 0x5C5E66)
    #expect(raster.pixel(x: 14, y: 7) == 0x5C5E66)
    #expect(raster.pixel(x: 16, y: 0) == 0)

    #expect(raster.pixel(x: 10, y: 4) == 0xD0D2DC)
    #expect(raster.pixel(x: 3, y: 7) == 0x0C0D10)
}

// The light-bar treatment the user picked ("open screen"): the frame turns
// dark, the screen is left open for the bar to show through, the white slider
// turns the frame's ink, and the blue deepens just far enough to clear 3:1 on
// a light bar. Sparkles deepen with the blue rather than vanish.
@Test func theLightOnlinePaletteIsTheOpenScreenTreatment() {
    let raster = UserClock.raster(palette: UserClock.lightOnline, scale: 1)

    #expect(raster.pixel(x: 10, y: 4) == 0x1D1D1F)  // frame, dark
    #expect(raster.pixel(x: 10, y: 2) == 0x3A3A3F)  // blocks and feet, shaded
    #expect(raster.pixel(x: 3, y: 6) == 0)          // screen margin: open
    #expect(raster.pixel(x: 3, y: 7) == 0)          // screen: open
    #expect(raster.pixel(x: 6, y: 7) == 0x0A7FC2)   // blue, deepened
    #expect(raster.pixel(x: 10, y: 7) == 0x1D1D1F)  // white slider, now ink
    #expect(raster.pixel(x: 14, y: 7) == 0xBE55F9)  // purple, as drawn
    #expect(raster.pixel(x: 16, y: 0) == 0x0A7FC2)  // sparkles, deepened
}

// The light offline, by the same rule as the dark: sliders grey and dim, no
// sparkles, body unchanged.
@Test func theLightOfflineGreysTheSlidersAndDropsTheSparkles() {
    let raster = UserClock.raster(palette: UserClock.lightOffline, scale: 1)

    #expect(raster.pixel(x: 6, y: 7) == 0xA1A1A6)
    #expect(raster.pixel(x: 10, y: 7) == 0xA1A1A6)
    #expect(raster.pixel(x: 14, y: 7) == 0xA1A1A6)
    #expect(raster.pixel(x: 16, y: 0) == 0)

    #expect(raster.pixel(x: 10, y: 4) == 0x1D1D1F)
    #expect(raster.pixel(x: 3, y: 6) == 0)
}

// One art pixel is one point, so at @2x it is a 2x2 block of one colour and
// nothing else: no resampling, no half pixels — the property the whole map
// approach exists for. Checked on a sparkle (lit), the frame (lit) and the
// empty corner (empty), which are the three things scaling can get wrong.
@Test func theUserClockScalesAnArtPixelToScaleByScaleDevicePixels() {
    let raster = UserClock.raster(palette: UserClock.darkOnline, scale: 2)

    #expect(raster.width == 42)
    #expect(raster.height == 36)
    for y in 0...1 {
        for x in 32...33 {
            #expect(raster.pixel(x: x, y: y) == 0x66D0FA, "sparkle block at \(x),\(y)")
        }
    }
    for y in 8...9 {
        for x in 20...21 {
            #expect(raster.pixel(x: x, y: y) == 0xD0D2DC, "frame block at \(x),\(y)")
        }
    }
    #expect(raster.pixel(x: 0, y: 0) == 0)
    #expect(raster.pixel(x: 1, y: 1) == 0)
}

import Foundation
import Testing
@testable import PixbarTilesApp

// MARK: - The menu bar glyph: a pixel P on a screen, as device pixels

// Every check below is at @2x, where one point is two device pixels and the
// glyph's canvas is 56 x 36. The coordinates are the spec's points after the
// canvas shift of (1, 0.5) pt, times two: the P's top-left cell lands on
// device (21, 7), the bezel ring on columns 6 and 49 / rows 5 and 26, the red
// square on columns 47...54 / rows 0...7. Those are whole device pixels by
// construction, so each fact is a hard 0 or a hard 255 — no antialiasing
// tolerance is needed to state them.

private let white: UInt32 = 0xFFFFFF
private let black: UInt32 = 0x000000
private let red: UInt32 = 0xD6001C

private func glyph(_ state: PixbarGlyph.State, _ appearance: PixbarGlyph.Appearance = .dark)
    -> PixbarGlyph.Raster
{
    PixbarGlyph.raster(state, appearance: appearance, scale: 2)
}

/// Every device pixel of a raster, for the "nowhere" assertions.
private func allPixels(_ raster: PixbarGlyph.Raster) -> [PixbarGlyph.Pixel] {
    (0..<raster.height).flatMap { y in (0..<raster.width).map { raster.pixel(x: $0, y: y) } }
}

private func isInk(_ pixel: PixbarGlyph.Pixel, _ ink: UInt32 = white) -> Bool {
    pixel == PixbarGlyph.Pixel(rgb: ink, alpha: 255)
}

// The canvas is 28 x 18 pt at every scale — the bar caps an item's height at
// 18 pt, and the case with its feet is exactly that tall.
@Test func theGlyphMeasuresTwentyEightByEighteenPointsTimesTheScale() {
    for scale in 1...3 {
        let raster = PixbarGlyph.raster(.online, appearance: .dark, scale: scale)
        #expect(raster.width == 28 * scale)
        #expect(raster.height == 18 * scale)
    }
}

// The P is the app icon's: 7 x 9, a three-column stem, a six-row bowl with a
// 2 x 2 counter, the bowl's two right corners cut.
@Test func thePIsTheAppIconsP() {
    #expect(PixelP.map == [
        "######.",
        "#######",
        "###..##",
        "###..##",
        "#######",
        "######.",
        "###....",
        "###....",
        "###....",
    ])
}

// Online: the case is filled with ink, and the P's cells are knocked out of it
// — the bar shows through the letter. The counter and the cut corners are NOT
// P cells, so they stay ink.
@Test func onlineKnocksThePsCellsOutOfTheFilledCase() {
    let raster = glyph(.online)
    for (row, line) in PixelP.map.enumerated() {
        for (col, character) in line.enumerated() {
            for dy in 0...1 {
                for dx in 0...1 {
                    let pixel = raster.pixel(x: 21 + col * 2 + dx, y: 7 + row * 2 + dy)
                    if character == "#" {
                        #expect(pixel.alpha == 0, "P cell \(col),\(row) knocked out")
                    } else {
                        #expect(isInk(pixel), "screen at \(col),\(row) lit")
                    }
                }
            }
        }
    }
}

// The half-point bezel ring is knocked out too: one device pixel at @2x, at
// columns 6 and 49 and rows 5 and 26. Either side of it is lit case.
@Test func onlineKnocksTheHalfPointBezelRingOut() {
    let raster = glyph(.online)
    for x in 6...49 {
        #expect(raster.pixel(x: x, y: 5).alpha == 0, "top of the ring at \(x)")
        #expect(raster.pixel(x: x, y: 26).alpha == 0, "bottom of the ring at \(x)")
    }
    for y in 5...26 {
        #expect(raster.pixel(x: 6, y: y).alpha == 0, "left of the ring at \(y)")
        #expect(raster.pixel(x: 49, y: y).alpha == 0, "right of the ring at \(y)")
    }
    #expect(isInk(raster.pixel(x: 5, y: 15)))   // the case outside the ring
    #expect(isInk(raster.pixel(x: 7, y: 15)))   // the screen inside it
    #expect(isInk(raster.pixel(x: 15, y: 15)))
    #expect(isInk(raster.pixel(x: 50, y: 15)))
}

// The case's corners are a two-step pixel staircase, not a curve: on the
// case's first row the fill starts two points in, the canvas corner is empty.
@Test func onlineCutsTheCaseCornersAsAStaircase() {
    let raster = glyph(.online)
    #expect(raster.pixel(x: 0, y: 0).alpha == 0)
    #expect(raster.pixel(x: 5, y: 3).alpha == 0)    // inside the cut
    #expect(isInk(raster.pixel(x: 9, y: 3)))        // past the second step
    #expect(isInk(raster.pixel(x: 5, y: 15)))       // the straight side
    #expect(isInk(raster.pixel(x: 11, y: 31)))      // a foot
    #expect(!allPixels(raster).contains { $0.alpha > 0 && $0.rgb == red })
}

// Offline: the case is a 1.5-pt stroke (three device pixels at @2x) with the
// screen open, and the P is its outline — the edge half-point cells of its
// silhouette, one device pixel each. The stem's and the bowl's insides are
// empty.
@Test func offlineDrawsThePAsAHalfPointContourOnAnOpenScreen() {
    let raster = glyph(.offline)
    #expect(isInk(raster.pixel(x: 3, y: 15)))       // the left wall
    #expect(raster.pixel(x: 6, y: 15).alpha == 0)   // the open screen
    #expect(raster.pixel(x: 15, y: 15).alpha == 0)

    #expect(isInk(raster.pixel(x: 21, y: 7)))       // the P's top-left corner
    #expect(isInk(raster.pixel(x: 21, y: 20)))      // the stem's left edge
    #expect(isInk(raster.pixel(x: 26, y: 20)))      // the stem's right edge
    #expect(raster.pixel(x: 23, y: 20).alpha == 0)  // inside the stem
    #expect(isInk(raster.pixel(x: 26, y: 12)))      // round the counter
    #expect(raster.pixel(x: 28, y: 12).alpha == 0)  // the counter itself
    #expect(raster.pixel(x: 29, y: 8).alpha == 0)   // inside the bowl

    // The whole contour, cell for cell: a half-point cell of the silhouette is
    // ink exactly when a 4-neighbour of it lies outside.
    let inside = { (i: Int, j: Int) -> Bool in
        i >= 0 && j >= 0 && i < 14 && j < 18
            && Array(PixelP.map[j / 2])[i / 2] == "#"
    }
    for j in 0..<18 {
        for i in 0..<14 {
            let edge = inside(i, j)
                && (!inside(i - 1, j) || !inside(i + 1, j) || !inside(i, j - 1) || !inside(i, j + 1))
            let pixel = raster.pixel(x: 21 + i, y: 7 + j)
            #expect(edge ? isInk(pixel) : pixel.alpha == 0, "contour cell \(i),\(j)")
        }
    }
}

// The red square sits on the case's top-right corner, 4 x 4 pt, and a clear
// 1-pt moat round it cuts the stroke so the square reads apart from the case.
@Test func offlinePutsARedSquareInAClearMoatOnTheCorner() {
    let raster = glyph(.offline)
    for y in 0...7 {
        for x in 47...54 {
            #expect(raster.pixel(x: x, y: y) == PixbarGlyph.Pixel(rgb: red, alpha: 255),
                    "red at \(x),\(y)")
        }
    }
    for y in 0...9 {
        for x in [45, 46, 55] {
            #expect(raster.pixel(x: x, y: y).alpha == 0, "moat at \(x),\(y)")
        }
    }
    for x in 45...55 {
        #expect(raster.pixel(x: x, y: 8).alpha == 0, "moat at \(x),8")
        #expect(raster.pixel(x: x, y: 9).alpha == 0, "moat at \(x),9")
    }
    #expect(isInk(raster.pixel(x: 44, y: 2)))       // the top wall, past the moat
    #expect(isInk(raster.pixel(x: 52, y: 10)))      // the right wall, below it
    let reds = allPixels(raster).filter { $0.alpha > 0 && $0.rgb == red }
    #expect(reds.count == 64)
}

// Empty: the case and its feet, and nothing on the screen — no P, no badge.
@Test func emptyDrawsTheCaseAndNothingOnIt() {
    let raster = glyph(.empty)
    #expect(isInk(raster.pixel(x: 3, y: 15)))
    #expect(isInk(raster.pixel(x: 40, y: 2)))
    #expect(isInk(raster.pixel(x: 11, y: 31)))
    // Inside the stroke's inner staircase: rows 8..<24 and columns 5..<51
    // clear the two steps at every corner.
    for y in 8..<24 {
        for x in 5..<51 {
            #expect(raster.pixel(x: x, y: y).alpha == 0, "screen at \(x),\(y)")
        }
    }
    #expect(!allPixels(raster).contains { $0.alpha > 0 && $0.rgb == red })
    #expect(isInk(raster.pixel(x: 50, y: 5)))       // the corner, uncut: no moat
}

// The light bar takes black ink; the red stays red; the knockouts stay clear.
@Test func theLightBarDrawsInBlackInk() {
    let online = glyph(.online, .light)
    #expect(isInk(online.pixel(x: 15, y: 15), black))
    #expect(online.pixel(x: 21, y: 7).alpha == 0)
    #expect(online.pixel(x: 6, y: 15).alpha == 0)

    let offline = glyph(.offline, .light)
    #expect(isInk(offline.pixel(x: 3, y: 15), black))
    #expect(isInk(offline.pixel(x: 21, y: 7), black))
    #expect(offline.pixel(x: 50, y: 4) == PixbarGlyph.Pixel(rgb: red, alpha: 255))

    #expect(isInk(glyph(.empty, .light).pixel(x: 3, y: 15), black))
}

// Every scale comes from the one geometry: at @3x the canvas shift puts the
// half points on half device pixels, so the red square's 12 x 12 device
// pixels keep 11 whole columns (its left and right columns are half-covered),
// and the P's top-left cell still covers device (32, 11) whole.
@Test func everyScaleIsDrawnFromTheOneGeometry() {
    let triple = PixbarGlyph.raster(.offline, appearance: .dark, scale: 3)
    let reds = allPixels(triple).filter { $0.alpha == 255 && $0.rgb == red }
    #expect(reds.count == 132)
    let online = PixbarGlyph.raster(.online, appearance: .dark, scale: 3)
    #expect(online.pixel(x: 32, y: 11).alpha == 0)  // P cell (0,0): canvas (10.5, 3.5) pt
    #expect(isInk(online.pixel(x: 32 + 3 * 3, y: 11 + 3 * 2)))  // the counter
}

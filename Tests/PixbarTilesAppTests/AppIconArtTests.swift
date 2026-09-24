import Foundation
import Testing
@testable import PixbarTilesApp

// MARK: - The app icon: a pixel P and a sparkle on a 17 x 17 LED grid

// Spot checks on the 1024 master, sampled at pixel centres. At 1024 the grid
// cell is floor(1024 x 0.84 / 17) = 50 px, the grid starts at
// round((1024 - 850) / 2) = 87 px, a dot has radius 21 px, and grid cell
// (col, row) is centred on (87 + 50 col + 25, 87 + 50 row + 25). The pair
// sits at gx0 = 3, gy0 = 3, the P lifted a row: P row y on grid row 4 + y.

private func centre(_ col: Int, _ row: Int) -> (Int, Int) {
    (87 + 50 * col + 25, 87 + 50 * row + 25)
}

private func sample(_ at: (Int, Int)) -> PixbarGlyph.Pixel {
    PixbarIcon.sample(size: 1024, x: at.0, y: at.1)
}

@Test func theIconLayoutAt1024IsTheSpecsArithmetic() {
    let layout = PixbarIcon.layout(size: 1024)
    #expect(layout.inset == 82)
    #expect(layout.cell == 50)
    #expect(layout.origin == 87)
    #expect(PixbarIcon.gx0 == 3)
    #expect(PixbarIcon.gy0 == 3)
}

// The plate is #141417, opaque; outside it, past the rounded corner, nothing.
@Test func thePlateIsNearBlackAndRounded() {
    #expect(sample((487, 512)) == PixbarGlyph.Pixel(rgb: 0x141417, alpha: 255))  // between dots
    #expect(sample((85, 512)) == PixbarGlyph.Pixel(rgb: 0x141417, alpha: 255))   // the grid's margin
    #expect(sample((10, 10)).alpha == 0)
    #expect(sample((90, 90)).alpha == 0)    // inside the inset square, outside the corner
    #expect(sample((1020, 512)).alpha == 0)
}

// The P's lit cells by row band: rows 0-2 blue, 3-5 white, 6-8 purple.
@Test func thePsCellsAreLitInThreeBands() {
    #expect(sample(centre(3, 4)) == PixbarGlyph.Pixel(rgb: 0x4FB8F5, alpha: 255))   // P (0, 0)
    #expect(sample(centre(8, 5)) == PixbarGlyph.Pixel(rgb: 0x4FB8F5, alpha: 255))   // P (5, 1)
    #expect(sample(centre(3, 7)) == PixbarGlyph.Pixel(rgb: 0xEEF0F4, alpha: 255))   // P (0, 3)
    #expect(sample(centre(9, 7)) == PixbarGlyph.Pixel(rgb: 0xEEF0F4, alpha: 255))   // P (6, 3)
    #expect(sample(centre(3, 12)) == PixbarGlyph.Pixel(rgb: 0xB65CF5, alpha: 255))  // P (0, 8)
}

// Not every cell of the P's box is lit: the counter and the cut corners are
// unlit dots — white at 6 % over the plate.
@Test func theUnlitDotsAreFaint() {
    let faint = PixbarGlyph.Pixel(
        rgb: (UInt32((0x14 * 0.94 + 255 * 0.06).rounded()) << 16)
            | (UInt32((0x14 * 0.94 + 255 * 0.06).rounded()) << 8)
            | UInt32((0x17 * 0.94 + 255 * 0.06).rounded()),
        alpha: 255
    )
    #expect(sample(centre(0, 8)) == faint)
    #expect(sample(centre(6, 6)) == faint)   // the counter, P (3, 2)
    #expect(sample(centre(9, 4)) == faint)   // the cut corner, P (6, 0)
    #expect(sample(centre(15, 15)) == faint)
}

// The plate's corner radius (0.225 of the canvas) is wider than the grid's
// margin, so the four corner dots of the grid fall off the plate: the oracle
// draws them anyway, white at 6 % over nothing.
@Test func theGridsCornerDotsFallOffThePlate() {
    let offPlate = PixbarGlyph.Pixel(rgb: 0xFFFFFF, alpha: 15)
    #expect(sample(centre(0, 0)) == offPlate)
    #expect(sample(centre(16, 0)) == offPlate)
    #expect(sample(centre(0, 16)) == offPlate)
    #expect(sample(centre(16, 16)) == offPlate)
}

// The sparkle: an open plus of half-cell squares, cyan, its top-left at grid
// (gx0 + 8, gy0). An edge cell is one with a 4-neighbour outside the solid
// plus, so the concave corners stay open, and the four arm tips are removed.
@Test func theSparkleIsACyanOpenPlus() {
    #expect(PixbarIcon.sparkle == [
        "..#.#..",
        "..#.#..",
        "##...##",
        ".......",
        "##...##",
        "..#.#..",
        "..#.#..",
    ])
    // Half-cell (2, 0): centre (637 + 62.5, 237 + 12.5), a 34 px square.
    #expect(sample((700, 250)) == PixbarGlyph.Pixel(rgb: 0x63D1FF, alpha: 255))
    // Half-cell (4, 6): centre (637 + 112.5, 237 + 162.5).
    #expect(sample((750, 400)) == PixbarGlyph.Pixel(rgb: 0x63D1FF, alpha: 255))
    // The removed tip (3, 0) is not cyan.
    #expect(sample((724, 249)).rgb != 0x63D1FF)
}

import CoreGraphics
import PixbarKit
import Testing
@testable import PixbarTilesApp

// The wordmark's two facts that are not a matter of pixels on the screen: the
// drawn word IS the clock's own tiny face spelling PIXBAR, and "Tiles" sits
// where the approved design put it — its capitals centred 1.5 clock pixels
// above PIXBAR's centre, at every pixel size.

// The approved bitmap, as the mockup the user picked drew it. Pinned letter by
// letter so a changed glyph in the tiny face shows up here as a decision, not
// as a wordmark that quietly changed shape.
@Test func theDrawnWordIsPIXBARInTheTinyFace() {
    let approved = [
        "###.###.#.#.##...#..##.",
        "#.#..#..#.#.#.#.#.#.#.#",
        "###..#...#..##..###.##.",
        "#....#..#.#.#.#.#.#.#.#",
        "#...###.#.#.##..#.#.#.#",
    ].map { $0.replacingOccurrences(of: "#", with: String(PanelGlyph.wordInk)) }

    #expect(Wordmark.drawn == "PIXBAR")
    #expect(Wordmark.map == approved)
    #expect(Wordmark.map == PanelGlyph.text("PIXBAR", in: PixelFont.tiny))
}

// Tiles' baseline above PIXBAR's bottom edge. PIXBAR is five pixels tall, so
// its centre is 2.5 pixels up; the capitals' centre is 1.5 pixels higher, and
// the baseline half a cap height below that.
@Test func tilesBaselineRiseIsFromThePixelSizeAndTheCapHeight() {
    #expect(Wordmark.baselineRise(pixel: 2, capHeight: 9) == 3.5)
    #expect(Wordmark.baselineRise(pixel: 3, capHeight: 13) == 5.5)
    #expect(Wordmark.baselineRise(pixel: 1, capHeight: 4) == 2)
}

// The invariant itself, at any size: Tiles' cap centre minus PIXBAR's centre
// is always one and a half clock pixels.
@Test func tilesCapitalsSitOneAndAHalfPixelsAboveThePixelWordsCentre() {
    for pixel in [1.0, 2.0, 2.5, 3.0, 4.0] as [CGFloat] {
        for capHeight in [7.0, 9.4, 13.0] as [CGFloat] {
            let capCentre = Wordmark.baselineRise(pixel: pixel, capHeight: capHeight) + capHeight / 2
            let markCentre = CGFloat(Wordmark.map.count) * pixel / 2
            #expect(abs((capCentre - markCentre) - 1.5 * pixel) < 0.000_1)
        }
    }
}

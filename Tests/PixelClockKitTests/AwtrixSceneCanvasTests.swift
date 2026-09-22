// Tests/PixelClockKitTests/AwtrixSceneCanvasTests.swift
import Testing
@testable import PixelClockKit

// The AWTRIX scene drawn onto the raster the preview shows. The device draws
// the text with its own font; the canvas draws it with the kit's — the same
// words at the same place, which is what a preview can promise before the
// BDF font lands (the follow-up that widens the glyph set).

@Suite struct AwtrixSceneCanvasTests {
    @Test func theCanvasIsTheAWTRIXPanelsSize() {
        let canvas = AwtrixScene(text: "-").canvas()
        #expect(canvas.width == 32)
        #expect(canvas.height == 16)
        #expect(canvas[31, 15] == .black)   // the whole panel exists to draw on
    }

    // One dash, scale 2, centred: 6 px wide at x = (32 − 6) / 2, on glyph
    // row 2 of a block starting at y = (16 − 10 − 2) / 2 — rows 6–7 at the
    // double height, one band above the progress bar's.
    @Test func theTextIsCentredAtTheDoubleHeight() {
        let canvas = AwtrixScene(text: "-").canvas()
        #expect(canvas[13, 6] == .white)
        #expect(canvas[18, 7] == .white)
        #expect(canvas[12, 6] == .black)    // nothing left of the centred block
    }

    @Test func theSceneColourInksTheText() {
        let canvas = AwtrixScene(text: "-", color: "#FF0000").canvas()
        #expect(canvas[13, 6] == Pixel(red: 255, green: 0, blue: 0))
    }

    // A word wider than the double height allows drops to the single height
    // rather than off the panel's sides.
    @Test func aLongTextFallsToTheSingleHeight() {
        let canvas = AwtrixScene(text: "WK 1234").canvas()
        // Seven characters at scale 2 would be 54 px wide — more than the 32
        // the panel has. At scale 1 they are 27, centred at x = 2, on glyph
        // rows 4–8.
        #expect(canvas[2, 4] == .white)     // W's top-left, scale 1
        #expect(canvas[3, 2] == .black)     // above the single-height band
    }

    @Test func theProgressBarFillsFromTheLeftOverItsTrack() {
        let canvas = AwtrixScene(
            text: "-",
            progress: ProgressBar(percent: 50, fill: "#00FF00", track: "#222222")
        ).canvas()
        // The bar is the panel's bottom band: the whole width is track, the
        // left half is fill.
        #expect(canvas[0, 14] == Pixel(red: 0, green: 255, blue: 0))
        #expect(canvas[15, 15] == Pixel(red: 0, green: 255, blue: 0))
        #expect(canvas[16, 14] == Pixel(red: 0x22, green: 0x22, blue: 0x22))
        #expect(canvas[31, 15] == Pixel(red: 0x22, green: 0x22, blue: 0x22))
    }

    @Test func anIconReferenceDrawsNothingOnItsOwn() {
        // An icon is a reference, not pixels: the canvas draws the words and
        // leaves the mark to the device's flash, which the preview does not
        // have.
        let canvas = AwtrixScene(text: "-", icon: .bundled("clouds.gif")).canvas()
        #expect(canvas[13, 6] == .white)    // the text still draws
        #expect(canvas[0, 0] == .black)     // and no corner art appears
    }
}

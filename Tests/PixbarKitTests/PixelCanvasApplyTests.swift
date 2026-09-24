// Tests/PixbarKitTests/PixelCanvasApplyTests.swift
import Testing
@testable import PixbarKit

// The canvas speaking the device's own draw vocabulary: a scene's `draw[]`
// commands painted onto the raster the preview shows. The bitmap case is the
// one every shipped face uses; the geometry cases exist so the preview draws
// any face the kit holds (the idle dot is a filledCircle), clipped the way
// the canvas's own primitives clip.

@Suite struct PixelCanvasApplyTests {
    @Test func bitmapCommandBlitsItsPackedPixels() {
        var canvas = PixelCanvas()
        canvas.apply(
            .bitmap(
                width: 2, height: 1,
                pixels: [0xFF_00_00, 0x00_FF_00],
                at: PixelPoint(x: 10, y: 5)
            )
        )
        #expect(canvas[10, 5] == Pixel(red: 255, green: 0, blue: 0))
        #expect(canvas[11, 5] == Pixel(red: 0, green: 255, blue: 0))
    }

    @Test func filledCircleCommandPaintsTheDisc() {
        var canvas = PixelCanvas()
        canvas.apply(.filledCircle(center: PixelPoint(x: 6, y: 6), radius: 2, .white))
        #expect(canvas[6, 6] == .white)   // the center
        #expect(canvas[6 + 2, 6] == .white)  // the right arm
        #expect(canvas[6, 6 - 2] == .white)  // the top arm
        #expect(canvas[6 + 1, 6 + 1] == .white) // inside the radius
        #expect(canvas[6 + 3, 6] == .black)  // beyond it
    }

    @Test func circleCommandPaintsTheRingAndLeavesTheCenter() {
        var canvas = PixelCanvas()
        canvas.apply(.circle(center: PixelPoint(x: 6, y: 6), radius: 2, .white))
        #expect(canvas[6 + 2, 6] == .white)   // the ring's four extremes
        #expect(canvas[6 - 2, 6] == .white)
        #expect(canvas[6, 6 + 2] == .white)
        #expect(canvas[6, 6 - 2] == .white)
        #expect(canvas[6, 6] == .black)       // the center is not the ring's
    }

    @Test func rectCommandOutlinesAndFilledRectFills() {
        var outlined = PixelCanvas()
        outlined.apply(.rect(x: 1, y: 1, w: 4, h: 4, .white))
        #expect(outlined[1, 1] == .white)
        #expect(outlined[4, 4] == .white)
        #expect(outlined[2, 2] == .black)     // the inside stays empty

        var filled = PixelCanvas()
        filled.apply(.filledRect(x: 1, y: 1, w: 4, h: 4, .white))
        #expect(filled[2, 2] == .white)
    }

    @Test func lineAndPixelCommandsPaintWhereTheySay() {
        var canvas = PixelCanvas()
        canvas.apply([
            .pixel(PixelPoint(x: 0, y: 0), .white),
            .line(PixelPoint(x: 2, y: 2), PixelPoint(x: 5, y: 2), .white),
        ])
        #expect(canvas[0, 0] == .white)
        #expect(canvas[2, 2] == .white)
        #expect(canvas[5, 2] == .white)
        #expect(canvas[3, 3] == .black)
    }

    @Test func textCommandDrawsThroughTheCanvasFontAtItsHeights() {
        var small = PixelCanvas()
        small.apply(.text("A", at: PixelPoint(x: 0, y: 0), color: .white, font: .small))
        #expect(small[1, 0] == .white)   // ".#." — the top row's one column
        #expect(small[1, 2] == .white)   // "###" — the middle row

        var large = PixelCanvas()
        large.apply(.text("-", at: PixelPoint(x: 0, y: 0), color: .white, font: .large))
        // The dash lives on glyph row 2; at the large height (scale 2) that is
        // rows 4–5, columns 0–5.
        #expect(large[0, 4] == .white)
        #expect(large[5, 5] == .white)
    }

    @Test func commandsClipInsteadOfCrashing() {
        var canvas = PixelCanvas()
        canvas.apply([
            .pixel(PixelPoint(x: 100, y: 100), .white),
            .rect(x: 50, y: 14, w: 10, h: 10, .white),
            .filledCircle(center: PixelPoint(x: 51, y: 15), radius: 4, .white),
            .circle(center: PixelPoint(x: 0, y: 0), radius: 3, .white),
            .bitmap(width: 2, height: 2, pixels: [0xFF_FF_FF, 0, 0, 0], at: PixelPoint(x: 51, y: 15)),
        ])
        #expect(canvas[51, 15] == .white)   // what reached the corner got painted
        #expect(canvas[47, 13] == .black)   // what did not, did not wrap
    }
}

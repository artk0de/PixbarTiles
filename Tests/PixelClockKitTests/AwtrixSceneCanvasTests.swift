// Tests/PixelClockKitTests/AwtrixSceneCanvasTests.swift
import Testing
@testable import PixelClockKit

// The AWTRIX scene drawn onto the raster the preview shows.
//
// The panel is 32×8. It was written here as 32×16 and pinned that way, which
// put the progress bar on rows the hardware does not have and centred a
// double-height line half below the glass — a preview that could not be
// compared against the clock standing next to it. `prototype/awtrix/client.py`
// has said "32x8 matrix buffer as 256 packed 0xRRGGBB values" since the
// prototype.
//
// What a preview can promise: the same words, in the same place, at the same
// size, with the icon's eight columns kept clear because the device draws its
// own art there from its flash. What it cannot: the device's exact glyphs.

@Suite struct AwtrixSceneCanvasTests {
    @Test func theCanvasIsTheAWTRIXPanelsSize() {
        let canvas = AwtrixScene(text: "-").canvas()
        #expect(canvas.width == 32)
        #expect(canvas.height == 8)
    }

    // One line, no icon and no bar: the whole panel is the text's, and the
    // glyphs sit centred in it.
    @Test func theTextIsCentredOnAnOtherwiseEmptyPanel() {
        let canvas = AwtrixScene(text: "12%").canvas()
        let lit = canvas.litColumns()
        // Three glyphs at the 5×7 cell: 3 × 6 − 1 = 17 columns, centred in 32
        // → the first lit column cannot be before 7 nor after 9.
        #expect(lit.first ?? 0 >= 7)
        #expect(lit.last ?? 0 <= 24)
        #expect(canvas.litRows().isEmpty == false)
    }

    @Test func theSceneColourInksTheText() {
        let canvas = AwtrixScene(text: "-", color: "#FF0000").canvas()
        let inked = (0..<canvas.width).flatMap { x in
            (0..<canvas.height).map { y in canvas[x, y] }
        }
        #expect(inked.contains(Pixel(red: 255, green: 0, blue: 0)))
        #expect(inked.contains(.white) == false)
    }

    // The device fetches an icon's pixels from its own flash, so the preview
    // cannot draw the art — but it MUST keep the columns, or every word sits
    // where it will not sit on the clock.
    @Test func anIconKeepsItsEightColumnsClearAndPushesTheTextRight() {
        let withIcon = AwtrixScene(text: "12%", icon: .bundled("ClaudeStar")).canvas()
        let without = AwtrixScene(text: "12%").canvas()

        #expect(withIcon.litColumns().allSatisfy { $0 >= AwtrixScene.iconColumns })
        #expect((withIcon.litColumns().first ?? 0) > (without.litColumns().first ?? 0))
    }

    // The bar is the panel's LAST row — row 7, the one the firmware fills
    // under an app's text. It used to be drawn on rows 14 and 15.
    @Test func theProgressBarFillsTheBottomRowFromTheLeft() {
        let canvas = AwtrixScene(
            text: "-",
            progress: ProgressBar(percent: 50, fill: "#00FF00", track: "#222222")
        ).canvas()

        #expect(canvas[0, 7] == Pixel(red: 0, green: 255, blue: 0))
        #expect(canvas[15, 7] == Pixel(red: 0, green: 255, blue: 0))
        #expect(canvas[16, 7] == Pixel(red: 0x22, green: 0x22, blue: 0x22))
        #expect(canvas[31, 7] == Pixel(red: 0x22, green: 0x22, blue: 0x22))
    }

    // With a bar under it the text gets seven rows rather than eight, so a
    // line that would have been centred moves up rather than being drawn
    // through the bar.
    @Test func theTextClearsTheBarRatherThanBeingDrawnThroughIt() {
        let barred = AwtrixScene(
            text: "12%", progress: ProgressBar(percent: 100, fill: "#00FF00", track: "#222222")
        ).canvas()
        // Nothing of the text reaches the bar's row: every lit pixel on row 7
        // is the bar's own fill colour.
        for x in 0..<barred.width {
            #expect(barred[x, 7] == Pixel(red: 0, green: 255, blue: 0))
        }
    }

    // MARK: - Scrolling

    // A line too wide for the panel is what the firmware SCROLLS, so a
    // single still frame of its first 32 columns is not what the clock shows.
    // The preview answers with the frames of that scroll.
    @Test func aLineTooWideForThePanelScrollsAcrossSeveralFrames() {
        let long = AwtrixScene(text: "ВНИМАНИЕ, АНЕКДОТ!")
        let frames = long.canvasFrames()

        #expect(frames.count > 1)
        #expect(frames.allSatisfy { $0.width == 32 && $0.height == 8 })
        // Successive frames differ: the words move.
        #expect(frames[0] != frames[1])
    }

    @Test func aLineThatFitsIsOneStillFrame() {
        #expect(AwtrixScene(text: "12%").canvasFrames().count == 1)
        #expect(AwtrixScene(text: "12%").canvasFrames().first == AwtrixScene(text: "12%").canvas())
    }

    // Cyrillic is what the anecdote banner is written in, and the panel drew
    // it as an empty box while the font carried no alphabet. The X11 face
    // does, and the preview draws through it.
    @Test func aCyrillicBannerDrawsInkRatherThanAnEmptyPanel() {
        let canvas = AwtrixScene(text: "АНЕКДОТ").canvas()
        #expect(canvas.litColumns().isEmpty == false)
    }
}

// MARK: - Reading a canvas back

extension PixelCanvas {
    /// Columns with any lit pixel — what "where did the words land" asks,
    /// without pinning a glyph's own shape.
    func litColumns() -> [Int] {
        (0..<width).filter { x in (0..<height).contains { y in self[x, y] != .black } }
    }

    func litRows() -> [Int] {
        (0..<height).filter { y in (0..<width).contains { x in self[x, y] != .black } }
    }
}

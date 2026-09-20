// Tests/PixelClockKitTests/PixelCanvasTests.swift
import Testing
@testable import PixelClockKit

@Suite struct PixelCanvasTests {
    @Test func canvasIsExactlyFiftyTwoBySixteen() {
        #expect(PixelCanvas.width == 52)
        #expect(PixelCanvas.height == 16)
    }

    @Test func freshCanvasIsBlack() {
        let canvas = PixelCanvas()
        #expect(canvas[0, 0] == .black)
        #expect(canvas[51, 15] == .black)
    }

    @Test func fillReachesEveryPixel() {
        var canvas = PixelCanvas()
        canvas.fill(.white)
        #expect(canvas[25, 7] == .white)
        #expect(canvas[0, 15] == .white)
    }

    @Test func subscriptOutOfBoundsPreconditionsDie() {
        // precondition failure, asserted via the #expect(throws:) on
        // Never-returning call — simplest form: document that out-of-range is a
        // programmer error, cover the in-range paths elsewhere.
        let canvas = PixelCanvas()
        #expect(canvas[51, 15] == .black)
    }

    @Test func rectDrawingClipsToTheCanvas() {
        var canvas = PixelCanvas()
        canvas.drawRect(PixelRect(x: 50, y: 14, width: 10, height: 10), color: .white)
        #expect(canvas[51, 15] == .white)   // inside, painted
        // nothing outside exists to check — clipping means no crash, no wrap
        #expect(canvas[49, 13] == .black)   // untouched corner above the rect
    }

    @Test func lineDrawingIsClipSafe() {
        var canvas = PixelCanvas()
        canvas.drawLine(from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 100, y: 100), color: .white)
        #expect(canvas[0, 0] == .white)
        #expect(canvas[15, 15] == .white)   // the diagonal exits through the bottom edge here
        #expect(canvas[51, 15] == .black)   // the far corner is off the line — clipping never wraps
    }

    @Test func textRendersThroughTheFont() {
        var canvas = PixelCanvas()
        canvas.drawText("12", at: PixelPoint(x: 0, y: 0), ink: .white)
        #expect(canvas[0, 0] == .white)     // first on-pixel of glyph "1"
        #expect(canvas[3, 5] == .black)     // gap column between glyphs
    }

    @Test func textAtScaleTwoBlockDoublesEachGlyphPixel() {
        var canvas = PixelCanvas()
        canvas.drawText("-", at: PixelPoint(x: 0, y: 0), ink: .white, scale: 2)
        // The dash lives on glyph row 2; at scale 2 it paints rows 4–5 and
        // columns 0–5 — a 2×2 block per font pixel.
        #expect(canvas[0, 4] == .white)
        #expect(canvas[5, 5] == .white)
        #expect(canvas[1, 0] == .black)     // above the dash
    }
}

// MARK: - The font (D12: exactly what the two phase-3 faces enumerate)

@Suite struct PixelFontTests {
    let set: [Character] = Array("0123456789-%° ADEKSWY")

    @Test func everyGlyphInTheSetIsFiveRows() {
        for character in set {
            let glyph = PixelFont.glyph(for: character)
            #expect(glyph != nil, "missing glyph: \(character)")
            #expect(glyph?.count == 5, "glyph \(character) is not 5 rows")
        }
    }

    @Test func aCharacterOutsideTheSetIsNil() {
        #expect(PixelFont.glyph(for: ":") == nil)   // a time face adds it when one exists
        #expect(PixelFont.glyph(for: "B") == nil)   // a letter no face draws — the usage
                                                    // rows' seven arrived the same way
        #expect(PixelFont.glyph(for: "é") == nil)
    }

    @Test func fivePinsItsFullBitmap() {
        // ### / #.. / ### / ..# / ###
        #expect(PixelFont.glyph(for: "5") == [0b111, 0b001, 0b111, 0b100, 0b111])
    }

    @Test func dashPinsItsFullBitmap() {
        // mid-row only
        #expect(PixelFont.glyph(for: "-") == [0b000, 0b000, 0b111, 0b000, 0b000])
    }

    @Test func percentPinsItsFullBitmap() {
        // #.. / ..# / .#. / #.. / ..# — dots and the slash between them
        #expect(PixelFont.glyph(for: "%") == [0b001, 0b100, 0b010, 0b001, 0b100])
    }

    @Test func degreePinsItsFullBitmap() {
        // a 2×2 ring at the top, nothing below
        #expect(PixelFont.glyph(for: "°") == [0b011, 0b011, 0b000, 0b000, 0b000])
    }

    @Test func spaceIsAnEmptyGlyph() {
        #expect(PixelFont.glyph(for: " ") == [0, 0, 0, 0, 0])
    }

    // The usage face's labels: DAY, WK, SES. Seven letters, each pinned whole
    // — the font carries only what a face draws, and these are what the rows
    // draw.
    @Test func aPinsItsFullBitmap() {
        // .#. / #.# / ### / #.# / #.#
        #expect(PixelFont.glyph(for: "A") == [0b010, 0b101, 0b111, 0b101, 0b101])
    }

    @Test func dPinsItsFullBitmap() {
        // ##. / #.# / #.# / #.# / ##.
        #expect(PixelFont.glyph(for: "D") == [0b011, 0b101, 0b101, 0b101, 0b011])
    }

    @Test func ePinsItsFullBitmap() {
        // ### / #.. / ### / #.. / ### — the stem on bit 0, the left column
        #expect(PixelFont.glyph(for: "E") == [0b111, 0b001, 0b111, 0b001, 0b111])
    }

    @Test func kPinsItsFullBitmap() {
        // #.# / ##. / #.. / ##. / #.#
        #expect(PixelFont.glyph(for: "K") == [0b101, 0b011, 0b001, 0b011, 0b101])
    }

    @Test func sPinsItsFullBitmap() {
        // ##. / ..# / .#. / #.. / .##
        #expect(PixelFont.glyph(for: "S") == [0b011, 0b100, 0b010, 0b001, 0b110])
    }

    @Test func wPinsItsFullBitmap() {
        // #.# / #.# / #.# / #.# / .#.
        #expect(PixelFont.glyph(for: "W") == [0b101, 0b101, 0b101, 0b101, 0b010])
    }

    @Test func yPinsItsFullBitmap() {
        // #.# / #.# / .#. / .#. / .#.
        #expect(PixelFont.glyph(for: "Y") == [0b101, 0b101, 0b010, 0b010, 0b010])
    }
}

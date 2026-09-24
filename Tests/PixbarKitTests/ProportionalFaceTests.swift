// Tests/PixbarKitTests/ProportionalFaceTests.swift
import Testing
@testable import PixbarKit

// The usage face's font: five rows for every glyph, widths by the glyph —
// `:` `.` and space one column, `w` and `m` five, the rest three — and one
// column of gap after each. The table is the approved design's (the
// `tc002-face-mockup` skill's `gen.py`, `G`), so the widths below are gen.py's
// own `text_width` answers, and the pixel oracle in `UsageFaceOracleTests`
// holds every drawn column to it.
@Suite struct ProportionalFaceTests {
    private let face = PixelFont.proportional

    @Test func everyGlyphIsFiveRowsTall() {
        #expect(face.height == 5)
    }

    @Test func narrowAndWideGlyphsTakeTheirOwnWidth() {
        #expect(face.width(of: "w", scale: 1) == 5)
        #expect(face.width(of: "s", scale: 1) == 3)
        #expect(face.width(of: ":", scale: 1) == 1)
        #expect(face.width(of: "m.: ", scale: 1) == 11)
    }

    @Test func aLineMeasuresWhatTheDesignMeasures() {
        #expect(face.width(of: "100%", scale: 1) == 15)
        #expect(face.width(of: "rst 14:30", scale: 1) == 31)
        #expect(face.width(of: "rst 26 sep 15:00", scale: 1) == 55)
        #expect(face.width(of: "", scale: 1) == 0)
    }

    // Every mark a reset or a percentage can spell — the digits, the month
    // abbreviations, the labels — has a shape of its own.
    @Test func everyMarkTheUsageFaceSpellsIsCovered() {
        let spelled = "0123456789%-:. rstw" + "jan feb mar apr may jun jul aug sep oct nov dec"
        for character in spelled {
            #expect(face.covers(character), "no glyph for \(character)")
        }
    }

    // A wide glyph draws all five columns and advances past them: `w` then
    // `:` lands the colon on column six, not on column four.
    @Test func aWideGlyphDrawsAllItsColumnsAndAdvancesPastThem() {
        var canvas = PixelCanvas(width: 8, height: 5)
        canvas.drawText("w:", at: .zero, ink: .white, font: face)
        let lit = (0..<5).map { y in
            String((0..<8).map { x in canvas[x, y] == .white ? "#" : "." })
        }
        #expect(lit == [
            "#...#...",
            "#...#.#.",
            "#.#.#...",
            "#.#.#.#.",
            ".#.#....",
        ])
    }

    // The fixed faces measure exactly as they did: a glyph width of their
    // own is the proportional face's, and nobody else's.
    @Test func theFixedFacesStillMeasureByTheirCell() {
        #expect(PixelFont.tiny.width(of: "wm:", scale: 1) == 11)
        #expect(PixelFont.standard.width(of: "wm:", scale: 2) == 34)
    }
}

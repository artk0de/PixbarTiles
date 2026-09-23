// Tests/PixelClockKitTests/PixelFontTests.swift
import Testing
@testable import PixelClockKit

// The kit's two faces, and the one property that made the preview lie: a
// character the font does not carry used to be drawn as NOTHING — the cursor
// advanced and the panel kept a hole where a letter belonged. "H45%" lost its
// H, "feels 12°" lost every letter it had. A font that cannot draw a mark now
// draws the substitute, so a gap on the panel means a space and nothing else.

// The per-glyph bitmaps are pinned next door in `PixelCanvasTests`; this suite
// is about the FACES — their cells, their coverage and what they do with a
// mark they cannot spell.
@Suite struct PixelFontFaceTests {
    // MARK: - The faces themselves

    @Test func theTinyFaceIsTheThreeByFiveCellTheBandsAreBuiltFor() {
        #expect(PixelFont.tiny.width == 3)
        #expect(PixelFont.tiny.height == 5)
        // The advance the bands have always stepped by: three columns and one
        // gap. Changing it moves every face that places text from an edge.
        #expect(PixelFont.tiny.advance == 4)
    }

    @Test func theStandardFaceIsTheX11FiveBySevenCell() {
        #expect(PixelFont.standard.width == 5)
        #expect(PixelFont.standard.height == 7)
        #expect(PixelFont.standard.advance == 6)
    }

    // MARK: - Coverage

    @Test func everyPrintableASCIIMarkIsDrawableInBothFaces() {
        var missingTiny: [Character] = []
        var missingStandard: [Character] = []
        for code in 0x20...0x7E {
            let character = Character(UnicodeScalar(UInt8(code)))
            if PixelFont.tiny.covers(character) == false { missingTiny.append(character) }
            if PixelFont.standard.covers(character) == false {
                missingStandard.append(character)
            }
        }
        #expect(missingTiny.isEmpty, "tiny is missing \(missingTiny)")
        #expect(missingStandard.isEmpty, "standard is missing \(missingStandard)")
    }

    // The X11 face is the one the live TC002 demo drew Russian with, so the
    // alphabet is a shipped capability rather than an accident of the table.
    @Test func theStandardFaceCarriesTheCyrillicAlphabet() {
        for character in "АБВГДЕЁЖЗИЙКЛМНОПРСТУФХЦЧШЩЪЫЬЭЮЯабвгдеёжзийклмнопрстуфхцчшщъыьэюя" {
            #expect(PixelFont.standard.covers(character), "no glyph for \(character)")
        }
    }

    // The degree sign is not ASCII and every weather face draws one.
    @Test func bothFacesCarryTheDegreeSign() {
        #expect(PixelFont.tiny.covers("°"))
        #expect(PixelFont.standard.covers("°"))
    }

    // MARK: - The substitute

    @Test func aMarkNoFaceCarriesDrawsTheSubstituteRatherThanAHole() {
        // A glyph is always returned, so `drawText` can never skip and leave
        // the cursor stepping over blank columns.
        let drawn = PixelFont.tiny.glyph(for: "\u{2603}")  // a snowman, which no face carries
        #expect(drawn != nil)
        #expect(drawn == PixelFont.tiny.glyph(for: PixelFont.substitute))
        #expect(PixelFont.tiny.covers("\u{2603}") == false)
    }

    // MARK: - Measuring

    @Test func aLineIsAsWideAsItsGlyphsPlusTheGapsBetweenThem() {
        // Four marks at the tiny cell: 4 × 4 − 1 = 15 columns, the trailing
        // gap not counted, because nothing is drawn in it.
        #expect(PixelFont.tiny.width(of: "12°C", scale: 1) == 15)
        #expect(PixelFont.tiny.width(of: "12°C", scale: 2) == 30)
        // The same line in the bigger face: 4 × 6 − 1 = 23.
        #expect(PixelFont.standard.width(of: "12°C", scale: 1) == 23)
        #expect(PixelFont.standard.width(of: "", scale: 1) == 0)
    }

    // The legacy spelling every shipped face still calls, kept pointing at the
    // tiny face so no face moved when the second one arrived.
    @Test func theBareFontSpellingIsStillTheTinyFace() {
        #expect(PixelFont.width(of: "12°C", scale: 1) == PixelFont.tiny.width(of: "12°C", scale: 1))
        #expect(PixelFont.glyph(for: "5") == PixelFont.tiny.glyph(for: "5"))
    }

    // MARK: - Drawing through the canvas

    @Test func theCanvasDrawsWhicheverFaceItIsGiven() {
        var tiny = PixelCanvas()
        tiny.drawText("1", at: .zero, ink: .white)
        var standard = PixelCanvas()
        standard.drawText("1", at: .zero, ink: .white, font: .standard)

        // The tiny "1" is three columns wide and five rows tall; the X11 one
        // reaches row 5, which the tiny cell does not have.
        #expect(tiny[1, 4] == .white)
        #expect(standard[1, 5] == .white || standard[2, 5] == .white)
        #expect(tiny[1, 5] == .black)
    }

    // The defect this whole file is about, drawn rather than measured: a word
    // the old table could not spell now reaches the panel with ink in every
    // character cell.
    @Test func aWordTheOldTableCouldNotSpellDrawsInkInEveryCell() {
        var canvas = PixelCanvas()
        canvas.drawText("feels", at: PixelPoint(x: 0, y: 0), ink: .white)

        for index in 0..<5 {
            let column = index * PixelFont.tiny.advance
            let cell = (0..<PixelFont.tiny.width).flatMap { dx in
                (0..<PixelFont.tiny.height).map { dy in canvas[column + dx, dy] }
            }
            #expect(cell.contains(.white), "character \(index) drew nothing")
        }
    }
}

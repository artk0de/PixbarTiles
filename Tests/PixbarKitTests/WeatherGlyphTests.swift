// Tests/PixbarKitTests/WeatherGlyphTests.swift
import Testing
@testable import PixbarKit

// The weather face's glyphs: the five-row marks it adds to the usage face's
// proportional face, and the 5×9 temperature digits. The approved tables are
// the skill's `weather/wgen.py` `G` and `B`, recorded into
// `weather_face_oracle.json`; every glyph drawn here must be those rows.

@Suite struct WeatherGlyphTests {
    @Test func everyWeatherGlyphMatchesTheApprovedTable() throws {
        let oracle = try WeatherOracle.load()
        for (face, font) in [("small", PixelFont.proportional), ("big", PixelFont.big)] {
            let table = try #require(oracle.glyphs[face], "\(face) table")
            #expect(table.isEmpty == false)
            for (character, rows) in table.sorted(by: { $0.key < $1.key }) {
                let width = rows[0].count
                #expect(font.covers(character), "\(face) \(character) is not in the face")
                #expect(font.columns(of: character) == width, "\(face) \(character) width")
                var canvas = PixelCanvas(width: width, height: rows.count)
                canvas.drawText(String(character), at: .zero, ink: .white, font: font)
                let drawn = (0..<rows.count).map { y in
                    String((0..<width).map { canvas[$0, y] == .white ? "#" : "." })
                }
                #expect(drawn == rows, "\(face) \(character)")
            }
        }
    }
}

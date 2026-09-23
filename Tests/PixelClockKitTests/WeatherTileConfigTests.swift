import Foundation
import PixelClockKit
import Testing
@testable import PixelClockKit

// The weather tile's own settings: what they decode from, what they change,
// and the one rule that keeps the preview honest — every control's answer is
// visible in the canvas the face draws, because the preview IS that canvas.

private let moscow = Coordinates(latitude: 55.7558, longitude: 37.6173)

private func reading(
    temperature: Double = 4.2, apparent: Double? = nil, humidity: Double? = nil
) -> WeatherReading {
    WeatherReading(
        code: 61, isDay: true, temperature: temperature, apparentTemperature: apparent,
        precipitation: 0, windSpeed: 0, interval: 900, relativeHumidity: humidity
    )
}

// MARK: - What a stored config decodes from

@Test func aConfigWrittenBeforeTheSettingsExistedDecodesWithTheShippedDefaults() throws {
    // The shape the weather config carried for its whole life before the tile
    // settings existed: the place and nothing else.
    let json = Data(#"{"latitude":55.7558,"longitude":37.6173}"#.utf8)
    let decoded = try JSONDecoder().decode(WeatherTileConfig.self, from: json)

    #expect(decoded == WeatherTileConfig(place: moscow))
    #expect(decoded.units == .celsius)
    #expect(decoded.showsHumidity)
    #expect(decoded.showsFeelsLike)
}

@Test func everySettingRoundTripsThroughTheStore() throws {
    let config = WeatherTileConfig(
        place: moscow, units: .fahrenheit, showsHumidity: false, showsFeelsLike: false
    )
    let roundTripped = try JSONDecoder().decode(
        WeatherTileConfig.self, from: JSONEncoder().encode(config)
    )

    #expect(roundTripped == config)
    // And the place reads the way every pre-settings reader read it.
    #expect(TileConfig.weather(config).location == moscow)
}

// MARK: - What each control changes

// The scale names itself now, because a picker chooses it: a bare number was
// the reading a person could misread as the other scale without ever
// noticing. The conversion rounds the way the Celsius one always has.
@Test func fahrenheitIsTheConvertedScaleAndItsOwnLetter() {
    #expect(WeatherConnector.degrees(4.2, units: .celsius) == "4°C")
    #expect(WeatherConnector.degrees(12.2, units: .fahrenheit) == "54°F")
    // -3.6 rounds away from zero, on the side where it matters.
    #expect(WeatherConnector.degrees(-3.6, units: .fahrenheit) == "26°F")
}

// The AWTRIX face: the felt temperature is the tile's own answer now, and
// colouring digits from a number they do not show reads as broken. With the
// felt line off, the colour comes from the air the digits name.
@Test func theFeltColourFollowsTheFeltSetting() throws {
    let config = WeatherTileConfig(place: moscow)
    var feltOff = config
    feltOff.showsFeelsLike = false
    let reading = reading(temperature: 4.2, apparent: -2)

    #expect(
        WeatherConnector.output(for: reading, config: config).color
            == TemperatureColour(celsius: -2).hex
    )
    #expect(
        WeatherConnector.output(for: reading, config: feltOff).color
            == TemperatureColour(celsius: 4.2).hex
    )
}

// The TC002 canvas, the preview's own pixels. Each control's answer is a
// different drawing — the three comparisons below are the requirement that
// flipping a control flips the preview.
@Test func eachControlFlipsTheCanvasThePreviewDraws() {
    let config = WeatherTileConfig(place: moscow)
    let answer = reading(humidity: 54)
    let canvas = WeatherConnector.canvas(for: answer, config: config)

    // Units: the same sky at the other scale is another drawing.
    var fahrenheit = config
    fahrenheit.units = .fahrenheit
    #expect(canvas != WeatherConnector.canvas(for: answer, config: fahrenheit))

    // Humidity off: no small band on the left. The dry reading is the same
    // canvas as the humid one with the tile's answer off — nothing is drawn
    // where nothing is asked for.
    var dry = config
    dry.showsHumidity = false
    let dryCanvas = WeatherConnector.canvas(for: answer, config: dry)
    #expect(canvas != dryCanvas)
    #expect(
        dryCanvas == WeatherConnector.canvas(for: reading(humidity: nil), config: config)
    )

    // Feels like off: the right-hand line goes, and the ink cools to the air
    // temperature's colour with it.
    var unfelt = config
    unfelt.showsFeelsLike = false
    #expect(canvas != WeatherConnector.canvas(for: answer, config: unfelt))
}

// And with every answer off, the panel is the temperature alone — nothing is
// drawn in the small band under it, where the answers would have ridden.
@Test func aTileWithEveryAnswerOffDrawsTheBareTemperature() {
    let config = WeatherTileConfig(
        place: moscow, units: .celsius, showsHumidity: false, showsFeelsLike: false
    )
    let canvas = WeatherConnector.canvas(for: reading(humidity: 54), config: config)

    // The bottom band is black: nothing small is drawn under the digits. The
    // rows that settle it are the last two — the centred digits reach into
    // row 12, but a scale-1 band would paint down to 15.
    var bandInk = false
    for x in 0..<PixelCanvas.width {
        for y in 14..<PixelCanvas.height where canvas[x, y] != .black {
            bandInk = true
        }
    }
    #expect(bandInk == false)
    // But the digits themselves are there.
    #expect(canvas != PixelCanvas())
}

// The band's two answers stay two. They sit on one 52-pixel row, and the
// felt temperature used to be spelled "feels 18°" — thirty-five pixels that
// left one column between it and "H78%", and at "feels -12°" ran straight
// over the humidity. The widest pair the band can be handed has to read as
// two groups with clear black between them.
@Test func theBandsTwoAnswersNeverTouch() {
    let config = WeatherTileConfig(place: moscow)
    for (humidity, felt) in [(78.0, 18.0), (100, -12), (100, -40), (5, 104)] {
        let canvas = WeatherConnector.canvas(
            for: reading(temperature: felt, apparent: felt, humidity: humidity), config: config
        )
        let inked = (0..<PixelCanvas.width).filter { x in
            (11..<PixelCanvas.height).contains { canvas[x, $0] != .black }
        }
        // Runs of inked columns, split wherever three or more columns in a
        // row are black: a glyph's own spacing, a narrow glyph's blank side
        // included, never reaches three; a word space always does.
        var runs: [ClosedRange<Int>] = []
        for x in inked {
            if let last = runs.last, x - last.upperBound <= 3 {
                runs[runs.count - 1] = last.lowerBound...x
            } else {
                runs.append(x...x)
            }
        }
        let label = "humidity \(humidity), felt \(felt): \(runs)"
        // Exactly two: the humidity, then the felt temperature as ONE word.
        #expect(runs.count == 2, "\(label)")
        guard runs.count == 2 else { continue }
        // The first run is the humidity and nothing else — it ends inside the
        // humidity's own cells, 4 pixels per mark from x = 1.
        let humidityEnd = 1 + "H\(Int(humidity))%".unicodeScalars.count * 4 - 2
        #expect(runs[0].upperBound <= humidityEnd, "\(label)")
        // Clear black between the two, and the right one on the panel.
        #expect(runs[1].lowerBound - runs[0].upperBound > 3, "\(label)")
        #expect(runs[1].upperBound < PixelCanvas.width, "\(label)")
    }
}

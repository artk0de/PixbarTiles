import Foundation
@testable import PixelClockKit

// The weather face's oracle, as the weather suites read it.
// `Scripts/make_weather_face_oracle.py` records two fixtures from the skill's
// `weather/wgen.py` and `weather/icons.py`; this file is their one loader.
//
// - `weather_icons_oracle.json`: every icon's frames, palette-indexed (one
//   base-36 digit per pixel, index 0 = `000000`, unlit).
// - `weather_face_oracle.json`: the glyph tables and the cases. A case's
//   frames are stored as `framesZ` — base64 of raw DEFLATE of the frames'
//   JSON — and inflated here.
//
// Reading field names mirror `WeatherReading` (°C, km/h, epoch seconds);
// `null` in the fixture is `nil` here. Config field names mirror
// `WeatherTileConfig`: `layout` anchor/pages/hybrid, `changeEvery` seconds,
// `units` celsius/fahrenheit, `windUnit`
// metresPerSecond/kilometresPerHour/milesPerHour.

struct WeatherOracle {
    struct Frame: Decodable, Equatable {
        let ms: Int
        /// Packed `RRGGBB` hex, one string per row.
        let rows: [String]
    }

    struct HourlyPoint: Decodable, Equatable {
        let time: Double
        let temperature: Double
        let precipitationProbability: Int?

        init(from decoder: Decoder) throws {
            var row = try decoder.unkeyedContainer()   // [epoch, temp °C, pop or null]
            time = try row.decode(Double.self)
            temperature = try row.decode(Double.self)
            precipitationProbability = try row.decodeIfPresent(Int.self)
        }
    }

    struct Reading: Decodable, Equatable {
        let code: Int
        let isDay: Bool
        let temperature: Double
        let apparentTemperature: Double?
        let relativeHumidity: Double?
        let windSpeed: Double              // km/h
        let windDirection: Double?         // degrees the wind comes FROM
        let windGusts: Double?             // km/h
        let uvIndex: Double?
        let todayHigh: Double?
        let todayLow: Double?
        let sunrises: [Double]?            // epochs: today, tomorrow
        let sunsets: [Double]?
        let hourly: [HourlyPoint]?
    }

    struct Config: Decodable, Equatable {
        let layout: String
        let changeEvery: Int
        let units: String
        let windUnit: String
        let feelsLikeColour: Bool
        let showsFeelsLike: Bool
        let showsHumidity: Bool
        let showsWind: Bool
        let showsHiLo: Bool
        let showsRainChance: Bool
        let showsUV: Bool
        let showsSunEvents: Bool
        let showsHourly: Bool
    }

    struct Facts: Decodable, Equatable {
        struct Sun: Decodable, Equatable {
            let event: String              // "rise" | "set"
            let at: Double
            let text: String               // "6:48", in the fixture's time zone
        }
        let icon: String
        let moon: Int
        let sun: Sun?
        let rain: Int?
        let arrow: String?
        let hours: [Double]                // the hourly chart's entries
    }

    struct Frames: Decodable, Equatable {
        /// Anchor: the weather icon's own loop (16x16) and the right area (34x16).
        let icon: [Frame]?
        let area: [Frame]?
        /// Pages and Hybrid: the one 52x16 timeline.
        let full: [Frame]?
    }

    struct Case {
        let id: String
        let now: Date
        let reading: Reading?
        let config: Config
        let facts: Facts
        /// The burst the budget rule fell back to, in milliseconds; nil = icons loop.
        let burst: Int?
        let frames: Frames
    }

    struct Icon: Decodable, Equatable {
        struct Frame: Decodable, Equatable {
            let ms: Int
            /// One base-36 palette index per pixel.
            let rows: [String]
        }
        /// `rrggbb`; index 0 is `000000`, unlit.
        let palette: [String]
        let frames: [Frame]

        /// A frame as packed `RRGGBB` hex rows, comparable to `WeatherOracle.hexRows`.
        func hexRows(_ frame: Frame) -> [String] {
            frame.rows.map { row in
                row.map { palette[Int(String($0), radix: 36)!] }.joined()
            }
        }
    }

    let timeZone: TimeZone
    let glyphs: [String: [Character: [String]]]   // "small" | "big" → rows of '#'/'.'
    let icons: [String: Icon]
    let cases: [Case]

    /// Packed `RRGGBB` hex rows of a canvas, as the fixtures store them.
    static func hexRows(_ canvas: PixelCanvas) -> [String] {
        (0..<canvas.height).map { y in
            (0..<canvas.width).map { x in
                let pixel = canvas[x, y]
                return String(format: "%02x%02x%02x", pixel.red, pixel.green, pixel.blue)
            }.joined()
        }
    }

    static func load() throws -> WeatherOracle {
        let iconsFile = try fixture("weather_icons_oracle")
        let faceFile = try fixture("weather_face_oracle")
        let icons = try JSONDecoder().decode(IconsFile.self, from: iconsFile).icons
        let face = try JSONDecoder().decode(FaceFile.self, from: faceFile)
        let cases = try face.cases.map { raw in
            Case(id: raw.id, now: Date(timeIntervalSince1970: raw.now), reading: raw.reading,
                 config: raw.config, facts: raw.facts, burst: raw.burst,
                 frames: try JSONDecoder().decode(Frames.self, from: inflate(raw.framesZ)))
        }
        var glyphs: [String: [Character: [String]]] = [:]
        for (face, table) in face.glyphs {
            glyphs[face] = Dictionary(uniqueKeysWithValues: table.map { (Character($0.key), $0.value) })
        }
        guard let zone = TimeZone(identifier: face.timeZone) else { throw OracleError.badTimeZone(face.timeZone) }
        return WeatherOracle(timeZone: zone, glyphs: glyphs, icons: icons, cases: cases)
    }

    /// base64 of raw DEFLATE → bytes. Apple's `.zlib` is raw DEFLATE (RFC 1951).
    static func inflate(_ base64: String) throws -> Data {
        guard let compressed = Data(base64Encoded: base64) else { throw OracleError.badBase64 }
        return try (compressed as NSData).decompressed(using: .zlib) as Data
    }

    enum OracleError: Error { case missingFixture(String), badBase64, badTimeZone(String) }

    private static func fixture(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw OracleError.missingFixture(name)
        }
        return try Data(contentsOf: url)
    }

    private struct IconsFile: Decodable { let icons: [String: Icon] }

    private struct FaceFile: Decodable {
        struct RawCase: Decodable {
            let id: String
            let now: Double
            let reading: Reading?
            let config: Config
            let facts: Facts
            let burst: Int?
            let framesZ: String
        }
        let timeZone: String
        let glyphs: [String: [String: [String]]]
        let cases: [RawCase]
    }
}

import Foundation

/// The weather tile's own settings: where the sky is read from, and what the
/// reading shows — the scale it names, and whether the humidity and the felt
/// temperature get their place on the panel.
///
/// The decode reads records written before these settings existed: a config
/// carrying only the coordinates is a config in the shipped defaults —
/// Celsius, humidity and felt temperature shown. Nothing rewrites those
/// records; the defaults are what the old face drew, said where the old face
/// assumed.
///
/// The TC002 face's settings (layout through `showsHourly`) follow the same
/// rule: each is defaulted when absent, so every record written before the
/// face — with or without units and the two switches — still reads, as the
/// face the spec ships by default.
public struct WeatherTileConfig: Codable, Equatable, Sendable {
    public enum Units: String, Codable, Sendable {
        case celsius
        case fahrenheit
    }

    /// How the TC002 face moves (spec §2): a fixed temperature with a sliding
    /// detail line, whole sliding pages, or the fixed temperature with a line
    /// that brings its own icon.
    public enum Layout: String, Codable, Sendable, CaseIterable {
        case anchor, pages, hybrid
    }

    /// One line of the face's rotation, in the order the spec's table puts
    /// them on screen — `allCases` IS that order.
    public enum Detail: String, Codable, Sendable, CaseIterable {
        case feels, humidity, wind, hilo, rain, uv, sun, moon, hourly
    }

    /// The intervals the settings window offers between two states.
    public static let changeEverySteps: [TimeInterval] = [3, 5, 8, 10, 15]

    public var place: Coordinates
    /// The city the place was CHOSEN by, when it was chosen rather than typed.
    ///
    /// A pair of coordinates is not a place anybody recognises, and the search
    /// already knows the answer at the moment a row is picked — so it is kept
    /// rather than thrown away and asked for again. Nil for a pair typed by
    /// hand: a name kept beside coordinates it no longer describes is the one
    /// way this surface could say Moscow over a reading from somewhere else.
    public var placeName: String?
    /// The country beside it, for the same reason and with the same rule.
    public var placeCountry: String?
    public var units: Units
    /// The `humidity` line and page.
    public var showsHumidity: Bool
    /// The `feels` line and page only. The digits' colour is
    /// `feelsLikeColour`'s — one setting per meaning.
    public var showsFeelsLike: Bool

    public var layout: Layout
    /// Seconds each state stays on screen.
    public var changeEvery: TimeInterval
    /// Whether the temperature is coloured from what it feels like rather
    /// than from the air. Read by both clocks' faces, so one switch means
    /// one thing on the TC001 and the TC002.
    public var feelsLikeColour: Bool
    public var showsWind: Bool
    public var windUnit: WindUnit
    public var showsHiLo: Bool
    public var showsRainChance: Bool
    public var showsUV: Bool
    public var showsSunEvents: Bool
    /// The `moon` line and page — the phase, a date fact, by day and by
    /// night — and the moon in its phase as a clear night's icon; off, a
    /// clear night is the plain `clearNight`.
    public var showsMoon: Bool
    public var showsHourly: Bool

    public init(
        place: Coordinates, placeName: String? = nil, placeCountry: String? = nil,
        units: Units = .celsius,
        showsHumidity: Bool = true, showsFeelsLike: Bool = true,
        layout: Layout = .anchor, changeEvery: TimeInterval = 10, feelsLikeColour: Bool = true,
        showsWind: Bool = true, windUnit: WindUnit = .metresPerSecond, showsHiLo: Bool = true,
        showsRainChance: Bool = true, showsUV: Bool = false, showsSunEvents: Bool = false,
        showsMoon: Bool = false, showsHourly: Bool = true
    ) {
        self.place = place
        self.placeName = placeName
        self.placeCountry = placeCountry
        self.units = units
        self.showsHumidity = showsHumidity
        self.showsFeelsLike = showsFeelsLike
        self.layout = layout
        self.changeEvery = changeEvery
        self.feelsLikeColour = feelsLikeColour
        self.showsWind = showsWind
        self.windUnit = windUnit
        self.showsHiLo = showsHiLo
        self.showsRainChance = showsRainChance
        self.showsUV = showsUV
        self.showsSunEvents = showsSunEvents
        self.showsMoon = showsMoon
        self.showsHourly = showsHourly
    }

    /// The lines the tile asks for, in the spec's order. Whether a reading
    /// can answer one is the face's question, not the config's.
    public var details: [Detail] {
        Detail.allCases.filter { detail in
            switch detail {
            case .feels: showsFeelsLike
            case .humidity: showsHumidity
            case .wind: showsWind
            case .hilo: showsHiLo
            case .rain: showsRainChance
            case .uv: showsUV
            case .sun: showsSunEvents
            case .moon: showsMoon
            case .hourly: showsHourly
            }
        }
    }

    private enum CodingKeys: String, CodingKey {
        case latitude, longitude, placeName, placeCountry
        case units, showsHumidity, showsFeelsLike
        case layout, changeEvery, feelsLikeColour, showsWind, windUnit, showsHiLo
        case showsRainChance, showsUV, showsSunEvents, showsMoon, showsHourly
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WeatherTileConfig(
            place: try Coordinates(
                latitude: container.decode(Double.self, forKey: .latitude),
                longitude: container.decode(Double.self, forKey: .longitude)
            )
        )
        func read<Value: Decodable>(_ key: CodingKeys, _ fallback: Value) throws -> Value {
            try container.decodeIfPresent(Value.self, forKey: key) ?? fallback
        }
        place = defaults.place
        placeName = try container.decodeIfPresent(String.self, forKey: .placeName)
        placeCountry = try container.decodeIfPresent(String.self, forKey: .placeCountry)
        units = try read(.units, defaults.units)
        showsHumidity = try read(.showsHumidity, defaults.showsHumidity)
        showsFeelsLike = try read(.showsFeelsLike, defaults.showsFeelsLike)
        layout = try read(.layout, defaults.layout)
        changeEvery = try read(.changeEvery, defaults.changeEvery)
        feelsLikeColour = try read(.feelsLikeColour, defaults.feelsLikeColour)
        showsWind = try read(.showsWind, defaults.showsWind)
        windUnit = try read(.windUnit, defaults.windUnit)
        showsHiLo = try read(.showsHiLo, defaults.showsHiLo)
        showsRainChance = try read(.showsRainChance, defaults.showsRainChance)
        showsUV = try read(.showsUV, defaults.showsUV)
        showsSunEvents = try read(.showsSunEvents, defaults.showsSunEvents)
        showsMoon = try read(.showsMoon, defaults.showsMoon)
        showsHourly = try read(.showsHourly, defaults.showsHourly)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(place.latitude, forKey: .latitude)
        try container.encode(place.longitude, forKey: .longitude)
        try container.encodeIfPresent(placeName, forKey: .placeName)
        try container.encodeIfPresent(placeCountry, forKey: .placeCountry)
        try container.encode(units, forKey: .units)
        try container.encode(showsHumidity, forKey: .showsHumidity)
        try container.encode(showsFeelsLike, forKey: .showsFeelsLike)
        try container.encode(layout, forKey: .layout)
        try container.encode(changeEvery, forKey: .changeEvery)
        try container.encode(feelsLikeColour, forKey: .feelsLikeColour)
        try container.encode(showsWind, forKey: .showsWind)
        try container.encode(windUnit, forKey: .windUnit)
        try container.encode(showsHiLo, forKey: .showsHiLo)
        try container.encode(showsRainChance, forKey: .showsRainChance)
        try container.encode(showsUV, forKey: .showsUV)
        try container.encode(showsSunEvents, forKey: .showsSunEvents)
        try container.encode(showsMoon, forKey: .showsMoon)
        try container.encode(showsHourly, forKey: .showsHourly)
    }
}

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
public struct WeatherTileConfig: Codable, Equatable, Sendable {
    public enum Units: String, Codable, Sendable {
        case celsius
        case fahrenheit
    }

    public var place: Coordinates
    public var units: Units
    public var showsHumidity: Bool
    public var showsFeelsLike: Bool

    public init(
        place: Coordinates, units: Units = .celsius,
        showsHumidity: Bool = true, showsFeelsLike: Bool = true
    ) {
        self.place = place
        self.units = units
        self.showsHumidity = showsHumidity
        self.showsFeelsLike = showsFeelsLike
    }

    private enum CodingKeys: String, CodingKey {
        case latitude, longitude, units, showsHumidity, showsFeelsLike
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        place = try Coordinates(
            latitude: container.decode(Double.self, forKey: .latitude),
            longitude: container.decode(Double.self, forKey: .longitude)
        )
        units = try container.decodeIfPresent(Units.self, forKey: .units) ?? .celsius
        showsHumidity = try container.decodeIfPresent(Bool.self, forKey: .showsHumidity) ?? true
        showsFeelsLike = try container.decodeIfPresent(Bool.self, forKey: .showsFeelsLike) ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(place.latitude, forKey: .latitude)
        try container.encode(place.longitude, forKey: .longitude)
        try container.encode(units, forKey: .units)
        try container.encode(showsHumidity, forKey: .showsHumidity)
        try container.encode(showsFeelsLike, forKey: .showsFeelsLike)
    }
}

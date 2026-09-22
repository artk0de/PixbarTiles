// Sources/PixelClockKit/Tiles/TileConfig.swift
import Foundation

/// What one tile needs that no other tile does: the weather tile's place, the
/// VPN tile's VPN, lamp and colours.
///
/// Closed, like the connectors themselves: a connector is a type in code, so
/// the settings it can have are known in code too. Stored under one key naming
/// the connector it belongs to:
///
///   {"weather":{"latitude":55.7558,"longitude":37.6173}}
///   {"vpn":{"slot":"top","upColour":"#90EE90","vpn":"pritunl",
///           "whenDown":{"colour":"#FF0000","kind":"blink"}}}
///   {"claude":"daily"}
public enum TileConfig: Equatable, Sendable {
    case weather(WeatherTileConfig)
    case vpn(VPNTileConfig)
    case zai(ZaiTileConfig)
    case claude(ClaudeDisplayMetric)

    /// A weather tile's config in the shipped defaults, at this place — the
    /// form every caller that knows only the place means. Overloading the
    /// case keeps the pre-settings call sites, and the records they write,
    /// reading exactly as they did.
    public static func weather(_ place: Coordinates) -> TileConfig {
        .weather(WeatherTileConfig(place: place))
    }

    /// The weather tile's whole config, or nil for any other tile.
    public var weatherConfig: WeatherTileConfig? {
        guard case let .weather(config) = self else { return nil }
        return config
    }

    /// The weather tile's place, or nil for any other tile.
    public var location: Coordinates? {
        guard case let .weather(config) = self else { return nil }
        return config.place
    }

    /// The VPN tile's lamp, or nil for any other tile.
    public var lamp: VPNTileConfig? {
        guard case let .vpn(lamp) = self else { return nil }
        return lamp
    }

    /// The z.ai tile's key handle, or nil for any other tile. A handle: the
    /// key itself lives in the login keychain and is never stored here.
    public var key: ZaiTileConfig? {
        guard case let .zai(handle) = self else { return nil }
        return handle
    }

    /// The Claude tile's display metric, or nil for any other tile.
    public var claude: ClaudeDisplayMetric? {
        guard case let .claude(metric) = self else { return nil }
        return metric
    }
}

extension TileConfig: Codable {
    private enum Key: String, CodingKey {
        case weather, vpn, zai, claude
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        // Exactly one key. Two would be a tile claiming two connectors' settings,
        // and picking one of them would be a guess about which it is.
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "a tile config names exactly one connector"
            ))
        }
        switch key {
        case .weather:
            self = .weather(try container.decode(WeatherTileConfig.self, forKey: .weather))
        case .vpn:
            self = .vpn(try container.decode(VPNTileConfig.self, forKey: .vpn))
        case .zai:
            self = .zai(try container.decode(ZaiTileConfig.self, forKey: .zai))
        case .claude:
            self = .claude(try container.decode(ClaudeDisplayMetric.self, forKey: .claude))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .weather(place):
            try container.encode(place, forKey: .weather)
        case let .vpn(lamp):
            try container.encode(lamp, forKey: .vpn)
        case let .zai(handle):
            try container.encode(handle, forKey: .zai)
        case let .claude(metric):
            try container.encode(metric, forKey: .claude)
        }
    }
}

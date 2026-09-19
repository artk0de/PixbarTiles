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
public enum TileConfig: Equatable, Sendable {
    case weather(Coordinates)
    case vpn(VPNTileConfig)

    /// The weather tile's place, or nil for any other tile.
    public var location: Coordinates? {
        guard case let .weather(place) = self else { return nil }
        return place
    }

    /// The VPN tile's lamp, or nil for any other tile.
    public var lamp: VPNTileConfig? {
        guard case let .vpn(lamp) = self else { return nil }
        return lamp
    }
}

extension TileConfig: Codable {
    private enum Key: String, CodingKey {
        case weather, vpn
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
            self = .weather(try container.decode(Coordinates.self, forKey: .weather))
        case .vpn:
            self = .vpn(try container.decode(VPNTileConfig.self, forKey: .vpn))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case let .weather(place):
            try container.encode(place, forKey: .weather)
        case let .vpn(lamp):
            try container.encode(lamp, forKey: .vpn)
        }
    }
}

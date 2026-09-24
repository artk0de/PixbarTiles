// Sources/PixbarKit/VPN/VPNTileConfig.swift
import Foundation

/// What one VPN tile needs that no other tile does.
///
/// Persisted shape, written by hand so nothing on disk moves with a rename:
///
///   {"slot":"top","upColour":"#90EE90","vpn":"pritunl",
///    "whenDown":{"colour":"#FF0000","kind":"blink"}}
///
/// `whenDown` is `{"kind":"off"}` for a lamp that goes dark with its tunnel.
public struct VPNTileConfig: Equatable, Sendable {
    public enum WhenDown: Equatable, Sendable {
        case off
        case blink(String)
    }

    /// Twice a second — fast enough to catch an eye that is not looking at the
    /// clock, slow enough not to strobe a dark room.
    public static let blinkMilliseconds = 500

    /// A `WatchedVPN.id`.
    public var vpn: String
    public var slot: IndicatorSlot
    /// `#RRGGBB`.
    public var upColour: String
    public var whenDown: WhenDown

    public init(vpn: String, slot: IndicatorSlot, upColour: String, whenDown: WhenDown) {
        self.vpn = vpn
        self.slot = slot
        self.upColour = upColour
        self.whenDown = whenDown
    }
}

extension VPNTileConfig: Codable {
    private enum Key: String, CodingKey {
        case vpn, slot, upColour, whenDown
    }

    private enum DownKey: String, CodingKey {
        case kind, colour
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let lamp = try container.decode(String.self, forKey: .slot)
        guard let slot = IndicatorSlot.allCases.first(where: { $0.lampName == lamp }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .slot, in: container, debugDescription: "no lamp called \(lamp)"
            )
        }
        let down = try container.nestedContainer(keyedBy: DownKey.self, forKey: .whenDown)
        let whenDown: WhenDown
        switch try down.decode(String.self, forKey: .kind) {
        case "off":
            whenDown = .off
        case "blink":
            whenDown = .blink(try down.decode(String.self, forKey: .colour))
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .kind, in: down, debugDescription: "no down behaviour called \(other)"
            )
        }
        self.init(
            vpn: try container.decode(String.self, forKey: .vpn),
            slot: slot,
            upColour: try container.decode(String.self, forKey: .upColour),
            whenDown: whenDown
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(vpn, forKey: .vpn)
        try container.encode(slot.lampName, forKey: .slot)
        try container.encode(upColour, forKey: .upColour)
        var down = container.nestedContainer(keyedBy: DownKey.self, forKey: .whenDown)
        switch whenDown {
        case .off:
            try down.encode("off", forKey: .kind)
        case let .blink(colour):
            try down.encode("blink", forKey: .kind)
            try down.encode(colour, forKey: .colour)
        }
    }
}

// Sources/PixelClockKit/VPN/VPNConnector.swift
import Foundation

/// One watched VPN, read for one tile, with the lamp it is to be shown on.
///
/// The config travels with the reading so the face stays a function of the
/// reading alone: which lamp, and in which colours, is the tile's to say, and
/// the face has nothing else to ask.
public struct VPNReading: Equatable, Sendable {
    public let isUp: Bool
    public let lamp: VPNTileConfig

    public init(isUp: Bool, lamp: VPNTileConfig) {
        self.isUp = isUp
        self.lamp = lamp
    }
}

public enum VPNConnectorError: Error, Equatable, Sendable {
    /// The tile names a VPN the catalogue no longer carries.
    case unknownVPN(String)
}

/// Whether a VPN is up, on one of the clock's corner lamps.
///
/// Not a `Connector`: a lamp is not a scene. It is written straight to the
/// clock's `IndicatorCustody`, off the delivery chain, so a lamp never waits
/// behind a playing anecdote — and who owns a shared lamp at this moment is
/// decided across tiles (`LampBoard`), which no per-tile face could do. One
/// tile per VPN, keyed by `WatchedVPN.id`. How the machine is asked is
/// injected: the process table is the app's to read.
public struct VPNConnector: Sendable {
    public static let id = "vpn"
    public var id: String { Self.id }
    public let displayName = "VPN"

    private let isUp: @Sendable (WatchedVPN) -> Bool

    public init(isUp: @escaping @Sendable (WatchedVPN) -> Bool) {
        self.isUp = isUp
    }

    public func read(config: VPNTileConfig) async throws -> VPNReading {
        guard let vpn = WatchedVPN.preset(id: config.vpn) else {
            throw VPNConnectorError.unknownVPN(config.vpn)
        }
        return VPNReading(isUp: isUp(vpn), lamp: config)
    }

    /// The AWTRIX face of a lamp: up is the tile's colour, steady; down is
    /// dark or a blink, as the tile says. The blink belongs to the firmware,
    /// so it costs one write and keeps going with this app asleep. There is no
    /// TC002 face — that clock has no lamps of its own.
    public static func signal(for reading: VPNReading) -> IndicatorSignal {
        if reading.isUp { return .steady(reading.lamp.upColour) }
        switch reading.lamp.whenDown {
        case .off:
            return .off
        case let .blink(colour):
            return .blinking(colour, everyMilliseconds: VPNTileConfig.blinkMilliseconds)
        }
    }
}

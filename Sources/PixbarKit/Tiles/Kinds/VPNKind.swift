// Sources/PixbarKit/Tiles/Kinds/VPNKind.swift
import Foundation

/// A watched VPN, as a lamp on an AWTRIX clock — one tile per VPN.
public enum VPNKind: TileKind {
    public typealias Parameters = VPNTileConfig
    public static let id = VPNConnector.id
    public static let presentation = TilePresentation(
        category: .network, icon: "lock.shield", blurb: "A watched VPN, as a lamp on the clock"
    )
    public static let models: Set<ClockModel> = [.awtrix3]
    public static let instancing = Instancing.perKey

    /// Its VPN's name.
    public static func secondaryName(of tile: TileRecord, parameters: VPNTileConfig?) -> String? {
        if let lamp = parameters {
            return WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn
        }
        return tile.key.instance.isEmpty ? nil : tile.key.instance
    }
}

extension VPNTileConfig: TileParameters {}

// Sources/PixelClockTilesApp/VPNTileMigration.swift
import Foundation
import PixelClockKit

/// Turns the two always-on VPN corners into two VPN tiles on the clock that
/// showed them.
///
/// Each tile carries what the always-on corners hard-coded, and their Focus rule
/// written out: `hold` on a Focus that cannot be named, because today such a
/// Focus leaves both corners dark. Written explicitly, so the tile never falls
/// back to the VPN defaults row, which says `run`.
///
/// On the first clock, which is the one the corners were lit on. A clock that
/// is not AWTRIX has no lamps, so there is nothing to carry over and the step
/// is done. No clock at all is a step that has not run yet.
struct VPNTileMigration {
    static let markerKey = "migration.vpnTiles"

    let defaults: UserDefaults

    func run() throws {
        guard defaults.bool(forKey: Self.markerKey) == false else { return }
        guard let clock = ClockStore(defaults: defaults).all().first else { return }
        if clock.model == .awtrix3 {
            let store = TileStore(defaults: defaults)
            let migrated = Self.tiles(on: clock.id)
            let keys = Set(migrated.map(\.key))
            // A run cut short before its marker left these behind; they are
            // replaced rather than added twice.
            try store.replaceAll(store.all().filter { !keys.contains($0.key) } + migrated)
        }
        defaults.set(true, forKey: Self.markerKey)
    }

    static func tiles(on clockId: UUID) -> [TileRecord] {
        [
            tile(
                on: clockId,
                lamp: VPNTileConfig(
                    vpn: WatchedVPN.pritunl.id, slot: .topRight,
                    upColour: "#90EE90", whenDown: .blink("#FF0000")
                ),
                workingIn: [.work]
            ),
            tile(
                on: clockId,
                lamp: VPNTileConfig(
                    vpn: WatchedVPN.amnezia.id, slot: .bottomRight,
                    upColour: "#A855F7", whenDown: .off
                ),
                workingIn: [.work, .personal]
            ),
        ]
    }

    private static func tile(
        on clockId: UUID, lamp: VPNTileConfig, workingIn focuses: Set<MacFocus>
    ) -> TileRecord {
        let named: Set<MacFocus> = [.noFocus, .work, .personal, .doNotDisturb, .sleep]
        let policy = TilePolicy(
            refreshSeconds: TileDefaults.vpn.refreshSeconds,
            focus: FocusRule(silencedIn: named.subtracting(focuses), whenUnknown: .hold)
        )
        return TileRecord(
            key: TileKey(clockId: clockId, connectorId: VPNConnector.id, instance: lamp.vpn),
            policy: TilePolicyRecord(policy),
            config: .vpn(lamp)
        )
    }
}

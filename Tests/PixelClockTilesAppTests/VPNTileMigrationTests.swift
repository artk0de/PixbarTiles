import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private func vpnTiles(in defaults: UserDefaults) -> [TileRecord] {
    TileStore(defaults: defaults).all().filter { $0.key.connectorId == VPNConnector.id }
}

@Test func theTwoCornersBecomeTwoVPNTilesOnTheFirstClock() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try storeTheMigratedTiles(on: clock, in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        let tiles = vpnTiles(in: defaults)
        #expect(tiles.map(\.key) == [
            TileKey(clockId: clock.id, connectorId: "vpn", instance: "pritunl"),
            TileKey(clockId: clock.id, connectorId: "vpn", instance: "amnezia"),
        ])
        #expect(tiles.map(\.config) == [
            .vpn(VPNTileConfig(vpn: "pritunl", slot: .topRight, upColour: "#90EE90", whenDown: .blink("#FF0000"))),
            .vpn(VPNTileConfig(vpn: "amnezia", slot: .bottomRight, upColour: "#A855F7", whenDown: .off)),
        ])
        #expect(tiles.allSatisfy { $0.policy.refreshSeconds == 60 && $0.policy.isPaused == false })
        // The three tiles already there are left where they were, in front.
        #expect(TileStore(defaults: defaults).all().count == 5)
    }
}

// What each corner followed, read back through the grid: Pritunl in Work only,
// Amnezia in Work and Personal, and neither under a Focus that cannot be named
// — which is what the always-on corners did.
@Test func eachTileWorksInTheFocusesItsCornerFollowed() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        let working = vpnTiles(in: defaults).map { tile in
            let policy = TilePolicy(tile.policy, defaults: TileDefaults.vpn)
            return MacFocus.allCases.filter { policy.runs(in: $0, atHour: 12) }
        }
        #expect(working == [[.work], [.work, .personal]])
    }
}

// Written out, so neither falls back to the VPN row's `run`.
@Test func bothVPNTilesHoldOnAFocusThatCannotBeNamedInWhatIsStored() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).map(\.policy.focus?.whenUnknown) == [.hold, .hold])
    }
}

@Test func aTC002HasNoCornersToCarryOver() throws {
    try withFreshDefaults { defaults in
        try storeAClock(.ulanziTC002, in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).isEmpty)
        #expect(defaults.bool(forKey: VPNTileMigration.markerKey))
    }
}

@Test func withNoClockYetTheVPNStepHasNotRun() throws {
    try withFreshDefaults { defaults in
        try VPNTileMigration(defaults: defaults).run()

        #expect(defaults.bool(forKey: VPNTileMigration.markerKey) == false)
    }
}

// A run cut short after the tiles and before the marker runs again from the
// start, and must not leave four.
@Test func aVPNStepCutShortDoesNotAddTheTilesTwice() throws {
    try withFreshDefaults { defaults in
        let clock = try storeAClock(in: defaults)
        try TileStore(defaults: defaults).replaceAll(VPNTileMigration.tiles(on: clock.id))

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).count == 2)
    }
}

@Test func theVPNTileMigrationWritesItsMarkerLast() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)

        try VPNTileMigration(defaults: defaults).run()

        #expect(defaults.writes.last == VPNTileMigration.markerKey)
    }
}

@Test func aSecondVPNTileMigrationChangesNothing() throws {
    try withFreshDefaults { defaults in
        try storeAClock(in: defaults)
        try VPNTileMigration(defaults: defaults).run()
        let removed = TileStore(defaults: defaults).all().filter { $0.key.instance != "amnezia" }
        try TileStore(defaults: defaults).replaceAll(removed)

        try VPNTileMigration(defaults: defaults).run()

        #expect(vpnTiles(in: defaults).map(\.key.instance) == ["pritunl"])
    }
}

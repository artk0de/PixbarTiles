import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let loft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.7")
private let tc002 = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

@Test @MainActor func aNewTileStartsFromItsConnectorsDefaults() {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])

    #expect(subject.addTile("claude", to: desk.id) == .saved)

    #expect(subject.storedPolicy(of: TileKey(clockId: desk.id, connectorId: "claude")) == StubConnector(id: "claude").defaultPolicy)
}

@Test @MainActor func aTileTheClockCannotTakeIsRefusedWithTheMenusReason() {
    let subject = testModel(connectors: [StubConnector(id: "anecdotes")], clocks: [desk, tc002], tiles: [])

    #expect(subject.addTile("anecdotes", to: tc002.id) == .refused("not supported on TC-002 Pixbar"))
}

@Test @MainActor func aSecondTileOfOneConnectorOnOneClockIsRefused() {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)

    #expect(subject.addTile("claude", to: desk.id) == .refused("already on Desk"))
}

// Uniqueness is per clock: a `.single` connector already on one clock is
// still offered, and saves, on another. Only an audible connector — the one
// speaking through this Mac — may not (design "Adding a tile", rules 2–3).
@Test @MainActor func aSingleConnectorSavesOnEachOfTwoClocks() {
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)], clocks: [desk, loft], tiles: []
    )
    _ = subject.addTile("claude", to: desk.id)

    #expect(subject.addTile("claude", to: loft.id) == .saved)
}

// The VPN presets are the `.multi` connectors: a second VPN joins the same
// clock while the lamps differ. The one refusal is the lamp-overlap rule, and
// that one is pinned above.
@Test @MainActor func aSecondVPNTileJoinsOneClockOnAFreeLamp() {
    let seeded = VPNTileMigration.tiles(on: desk.id).filter { $0.config?.lamp?.vpn == WatchedVPN.pritunl.id }
    let subject = testModel(clocks: [desk], tiles: seeded)

    #expect(
        subject.addTile(
            "vpn", to: desk.id, instance: WatchedVPN.amnezia.id,
            config: .vpn(VPNTileConfig(vpn: WatchedVPN.amnezia.id, slot: .middleRight, upColour: "#00F0FF", whenDown: .off))
        ) == .saved
    )
}

// The coding-subscription parameters are the tile's own config: chosen in the
// detail, saved with the policy untouched, and read back by the next open.
@Test @MainActor func theClaudeTilesParametersAreStoredInItsConfig() throws {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)
    let key = TileKey(clockId: desk.id, connectorId: "claude")
    let stored = try #require(subject.storedPolicy(of: key))
    let tuned = TileConfig.claude(ClaudeTileConfig(
        parameters: CodeUsage.Parameters(resetEvery: 30, resetAfter: 65)
    ))

    #expect(subject.saveTile(key: key, policy: stored, config: tuned) == .saved)
    #expect(subject.detailValue(for: key)?.config == tuned)
}

@Test @MainActor func aVPNTileClaimingAHeldLampIsRefusedInTheDesignsWords() {
    let subject = testModel(clocks: [desk], tiles: VPNTileMigration.tiles(on: desk.id))
    let amnezia = TileKey(clockId: desk.id, connectorId: "vpn", instance: "amnezia")
    var onTop = TilePolicy(refreshSeconds: 60, focus: FocusRule(silencedIn: [.noFocus, .doNotDisturb, .sleep], whenUnknown: .hold))
    onTop.window = .active(HourWindow(startHour: 10, endHour: 19))

    let outcome = subject.saveTile(
        key: amnezia,
        policy: onTop,
        config: .vpn(VPNTileConfig(vpn: "amnezia", slot: .topRight, upColour: "#A855F7", whenDown: .off))
    )

    #expect(outcome == .refused("Pritunl and Amnezia both claim the top lamp: Work, 10:00–19:00"))
}

// A pause takes the tile's app off the clock at once — on the TC002 that is
// the only thing that ever will.
@Test @MainActor func pausingATileTakesItOffItsClockAtOnce() async {
    let host = SpyHost()
    let subject = testModel(connectors: [StubConnector(id: "claude")], host: host, clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)
    var paused = StubConnector(id: "claude").defaultPolicy
    paused.isPaused = true

    _ = subject.saveTile(key: TileKey(clockId: desk.id, connectorId: "claude"), policy: paused, config: nil)

    #expect(await waitUntil { host.calls.contains("restore:claude") })
}

@Test @MainActor func removingATileTakesItOffItsClockAndOutOfTheList() async {
    let host = SpyHost()
    let subject = testModel(connectors: [StubConnector(id: "claude")], host: host, clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)

    subject.removeTile(TileKey(clockId: desk.id, connectorId: "claude"))

    #expect(await waitUntil { host.calls.contains("restore:claude") })
    #expect(subject.storedPolicy(of: TileKey(clockId: desk.id, connectorId: "claude")) == nil)
}

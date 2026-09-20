import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let tc002 = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

@Test @MainActor func aNewTileStartsFromItsConnectorsDefaults() {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])

    #expect(subject.addTile("claude", to: desk.id) == .saved)

    #expect(subject.storedPolicy(of: TileKey(clockId: desk.id, connectorId: "claude")) == StubConnector(id: "claude").defaultPolicy)
}

@Test @MainActor func aTileTheClockCannotTakeIsRefusedWithTheMenusReason() {
    let subject = testModel(connectors: [StubConnector(id: "anecdotes")], clocks: [desk, tc002], tiles: [])

    #expect(subject.addTile("anecdotes", to: tc002.id) == .refused("not supported on TC002"))
}

@Test @MainActor func aSecondTileOfOneConnectorOnOneClockIsRefused() {
    let subject = testModel(connectors: [StubConnector(id: "claude")], clocks: [desk], tiles: [])
    _ = subject.addTile("claude", to: desk.id)

    #expect(subject.addTile("claude", to: desk.id) == .refused("already on Desk"))
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

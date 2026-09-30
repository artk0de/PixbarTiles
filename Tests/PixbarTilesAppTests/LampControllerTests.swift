import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The lamp tiles: which VPN a new lamp watches, which corner it starts in,
/// and which lamps a clock carries.
@MainActor
@Suite struct LampControllerTests {
    private let clockId = UUID()
    private let tiles = TileStore(defaults: UserDefaults(suiteName: "lamps-\(UUID().uuidString)")!)

    private func controller() -> LampController {
        LampController(
            vpn: VPNConnector(isUp: { _ in false }),
            tiles: tiles,
            clockSessions: ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil),
            taskBag: TaskBag(),
            policy: { _ in TileDefaults.vpn },
            moment: { (.noFocus, 12) }
        )
    }

    private func lamp(_ vpn: WatchedVPN, slot: IndicatorSlot, on clockId: UUID) -> TileRecord {
        TileRecord(
            key: TileKey(clockId: clockId, connectorId: VPNConnector.id, instance: vpn.id),
            policy: TilePolicyRecord(TileDefaults.vpn),
            config: .vpn(VPNTileConfig(vpn: vpn.id, slot: slot, upColour: "#00FF00", whenDown: .off))
        )
    }

    @Test func aNewLampWatchesTheFirstVPNNoLampOnTheClockWatches() throws {
        let subject = controller()
        let first = WatchedVPN.catalogue[0]
        #expect(subject.freeLampVPN(on: clockId)?.id == first.id)
        try tiles.replaceAll([lamp(first, slot: .topRight, on: clockId)])
        #expect(subject.freeLampVPN(on: clockId)?.id == WatchedVPN.catalogue[1].id)
        #expect(subject.freeLampVPN(on: UUID())?.id == first.id)
    }

    @Test func aNewLampStartsInACornerNobodyHasClaimed() throws {
        let subject = controller()
        try tiles.replaceAll([lamp(WatchedVPN.catalogue[0], slot: IndicatorSlot.allCases[0], on: clockId)])
        let starting = subject.startingLamp(for: WatchedVPN.catalogue[1], on: clockId)
        #expect(starting.slot != IndicatorSlot.allCases[0])
        #expect(starting.vpn == WatchedVPN.catalogue[1].id)
        #expect(starting.whenDown == .off)
    }

    @Test func aClockCarriesOnlyItsOwnLamps() throws {
        let subject = controller()
        try tiles.replaceAll([
            lamp(WatchedVPN.catalogue[0], slot: .topRight, on: clockId),
            lamp(WatchedVPN.catalogue[0], slot: .topRight, on: UUID()),
        ])
        #expect(subject.lampTiles(on: clockId).map(\.key.clockId) == [clockId])
    }
}

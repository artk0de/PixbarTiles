import Foundation
import PixbarKit
import SwiftUI
import Testing
@testable import PixbarTilesApp

/// A wiring hears its tile's window open and close.
@MainActor
@Suite struct TileArrivalTests {
    private final class Heard: @unchecked Sendable {
        var calls: [String] = []
    }

    private struct Recording: TileKindWiring {
        typealias Kind = WeatherKind
        let heard: Heard
        var tileGlyph: [String] { [] }
        func arrived(_ key: TileKey, _ parameters: WeatherTileConfig?, _ actions: TileArrivalActions) {
            heard.calls.append("arrived \(key.connectorId) \(parameters?.place.latitude ?? -1)")
            actions.run(key)
        }
        func left(_ key: TileKey, _ parameters: WeatherTileConfig?, _ actions: TileArrivalActions) {
            heard.calls.append("left \(key.connectorId)")
        }
    }

    private final class Reachability: ReachabilityReading {
        func clockIsUnreachable(_ clockId: UUID) -> Bool { false }
        func recheckClocks() {}
    }

    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

    @Test func theHooksHearTheWindowOpenAndCloseOnce() throws {
        let tiles = TileStore(defaults: UserDefaults(suiteName: "arrival-\(UUID().uuidString)")!)
        let weather = TileKey(clockId: clock.id, connectorId: WeatherKind.id)
        try tiles.replaceAll([TileRecord(
            key: weather, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900),
            config: .weather(Coordinates(latitude: 55, longitude: 37))
        )])
        let registry = ConnectorRegistry()
        registry.register(StubConnector(id: WeatherKind.id, displayName: "Weather", isAudible: false))
        let sessions = ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil)
        sessions.open(clock)
        let taskBag = TaskBag()
        let reachability = Reachability()
        var hour = 12
        let subject = TileScheduler(
            tiles: tiles, registry: registry, clockSessions: sessions,
            runner: TileRunner(tiles: tiles, clockSessions: sessions, reachability: reachability, taskBag: taskBag),
            reachability: reachability, taskBag: taskBag, sleep: parked,
            busyMicrophone: { nil },
            policy: { _ in TilePolicy(refreshSeconds: 900, window: .active(HourWindow(startHour: 21, endHour: 7))) },
            moment: { (.noFocus, hour) }
        )
        let heard = Heard()
        var ran: [TileKey] = []
        subject.wirings = { $0 == WeatherKind.id ? Recording(heard: heard) : nil }
        subject.tileArrivalActions = TileArrivalActions(
            run: { ran.append($0) }, show: { _ in }, idle: { _ in }, morningTile: { _, _, _ in nil }
        )

        subject.reconcileTiles()
        subject.reconcileTiles()
        #expect(heard.calls.isEmpty)
        hour = 22
        subject.reconcileTiles()
        subject.reconcileTiles()
        hour = 8
        subject.reconcileTiles()
        #expect(heard.calls == ["arrived weather 55.0", "left weather"])
        #expect(ran == [weather])
    }
}

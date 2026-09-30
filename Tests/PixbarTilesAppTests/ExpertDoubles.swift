import Foundation
import PixbarKit
@testable import PixbarTilesApp

/// A schedule that does nothing — for an expert's test that is not about the
/// schedule.
@MainActor
final class InertSchedule: TileScheduling {
    func reschedule(_ key: TileKey, resuming: Bool) {}
    func reconcileTiles() {}
    func unschedule(_ key: TileKey) {}
    func pushDisplaySettings(_ key: TileKey) {}
}

/// A runner that does nothing, for the same reason.
@MainActor
final class InertRuns: TileRunning {
    func retract(_ key: TileKey) {}
    func pushDisplaySettings(_ key: TileKey) {}
}

/// Every clock answering.
@MainActor
final class EveryClockAnswers: ReachabilityReading {
    func clockIsUnreachable(_ clockId: UUID) -> Bool { false }
    func recheckClocks() {}
}

/// A tile book over one clock and the given connectors, with nothing behind
/// it that reaches a clock.
@MainActor
func inertTileBook(
    clock: ClockRecord, defaults: UserDefaults, connectors: [any Connector]
) -> TileBook {
    let tiles = TileStore(defaults: defaults)
    let registry = ConnectorRegistry()
    for connector in connectors { registry.register(connector) }
    let sessions = ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil)
    sessions.open(clock)
    let policy: @MainActor (TileKey) -> TilePolicy? = { TileBook.policy(of: $0, in: tiles, registry: registry) }
    let book = TileBook(
        tiles: tiles, registry: registry, defaults: defaults, clockSessions: sessions,
        lamps: LampController(
            vpn: VPNConnector(isUp: { _ in false }), tiles: tiles, clockSessions: sessions,
            taskBag: TaskBag(), policy: policy, moment: { (.noFocus, 12) }
        ),
        scheduler: InertSchedule(), runner: InertRuns(),
        pages: PageFollower(tiles: tiles, clockSessions: sessions, reachability: EveryClockAnswers(), policy: policy)
    )
    book.clocks = { [clock] }
    return book
}

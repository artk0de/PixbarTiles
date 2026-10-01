import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// A tile its schedule holds is taken off its clock — a TC002 page included,
/// and a tile that was already held when the app first looked at it.
@MainActor
@Suite struct HeldTileRetractionTests {
    private final class Pages: ConnectorRunning, UlanziConnectorRunning, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [String] = []
        var events: [String] { lock.withLock { recorded } }
        private func note(_ event: String) { lock.withLock { recorded.append(event) } }

        func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
        func runOnce(tile: TileRecord) async -> RunResult { .delivered }
        func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
        func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
        func restoreDeviceState(borrowedBy tileId: String?) async {}
        var indicators: IndicatorCustody? { nil }
        func deliver(_ output: UlanziDelivery, toTile tileId: String) async -> RunResult { .delivered }
        func markIdle(tileId: String) async -> RunResult {
            note("idle:\(tileId)")
            return .delivered
        }
        func tileRemoved(_ tileId: String) async { note("removed:\(tileId)") }
        func shutdown() async {}
    }

    private let clock = ClockRecord(name: "Bedroom", model: .ulanziTC002, address: "10.0.0.7")
    private var nightLight: TileKey { TileKey(clockId: clock.id, connectorId: NightLightKind.id) }

    private func scheduler(
        _ pages: Pages, hour: @escaping () -> Int
    ) throws -> (TileScheduler, TileRunner) {
        let tiles = TileStore(defaults: UserDefaults(suiteName: "held-\(UUID().uuidString)")!)
        try tiles.replaceAll([TileRecord(
            key: nightLight, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 3_600),
            config: TileConfig(NightLightTileConfig(), kind: NightLightKind.self)
        )])
        let sessions = ClockSessions(make: { _ in pages }, makeRegistry: nil)
        sessions.open(clock)
        let taskBag = TaskBag()
        let reachability = EveryClockAnswers()
        let runner = TileRunner(tiles: tiles, clockSessions: sessions, reachability: reachability, taskBag: taskBag)
        let subject = TileScheduler(
            tiles: tiles, registry: ConnectorRegistry(), clockSessions: sessions,
            runner: runner, reachability: reachability, taskBag: taskBag, sleep: parked,
            busyMicrophone: { nil },
            policy: { _ in TilePolicy(refreshSeconds: 3_600, window: .active(HourWindow(startHour: 21, endHour: 7))) },
            moment: { (.noFocus, hour()) }
        )
        return (subject, runner)
    }

    @Test func retractingATileTakesItsPageOffTheTC002() async throws {
        let pages = Pages()
        let (_, runner) = try scheduler(pages, hour: { 12 })

        runner.retract(nightLight)

        #expect(await waitUntil { pages.events.contains("removed:\(nightLight.tileId)") })
    }

    @Test func aTileHeldWhenFirstSeenIsTakenOff() async throws {
        let pages = Pages()
        let (subject, _) = try scheduler(pages, hour: { 12 })

        subject.reconcileTiles()

        #expect(await waitUntil { pages.events == ["removed:\(nightLight.tileId)"] })
    }

    @Test func aTileLeavingItsWindowIsTakenOff() async throws {
        let pages = Pages()
        var hour = 23
        let (subject, _) = try scheduler(pages, hour: { hour })
        subject.reconcileTiles()
        hour = 8

        subject.reconcileTiles()

        #expect(await waitUntil { pages.events.contains("removed:\(nightLight.tileId)") })
        #expect(pages.events.contains("idle:\(nightLight.tileId)") == false)
    }

    @Test func aTileInsideItsWindowIsLeftOnTheClock() async throws {
        let pages = Pages()
        let (subject, _) = try scheduler(pages, hour: { 23 })

        subject.reconcileTiles()
        subject.reconcileTiles()

        try await Task.sleep(for: .milliseconds(100))
        #expect(pages.events.isEmpty)
    }
}

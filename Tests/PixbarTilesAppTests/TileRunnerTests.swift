import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// Running a tile and saying how it went: the run's word, its failure, the
/// restock's complaint, the delivery stamp, and the runs a meeting holds.
@MainActor
@Suite struct TileRunnerTests {
    private final class Reachability: ReachabilityReading {
        var down: Set<UUID> = []
        private(set) var rechecks = 0
        func clockIsUnreachable(_ clockId: UUID) -> Bool { down.contains(clockId) }
        func recheckClocks() { rechecks += 1 }
    }

    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    private let host = SpyHost()
    private let reachability = Reachability()
    private let tiles = TileStore(defaults: UserDefaults(suiteName: "runner-\(UUID().uuidString)")!)

    private var key: TileKey { TileKey(clockId: clock.id, connectorId: "weather") }

    private func runner() throws -> TileRunner {
        try tiles.replaceAll([TileRecord(key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900))])
        let host = self.host
        let sessions = ClockSessions(make: { _ in host }, makeRegistry: nil)
        sessions.open(clock)
        return TileRunner(tiles: tiles, clockSessions: sessions, reachability: reachability, taskBag: TaskBag())
    }

    @Test func aDeliveredRunSaysSoAndStampsTheTile() async throws {
        let subject = try runner()
        await subject.runAndReport(key)
        #expect(subject.lastResult(of: key) == TileRunner.deliveredWord)
        #expect(host.calls == ["run:weather", "maintain:weather"])
        #expect(tiles.all().first?.lastDeliveredAt != nil)
        #expect(subject.pushState(of: clock.id) == .delivered)
    }

    @Test func nothingIsSentToAnUnreachableClockButTheRestockStillRuns() async throws {
        let subject = try runner()
        reachability.down = [clock.id]
        await subject.runAndReport(key)
        #expect(subject.lastResult(of: key) == AppModel.deviceUnreachable)
        #expect(host.calls == ["maintain:weather"])
    }

    @Test func aScheduledRunRestocksOnBothSidesOfTheRun() async throws {
        let subject = try runner()
        await subject.runScheduled(key)
        #expect(host.calls == ["maintain:weather", "run:weather", "maintain:weather"])
    }

    @Test func aHeldRunGoesOnlyWhenNothingHoldsItAnyMore() async throws {
        let subject = try runner()
        subject.hold(key)
        subject.hold(key)
        await subject.releaseHeldRuns(stillHeld: { _ in true })
        #expect(host.calls.isEmpty)
        await subject.releaseHeldRuns(stillHeld: { _ in false })
        await subject.releaseHeldRuns(stillHeld: { _ in false })
        #expect(host.calls == ["run:weather", "maintain:weather"])
    }

    @Test func theFailuresOfAClockThatWentAwayAreForgotten() throws {
        let subject = try runner()
        subject.record(.failed("timed out"), for: key)
        #expect(subject.lastFailure(of: key) == "timed out")
        #expect(reachability.rechecks == 1)
        #expect(subject.pushState(of: clock.id) == .failed)
        reachability.down = [clock.id]
        subject.forgetFailuresOfUnreachableClocks()
        #expect(subject.lastFailure(of: key) == nil)
        #expect(subject.lastResult(of: key) == AppModel.deviceUnreachable)
    }
}

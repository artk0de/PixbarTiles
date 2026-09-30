import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// Each tile's delivery loop, what holds it, and the line the panel shows
/// for it.
@MainActor
@Suite struct TileSchedulerTests {
    private final class Reachability: ReachabilityReading {
        var down: Set<UUID> = []
        func clockIsUnreachable(_ clockId: UUID) -> Bool { down.contains(clockId) }
        func recheckClocks() {}
    }

    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    private let reachability = Reachability()
    private let tiles = TileStore(defaults: UserDefaults(suiteName: "scheduler-\(UUID().uuidString)")!)

    private func key(_ id: String) -> TileKey { TileKey(clockId: clock.id, connectorId: id) }

    private func scheduler(busy: AudioInput? = nil, paused: Set<String> = []) throws -> TileScheduler {
        try tiles.replaceAll(["anecdotes", "weather"].map { id in
            TileRecord(key: key(id), policy: TilePolicyRecord(isPaused: paused.contains(id), refreshSeconds: 900))
        })
        let registry = ConnectorRegistry()
        registry.register(StubConnector(id: "anecdotes", displayName: "Anecdotes"))
        registry.register(StubConnector(id: "weather", displayName: "Weather", isAudible: false))
        let sessions = ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil)
        sessions.open(clock)
        let taskBag = TaskBag()
        let tiles = self.tiles
        return TileScheduler(
            tiles: tiles, registry: registry, clockSessions: sessions,
            runner: TileRunner(tiles: tiles, clockSessions: sessions, reachability: reachability, taskBag: taskBag),
            reachability: reachability, taskBag: taskBag, sleep: parked,
            busyMicrophone: { busy },
            policy: { AppModel.policy(of: $0, in: tiles, registry: registry) },
            moment: { (.noFocus, 12) }
        )
    }

    @Test func aSwitchedOffTileGetsNoLoopAndSaysSo() throws {
        let subject = try scheduler(paused: ["anecdotes"])
        subject.reschedule(key("anecdotes"))
        #expect(subject.isScheduled(key("anecdotes")) == false)
        #expect(subject.tileNextRun[key("anecdotes")] == .held(AppModel.switchedOff))
    }

    @Test func aRunningTileIsScheduledAndNamesWhenItIsDue() async throws {
        let subject = try scheduler()
        subject.reschedule(key("anecdotes"))
        #expect(subject.isScheduled(key("anecdotes")))
        #expect(await waitUntil {
            if case .due = subject.tileNextRun[key("anecdotes")] { return true }
            return false
        })
        let stopped = subject.stopAll()
        for task in stopped { task.cancel() }
        #expect(subject.isScheduled(key("anecdotes")) == false)
    }

    @Test func theClockHoldsEveryTileAndAMicrophoneOnlyTheOnesThatSpeak() throws {
        let subject = try scheduler(busy: Inputs.capturing(Inputs.builtIn))
        #expect(subject.scheduleHold(for: key("anecdotes")) == MicrophoneGate.inUse(Inputs.builtIn.name))
        #expect(subject.scheduleHold(for: key("weather")) == nil)
        reachability.down = [clock.id]
        #expect(subject.scheduleHold(for: key("weather")) == AppModel.deviceUnreachable)
    }
}

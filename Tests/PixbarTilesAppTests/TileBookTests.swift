import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The tiles as stored: adding, saving, removing and re-keying them, their
/// order, and the settings a removed tile leaves for its return.
@MainActor
@Suite struct TileBookTests {
    private final class Schedule: TileScheduling {
        private(set) var rescheduled: [TileKey] = []
        private(set) var unscheduled: [TileKey] = []
        func reschedule(_ key: TileKey, resuming: Bool) { rescheduled.append(key) }
        func reconcileTiles() {}
        func unschedule(_ key: TileKey) { unscheduled.append(key) }
        func pushDisplaySettings(_ key: TileKey) {}
    }

    private final class Runs: TileRunning {
        private(set) var retracted: [TileKey] = []
        func retract(_ key: TileKey) { retracted.append(key) }
        func pushDisplaySettings(_ key: TileKey) {}
    }

    private final class Reachable: ReachabilityReading {
        func clockIsUnreachable(_ clockId: UUID) -> Bool { false }
        func recheckClocks() {}
    }

    private let clock = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    private let defaults = UserDefaults(suiteName: "book-\(UUID().uuidString)")!
    private let schedule = Schedule()
    private let runs = Runs()

    private func book() -> TileBook {
        let tiles = TileStore(defaults: defaults)
        let registry = ConnectorRegistry()
        registry.register(StubConnector(id: "weather", displayName: "Weather"))
        registry.register(StubConnector(id: "claude", displayName: "Claude"))
        registry.register(StubConnector(id: "github", displayName: "GitHub", instancing: .perKey))
        let sessions = ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil)
        sessions.open(clock)
        let policy: @MainActor (TileKey) -> TilePolicy? = { TileBook.policy(of: $0, in: tiles, registry: registry) }
        let book = TileBook(
            tiles: tiles, registry: registry, defaults: defaults, clockSessions: sessions,
            lamps: LampController(
                vpn: VPNConnector(isUp: { _ in false }), tiles: tiles, clockSessions: sessions,
                taskBag: TaskBag(), policy: policy, moment: { (.noFocus, 12) }
            ),
            scheduler: schedule, runner: runs,
            pages: PageFollower(tiles: tiles, clockSessions: sessions, reachability: Reachable(), policy: policy)
        )
        let clock = self.clock
        book.clocks = { [clock] }
        return book
    }

    private func key(_ id: String, _ instance: String = "") -> TileKey {
        TileKey(clockId: clock.id, connectorId: id, instance: instance)
    }

    @Test func aTileIsAddedOnceAndScheduled() {
        let subject = book()
        #expect(subject.addTile("weather", to: clock.id) == .saved)
        #expect(subject.tileRecords.map(\.key) == [key("weather")])
        #expect(schedule.rescheduled == [key("weather")])
        if case .refused = subject.addTile("weather", to: clock.id) {} else { Issue.record("a second weather tile was added") }
    }

    @Test func aRemovedTilesSettingsComeBackWithIt() {
        let subject = book()
        let config = TileConfig.github(GitHubTileConfig(repo: "a/b"))
        #expect(subject.addTile("github", to: clock.id, instance: "a/b", config: config) == .saved)
        subject.removeTile(key("github", "a/b"))
        #expect(subject.tileRecords.isEmpty)
        #expect(runs.retracted == [key("github", "a/b")])
        #expect(subject.addTile("github", to: clock.id, instance: "a/b") == .saved)
        #expect(subject.storedTile(key("github", "a/b"))?.config == config)
    }

    @Test func aRekeyedTileKeepsItsPlaceAndLeavesItsOldKeyBehind() {
        let subject = book()
        _ = subject.addTile("github", to: clock.id, instance: "a/b", config: .github(GitHubTileConfig(repo: "a/b")))
        _ = subject.addTile("weather", to: clock.id)
        let moved = key("github", "c/d")
        #expect(subject.rekey(key("github", "a/b"), to: moved, config: .github(GitHubTileConfig(repo: "c/d"))) == .saved)
        #expect(subject.tileRecords.map(\.key) == [moved, key("weather")])
        #expect(schedule.unscheduled == [key("github", "a/b")])
        #expect(runs.retracted == [key("github", "a/b")])
        #expect(subject.storedTile(moved)?.config?.github?.repo == "c/d")
    }

    @Test func aReorderMovesOnlyTheRowsAndSaysSo() {
        let subject = book()
        _ = subject.addTile("weather", to: clock.id)
        _ = subject.addTile("claude", to: clock.id)
        subject.moveTile(key("claude"), to: key("weather"))
        #expect(subject.tileRecords.map(\.key) == [key("claude"), key("weather")])
        #expect(subject.tileOrderRevision == 1)
    }
}

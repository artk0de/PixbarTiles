import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// Which tile's page each clock shows, and the settings window's follow: open
/// brings the tile's page up, close puts back the page from before.
@MainActor
@Suite struct PageFollowerTests {
    /// A clock that names its pages from a table and reports the one it shows.
    private final class PageClock: ConnectorRunning, ClockPageShowing, UlanziClockWatching, @unchecked Sendable {
        private let lock = NSLock()
        private let pages: [String: String]
        private var onScreen: String?
        private var switches: [String] = []
        /// Tiles whose page is not on the clock: taken off out of their hours.
        private var retracted: Set<String>

        init(pages: [String: String], onScreen: String?, retracted: Set<String> = []) {
            self.pages = pages
            self.onScreen = onScreen
            self.retracted = retracted
        }

        var shown: [String] { lock.withLock { switches } }

        func put(_ tileId: String) { lock.withLock { _ = retracted.remove(tileId) } }
        func takeOff(_ tileId: String) { lock.withLock { _ = retracted.insert(tileId) } }

        func page(forTile tileId: String) async throws -> String? {
            lock.withLock { retracted.contains(tileId) ? nil : pages[tileId] }
        }
        func currentPage() async throws -> String? { lock.withLock { onScreen } }
        func showPage(_ page: String) async throws {
            lock.withLock {
                switches.append(page)
                if onScreen != nil { onScreen = page }
            }
        }
        func clockReturned() async {}
        func verifyPages() async {}
        func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
        func runOnce(tile: TileRecord) async -> RunResult { .delivered }
        func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
        func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
        func restoreDeviceState(borrowedBy tileId: String?) async {}
        var indicators: IndicatorCustody? { nil }
    }

    private final class Reachable: ReachabilityReading {
        func clockIsUnreachable(_ clockId: UUID) -> Bool { false }
        func recheckClocks() {}
    }

    private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

    /// What the follower asked of the off-hours preview, in order.
    private final class Lending {
        var offHours: Set<String>
        var asks: [String] = []
        init(offHours: Set<String>) { self.offHours = offHours }
    }

    private func follower(
        _ clock: PageClock, paused: Set<String> = [], lending: Lending? = nil
    ) throws -> PageFollower {
        let tiles = TileStore(defaults: UserDefaults(suiteName: "pages-\(UUID().uuidString)")!)
        try tiles.replaceAll(["weather", "claude"].map { id in
            TileRecord(
                key: TileKey(clockId: desk.id, connectorId: id),
                policy: TilePolicyRecord(isPaused: paused.contains(id), refreshSeconds: 900)
            )
        })
        let sessions = ClockSessions(make: { _ in clock }, makeRegistry: nil)
        sessions.open(desk)
        return PageFollower(
            tiles: tiles, clockSessions: sessions, reachability: Reachable(),
            policy: { key in
                tiles.all().first { $0.key == key }.map { TilePolicy($0.policy, defaults: TilePolicy(refreshSeconds: 900)) }
            },
            offHours: lending.map { lending in
                OffHoursPreview(
                    isOffHours: { lending.offHours.contains($0.connectorId) },
                    deliver: { key in
                        lending.asks.append("deliver \(key.connectorId)")
                        clock.put(key.connectorId)
                    },
                    retract: { key in
                        lending.asks.append("retract \(key.connectorId)")
                        clock.takeOff(key.connectorId)
                    }
                )
            }
        )
    }

    private func key(_ connectorId: String) -> TileKey { TileKey(clockId: desk.id, connectorId: connectorId) }

    @Test func theSettingsWindowBringsTheTilesPageUpAndPutsTheOldOneBack() async throws {
        let clock = PageClock(pages: ["weather": "p-weather", "claude": "p-claude"], onScreen: "p-clock")
        let subject = try follower(clock)
        subject.openDetail(for: key("weather"))
        await subject.pageSwitchesSettled()
        #expect(subject.detailTileKey == key("weather"))
        #expect(subject.tileOnScreen[desk.id] == key("weather"))
        subject.closeDetail()
        await subject.pageSwitchesSettled()
        #expect(clock.shown == ["p-weather", "p-clock"])
        #expect(subject.tileOnScreen[desk.id] == nil)
    }

    @Test func aTileOutOfItsHoursIsPutOnTheClockWhileItsSettingsAreOpen() async throws {
        let clock = PageClock(pages: ["weather": "p-weather"], onScreen: nil, retracted: ["weather"])
        let lending = Lending(offHours: ["weather"])
        let subject = try follower(clock, lending: lending)
        subject.openDetail(for: key("weather"))
        await subject.pageSwitchesSettled()
        #expect(lending.asks == ["deliver weather"])
        #expect(clock.shown == ["p-weather"])
        subject.closeDetail()
        await subject.pageSwitchesSettled()
        #expect(lending.asks == ["deliver weather", "retract weather"])
    }

    @Test func aTileInItsHoursIsNeitherDeliveredNorTakenOff() async throws {
        let clock = PageClock(pages: ["weather": "p-weather"], onScreen: nil)
        let lending = Lending(offHours: [])
        let subject = try follower(clock, lending: lending)
        subject.openDetail(for: key("weather"))
        subject.closeDetail()
        await subject.pageSwitchesSettled()
        #expect(lending.asks.isEmpty)
        #expect(clock.shown == ["p-weather"])
    }

    @Test func reAimingTakesTheLentTileBackOff() async throws {
        let clock = PageClock(pages: ["weather": "p-weather", "claude": "p-claude"], onScreen: nil, retracted: ["weather"])
        let lending = Lending(offHours: ["weather"])
        let subject = try follower(clock, lending: lending)
        subject.openDetail(for: key("weather"))
        subject.openDetail(for: key("claude"))
        await subject.pageSwitchesSettled()
        #expect(lending.asks == ["deliver weather", "retract weather"])
        #expect(clock.shown == ["p-weather", "p-claude"])
    }

    @Test func aTileWhoseHoursBeganWhileOpenStaysOnTheClock() async throws {
        let clock = PageClock(pages: ["weather": "p-weather"], onScreen: nil, retracted: ["weather"])
        let lending = Lending(offHours: ["weather"])
        let subject = try follower(clock, lending: lending)
        subject.openDetail(for: key("weather"))
        await subject.pageSwitchesSettled()
        lending.offHours = []
        subject.closeDetail()
        await subject.pageSwitchesSettled()
        #expect(lending.asks == ["deliver weather"])
        #expect(subject.isLending(key("weather")) == false)
    }

    @Test func aPausedTileOwnsNoPage() throws {
        let clock = PageClock(pages: [:], onScreen: nil)
        let subject = try follower(clock, paused: ["claude"])
        #expect(subject.ownsPage(key("weather")))
        #expect(subject.ownsPage(key("claude")) == false)
        #expect(subject.ownsPage(TileKey(clockId: desk.id, connectorId: VPNConnector.id)) == false)
    }

    @Test func aClockThatReturnedForgetsWhichPageTheAppPutUp() async throws {
        let clock = PageClock(pages: ["weather": "p-weather"], onScreen: nil)
        let subject = try follower(clock)
        subject.showOnClock(key("weather"))
        await subject.pageSwitchesSettled()
        #expect(subject.tileOnScreen[desk.id] == key("weather"))
        await subject.ulanziWatcher(for: desk.id)?.clockReturned()
        #expect(subject.tileOnScreen[desk.id] == nil)
    }
}

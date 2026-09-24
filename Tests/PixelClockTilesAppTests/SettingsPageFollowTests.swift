import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Opening a tile's settings brings that tile's page up on its clock, so the
// user sees what the controls change without turning the knob; closing the
// window puts the clock back on the page it showed before — when the clock
// could say which page that was. The user asked for it, which is what makes
// it allowed: every automatic path still leaves the page alone (D3).

/// A clock slot that answers the page questions from a table and records every
/// switch it is asked for.
private final class SpyPageClock: ConnectorRunning, ClockPageShowing, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [String: String]
    private var onScreen: String?
    private var switches: [String] = []
    private var lookups: [String] = []
    private let refuseSwitch: Bool

    init(pages: [String: String], onScreen: String?, refuseSwitch: Bool = false) {
        self.pages = pages
        self.onScreen = onScreen
        self.refuseSwitch = refuseSwitch
    }

    /// Every page the model asked to bring on screen, in order.
    var shown: [String] { lock.withLock { switches } }
    /// Every tile whose page was looked up.
    var looked: [String] { lock.withLock { lookups } }

    func page(forTile tileId: String) async throws -> String? {
        lock.withLock {
            lookups.append(tileId)
            return pages[tileId]
        }
    }
    func currentPage() async throws -> String? { lock.withLock { onScreen } }
    func showPage(_ page: String) async throws {
        try lock.withLock {
            switches.append(page)
            if refuseSwitch { throw URLError(.cannotConnectToHost) }
        }
    }

    func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
    func runOnce(tile: TileRecord) async -> RunResult { .delivered }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
    func restoreDeviceState(borrowedBy tileId: String?) async {}
    var indicators: IndicatorCustody? { nil }
}

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

private func tile(_ connectorId: String, paused: Bool = false, on clock: ClockRecord = desk) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connectorId),
        policy: TilePolicyRecord(isPaused: paused, refreshSeconds: 900)
    )
}

@MainActor
private func model(_ clock: SpyPageClock, tiles: [TileRecord]) -> AppModel {
    testModel(
        connectors: [
            StubConnector(id: "weather", displayName: "Weather"),
            StubConnector(id: "claude", displayName: "Claude"),
        ],
        clocks: [desk], tiles: tiles, sessions: [desk.id: clock]
    )
}

@Test @MainActor func openingATilesSettingsBringsItsPageUp() async {
    let clock = SpyPageClock(pages: ["weather": "weather"], onScreen: "Time")
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["weather"])
    await subject.teardown()
}

@Test @MainActor func closingPutsTheClockBackOnThePageItShowedBefore() async {
    let clock = SpyPageClock(pages: ["weather": "weather"], onScreen: "Time")
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["weather", "Time"])
    await subject.teardown()
}

// The window moving to another tile follows it, and the page put back at the
// end is the one from before the FIRST open — not the first tile's.
@Test @MainActor func movingToAnotherTileThenClosingReturnsToTheOriginalPage() async {
    let clock = SpyPageClock(pages: ["weather": "weather", "claude": "claude"], onScreen: "Time")
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.openDetail(for: weather.key)
    subject.openDetail(for: claude.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["weather", "claude", "Time"])
    await subject.teardown()
}

// A clock that cannot say what it showed — the TC002 — is switched and then
// left where the window put it: there is nothing known to go back to.
@Test @MainActor func anUnknownPageBeforeIsNotRestored() async {
    let clock = SpyPageClock(pages: ["weather": "pct-weather"], onScreen: nil)
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["pct-weather"])
    await subject.teardown()
}

// Already on the tile's page: nothing to switch, and nothing to put back.
@Test @MainActor func aClockAlreadyOnThePageIsNotTouched() async {
    let clock = SpyPageClock(pages: ["weather": "weather"], onScreen: "weather")
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown.isEmpty)
    await subject.teardown()
}

// The VPN lamp owns no page: it lights a corner of whatever is on screen.
@Test @MainActor func theVPNLampSwitchesNothing() async {
    let clock = SpyPageClock(pages: [VPNConnector.id: "vpn"], onScreen: "Time")
    let lamp = tile(VPNConnector.id)
    let subject = model(clock, tiles: [lamp])

    subject.openDetail(for: lamp.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown.isEmpty)
    #expect(clock.looked.isEmpty)
    await subject.teardown()
}

// A paused tile's page is not its content, and one not on the clock yet has
// no page at all: neither is a reason to move the clock.
@Test @MainActor func aPausedTileSwitchesNothing() async {
    let clock = SpyPageClock(pages: ["weather": "weather"], onScreen: "Time")
    let weather = tile("weather", paused: true)
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown.isEmpty)
    await subject.teardown()
}

@Test @MainActor func aTileWithNoPageOnTheClockSwitchesNothing() async {
    let clock = SpyPageClock(pages: [:], onScreen: "Time")
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown.isEmpty)
    await subject.teardown()
}

// A switch the clock refuses is silent — the window stays open on its tile —
// and since the clock never moved, closing has nothing to put back.
@Test @MainActor func aRefusedSwitchIsSilentAndLeavesNothingToRestore() async {
    let clock = SpyPageClock(pages: ["weather": "weather"], onScreen: "Time", refuseSwitch: true)
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    await subject.pageSwitchesSettled()
    #expect(subject.detailTileKey == weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["weather"])
    await subject.teardown()
}

import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// Opening a tile's settings brings that tile's page up on its clock, so the
// user sees what the controls change without turning the knob; closing the
// window puts the clock back on the page it showed before — when the clock
// could say which page that was. The user asked for it, which is what makes
// it allowed: every automatic path still leaves the page alone (D3).

/// A clock slot that answers the page questions from a table and records every
/// switch it is asked for.
private final class SpyPageClock: ConnectorRunning, ClockPageShowing, UlanziClockWatching, @unchecked Sendable {
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

    private var returnsHeard = 0
    /// How many times the reachability poll's "the clock returned" got here.
    var returns: Int { lock.withLock { returnsHeard } }
    func clockReturned() async { lock.withLock { returnsHeard += 1 } }
    func verifyPages() async {}

    /// Someone turned the clock's knob: a readable clock now reports this page.
    func turnKnob(to page: String) { lock.withLock { onScreen = page } }

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
            // A clock that reports its page reports the one it was moved to.
            if onScreen != nil { onScreen = page }
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
    let clock = SpyPageClock(pages: ["weather": "pbt-weather"], onScreen: nil)
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["pbt-weather"])
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

// MARK: - The eye on a tile card

// The card's eye is open on the tile whose page the clock is showing, read
// when the list appears.
@Test @MainActor func theListLearnsWhichTileIsOnScreen() async {
    let clock = SpyPageClock(pages: ["weather": "weather", "claude": "claude"], onScreen: "claude")
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.refreshTileOnScreen(clockId: desk.id)
    await subject.pageSwitchesSettled()

    #expect(subject.tileOnScreen[desk.id] == claude.key)
    #expect(clock.shown.isEmpty)
    await subject.teardown()
}

// A page that is none of ours — the clock's own Time — opens no eye.
@Test @MainActor func aPageOfTheClocksOwnOpensNoEye() async {
    let clock = SpyPageClock(pages: ["weather": "weather"], onScreen: "Time")
    let subject = model(clock, tiles: [tile("weather")])

    subject.refreshTileOnScreen(clockId: desk.id)
    await subject.pageSwitchesSettled()

    #expect(subject.tileOnScreen[desk.id] == nil)
    await subject.teardown()
}

// Clicking a closed eye brings that tile's page up, and the eye opens.
@Test @MainActor func clickingAnEyeShowsThatTileAndOpensItsEye() async {
    let clock = SpyPageClock(pages: ["weather": "weather", "claude": "claude"], onScreen: "weather")
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.showOnClock(claude.key)
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["claude"])
    #expect(subject.tileOnScreen[desk.id] == claude.key)
    await subject.teardown()
}

// The TC002 cannot say what is on screen, so the app believes what it last put
// there itself: the clicked tile's eye opens, the others stay closed.
@Test @MainActor func onAClockThatCannotSayTheClickedEyeOpens() async {
    let clock = SpyPageClock(pages: ["weather": "pbt-weather", "claude": "pbt-claude"], onScreen: nil)
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.showOnClock(weather.key)
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["pbt-weather"])
    #expect(subject.tileOnScreen[desk.id] == weather.key)
    await subject.teardown()
}

// A second click moves the belief — and the open eye — to the other tile.
@Test @MainActor func onAClockThatCannotSayASecondClickMovesTheEye() async {
    let clock = SpyPageClock(pages: ["weather": "pbt-weather", "claude": "pbt-claude"], onScreen: nil)
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.showOnClock(weather.key)
    subject.showOnClock(claude.key)
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["pbt-weather", "pbt-claude"])
    #expect(subject.tileOnScreen[desk.id] == claude.key)
    // The list appearing again reads the same belief, not nothing.
    subject.refreshTileOnScreen(clockId: desk.id)
    await subject.pageSwitchesSettled()
    #expect(subject.tileOnScreen[desk.id] == claude.key)
    await subject.teardown()
}

// The settings window's follow is the app putting a page up too: on a clock
// that cannot say, the followed tile's eye opens, and stays open after the
// close — the TC002 is left where the window put it.
@Test @MainActor func onAClockThatCannotSayTheFollowedTilesEyeOpens() async {
    let clock = SpyPageClock(pages: ["weather": "pbt-weather"], onScreen: nil)
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.openDetail(for: weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(subject.tileOnScreen[desk.id] == weather.key)
    await subject.teardown()
}

// A switch the clock refused put nothing up: no belief, no open eye.
@Test @MainActor func aRefusedClickOpensNoEye() async {
    let clock = SpyPageClock(pages: ["weather": "pbt-weather"], onScreen: nil, refuseSwitch: true)
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])

    subject.showOnClock(weather.key)
    await subject.pageSwitchesSettled()

    #expect(subject.tileOnScreen[desk.id] == nil)
    await subject.teardown()
}

// A clock that returned — from an outage, or a zkgui restart — has rebuilt its
// page set and shows whatever it booted to: the belief is forgotten, every eye
// closes. Heard through the same watcher the reachability poll tells.
@Test @MainActor func aReturnedClockForgetsWhichPageTheAppPutUp() async throws {
    let clock = SpyPageClock(pages: ["weather": "pbt-weather"], onScreen: nil)
    let weather = tile("weather")
    let subject = model(clock, tiles: [weather])
    subject.showOnClock(weather.key)
    await subject.pageSwitchesSettled()
    #expect(subject.tileOnScreen[desk.id] == weather.key)

    await (try #require(subject.ulanziWatcher(for: desk.id))).clockReturned()

    #expect(subject.tileOnScreen[desk.id] == nil)
    #expect(clock.returns == 1)                     // the session still hears it
    subject.refreshTileOnScreen(clockId: desk.id)
    await subject.pageSwitchesSettled()
    #expect(subject.tileOnScreen[desk.id] == nil)
    await subject.teardown()
}

// A clock that CAN say (the AWTRIX) is believed over the app: the knob turned
// after a click, and the eye follows the clock, not the click.
@Test @MainActor func aReadableClockWinsOverWhatTheAppLastShowed() async {
    let clock = SpyPageClock(pages: ["weather": "weather", "claude": "claude"], onScreen: "Time")
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])
    subject.showOnClock(claude.key)
    await subject.pageSwitchesSettled()

    clock.turnKnob(to: "weather")
    subject.refreshTileOnScreen(clockId: desk.id)
    await subject.pageSwitchesSettled()

    #expect(subject.tileOnScreen[desk.id] == weather.key)
    await subject.teardown()
}

// The settings window closing puts the AWTRIX back on its page from before —
// and the eye goes back with it.
@Test @MainActor func theRestoredPageIsTheOneWhoseEyeIsOpen() async {
    let clock = SpyPageClock(pages: ["weather": "weather", "claude": "claude"], onScreen: "claude")
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.openDetail(for: weather.key)
    await subject.pageSwitchesSettled()
    #expect(subject.tileOnScreen[desk.id] == weather.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["weather", "claude"])
    #expect(subject.tileOnScreen[desk.id] == claude.key)
    await subject.teardown()
}

// The lamp and a paused tile own no page, so their cards carry no eye.
@Test @MainActor func onlyTilesWithAPageCarryAnEye() async {
    let clock = SpyPageClock(pages: [:], onScreen: nil)
    let weather = tile("weather")
    let paused = tile("claude", paused: true)
    let lamp = tile(VPNConnector.id)
    let subject = model(clock, tiles: [weather, paused, lamp])

    #expect(subject.ownsPage(weather.key))
    #expect(subject.ownsPage(paused.key) == false)
    #expect(subject.ownsPage(lamp.key) == false)
    await subject.teardown()
}

// An eye clicked while a tile's settings are open is the user choosing the
// page: closing the window afterwards does not take it back.
@Test @MainActor func anEyeClickWhileSettingsAreOpenIsNotUndoneByTheClose() async {
    let clock = SpyPageClock(pages: ["weather": "weather", "claude": "claude"], onScreen: "Time")
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = model(clock, tiles: [weather, claude])

    subject.openDetail(for: weather.key)
    subject.showOnClock(claude.key)
    subject.closeDetail()
    await subject.pageSwitchesSettled()

    #expect(clock.shown == ["weather", "claude"])
    await subject.teardown()
}

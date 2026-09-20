import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Every tile is held by its own policy now, and the words the panel shows are
// the ones `FocusGate` used, so nothing the user reads changes with the move.

private func tileOf(_ connector: String, _ policy: TilePolicy, on clock: ClockRecord) -> TileRecord {
    TileRecord(key: TileKey(clockId: clock.id, connectorId: connector), policy: TilePolicyRecord(policy))
}

private let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")

@Test @MainActor func aTileInItsQuietHoursIsHeldAndSaysSo() async {
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "anecdotes")],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .noFocus),
        now: { atHour(3) },
        clocks: [clock],
        tiles: [tileOf("anecdotes", TileDefaults.anecdotes, on: clock)]
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["anecdotes"] == .held(AppModel.duringQuietHours) })
    #expect(host.calls.contains("run:anecdotes") == false)
    await subject.teardown()
}

@Test @MainActor func aTileIsHeldByAFocusItDoesNotWorkIn() async {
    let host = SpyHost()
    // Silent, like the real Claude tile: the quiet rules reach it now only
    // because every tile carries a policy.
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")),
        now: { atHour(12) },
        clocks: [clock],
        tiles: [tileOf("claude", TileDefaults.claude, on: clock)]
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["claude"] == .held(AppModel.duringFocus) })
    #expect(host.calls.contains("run:claude") == false)
    await subject.teardown()
}

// The weather's row silences nothing, so a Sleep at 3 a.m. still draws the
// temperature — what the audible-only rule guaranteed before.
@Test @MainActor func theWeatherRunsThroughTheNightAndEveryFocus() async {
    let host = SpyHost()
    let schedule = Metronome()
    let subject = testModel(
        connectors: [StubConnector(id: "weather", isAudible: false)],
        host: host,
        sleep: schedule.sleep,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")),
        now: { atHour(3) },
        clocks: [clock],
        tiles: [tileOf("weather", TileDefaults.weather, on: clock)]
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })
    schedule.tick()

    #expect(await waitUntil { host.calls.contains("run:weather") })
    await subject.teardown()
}

// A record Phase 1 wrote has no Focus rule and no hours, and is read as its
// connector's row — which for the anecdotes is the night off.
@Test @MainActor func aTileStoredBeforePhaseFourIsHeldByItsConnectorsRow() async {
    let host = SpyHost()
    let old = TileRecord(
        key: TileKey(clockId: clock.id, connectorId: "anecdotes"),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 1_800)
    )
    let subject = testModel(
        connectors: [AnecdoteRowConnector()],
        host: host,
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .noFocus),
        now: { atHour(3) },
        clocks: [clock],
        tiles: [old]
    )

    subject.start()

    #expect(await waitUntil { subject.nextRun["anecdotes"] == .held(AppModel.duringQuietHours) })
    await subject.teardown()
}

/// A stub whose default is the anecdote row, so the mapping has a row to read.
private struct AnecdoteRowConnector: Connector {
    let id = "anecdotes"
    let displayName = "Anecdotes"
    let defaultInterval: TimeInterval = 1_800
    var defaultPolicy: TilePolicy { TileDefaults.anecdotes }
    func read() async throws -> String { "" }
    var awtrixFace: AwtrixFace<String> { AwtrixFace { AwtrixDelivery(text: $0) } }
}

// MARK: - The anecdotes row, read as a Focus rule

// The two claims that changed ON PURPOSE with the move (spec § Persistence,
// "Behaviour that changes on purpose"): the app-wide gate spoke through every
// Focus it could not name, so Fitness spoke too; the anecdotes row keeps its
// tile for any Focus it cannot tell apart, because it is the one tile that
// speaks.

@Test func aFocusOutsideTheFourNowHoldsTheAnecdotes() {
    let row = TileDefaults.anecdotes
    // Fitness is a named mode the kit does not map, so it resolves to
    // `.unknown` — the Other Focus — and the anecdote row keeps its tile
    // there, because it is the one tile that speaks.
    let fitness = MacFocus(modeIdentifier: "com.apple.focus.fitness")

    #expect(row.hold(in: fitness, atHour: 12) == .focus)
}

@Test func workAndPersonalSpeakThroughTheAnecdotesRow() {
    let row = TileDefaults.anecdotes

    #expect(row.hold(in: .work, atHour: 12) == nil)
    #expect(row.hold(in: .personal, atHour: 12) == nil)
}

import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Every tile is held by its own policy now, and the words the panel shows are
// the ones the app-wide gate used, so nothing the user reads changes.

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
        tiles: [tileOf("claude", TileDefaults.codeUsage, on: clock)]
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

// MARK: - The modes, read the way the app-wide gate read them

// The same five claims the gate's own suite made, now through
// `MacFocus.resolved` and the anecdotes row — the row whose Focus rule is the
// one the gate carried.

private func anecdotesHolds(access: FocusAccess, mode: ActiveFocusMode, focused: Bool) -> Bool {
    TileDefaults.anecdotes
        .hold(in: MacFocus.resolved(access: access, activeMode: mode, isFocused: focused), atHour: 12) != nil
}

@Test func doNotDisturbAndSleepSilenceTheSchedule() {
    #expect(anecdotesHolds(access: .authorized, mode: .mode("com.apple.donotdisturb.mode.default"), focused: true))
    #expect(anecdotesHolds(access: .authorized, mode: .mode("com.apple.sleep.sleep-mode"), focused: true))
}

// The whole point of the task. macOS reports a Focus, the app is authorized to
// believe it, and it speaks anyway — because the Focus is Work, and being at
// work is not a reason to be quiet. Reading, which no list here can be asked
// to enumerate, is the one that CHANGED on purpose: the row keeps its tile for
// a Focus it cannot tell apart.
@Test func everyOtherFocusIsSpokenThrough() {
    #expect(anecdotesHolds(access: .authorized, mode: .mode("com.apple.focus.work"), focused: true) == false)
    #expect(anecdotesHolds(access: .authorized, mode: .mode("com.apple.focus.personal"), focused: true) == false)
    // A Focus the user made themselves, which is an identifier no list can
    // enumerate. Holding it is the behaviour that CHANGED on purpose with the
    // move: the app-wide gate spoke through every Focus it could not name.
    #expect(anecdotesHolds(access: .authorized, mode: .mode("com.apple.focus.reading"), focused: true))
}

// The idle Mac, end to end: the real file that names Do Not Disturb five times
// and has nothing asserted, through the parser, into the resolution. It speaks.
@Test func anIdleMacSpeaks() {
    let idle = MacFocus.resolved(
        access: .authorized,
        activeMode: DoNotDisturbDatabase.activeMode(
            inAssertions: Data(CapturedFocusDatabase.noFocus.utf8)
        ),
        isFocused: false
    )

    #expect(TileDefaults.anecdotes.hold(in: idle, atHour: 12) == nil)
}

// The fallback, and the direction it leans is deliberate. Told nothing about
// which Focus is on, the resolution goes back to the boolean and treats every
// Focus as the Other one — being quiet when it could have spoken is a joke the
// user misses, and the other way round is what wakes somebody at three in the
// morning.
@Test func aDatabaseThisAppCannotReadFallsBackToTheBoolean() {
    #expect(anecdotesHolds(access: .authorized, mode: .cannotTell, focused: true))
    // Not a mute: the boolean still decides both ways.
    #expect(anecdotesHolds(access: .authorized, mode: .cannotTell, focused: false) == false)
}

// The mode is read on ONE of the two branches, exactly as `isFocused` is. A
// centre this app may not believe is a centre whose database it has no business
// acting on either — the user's own hours are what stand in, and a Work
// assertion must not reopen the night.
@Test func theModeIsNotConsultedWhileTheCenterIsUnauthorized() {
    let row = TilePolicy(
        refreshSeconds: TileDefaults.anecdotes.refreshSeconds,
        focus: TileDefaults.anecdotes.focus,
        window: .quiet(HourWindow(startHour: 23, endHour: 8))
    )
    let resolved = MacFocus.resolved(
        access: .denied, activeMode: .mode("com.apple.focus.work"), isFocused: false
    )

    #expect(row.hold(in: resolved, atHour: 3) == .hours)
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

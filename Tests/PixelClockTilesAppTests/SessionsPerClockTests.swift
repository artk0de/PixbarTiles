import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Two clocks, two sessions, and a tile only ever reaches the clock it is on.
// A clock that stops answering holds up only its own tiles; a quit gives every
// clock back at once, inside the budget one clock had.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")

private func tile(_ connector: String, on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connector),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )
}

@Test @MainActor func eachTileRunsThroughTheSessionOfItsOwnClock() async {
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "weather"), StubConnector(id: "claude")],
        clocks: [desk, kitchen],
        tiles: [tile("weather", on: desk), tile("claude", on: kitchen)],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.runNow(TileKey(clockId: desk.id, connectorId: "weather"))
    subject.runNow(TileKey(clockId: kitchen.id, connectorId: "claude"))

    #expect(await waitUntil { onDesk.calls.contains("run:weather") && inKitchen.calls.contains("run:claude") })
    #expect(onDesk.calls.contains("run:claude") == false)
    #expect(inKitchen.calls.contains("run:weather") == false)
}

// The same connector on two clocks is two tiles with two schedules, and each
// asks its own session how long to wait — a backoff on one is not the other's.
@Test @MainActor func theSameConnectorOnTwoClocksIsTwoSchedules() async {
    let schedule = Metronome()
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "weather")],
        sleep: schedule.sleep,
        clocks: [desk, kitchen],
        tiles: [tile("weather", on: desk), tile("weather", on: kitchen)],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.start()

    #expect(await waitUntil { schedule.parked == 2 })
    #expect(onDesk.delayQueries == 1)
    #expect(inKitchen.delayQueries == 1)
    await subject.teardown()
}

// Both restores are entered before either is let go: a second clock does not
// double what a quit may take.
@Test @MainActor func quittingGivesEveryClockBackAtOnce() async {
    let gate = Gate()
    let onDesk = SpyHost(parkInRestore: gate)
    let inKitchen = SpyHost(parkInRestore: gate)
    let subject = testModel(clocks: [desk, kitchen], tiles: [], sessions: [desk.id: onDesk, kitchen.id: inKitchen])

    let quit = Task { await subject.teardown() }

    #expect(await waitUntil { gate.enteredCount == 2 })
    gate.open()
    await quit.value
    #expect(onDesk.calls.contains("restore:all"))
    #expect(inKitchen.calls.contains("restore:all"))
}

@Test @MainActor func aClockTakenOutOfTheListIsGivenBackAndItsTilesStop() async throws {
    let schedule = Metronome()
    let inKitchen = SpyHost()
    let defaults = try #require(UserDefaults(suiteName: "sessions-\(UUID().uuidString)"))
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        defaults: defaults,
        sleep: schedule.sleep,
        clocks: [desk, kitchen],
        tiles: [tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: inKitchen]
    )
    subject.start()
    #expect(await waitUntil { schedule.parked == 1 })

    try ClockStore(defaults: defaults).replaceAll([desk])
    subject.reloadClocks()

    #expect(await waitUntil { inKitchen.calls.contains("restore:all") })
    #expect(subject.clocks == [desk])
    // And its schedule is gone with it, not merely muted: the loop's sleeper
    // was cancelled, so the tick releases nothing.
    #expect(await waitUntil { schedule.parked == 0 })
    schedule.tick()
    #expect(await waitUntil({ inKitchen.calls.contains("run:claude") }, limit: 0.1) == false)
    await subject.teardown()
}

@Test @MainActor func aClockAddedToTheListGetsASessionAndItsTilesRun() async throws {
    let defaults = try #require(UserDefaults(suiteName: "sessions-\(UUID().uuidString)"))
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        defaults: defaults,
        clocks: [desk],
        tiles: [],
        sessions: [kitchen.id: inKitchen]
    )

    try ClockStore(defaults: defaults).replaceAll([desk, kitchen])
    try TileStore(defaults: defaults).replaceAll([tile("claude", on: kitchen)])
    subject.reloadClocks()
    subject.runNow(TileKey(clockId: kitchen.id, connectorId: "claude"))

    #expect(await waitUntil { inKitchen.calls.contains("run:claude") })
}

// The History is the anecdote tile's, and Play again goes to its clock.
@Test @MainActor func playAgainGoesThroughTheClockTheAnecdoteTileIsOn() async throws {
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let anecdote = try playableAnecdote(id: "a1", text: "joke")
    let subject = testModel(
        connectors: [StubConnector(id: "anecdotes")],
        anecdotes: StubAnecdotes(id: "anecdotes"),
        clocks: [desk, kitchen],
        tiles: [tile("anecdotes", on: kitchen)],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.replay(anecdote)

    #expect(await waitUntil { inKitchen.calls.contains { $0.hasPrefix("deliver:") } })
    #expect(onDesk.calls.contains { $0.hasPrefix("deliver:") } == false)
}

// Until Phase 5 draws tiles, the panel reads rows by connector — the selected
// clock's.
@Test @MainActor func thePanelShowsTheSelectedClocksTiles() async {
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        clocks: [desk, kitchen],
        tiles: [tile("claude", on: desk), tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )

    subject.selectedClockId = kitchen.id
    subject.runNow(TileKey(clockId: kitchen.id, connectorId: "claude"))

    #expect(await waitUntil { subject.lastResults["claude"] != nil })
    subject.selectedClockId = desk.id
    #expect(subject.lastResults["claude"] == nil)
}

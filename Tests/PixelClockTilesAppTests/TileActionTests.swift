import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The four actions the rows carry, per tile: add, run now, pause, remove.
// The custody behind them is the sessions' own work — these pin what the
// panel's intent reaches on each clock's wire.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")

@Test @MainActor func aRunNowDeliversExactlyOnceThroughTheTilesSession() async {
    let host = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "weather")],
        host: host,
        clocks: [desk],
        tiles: [TileRecord(
            key: TileKey(clockId: desk.id, connectorId: "weather"),
            policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
        )]
    )

    subject.runNow(TileKey(clockId: desk.id, connectorId: "weather"))

    #expect(await waitUntil { host.calls.contains("run:weather") })
    // Once means once: nothing second arrives while the first is on the wire.
    #expect(
        await waitUntil({ host.calls.filter { $0 == "run:weather" }.count > 1 }, limit: 0.1)
            == false
    )
}

// The pause is the disable the schedule has always known, named by tile: the
// record flips, and what the tile borrowed goes back at once.
@Test @MainActor func pausingATileOnTheAwtrixBehavesAsDisablingDoes() async {
    let host = SpyHost()
    let key = TileKey(clockId: desk.id, connectorId: "claude")
    let subject = testModel(
        connectors: [StubConnector(id: "claude")],
        host: host,
        clocks: [desk],
        tiles: [TileRecord(key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600))]
    )

    subject.setPaused(true, tile: key)

    #expect(await waitUntil { host.calls.contains("restore:claude") })
    #expect(subject.storedPolicy(of: key)?.isPaused == true)
}

// D4: paused on the TC002, never deleted — the page keeps its place in the
// knob cycle on the idle frame, and no empty-body delete ever goes out.
@Test @MainActor func pausingATileOnTheTC002MarksThePageIdleAndNeverDeletes() async throws {
    let (transport, subject, key) = try liveTC002()

    subject.setPaused(true, tile: key)

    #expect(await waitUntil {
        transport.requests.contains { request in
            request.httpMethod == "POST"
                && request.url?.query == "name=pct-weather"
                && (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())
                    as? [String: Any])?["draw"] != nil
        }
    })
    #expect(
        transport.requests.contains { request in
            request.httpMethod == "POST"
                && request.url?.query == "name=pct-weather"
                && (request.httpBody ?? Data()).isEmpty
        } == false
    )
}

// Phase-3 A9 on the removal path: the page leaves the knob cycle, and the
// measured contract is the EMPTY body — a `{}` body would update the app to
// nothing visible and leave it turning.
@Test @MainActor func removingATileOnTheTC002PostsTheEmptyBodyDelete() async throws {
    let (transport, subject, key) = try liveTC002()
    // The page is on the clock: its name was claimed by the one delivery a
    // running tile makes. Removal presupposes that state.
    let ulanzi = try #require(subject.ulanzi)
    _ = await ulanzi.deliver(UlanziDelivery(scene: plainScene()), toTile: "weather")
    let claim = transport.requests.count

    subject.removeTile(key)

    #expect(await waitUntil {
        transport.requests.contains { request in
            request.httpMethod == "POST"
                && request.url?.query == "name=pct-weather"
                && (request.httpBody ?? Data()).isEmpty
                && request.httpBodyStream == nil
        }
    })
    // And the record is gone, so nothing re-creates the page it took down.
    #expect(subject.storedPolicy(of: key) == nil)
}

// MARK: - A live model on one TC002 clock

/// One TC002 clock as the only one stored, a weather tile on it, and the
/// model `live()` builds over them. The key names the tile as the stored
/// clock itself does — the clock makes its own id.
@MainActor
private func liveTC002() throws -> (StubTransport, AppModel, TileKey) {
    let suite = "tile-action-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let tc002 = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "192.0.2.9")
    defaults.set(true, forKey: ClockMigration.markerKey)
    defaults.set(try JSONEncoder().encode([tc002]), forKey: ClockStore.key)
    let transport = StubTransport(body: Data(#"{"code":200,"message":"ok"}"#.utf8))
    let subject = AppModel.live(
        defaults: defaults,
        transport: transport,
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("tile-action-\(UUID().uuidString).json")
    )
    let key = TileKey(clockId: tc002.id, connectorId: "weather")
    try TileStore(defaults: defaults).replaceAll([TileRecord(
        key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )])
    return (transport, subject, key)
}

private func plainScene() -> UlanziScene {
    var canvas = PixelCanvas()
    canvas.fill(.white)
    return UlanziScene(frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])])
}

// MARK: - Reorder

// Dragging a row to a new place is the one action whose effect is only the
// store's order: the order IS the tiles record's order, and it is the same
// on every clock, so a reorder of one clock's rows must not disturb any
// other clock's place in the record.

@Test @MainActor func draggingARowReordersTheSelectedClocksTiles() {
    let loft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.6")
    let subject = testModel(
        connectors: [
            StubConnector(id: "weather"),
            StubConnector(id: "claude"),
            StubConnector(id: "anecdotes"),
        ],
        clocks: [desk, loft],
        tiles: [
            assembledRecord("weather", on: desk),
            assembledRecord("claude", on: desk),
            assembledRecord("anecdotes", on: desk),
            assembledRecord("weather", on: loft),
            assembledRecord("claude", on: loft),
        ]
    )

    // The second row dragged onto where the first stands: it takes that
    // place, and everything else keeps its relative order.
    subject.moveTile(assembledKey("claude", on: desk), to: assembledKey("weather", on: desk))

    let order = subject.tileRows.map { $0.key.connectorId }
    #expect(order == ["claude", "weather", "anecdotes"])
    // And the other clock's order is untouched, inside the same record.
    subject.selectedClockId = loft.id
    #expect(subject.tileRows.map { $0.key.connectorId } == ["weather", "claude"])
}

@Test @MainActor func aRowDroppedOnAnotherClocksRowIsNotAMove() {
    let loft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.6")
    let subject = testModel(
        connectors: [StubConnector(id: "weather"), StubConnector(id: "claude")],
        clocks: [desk, loft],
        tiles: [
            assembledRecord("weather", on: desk),
            assembledRecord("claude", on: desk),
            assembledRecord("weather", on: loft),
        ]
    )

    subject.moveTile(assembledKey("weather", on: desk), to: assembledKey("weather", on: loft))

    #expect(subject.tileRows.map { $0.key.connectorId } == ["weather", "claude"])
}

@Test @MainActor func aRowDroppedOntoItselfIsNotAMove() {
    let subject = testModel(
        connectors: [StubConnector(id: "weather"), StubConnector(id: "claude")],
        clocks: [desk],
        tiles: [
            assembledRecord("weather", on: desk),
            assembledRecord("claude", on: desk),
        ]
    )

    subject.moveTile(assembledKey("weather", on: desk), to: assembledKey("weather", on: desk))

    #expect(subject.tileRows.map { $0.key.connectorId } == ["weather", "claude"])
}

@Test @MainActor func aDragPayloadRoundTripsThroughTheKeyItNames() {
    let key = TileKey(clockId: desk.id, connectorId: "claude", instance: "pritunl")
    #expect(TileKey(dragPayload: key.dragPayload) == key)
}

private func assembledRecord(
    _ connector: String, on clock: ClockRecord
) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connector),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )
}

private func assembledKey(
    _ connector: String, on clock: ClockRecord
) -> TileKey {
    TileKey(clockId: clock.id, connectorId: connector)
}

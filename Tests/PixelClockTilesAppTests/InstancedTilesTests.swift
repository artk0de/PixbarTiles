import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// Two tiles of one connector on one clock — two repositories — are two tiles
// all the way down: the schedule runs each under its own key, and every event
// a tile raises names that tile's page and no other.

/// A connector one clock carries once per key, the shape the GitHub tile has.
private let perKeyConnector = StubConnector(
    id: "github", displayName: "GitHub", defaultInterval: 900, instancing: .perKey
)

private func repo(_ instance: String, on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: perKeyConnector.id, instance: instance),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900)
    )
}

/// The TC002 slot's event half, recorded: what the model asked the clock to do
/// to which page. Also the schedule's slot, since the model reaches the event
/// half through the schedule's by a cast — exactly as the shipped slot does.
private final class SpyPages: ConnectorRunning, UlanziConnectorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    /// `idle:<tileId>`, `removed:<tileId>`, `restore:<tileId>`, in call order.
    var events: [String] { lock.withLock { recorded } }

    private func note(_ event: String) { lock.withLock { recorded.append(event) } }

    func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
    func runOnce(tile: TileRecord) async -> RunResult { .delivered }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
    func restoreDeviceState(borrowedBy tileId: String?) async {
        note("restore:\(tileId ?? "all")")
    }
    var indicators: IndicatorCustody? { nil }

    func deliver(_ output: UlanziDelivery, toTile tileId: String) async -> RunResult { .delivered }
    func markIdle(tileId: String) async -> RunResult {
        note("idle:\(tileId)")
        return .delivered
    }
    func tileRemoved(_ tileId: String) async { note("removed:\(tileId)") }
    func shutdown() async {}
}

@Test @MainActor func twoInstancesOnOneClockRunIndependently() async {
    let host = SpyHost()
    let schedule = Metronome()
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let a = repo("a/x", on: desk)
    let b = repo("b/y", on: desk)
    let subject = testModel(
        connectors: [perKeyConnector], host: host, sleep: schedule.sleep,
        clocks: [desk], tiles: [a, b]
    )

    subject.start()
    #expect(await waitUntil { schedule.parked == 2 })
    schedule.tick()

    #expect(await waitUntil {
        host.calls.contains("run:\(a.key.tileId)") && host.calls.contains("run:\(b.key.tileId)")
    })
    // Never under the bare connector id: that would be one tile standing for both.
    #expect(host.calls.contains("run:github") == false)
    await subject.teardown()
}

@Test @MainActor func pausingOneInstanceIdlesOnlyItsPage() async {
    let pages = SpyPages()
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.5")
    let a = repo("a/x", on: kitchen)
    let b = repo("b/y", on: kitchen)
    let subject = testModel(
        connectors: [perKeyConnector], clocks: [kitchen], tiles: [a, b],
        sessions: [kitchen.id: pages]
    )

    subject.setPaused(true, tile: a.key)

    #expect(await waitUntil { pages.events.contains("idle:\(a.key.tileId)") })
    #expect(pages.events.allSatisfy { $0.hasSuffix(b.key.tileId) == false })
    await subject.teardown()
}

@Test @MainActor func removingOneInstanceReleasesOnlyItsPage() async {
    let pages = SpyPages()
    let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.5")
    let a = repo("a/x", on: kitchen)
    let b = repo("b/y", on: kitchen)
    let subject = testModel(
        connectors: [perKeyConnector], clocks: [kitchen], tiles: [a, b],
        sessions: [kitchen.id: pages]
    )

    subject.removeTile(a.key)

    #expect(await waitUntil {
        pages.events.contains("removed:\(a.key.tileId)")
            && pages.events.contains("restore:\(a.key.tileId)")
    })
    #expect(pages.events.allSatisfy { $0.hasSuffix(b.key.tileId) == false })
    #expect(subject.storedTile(b.key) != nil)
    await subject.teardown()
}

// A single tile's page keeps the name it has always been delivered under, so
// nothing already on a clock is orphaned by tiles becoming instanced.
@Test @MainActor func aSingleTileKeepsItsPageName() async {
    let host = SpyHost()
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let weather = StubConnector(id: "weather", displayName: "Weather")
    let subject = testModel(connectors: [weather], host: host, clocks: [desk])

    subject.runNow(TileKey(clockId: desk.id, connectorId: "weather"))

    #expect(await waitUntil { host.calls.contains("run:weather") })
    await subject.teardown()
}

// The panel's per-tile maps list a per-key connector's instances, each under
// its own tile id — the single tiles' entries keep their connector id.
@Test @MainActor func thePanelSeesEachInstanceUnderItsOwnName() async {
    let host = SpyHost()
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let a = repo("a/x", on: desk)
    let subject = testModel(
        connectors: [perKeyConnector], host: host, clocks: [desk], tiles: [a]
    )

    subject.runNow(a.key)

    #expect(await waitUntil { subject.lastResults[a.key.tileId] == AppModel.deliveredWord })
    await subject.teardown()
}

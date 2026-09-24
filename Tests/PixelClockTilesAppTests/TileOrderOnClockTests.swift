import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The TC002 runs its pages in the order they were created, and the tile list
// is the order the user means. A drag in the list tells the clock's slot at
// once, rather than waiting for the next reachability poll to notice.

/// A TC002 slot that records being told the order moved.
private final class SpyOrderedPages: ConnectorRunning, UlanziPageOrdering, @unchecked Sendable {
    private let lock = NSLock()
    private var told = 0
    var reorders: Int { lock.withLock { told } }

    func pagesReordered() async { lock.withLock { told += 1 } }

    func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }
    func runOnce(tile: TileRecord) async -> RunResult { .delivered }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
    func restoreDeviceState(borrowedBy tileId: String?) async {}
    var indicators: IndicatorCustody? { nil }
}

private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

private func tile(_ connectorId: String) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: kitchen.id, connectorId: connectorId),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 900)
    )
}

@Test @MainActor func aDragInTheListTellsTheClocksSlot() async {
    let pages = SpyOrderedPages()
    let weather = tile("weather")
    let claude = tile("claude")
    let subject = testModel(
        connectors: [
            StubConnector(id: "weather", displayName: "Weather"),
            StubConnector(id: "claude", displayName: "Claude"),
        ],
        clocks: [kitchen], tiles: [weather, claude], sessions: [kitchen.id: pages]
    )

    subject.moveTile(claude.key, to: weather.key)

    #expect(await waitUntil { pages.reorders == 1 })
    await subject.teardown()
}

@Test @MainActor func aMoveThatChangesNothingTellsNobody() async {
    let pages = SpyOrderedPages()
    let weather = tile("weather")
    let subject = testModel(
        connectors: [StubConnector(id: "weather", displayName: "Weather")],
        clocks: [kitchen], tiles: [weather], sessions: [kitchen.id: pages]
    )

    subject.moveTile(weather.key, to: weather.key)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(pages.reorders == 0)
    await subject.teardown()
}

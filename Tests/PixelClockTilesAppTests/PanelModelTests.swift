import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The panel's projection: every clock a section of STATISTICS — the status
// dot its session has earned, the connection in words, the battery beside it
// — and nothing else.
//
// The projection lags its model by one main-actor hop: `objectWillChange`
// delivers in `willSet`, so a rebuild run straight in the sink would read the
// state the change is about to replace. Every assertion on `sections` is
// therefore a `waitUntil` — and that is not patience, it is the mechanism.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")
private let loft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.7")

/// A host that delivers for its healthy connectors and fails for the named
/// ones — how one sick tile among healthy ones is posed without a second
/// clock: the host is the clock's, so the choice lives in it.
private struct SelectiveHost: ConnectorRunning {
    let failing: Set<String>

    init(failing: Set<String> = []) { self.failing = failing }

    func maintain(tile: TileRecord) async -> MaintenanceResult { .completed }
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval { interval }
    func runOnce(tile: TileRecord) async -> RunResult {
        failing.contains(tile.key.tileId) ? .failed("feed is down") : .delivered
    }
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .delivered }
    func restoreDeviceState(borrowedBy tileId: String?) async {}
    var indicators: IndicatorCustody? { nil }
}

// MARK: - Sections

@Test @MainActor func thePanelCarriesEveryClockInStoredOrder() {
    let model = testModel(clocks: [desk, kitchen], sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()])
    let subject = panel(model)

    // Sections in the clocks' own stored order — the order the settings
    // rearrange. The panel is the clocks' glance; what is ON each clock is
    // the clock-settings window's answer.
    #expect(subject.sections.map(\.clock.id) == [desk.id, kitchen.id])
    #expect(subject.sections.map(\.clock.name) == ["Desk", "Kitchen"])
}

@Test @MainActor func aSectionSaysTheTwoStatisticsThePanelExistsFor() {
    // Unstarted: the connection is still being checked, and no clock has
    // said anything about a battery — the AWTRIX has not answered and the
    // TC002 has no cell at all.
    let model = testModel(clocks: [desk, kitchen], sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()])
    let subject = panel(model)

    #expect(subject.sections[0].statusLine == "Checking…")
    #expect(subject.sections[0].batteryLine == nil)
    #expect(subject.sections[1].statusLine == "Checking…")
    #expect(subject.sections[1].batteryLine == nil)
}

@Test @MainActor func aModelWithNoClocksHasNoSectionsAndSaysSo() {
    // Empty on purpose: the factory invents a default clock for every other
    // test, and this one is about the absence. The tiles go with it — the
    // factory's default tiles hang on a first clock that is not there.
    let subject = panel(testModel(clocks: [], tiles: []))

    #expect(subject.hasNoClocks)
    #expect(subject.sections.isEmpty)
}

// MARK: - The dot

// The dot is the CONNECTION and nothing else. A failed push is the failed
// TILE's to wear — the red warning sign on its card — never the clock's.
@Test func theStatusDotIsThreeValued() {
    typealias Dot = PanelModel.ClockDot
    #expect(PanelModel.dot(reachability: .unreachable, push: .delivered) == Dot.red)
    #expect(PanelModel.dot(reachability: .unreachable, push: .none) == Dot.red)
    #expect(PanelModel.dot(reachability: .unknown, push: .none) == Dot.yellow)
    #expect(PanelModel.dot(reachability: .unknown, push: .running) == Dot.yellow)
    #expect(PanelModel.dot(reachability: .reachable, push: .running) == Dot.yellow)
    #expect(PanelModel.dot(reachability: .reachable, push: .none) == Dot.green)
    #expect(PanelModel.dot(reachability: .reachable, push: .delivered) == Dot.green)
    // The correction's own case: connected, last push failed — the clock is
    // still connected.
    #expect(PanelModel.dot(reachability: .reachable, push: .failed) == Dot.green)
}

@Test @MainActor func aClockWithNothingPushedYetIsYellow() {
    // Unstarted, so the monitor has never asked and nothing has ever pushed:
    // the launch state, and the one the yellow dot exists to name.
    let subject = panel(testModel())

    #expect(subject.sections[0].dot == .yellow)
}

@Test @MainActor func aClockWithARunUnderWayIsYellowUntilItDeliversAndGreenAfter() async {
    let model = testModel(host: SpyHost())
    let subject = panel(model)

    model.runNow("stub")
    #expect(await waitUntil { subject.sections[0].dot == .green })
}

@Test @MainActor func aClockThatStopsAnsweringIsRed() async {
    let model = testModel(
        transport: StubTransport(failure: URLError(.cannotConnectToHost)),
        pollSleep: parked
    )
    let subject = panel(model)
    model.start()
    #expect(await waitUntil { isOffline(model) })

    #expect(await waitUntil { subject.sections[0].dot == .red })
    await model.teardown()
}

// A failure on ONE tile is THAT TILE's to wear — the clock's dot stays the
// connection's truth (green: the clock is answering). The failure surfaces
// on the tile's card: the model keeps the failure where the card's red sign
// and hover words read it.
@Test @MainActor func aFailingTileWearsTheFailureAndTheClockStaysConnected() async {
    let model = testModel(
        connectors: [
            StubConnector(id: "first", displayName: "First"),
            StubConnector(id: "second", displayName: "Second", isAudible: false),
        ],
        host: SelectiveHost(failing: ["second"])
    )
    let subject = panel(model)
    // Started, so the clock's own answer is the connection truth the dot
    // reads — a tile failing does not reach into it.
    model.start()
    #expect(await waitUntil { model.isDeviceOnline })

    model.runNow("second")
    #expect(
        await waitUntil {
            model.lastFailure(of: TileKey(clockId: model.clocks[0].id, connectorId: "second")) != nil
        }
    )
    #expect(await waitUntil { subject.sections[0].dot == .green })
    await model.teardown()
}

@MainActor
private func panel(_ model: AppModel) -> PanelModel { PanelModel(model: model) }

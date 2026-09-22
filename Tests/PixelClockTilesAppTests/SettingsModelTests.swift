import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The Settings window's facade: the tab it opens on, the clock a gear aimed
// it at, and the Clocks tab's visibility — the one fact about a window that
// the browse rule reads.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

@Test @MainActor func theClockSettingsItemAimsTheWindowAtThatClocksTab() {
    let model = testModel(clocks: [desk, kitchen], sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()])
    let subject = SettingsModel(model: model)

    // A window opens wherever it was last; the gear's job is to move it
    // BEFORE it opens, so what the user is shown is the clock they pressed.
    subject.showClockSettings(kitchen.id)

    #expect(subject.tab == .clocks)
    #expect(subject.selectedClockId == kitchen.id)
}

@Test @MainActor func theTabTheUserLeftItOnIsTheTabItOpensOn() {
    let subject = SettingsModel(model: testModel())

    #expect(subject.tab == .clocks)
    subject.tab = .general
    #expect(subject.tab == .general)
}

// The Clocks tab's visibility is mirrored onto the model, where the browse
// rule reads it: the tab is the reason a browse runs while the window is
// open, and a mirror that stayed on the facade would be a reason nobody
// heard.
@Test @MainActor func theClocksTabsVisibilityIsHeardByTheModel() {
    let model = testModel(clocks: [desk], sessions: [desk.id: SpyHost()])
    let subject = SettingsModel(model: model)

    #expect(model.clocksSectionVisible == false)

    subject.clocksSectionVisibilityChanged(true)
    #expect(model.clocksSectionVisible)
    #expect(subject.clocksSectionVisible)

    subject.clocksSectionVisibilityChanged(false)
    #expect(model.clocksSectionVisible == false)
}

// Drag reorder: the source clock moves to the destination row's place, and
// the order IS the store's — what a relaunch reads and what the panel's
// sections follow.
@Test @MainActor func draggingAReorderedClockLandsItInTheStore() async throws {
    let defaults = try #require(UserDefaults(suiteName: "settings-model-\(UUID().uuidString)"))
    let model = testModel(
        defaults: defaults,
        clocks: [desk, kitchen],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )
    let subject = SettingsModel(model: model)

    subject.moveClock(kitchen.id, to: desk.id)

    #expect(
        await waitUntil { subject.clocks.map(\.id) == [kitchen.id, desk.id] }
    )
    #expect(ClockStore(defaults: defaults).all().map(\.id) == [kitchen.id, desk.id])
}

// The Defaults tab's answer is what a tile ADDED LATER starts from: a fixed
// interval overrides the connector's own default at add time, no opinion
// leaves every connector where it was.
@Test @MainActor func aFixedDefaultIntervalIsWhatANewTileStartsAt() async {
    let model = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude", defaultInterval: 900)],
        clocks: [desk],
        tiles: []
    )
    let key = TileKey(clockId: desk.id, connectorId: "claude")

    // No opinion: the connector's own default.
    _ = model.addTile("claude", to: desk.id)
    #expect(model.storedPolicy(of: key)?.refreshSeconds == 900)
    model.removeTile(key)

    model.setNewTileInterval(seconds: 60)
    _ = model.addTile("claude", to: desk.id)
    #expect(await waitUntil { model.storedPolicy(of: key)?.refreshSeconds == 60 })
}

// MARK: - The per-clock settings window

// The gear aims the per-clock window at ITS clock, and a second gear's
// click re-aims the same window rather than stacking another one.
@Test @MainActor func theClockWindowIsAimedAndReaimedByTheGears() {
    let model = testModel(clocks: [desk, kitchen])
    let subject = SettingsModel(model: model)

    #expect(subject.aimedClock == nil)
    subject.showClockWindow(kitchen.id)
    #expect(subject.aimedClock?.id == kitchen.id)
    subject.showClockWindow(desk.id)
    #expect(subject.aimedClock?.id == desk.id)
}

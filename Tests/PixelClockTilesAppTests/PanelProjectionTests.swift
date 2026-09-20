import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The panel is drawn per clock now: one projection, the selected clock's —
// its rows, its status, its Add tile menu — and a selection that outlives the
// model that made it.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "10.0.0.6")

private func tile(_ connector: String, on clock: ClockRecord) -> TileRecord {
    TileRecord(
        key: TileKey(clockId: clock.id, connectorId: connector),
        policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
    )
}

@Test @MainActor func theProjectionNamesTheSelectedClocksTilesAndStatusOnly() {
    let subject = testModel(
        connectors: [
            StubConnector(id: "weather", displayName: "Weather", isAmbient: true),
            StubConnector(id: "claude", displayName: "Claude"),
        ],
        clocks: [desk, kitchen],
        tiles: [tile("weather", on: desk), tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )

    subject.selectedClockId = desk.id
    #expect(subject.tileRows.map(\.name) == ["Weather"])
    #expect(subject.tileRows.map(\.isAmbient) == [true])
    #expect(subject.tileRows.map(\.removeQuestion) == ["Remove Weather from Desk?"])
    #expect(subject.selectedAddress == "10.0.0.5")
    #expect(subject.selectedClockIsAwtrix)

    subject.selectedClockId = kitchen.id
    #expect(subject.tileRows.map(\.name) == ["Claude"])
    #expect(subject.tileRows.map(\.removeQuestion) == ["Remove Claude from Kitchen?"])
    #expect(subject.selectedAddress == "10.0.0.6")
    #expect(subject.selectedClockIsAwtrix == false)
}

@Test @MainActor func theAddTileMenuCarriesTheAvailabilityOfTheListedConnectors() {
    let loft = ClockRecord(name: "Loft", model: .awtrix3, address: "10.0.0.7")
    let subject = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        clocks: [desk, loft, kitchen],
        tiles: [tile("claude", on: desk)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )

    // Claude's single tile is already on the desk clock, so the connector is
    // not listed there at all — the lamp is what the menu offers.
    subject.selectedClockId = desk.id
    #expect(subject.addTileMenuItems.map(\.title) == ["VPN"])

    subject.selectedClockId = loft.id
    #expect(subject.addTileMenuItems.map(\.title) == ["Claude", "VPN"])
    #expect(
        subject.addTileMenuItems.map(\.availability)
            == [.unavailable(reason: "already speaking through Desk"), .available]
    )

    // The face rule is the catalogue's first: the same connector on the TC002
    // carries that reason instead of the audible one — and so does the lamp,
    // which has no face for the TC002 either.
    subject.selectedClockId = kitchen.id
    #expect(subject.addTileMenuItems.map(\.title) == ["Claude", "VPN"])
    #expect(
        subject.addTileMenuItems.map(\.availability)
            == [.unavailable(reason: "not supported on TC002"),
                .unavailable(reason: "not supported on TC002")]
    )
}

// D3: the selection is a stored key, so the panel that opens tomorrow opens
// on the clock it was left on.
@Test @MainActor func theSelectionIsRememberedByTheNextModel() throws {
    let defaults = try #require(UserDefaults(suiteName: "projection-\(UUID().uuidString)"))
    let first = testModel(
        defaults: defaults,
        clocks: [desk, kitchen],
        tiles: [],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )
    first.selectedClockId = kitchen.id

    let second = testModel(
        defaults: defaults,
        clocks: [desk, kitchen],
        tiles: [],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )

    #expect(second.selectedClockId == kitchen.id)
}

// The badge is the projection's work: the row reads the tile's own hold from
// its policy against the Focus the machine is in right now.
@Test @MainActor func aTileHeldByAFocusDrawsTheFocusHold() {
    let subject = testModel(
        connectors: [StubConnector(id: "claude", displayName: "Claude")],
        focusStatus: StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.sleep.sleep-mode")),
        clocks: [desk, kitchen],
        tiles: [tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )
    subject.selectedClockId = kitchen.id

    #expect(subject.tileRows.map(\.hold) == [.focus])
}

// D4: the detail is a surface, opened for one tile and closed again.
@Test @MainActor func theDetailSurfaceCarriesTheTileItWasOpenedFor() {
    let subject = testModel(
        clocks: [desk, kitchen],
        tiles: [tile("claude", on: kitchen)],
        sessions: [desk.id: SpyHost(), kitchen.id: SpyHost()]
    )
    let key = TileKey(clockId: kitchen.id, connectorId: "claude")

    subject.openDetail(for: key)
    #expect(subject.detailTileKey == key)

    subject.closeDetail()
    #expect(subject.detailTileKey == nil)
}

import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.6")

@Test func aBatteryWarningNamesTheClockItIsAbout() {
    let warning = BatteryWarning(threshold: 20, percent: 19)

    #expect(BatteryAlertWords.body(for: warning, on: "Desk") == "Desk: 19% left, and falling.")
}

// The kitchen clock is unplugged; the desk carries on and the glyph, which is
// about the selected clock, stays online.
@Test @MainActor func aClockThatStopsAnsweringStallsOnlyItsOwnTiles() async {
    let transport = RoutingByHostTransport(online: ["10.0.0.5"])
    let schedule = Metronome()
    // The poll loop's own metronome: a second poll has to be drivable apart
    // from the tiles' schedule, which answers a different question.
    let polls = Metronome()
    let onDesk = SpyHost()
    let inKitchen = SpyHost()
    let subject = testModel(
        connectors: [StubConnector(id: "claude", isAudible: false)],
        transport: transport,
        sleep: schedule.sleep,
        pollSleep: polls.sleep,
        clocks: [desk, kitchen],
        tiles: [
            TileRecord(key: TileKey(clockId: desk.id, connectorId: "claude"), policy: TilePolicyRecord(TileDefaults.codeUsage)),
            TileRecord(key: TileKey(clockId: kitchen.id, connectorId: "claude"), policy: TilePolicyRecord(TileDefaults.codeUsage)),
        ],
        sessions: [desk.id: onDesk, kitchen.id: inKitchen]
    )

    subject.start()
    #expect(await waitUntil { subject.isDeviceOnline && schedule.parked == 2 })
    schedule.tick()

    #expect(await waitUntil { onDesk.calls.contains("run:claude") })
    #expect(await waitUntil({ inKitchen.calls.contains("run:claude") }, limit: 0.2) == false)

    // The glyph is about the SELECTED clock: selecting the unplugged one turns
    // it offline even while the desk keeps answering.
    subject.selectedClockId = kitchen.id
    // Parked again is the next poll over — the same wait-then-tick the shell
    // tests use, because a tick landing mid-poll wakes nothing.
    #expect(await waitUntil { polls.parked == 1 })
    polls.tick()
    #expect(await waitUntil { subject.isDeviceOnline == false })
    await subject.teardown()
}

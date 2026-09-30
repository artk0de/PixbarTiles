import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// The clocks this app drives: the list, the selection, the address and
/// location fields, and the moves the Clocks tab makes.
@MainActor
@Suite struct ClockDirectoryTests {
    private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.5")
    private let desk = ClockRecord(name: "Desk", model: .ulanziTC002, address: "10.0.0.6")
    private let defaults = UserDefaults(suiteName: "directory-\(UUID().uuidString)")!

    private func directory(
        probe: (@Sendable (String) async -> UlanziProbe.Detection)? = nil
    ) throws -> (ClockDirectory, ClockHealthMonitor, ClockStore) {
        let store = ClockStore(defaults: defaults)
        try store.replaceAll([kitchen, desk])
        let taskBag = TaskBag()
        let health = ClockHealthMonitor(
            device: AwtrixDevice(host: kitchen.address, transport: StubTransport()),
            pollSleep: parked, alerts: SpyAlerts(), taskBag: taskBag
        )
        let subject = ClockDirectory(
            clocks: [kitchen, desk], clockStore: store,
            location: StoredLocation(defaults: defaults, clockId: kitchen.id),
            defaults: defaults, probe: probe, health: health,
            clockSessions: ClockSessions(make: { _ in SpyHost() }, makeRegistry: nil),
            tiles: TileStore(defaults: defaults)
        )
        subject.onClocksChanged = { [weak subject] in subject?.adopt(store.all()) }
        return (subject, health, store)
    }

    @Test func theFirstClockIsSelectedAndTheSelectionIsKept() throws {
        let (subject, health, _) = try directory()
        #expect(subject.selectedClockId == kitchen.id)
        #expect(health.selectedClockId == kitchen.id)
        subject.selectedClockId = desk.id
        #expect(health.selectedClockId == desk.id)
        #expect(defaults.string(forKey: ClockDirectory.selectedClockKey) == desk.id.uuidString)
        #expect(subject.selectedAddress == desk.address)
        #expect(subject.selectedClockIsAwtrix == false)
    }

    @Test func aRenameAndAReorderGoThroughTheStore() throws {
        let (subject, _, store) = try directory()
        subject.renameClock(desk.id, to: "Study")
        subject.moveClock(desk.id, to: kitchen.id)
        #expect(store.all().map(\.name) == ["Study", "Kitchen"])
        #expect(subject.clocks.map(\.name) == ["Study", "Kitchen"])
    }

    @Test func anAddressIsCheckedBeforeAnythingIsAsked() async throws {
        let (subject, _, _) = try directory(probe: { _ in .otherDevice })
        #expect(await subject.addClock(address: "not an address!") == .refused("not an address: not an address!"))
        #expect(await subject.addClock(address: kitchen.address) == .refused("already configured at \(kitchen.address)"))
        #expect(await subject.addClock(address: "10.0.0.7") == .added)
        #expect(subject.clocks.last?.model == ClockModel.awtrix3)
    }

    @Test func removingTheSelectedClockMovesTheSelectionOn() throws {
        let (subject, _, _) = try directory()
        subject.removeClock(kitchen.id)
        #expect(subject.clocks.map(\.id) == [desk.id])
        #expect(subject.selectedClockId == desk.id)
        #expect(subject.deviceHost == desk.address)
    }
}

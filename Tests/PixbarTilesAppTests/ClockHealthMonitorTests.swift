import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// One health per clock, polled together: the selected clock's answer is the
/// glyph's, every clock's answer is its own dot, and each poll hands on to
/// whatever hangs off a fresh answer.
@MainActor
@Suite struct ClockHealthMonitorTests {
    private let kitchen = ClockRecord(name: "Kitchen", model: .awtrix3, address: "10.0.0.5")
    private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.6")

    /// Kitchen answers, Desk does not.
    private func monitor() -> ClockHealthMonitor {
        let transport = RoutingByHostTransport(online: [kitchen.address])
        let store = ClockStore(defaults: UserDefaults(suiteName: "health-\(UUID().uuidString)")!)
        let monitor = ClockHealthMonitor(
            device: AwtrixDevice(host: kitchen.address, transport: transport),
            pollSleep: parked, alerts: SpyAlerts(), taskBag: TaskBag()
        )
        for clock in [kitchen, desk] {
            monitor.track(ClockHealth(
                clock: clock,
                device: AwtrixDevice(host: clock.address, transport: transport),
                history: InMemoryBatteryHistoryStore(),
                relocate: nil, clocks: store, didMove: { _, _ in }
            ))
        }
        return monitor
    }

    @Test func beforeTheFirstPollNoClockHasAnswered() {
        let subject = monitor()
        subject.selectedClockId = kitchen.id
        #expect(subject.reachability(of: kitchen.id) == .unknown)
        #expect(subject.clockIsUnreachable(desk.id) == false)
        #expect(subject.isDeviceOnline == false)
    }

    @Test func aPollAnswersForEveryClockAndTheGlyphForTheSelectedOne() async {
        let subject = monitor()
        subject.selectedClockId = kitchen.id
        await subject.poll()
        #expect(subject.reachability(of: kitchen.id) == .reachable)
        #expect(subject.reachability(of: desk.id) == .unreachable)
        #expect(subject.clockIsUnreachable(desk.id))
        #expect(subject.isDeviceOnline)
        subject.selectedClockId = desk.id
        #expect(subject.isDeviceOnline == false)
    }

    @Test func eachPollMovesTheRevisionAndHandsOnOnce() async {
        let subject = monitor()
        var handedOn = 0
        subject.onPolled = { handedOn += 1 }
        await subject.poll()
        await subject.poll()
        #expect(handedOn == 2)
        #expect(subject.healthRevision == 2)
    }

    @Test func followingTheStoredClocksForgetsTheGoneOnes() async {
        let subject = monitor()
        await subject.poll()
        subject.followClocks([kitchen], making: { _ in nil })
        #expect(subject.reachability(of: desk.id) == .unknown)
        #expect(subject.reachability(of: kitchen.id) == .reachable)
        #expect(subject.healthRevision == 2)
    }
}

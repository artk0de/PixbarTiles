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

    /// Answers for Kitchen at once; holds Desk's request until the gate opens
    /// — an unreachable clock whose request takes its time to fail.
    private final class OneSlowHost: Transport, @unchecked Sendable {
        let slowHost: String
        let gate: Gate
        /// Whether the slow host answers once the gate opens, or fails.
        let slowAnswers: Bool
        init(slowHost: String, gate: Gate, slowAnswers: Bool = false) {
            self.slowHost = slowHost
            self.gate = gate
            self.slowAnswers = slowAnswers
        }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.url?.host == slowHost {
                await gate.enter()
                if !slowAnswers { throw URLError(.cannotConnectToHost) }
            }
            return (onlineStats, HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:]
            )!)
        }
    }

    // The glyph and the panel's dot say the same thing at the same moment:
    // the selected clock's answer reaches the glyph as it lands, not once
    // the slowest other clock has given up (2026-09-30: the dot said
    // Connected while the glyph stayed offline for seconds).
    @Test func theGlyphHearsTheSelectedClockWithoutWaitingForTheOthers() async {
        let gate = Gate()
        let transport = OneSlowHost(slowHost: desk.address, gate: gate)
        let store = ClockStore(defaults: UserDefaults(suiteName: "health-\(UUID().uuidString)")!)
        let subject = ClockHealthMonitor(
            device: AwtrixDevice(host: kitchen.address, transport: transport),
            pollSleep: parked, alerts: SpyAlerts(), taskBag: TaskBag()
        )
        for clock in [kitchen, desk] {
            subject.track(ClockHealth(
                clock: clock,
                device: AwtrixDevice(host: clock.address, transport: transport),
                history: InMemoryBatteryHistoryStore(),
                relocate: nil, clocks: store, didMove: { _, _ in }
            ))
        }
        subject.selectedClockId = kitchen.id

        let polling = Task { await subject.poll() }
        #expect(await waitUntil { subject.isDeviceOnline })
        #expect(gate.enteredCount == 1)
        gate.open()
        await polling.value
        #expect(subject.isDeviceOnline)
        #expect(subject.healthRevision == 1)
    }

    // A card's refresh asks its own clock and no other, and the glyph and the
    // dots hear the answer at once.
    @Test func aRecheckAsksOnlyTheNamedClock() async {
        let subject = monitor()
        subject.selectedClockId = kitchen.id
        let answer = await subject.recheck(kitchen.id)
        #expect(answer == .reachable)
        #expect(subject.isDeviceOnline)
        #expect(subject.reachability(of: desk.id) == .unknown)
        #expect(subject.healthRevision == 1)
        #expect(await subject.recheck(desk.id) == .unreachable)
    }

    private func slowDesk(answers: Bool) -> (ClockHealthMonitor, Gate) {
        let gate = Gate()
        let transport = OneSlowHost(slowHost: desk.address, gate: gate, slowAnswers: answers)
        let store = ClockStore(defaults: UserDefaults(suiteName: "health-\(UUID().uuidString)")!)
        let subject = ClockHealthMonitor(
            device: AwtrixDevice(host: kitchen.address, transport: transport),
            pollSleep: parked, alerts: SpyAlerts(), taskBag: TaskBag()
        )
        for clock in [kitchen, desk] {
            subject.track(ClockHealth(
                clock: clock,
                device: AwtrixDevice(host: clock.address, transport: transport),
                history: InMemoryBatteryHistoryStore(),
                relocate: nil, clocks: store, didMove: { _, _ in }
            ))
        }
        return (subject, gate)
    }

    // A switched-off clock never answers; the refresh does not wait out the
    // request's whole timeout. Silent past its deadline, the clock is read as
    // unreachable at once — dot, glyph and schedule alike (2026-09-30:
    // "checking на выключенных часах слишком долгий").
    @Test func aRecheckThatHearsNothingInTimeCallsTheClockUnreachable() async {
        let (subject, gate) = slowDesk(answers: false)
        subject.selectedClockId = desk.id
        let answer = await subject.recheck(desk.id, within: .milliseconds(50))
        #expect(answer == .unreachable)
        #expect(subject.reachability(of: desk.id) == .unreachable)
        #expect(subject.clockIsUnreachable(desk.id))
        #expect(subject.isDeviceOnline == false)
        gate.open()
    }

    // The request goes on after the deadline; an answer that does land after
    // it is the fresher evidence and wins.
    @Test func aLateAnswerOverturnsTheDeadline() async {
        let (subject, gate) = slowDesk(answers: true)
        subject.selectedClockId = desk.id
        #expect(await subject.recheck(desk.id, within: .milliseconds(50)) == .unreachable)
        gate.open()
        #expect(await waitUntil { subject.reachability(of: desk.id) == .reachable })
        #expect(await waitUntil { subject.isDeviceOnline })
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

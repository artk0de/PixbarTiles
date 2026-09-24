import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

// The panel as cards: each clock's section carries its battery as a reading
// rather than as words, so the card can draw the cells, the bolt and the
// caption each in its own place — and the header says how many of the clocks
// are answering.

private let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
private let kitchen = ClockRecord(name: "Kitchen", model: .ulanziTC002, address: "192.0.2.9")

private func reading(
    _ percent: Int, _ direction: BatteryDirection, left: TimeInterval? = nil
) -> BatteryReading {
    BatteryReading(
        percent: percent, shownPercent: percent, direction: direction, timeRemaining: left
    )
}


/// Answers /getBase with the one firmware whose battery offset is known.
private struct IdentityTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data(#"{"appVer":"1.1.1","devSn":"sn-1","ip":"192.0.2.9"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (body, response)
    }
}

// MARK: - The projection

@Test @MainActor func aSectionCarriesTheBatteryAsAReading() async {
    let polls = Metronome()
    let model = testModel(
        transport: IdentityTransport(),
        pollSleep: polls.sleep,
        deviceHost: "192.0.2.9",
        clocks: [kitchen],
        ulanziBattery: UlanziBattery(adb: FakeBatteryADB(percent: 90, charging: 1), helper: Data("ELF".utf8))
    )
    let subject = PanelModel(model: model)
    #expect(subject.sections[0].battery == nil)

    model.start()
    polls.tick()

    #expect(await waitUntil { subject.sections[0].battery?.percent == 90 })
    #expect(subject.sections[0].battery?.direction == .charging)
    #expect(subject.sections[0].isLive)
    await model.teardown()
}

@Test @MainActor func theHeaderCountsTheClocksThatAnswer() {
    // Unstarted: nothing has answered yet, so none is online.
    let subject = PanelModel(model: testModel(clocks: [desk, kitchen]))
    #expect(subject.onlineSummary == "0 of 2 online")
}

@Test func aSectionIsLiveUnlessItsClockIsDown() {
    func section(_ dot: PanelModel.ClockDot) -> PanelModel.ClockSection {
        PanelModel.ClockSection(
            clock: desk, dot: dot, statusLine: "", batteryLine: nil, battery: nil
        )
    }
    #expect(section(.green).isLive)
    #expect(section(.yellow).isLive)
    #expect(!section(.red).isLive)
}

// MARK: - The caption under the cells

@Test func theCaptionSaysWhatHappensNext() {
    #expect(BatteryLine.caption(for: reading(90, .charging), live: true) == "Charging")
    #expect(
        BatteryLine.caption(for: reading(60, .discharging, left: 4 * 3_600), live: true)
            == "~4 h left"
    )
    #expect(BatteryLine.caption(for: reading(60, .discharging), live: true) == "estimating…")
    #expect(BatteryLine.caption(for: reading(60, .unknown), live: true) == "estimating…")
}

// A clock still on the charger at 100% is not charging any more — the charger's
// own LED has gone green and nothing is going in. "100% · Charging" asks the
// reader to decide which half to believe.
@Test func aChargeThatFinishedIsCaptionedFull() {
    #expect(BatteryLine.caption(for: reading(100, .charging), live: true) == "Full")
    #expect(BatteryLine.caption(for: reading(99, .charging), live: true) == "Charging")
}

@Test func aRememberedChargeIsCaptionedAsOne() {
    #expect(BatteryLine.caption(for: reading(41, .discharging, left: 3_600), live: false) == "last known")
}

@Test func noReadingHasNoCaption() {
    #expect(BatteryLine.caption(for: nil, live: true) == nil)
    #expect(BatteryLine.caption(for: nil, live: false) == nil)
}

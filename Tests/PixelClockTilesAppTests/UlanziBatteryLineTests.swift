import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// The panel's battery line for a TC002. The charge does not come over HTTP —
// it is read out of the clock's own process memory over adb — but by the time
// it reaches the panel it is the same `BatteryReading` an AWTRIX clock
// produces, drawn by the same `BatteryLine`.

/// Feeds one plausible window, so a poll produces a reading.
private actor StubBatteryADB: ADB {
    let percent: UInt32
    let charging: UInt32
    init(percent: UInt32, charging: UInt32) {
        self.percent = percent
        self.charging = charging
    }
    func shell(_ command: String) async throws -> Data {
        if command.contains("cmdline") { return Data("/proc/670\r\n/bin/zkgui\u{0}\r\n\r\n".utf8) }
        if command.contains("maps") {
            return Data("43e87000-44571000 r-xp 00000000 1f:03 12 /res/lib/libzkgui.so\r\n".utf8)
        }
        return Data()
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {}
    func pull(_ path: String) async throws -> Data {
        var d = Data()
        for v in [charging, percent, UInt32(3600)] {
            withUnsafeBytes(of: v.littleEndian) { d.append(Data($0)) }
        }
        return d
    }
}

/// Answers /getBase with the one firmware whose battery offset is known.
private struct BatteryIdentityTransport: Transport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data(#"{"appVer":"1.1.1","devSn":"sn-1","ip":"192.0.2.9"}"#.utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: [:])!
        return (body, response)
    }
}

@MainActor
@Suite struct UlanziBatteryLineTests {
    private let desk = ClockRecord(name: "desk", model: .ulanziTC002, address: "192.0.2.9")

    @Test func aTC002DrawsItsChargeOnceThePollHasReadIt() async {
        let polls = Metronome()
        let subject = testModel(
            transport: BatteryIdentityTransport(),
            pollSleep: polls.sleep,
            deviceHost: "192.0.2.9",
            clocks: [desk],
            ulanziBattery: UlanziBattery(
                adb: StubBatteryADB(percent: 73, charging: 0), helper: Data("ELF".utf8)
            )
        )

        // Before any poll there is nothing read, so there is nothing to say.
        #expect(subject.batteryLine(of: desk) == nil)

        subject.start()
        polls.tick()

        // One sample is under the estimate's minimum span, so the line is the
        // percentage and the honest "working on it" — not a figure invented
        // from a single reading.
        #expect(await waitUntil { subject.batteryLine(of: desk) == "73% · estimating…" })
    }

    @Test func aTC002WithNoBatteryRouteSaysNothingRatherThanZero() async {
        let polls = Metronome()
        let subject = testModel(
            transport: BatteryIdentityTransport(),
            pollSleep: polls.sleep,
            deviceHost: "192.0.2.9",
            clocks: [desk]                      // no battery reader wired
        )

        subject.start()
        polls.tick()

        #expect(await waitUntil { subject.statusLine(of: desk) == "Connected" })
        #expect(subject.batteryLine(of: desk) == nil)
    }
}

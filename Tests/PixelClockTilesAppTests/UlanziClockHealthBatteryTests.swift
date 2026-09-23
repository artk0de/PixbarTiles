import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

/// Answers /getBase with a fixed appVer, so the health's identity poll succeeds
/// and hands that version to the battery read.
private struct StubIdentityTransport: Transport {
    let appVer: String
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = Data("{\"appVer\":\"\(appVer)\",\"devSn\":\"TC-1\"}".utf8)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (body, response)
    }
}

/// A transport that never answers — the clock is off the network.
private struct DeadTransport: Transport {
    struct Unreachable: Error {}
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw Unreachable()
    }
}

/// Feeds one plausible battery window, so the trajectory produces a reading.
private actor StubADB: ADB {
    let percent: UInt32
    let charging: UInt32
    init(percent: UInt32, charging: UInt32) {
        self.percent = percent
        self.charging = charging
    }
    func shell(_ command: String) async throws -> Data {
        if command.contains("cmdline") {
            return Data("/proc/670\r\n/bin/zkgui\u{0}\r\n\r\n".utf8)
        }
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

@MainActor
private func health(
    appVer: String = "1.1.1", percent: UInt32 = 73, charging: UInt32 = 0
) -> UlanziClockHealth {
    UlanziClockHealth(
        clockId: UUID(),
        name: "Desk",
        device: UlanziDevice(host: "192.168.1.72", transport: StubIdentityTransport(appVer: appVer)),
        battery: UlanziBattery(adb: StubADB(percent: percent, charging: charging), helper: Data("ELF".utf8))
    )
}

@MainActor
@Test func aTc002HealthReadsABatteryReadingThroughItsPoll() async {
    let clock = health()

    _ = await clock.poll(at: Date(timeIntervalSince1970: 1_000))

    #expect(clock.isOnline)
    #expect(clock.lastKnownBattery?.shownPercent == 73)
    #expect(clock.lastKnownBattery?.direction == .discharging)
}

@MainActor
@Test func aChargingClockSaysSoFromTheFlagAlone() async {
    let clock = health(percent: 90, charging: 1)

    _ = await clock.poll(at: Date(timeIntervalSince1970: 1_000))

    #expect(clock.lastKnownBattery?.direction == .charging)
    #expect(clock.lastKnownBattery?.timeRemaining == nil)
}

@MainActor
@Test func anUnknownFirmwareLeavesTheBatteryUnread() async {
    let clock = health(appVer: "9.9.9")

    _ = await clock.poll(at: Date(timeIntervalSince1970: 1_000))

    #expect(clock.isOnline)                     // it answered /getBase
    #expect(clock.lastKnownBattery == nil)      // but says nothing about charge
}

@MainActor
@Test func aClockThatWentAwayKeepsItsLastKnownCharge() async {
    let clock = health()
    _ = await clock.poll(at: Date(timeIntervalSince1970: 1_000))
    #expect(clock.lastKnownBattery?.shownPercent == 73)

    // The same health, now unreachable: the panel is a glance, and a battery
    // that vanishes on one blip is a figure nobody can plan around.
    let gone = UlanziClockHealth(
        clockId: UUID(), name: "Desk",
        device: UlanziDevice(host: "192.168.1.72", transport: DeadTransport()),
        battery: nil
    )
    _ = await gone.poll(at: Date(timeIntervalSince1970: 2_000))
    #expect(gone.isOnline == false)
    #expect(gone.lastKnownBattery == nil)
}

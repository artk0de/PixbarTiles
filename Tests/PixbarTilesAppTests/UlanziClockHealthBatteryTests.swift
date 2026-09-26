import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

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


@MainActor
private func health(
    appVer: String = "1.1.1", percent: UInt32 = 73, charging: UInt32 = 0
) -> UlanziClockHealth {
    UlanziClockHealth(
        clockId: UUID(),
        name: "Desk",
        device: UlanziDevice(host: "192.168.1.72", transport: StubIdentityTransport(appVer: appVer)),
        battery: UlanziBattery(adb: FakeBatteryADB(percent: percent, charging: charging), helper: Data("ELF".utf8))
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

/// An adb route that never answers — what a clock back on the network with
/// adbd not listening yet looked like to the app: the connect waited forever.
private actor SilentADB: ADB {
    private(set) var asked = 0
    func shell(_ command: String) async throws -> Data {
        asked += 1
        try await Task.sleep(for: .seconds(3_600))
        return Data()
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {
        asked += 1
        try await Task.sleep(for: .seconds(3_600))
    }
    func pull(_ path: String) async throws -> Data {
        asked += 1
        try await Task.sleep(for: .seconds(3_600))
        return Data()
    }
}

/// A battery read that hangs does not hang the poll. The poll is what every
/// clock's reachability, the menu bar glyph and the battery line hang off, and
/// a read that never came back froze all three after a clock returned
/// (reported 2026-09-26). The clock answered `/getBase`, so it is online; the
/// charge is simply not known yet — and the next poll does not start a second
/// read on top of the one still hanging.
@MainActor
@Test(.timeLimit(.minutes(1)))
func aBatteryReadThatNeverAnswersDoesNotHoldThePoll() async {
    let adb = SilentADB()
    let clock = UlanziClockHealth(
        clockId: UUID(), name: "Desk",
        device: UlanziDevice(host: "192.168.1.72", transport: StubIdentityTransport(appVer: "1.1.1")),
        battery: UlanziBattery(adb: adb, helper: Data("ELF".utf8)),
        batteryDeadline: .milliseconds(100)
    )

    _ = await clock.poll(at: Date(timeIntervalSince1970: 1_000))
    #expect(clock.isOnline)
    #expect(clock.lastKnownBattery == nil)

    _ = await clock.poll(at: Date(timeIntervalSince1970: 1_060))
    #expect(clock.isOnline)
    #expect(await adb.asked == 1)
}

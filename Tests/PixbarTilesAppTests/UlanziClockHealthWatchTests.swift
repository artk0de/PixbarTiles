import Foundation
import PixbarKit
import Testing
@testable import PixbarTilesApp

/// Answers /getBase while up, throws like an unplugged clock while down.
private final class SwitchableIdentityTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var up = true
    var answering: Bool {
        get { lock.withLock { up } }
        set { lock.withLock { up = newValue } }
    }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard answering else { throw URLError(.timedOut) }
        let body = Data(#"{"appVer":"1.1.1","devSn":"TC-1"}"#.utf8)
        return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

/// What the health told the clock's session, in order.
private actor RecordingWatcher: UlanziClockWatching {
    private(set) var heard: [String] = []
    func clockReturned() async { heard.append("returned") }
    func verifyPages() async { heard.append("verify") }
}

/// A clock whose zkgui can be restarted under a new pid: the old pid's memory
/// then reads nothing, and the sweep finds the new one.
private actor RestartableBatteryADB: ADB {
    private var pid = 670
    private var pulls: [Data] = []

    func restart() { pid = 671 }

    func shell(_ command: String) async throws -> Data {
        if command.contains("cmdline") { return Data("/proc/\(pid)\r\n/bin/zkgui\u{0}\r\n\r\n".utf8) }
        return BatteryFixture.shellAnswer(command)
    }
    func push(_ bytes: Data, to path: String, mode: Int) async throws {
        guard path == "/tmp/pbt-req" else { return }
        // The request's path names the pid; a dead pid's memory reads nothing.
        let named = String(decoding: bytes.dropFirst(8), as: UTF8.self)
        let address = bytes.prefix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        if !named.hasPrefix("/proc/\(pid)/") {
            pulls.append(Data())
        } else if address == BatteryFixture.monitorAddress {
            pulls.append(BatteryFixture.monitor(percent: 70, charging: 0))
        } else {
            pulls.append(BatteryFixture.le32(BatteryFixture.monitorAddress))
        }
    }
    func pull(_ path: String) async throws -> Data { pulls.isEmpty ? Data() : pulls.removeFirst() }
}

@MainActor
@Test func aRestartedZkguiIsAReturn() async {
    let transport = SwitchableIdentityTransport()
    let watcher = RecordingWatcher()
    let adb = RestartableBatteryADB()
    let health = watchedHealth(transport, watcher, battery: UlanziBattery(adb: adb, helper: Data("ELF".utf8)))
    _ = await health.poll(at: Date())
    await health.watching?.value

    await adb.restart()
    _ = await health.poll(at: Date())
    await health.watching?.value

    #expect(health.lastKnownBattery?.shownPercent == 70)
    #expect(await watcher.heard == ["verify", "returned"])
}

@MainActor
private func watchedHealth(
    _ transport: SwitchableIdentityTransport, _ watcher: RecordingWatcher, battery: UlanziBattery? = nil
) -> UlanziClockHealth {
    UlanziClockHealth(
        clockId: UUID(), name: "Desk",
        device: UlanziDevice(host: "192.168.1.72", transport: transport),
        battery: battery,
        watcher: { watcher }
    )
}

/// The reachability poll is the one steady look the app takes at a TC002, so
/// it is where a reboot is noticed: the clock coming back from unreachable
/// owes the pages a sweep, and every answering tick has the session check its
/// page list for a page the clock lost.
@MainActor
@Test func anAnsweringTickAsksTheSessionToCheckItsPages() async {
    let transport = SwitchableIdentityTransport()
    let watcher = RecordingWatcher()
    let health = watchedHealth(transport, watcher)

    _ = await health.poll(at: Date())
    await health.watching?.value

    #expect(await watcher.heard == ["verify"])
}

@MainActor
@Test func comingBackFromUnreachableIsAReturnNotACheck() async {
    let transport = SwitchableIdentityTransport()
    let watcher = RecordingWatcher()
    let health = watchedHealth(transport, watcher)
    _ = await health.poll(at: Date())
    await health.watching?.value

    transport.answering = false
    _ = await health.poll(at: Date())
    await health.watching?.value
    transport.answering = true
    _ = await health.poll(at: Date())
    await health.watching?.value
    _ = await health.poll(at: Date())
    await health.watching?.value

    // Nothing is said while the clock is gone; its return once; then checks.
    #expect(await watcher.heard == ["verify", "returned", "verify"])
}

import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

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

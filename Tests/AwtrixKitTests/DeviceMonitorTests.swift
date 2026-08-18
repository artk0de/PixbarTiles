import Combine
import Foundation
import Testing
@testable import AwtrixKit

private let statsJSON = #"{"bat":83,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#

private let reportedStats = DeviceStats(
    version: "0.98", uid: "awtrix_a07f9c", bat: 83, ram: 139112, ipAddress: "192.168.1.72"
)

/// Counts `objectWillChange` emissions. Lock-guarded for the same reason
/// `RecordingTransport` is: the sink closure is not bound to any actor.
private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var seen = 0

    var count: Int { lock.withLock { seen } }

    func bump() { lock.withLock { seen += 1 } }
}

@Test @MainActor func refreshGoesOnlineOnAGoodResponse() async {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    #expect(monitor.isOnline)
    #expect(monitor.batteryPercent == 83)
}

@Test @MainActor func refreshGoesOfflineOnFailure() async {
    let transport = RecordingTransport()
    transport.status = 500
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    #expect(!monitor.isOnline)
    #expect(monitor.batteryPercent == nil)
}

@Test @MainActor func stateStartsUnknownBeforeAnyRefresh() {
    let monitor = DeviceMonitor(
        device: AwtrixDevice(host: "10.0.0.5", transport: RecordingTransport())
    )

    #expect(monitor.state == .unknown)
}

@Test @MainActor func aFailedRefreshRecordsOfflineRatherThanUnknown() async {
    let transport = RecordingTransport()
    transport.status = 500
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    // "Never asked" and "asked and could not reach it" are different answers;
    // the menu bar shows only the second one as a fault.
    guard case .offline = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
}

@Test @MainActor func theOfflineStateCarriesTheReasonTheDeviceFailed() async {
    let transport = RecordingTransport()
    transport.status = 500
    transport.body = Data("boom".utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    guard case let .offline(reason) = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
    #expect(reason.contains("/api/stats"))
    #expect(reason.contains("500"))
    #expect(reason.contains("boom"))
}

@Test @MainActor func aDeviceThatWasNeverAskedIsNotReportedAsOnline() {
    let monitor = DeviceMonitor(
        device: AwtrixDevice(host: "10.0.0.5", transport: RecordingTransport())
    )

    #expect(!monitor.isOnline)
    #expect(monitor.batteryPercent == nil)
}

@Test @MainActor func aDeviceThatComesBackGoesOnlineAgain() async {
    let transport = RecordingTransport()
    transport.status = 500
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    await monitor.refresh()
    #expect(!monitor.isOnline)

    transport.status = 200
    transport.body = Data(statsJSON.utf8)
    await monitor.refresh()

    #expect(monitor.isOnline)
    #expect(monitor.batteryPercent == 83)
}

@Test @MainActor func aDeviceThatDisappearsGoesOfflineAgain() async {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    await monitor.refresh()
    #expect(monitor.isOnline)

    transport.status = 500
    await monitor.refresh()

    #expect(!monitor.isOnline)
    #expect(monitor.batteryPercent == nil)
}

@Test @MainActor func refreshAsksTheDeviceForItsStatsOnce() async throws {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    #expect(transport.requests.count == 1)
    let request = try #require(transport.requests.first)
    #expect(request.url?.absoluteString == "http://10.0.0.5/api/stats")
    #expect(request.httpMethod == "GET")
}

@Test @MainActor func aStateChangeReachesObservers() async {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    let changes = ChangeCounter()
    let subscription = monitor.objectWillChange.sink { _ in changes.bump() }

    await monitor.refresh()

    // The menu bar redraws off this notification, not off polling `state`.
    #expect(changes.count == 1)
    subscription.cancel()
}

@Test @MainActor func theOnlineStateCarriesTheWholeDecodedReport() async {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    #expect(monitor.state == .online(reportedStats))
}

@Test func twoReportsThatDifferOnlyInBatteryAreNotEqual() {
    let drained = DeviceStats(
        version: "0.98", uid: "awtrix_a07f9c", bat: 4, ram: 139112, ipAddress: "192.168.1.72"
    )

    #expect(DeviceState.online(reportedStats) != DeviceState.online(drained))
}

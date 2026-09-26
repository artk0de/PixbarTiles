import Foundation
import Testing
@testable import PixbarKit

private let statsJSON = #"{"bat":83,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#

private let drainedJSON = #"{"bat":4,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#

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

/// Fails before any status code exists. `RecordingTransport` can only produce
/// the `AwtrixError.http` family; this reaches the one a real network produces.
private struct UnreachableTransport: Transport {
    let code: URLError.Code
    let message: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        // Shaped the way URLSession delivers it: the localized text lives in
        // userInfo, and a hand-built URLError without it renders as a code.
        throw URLError(code, userInfo: [NSLocalizedDescriptionKey: message])
    }
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
    // `!isOnline` alone also holds for `.unknown`, which is not what the name
    // above claims — the device was reached once and then lost.
    guard case .offline = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
}

@Test @MainActor func aSecondReportReplacesTheFirstOne() async {
    let transport = RecordingTransport()
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    await monitor.refresh()
    #expect(monitor.batteryPercent == 83)

    // A clock that stayed online is the case where nothing forces the state to
    // move, so a frozen first report would read as a full battery forever.
    transport.body = Data(drainedJSON.utf8)
    await monitor.refresh()

    #expect(monitor.batteryPercent == 4)
}

@Test @MainActor func aSecondFailureReplacesTheFirstReason() async {
    let transport = RecordingTransport()
    transport.status = 500
    transport.body = Data("boom".utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    await monitor.refresh()

    // The remaining transition: a device that was already unreachable and
    // now fails differently. A frozen reason would name the wrong fault.
    transport.status = 404
    transport.body = Data("FileNotFound".utf8)
    await monitor.refresh()

    guard case let .offline(reason) = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
    #expect(reason.contains("404"))
    #expect(reason.contains("FileNotFound"))
}

@Test @MainActor func aGoodStatusWithAnUnreadableBodyGoesOffline() async {
    let transport = RecordingTransport()
    transport.body = Data("<html>router admin page</html>".utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    // 200 with a body that is not the report: the wrong host on the LAN, a
    // captive portal, or firmware that renamed a field. It throws past the
    // status guard as a DecodingError, not an AwtrixError.
    await monitor.refresh()

    guard case .offline = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
}

@Test @MainActor func theOfflineReasonReadsAsASentenceNotATypeDump() async {
    let transport = RecordingTransport()
    transport.body = Data("<html>router admin page</html>".utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    guard case let .offline(reason) = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
    // `String(describing:)` renders this family as a 328-character dump of the
    // decoder's Context. The menu bar has a tooltip, not a log viewer.
    #expect(!reason.contains("DecodingError"))
    #expect(!reason.contains("Debug description"))
}

@Test @MainActor func aTransportFailureGoesOfflineWithTheSystemsOwnMessage() async {
    let transport = UnreachableTransport(
        code: .cannotConnectToHost, message: "Could not connect to the server."
    )
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    guard case let .offline(reason) = monitor.state else {
        Issue.record("expected an offline state, got \(monitor.state)")
        return
    }
    #expect(reason == "Could not connect to the server.")
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

@Test @MainActor func aFailedRefreshRedrawsExactlyOnceToo() async {
    let transport = RecordingTransport()
    transport.status = 500
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    let changes = ChangeCounter()
    let subscription = monitor.objectWillChange.sink { _ in changes.bump() }

    await monitor.refresh()

    // Two writes on the way to offline would flicker the tray grey then red on
    // every failed poll of an unreachable device.
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

@Test func reportsThatDifferInAnyOneFieldAreNotEqual() {
    #expect(reportedStats == reportedStats)

    let variants: [(String, DeviceStats)] = [
        ("version", DeviceStats(
            version: "0.99", uid: "awtrix_a07f9c", bat: 83, ram: 139112, ipAddress: "192.168.1.72"
        )),
        ("uid", DeviceStats(
            version: "0.98", uid: "awtrix_ffffff", bat: 83, ram: 139112, ipAddress: "192.168.1.72"
        )),
        ("bat", DeviceStats(
            version: "0.98", uid: "awtrix_a07f9c", bat: 4, ram: 139112, ipAddress: "192.168.1.72"
        )),
        ("batRaw", DeviceStats(
            version: "0.98", uid: "awtrix_a07f9c", bat: 83, batRaw: 648, ram: 139112,
            ipAddress: "192.168.1.72"
        )),
        ("uptime", DeviceStats(
            version: "0.98", uid: "awtrix_a07f9c", bat: 83, uptime: 9000, ram: 139112,
            ipAddress: "192.168.1.72"
        )),
        ("ram", DeviceStats(
            version: "0.98", uid: "awtrix_a07f9c", bat: 83, ram: 1024, ipAddress: "192.168.1.72"
        )),
        ("ipAddress", DeviceStats(
            version: "0.98", uid: "awtrix_a07f9c", bat: 83, ram: 139112, ipAddress: "10.0.0.9"
        )),
    ]

    for (field, variant) in variants {
        #expect(reportedStats != variant, "DeviceStats equality ignores \(field)")
        #expect(DeviceState.online(reportedStats) != .online(variant), "state ignores \(field)")
    }
}

@Test func deviceStateTellsNeverAskedApartFromUnreachable() {
    #expect(DeviceState.unknown != .offline("could not connect"))
    #expect(DeviceState.offline("could not connect") != .offline("HTTP 500"))
}

// MARK: - The battery trajectory

private let trendingJSON = #"{"bat":83,"bat_raw":648,"uptime":9000,"ram":139112,"version":"0.98","uid":"awtrix_a07f9c","ip_address":"192.168.1.72"}"#

/// One `/api/stats` body with the two fields the trajectory reads.
///
/// Every raw figure below is one the firmware could answer with — above
/// `BatteryTrajectory.rawAtEmpty`, and around where its own `map(raw, 475, 665,
/// 0, 100)` puts the percentage beside it. They used to be roughly eight times
/// `bat`, which came from reading 648/91 as a slope rather than as one point on
/// a line, and the trajectory now discards anything off the bottom of that scale
/// as a converter it has not read yet. A fixture below 475 does not test a low
/// battery; it tests a clock that has just been switched on.
///
/// `bat` is deliberately NOT moved in step with the raw figure through the
/// ramps: holding it still is what makes a monitor that fed the trajectory a
/// percentage instead of the whole report have nothing to go on.
private func trendJSON(bat: Int, raw: Int, uptime: Int = 9_000) -> Data {
    Data(
        ("{\"bat\":\(bat),\"bat_raw\":\(raw),\"uptime\":\(uptime),\"ram\":139112,"
            + "\"version\":\"0.98\",\"uid\":\"awtrix_a07f9c\","
            + "\"ip_address\":\"192.168.1.72\"}").utf8
    )
}

private let origin = Date(timeIntervalSince1970: 1_700_000_000)

@Test @MainActor func theReportCarriesTheRawReadingAndTheUptime() async {
    let transport = RecordingTransport()
    transport.body = Data(trendingJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    guard case let .online(stats) = monitor.state else {
        Issue.record("expected an online state, got \(monitor.state)")
        return
    }
    // 648 raw is 91% on the real clock, so the raw figure is about seven times
    // finer than the percentage the panel shows.
    #expect(stats.batRaw == 648)
    #expect(stats.uptime == 9000)
}

@Test @MainActor func aReportWithoutTheTrendFieldsIsStillAReachableDevice() async {
    let transport = RecordingTransport()
    // The body every other test in this file uses: no `bat_raw`, no `uptime`.
    transport.body = Data(statsJSON.utf8)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh()

    // A firmware that omits them must not read as a clock that is not there.
    // Decoding is what puts this monitor offline, and a missing trend field is
    // not a missing device.
    #expect(monitor.isOnline)
    #expect(monitor.batteryPercent == 83)
    #expect(monitor.battery?.direction == .unknown)
}

@Test @MainActor func aRefreshFeedsTheReadingIntoTheTrajectory() async {
    // Ends on the raw reading whose MEASURED charge is 50 — the figure the
    // monitor reports — so the walk starts twenty-five steps above it.
    let fifty = (BatteryChargeCurve.rawAtEmpty...BatteryChargeCurve.rawAtFull).min {
        abs(BatteryChargeCurve.percent(atRaw: $0) - 50) < abs(BatteryChargeCurve.percent(atRaw: $1) - 50)
    }!
    let top = fifty + 25
    let transport = RecordingTransport()
    transport.body = trendJSON(bat: 50, raw: top)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    await monitor.refresh(at: origin)
    #expect(monitor.battery?.direction == .unknown)

    // Twenty-five minutes of the raw figure walking down. The percentage does
    // not move through any of it, so a monitor that fed the trajectory `bat`
    // rather than the whole report would still have nothing — and a fall is
    // fitted across an hour now, so nothing shorter than twenty minutes of it
    // says anything either.
    for minute in 1...25 {
        transport.body = trendJSON(bat: 50, raw: top - minute)
        await monitor.refresh(at: origin.addingTimeInterval(Double(minute) * 60))
    }

    #expect(monitor.battery?.direction == .discharging)
    #expect(monitor.battery?.percent == 50)
}

@Test @MainActor func aDeviceThatStopsAnsweringReportsNoBattery() async {
    let transport = RecordingTransport()
    transport.body = trendJSON(bat: 50, raw: 570)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    await monitor.refresh(at: origin)
    transport.body = trendJSON(bat: 50, raw: 566)
    await monitor.refresh(at: origin.addingTimeInterval(20))
    #expect(monitor.battery != nil)

    transport.status = 500
    await monitor.refresh(at: origin.addingTimeInterval(40))

    // The last thing a clock said before it went quiet is not what it is doing
    // now, and a battery drawn beside "Disconnected" is a reading nobody took.
    #expect(monitor.battery == nil)
}

@Test @MainActor func aRefreshAnswersWithTheThresholdItJustCrossed() async {
    let transport = RecordingTransport()
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    // Twenty-five minutes of discharge before the crossing. The warnings are
    // gated on a direction, and since the fall was measured a direction is a
    // line fitted across an hour — so a crossing handed in before twenty
    // minutes have been watched is a crossing nobody is told about.
    // The raw figures are the ones this clock's MEASURED curve puts either side
    // of the twenty line — 604 down to 598 is thirty-two percent down to
    // twenty-one — rather than the 547-to-511 they used to be. Those readings
    // are below the voltage this clock was measured to die on, so on a curve
    // that knows where empty is they are all zero, and the fixture crossed the
    // last line rather than the first.
    for minute in 0...25 {
        transport.body = trendJSON(bat: 25, raw: 604 - minute / 4)
        #expect(await monitor.refresh(at: origin.addingTimeInterval(Double(minute) * 60)) == nil)
    }

    transport.body = trendJSON(bat: 19, raw: 597)

    #expect(
        await monitor.refresh(at: origin.addingTimeInterval(26 * 60))
            == BatteryWarning(threshold: 20, percent: 19)
    )
    // Once. The crossing is an edge, and a monitor that kept it would hand the
    // same one to every poll that followed.
    #expect(await monitor.refresh(at: origin.addingTimeInterval(27 * 60)) == nil)
}

@Test @MainActor func aRefreshThatReachesNothingAnswersWithNothing() async {
    let transport = RecordingTransport()
    transport.status = 500
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))

    #expect(await monitor.refresh(at: origin) == nil)
    #expect(monitor.battery == nil)
}

@Test @MainActor func aRefreshRedrawsExactlyOnceEvenNowThereIsABatteryToDraw() async {
    let transport = RecordingTransport()
    transport.body = trendJSON(bat: 50, raw: 570)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    let changes = ChangeCounter()
    let subscription = monitor.objectWillChange.sink { _ in changes.bump() }

    await monitor.refresh(at: origin)

    // The reading is derived from `state` rather than published beside it. A
    // second published property is a second notification for one poll, and the
    // tray redraws off these.
    #expect(changes.count == 1)
    subscription.cancel()
}

@Test @MainActor func theInstantTheCallerSuppliesIsTheOneTheTrajectoryUses() async {
    let transport = RecordingTransport()
    transport.body = trendJSON(bat: 50, raw: 570)
    let monitor = DeviceMonitor(device: AwtrixDevice(host: "10.0.0.5", transport: transport))
    await monitor.refresh(at: origin)
    for minute in 1...25 {
        transport.body = trendJSON(bat: 50, raw: 570 - minute)
        await monitor.refresh(at: origin.addingTimeInterval(Double(minute) * 60))
    }
    #expect(monitor.battery?.direction == .discharging)

    // Two refreshes a wall-clock millisecond apart, described as being an hour
    // and a half apart — which is what a Mac waking from sleep looks like. A
    // monitor reading the wall clock instead of its argument would see no gap
    // at all and carry the trend straight across it.
    transport.body = trendJSON(bat: 50, raw: 544)
    await monitor.refresh(at: origin.addingTimeInterval(1_500 + BatteryTrajectory.window + 1))

    #expect(monitor.battery?.direction == .unknown)
}

// MARK: - What the next launch inherits

/// Runs a monitor through the twenty-six minutes of discharge a verdict needs,
/// writing the series down as it goes.
@MainActor
private func watchADischarge(
    through history: any BatteryHistoryStore, on transport: RecordingTransport
) async -> DeviceMonitor {
    let monitor = DeviceMonitor(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), history: history
    )
    for minute in 0...25 {
        transport.body = trendJSON(bat: 50, raw: 570 - minute)
        await monitor.refresh(at: origin.addingTimeInterval(Double(minute) * 60))
    }
    return monitor
}

@Test @MainActor func aRelaunchedMonitorResumesTheSeriesTheLastOneWroteDown() async {
    let history = InMemoryBatteryHistoryStore()
    let transport = RecordingTransport()
    let before = await watchADischarge(through: history, on: transport)
    #expect(before.battery?.direction == .discharging)

    // The app was quit and opened again a minute later. A second monitor on the
    // same store is what that looks like from here.
    let after = DeviceMonitor(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport), history: history
    )
    // Still nothing until this launch has heard from the clock: the reading is
    // gated on the device answering, and a restored series is not an answer.
    #expect(after.battery == nil)

    transport.body = trendJSON(bat: 50, raw: 544)
    await after.refresh(at: origin.addingTimeInterval(26 * 60))

    // One poll, and there is a direction. Without the series behind it this is
    // `.unknown` for the next twenty minutes.
    #expect(after.battery?.direction == .discharging)
}

@Test @MainActor func aMonitorWithNothingStoredStartsColdAsItAlwaysDid() async {
    let transport = RecordingTransport()
    transport.body = trendJSON(bat: 50, raw: 570)
    let monitor = DeviceMonitor(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        history: InMemoryBatteryHistoryStore()
    )

    await monitor.refresh(at: origin)

    #expect(monitor.battery?.direction == .unknown)
}

import Foundation
import Testing

@testable import PixelClockKit

// The doubles these tests build a host out of — `StubConnector`, `BoomError`,
// `SpyAudio`, `StubIconInstaller` — are declared in `AwtrixClockSessionTests.swift`.
//
// One rule lives over there rather than here: a run torn down AFTER it reached
// the device needs the gated audio and the cancellation-aware transport, which
// are that file's own doubles. See
// `aRunTornDownAfterItReachedTheDeviceLeavesTheFailureCountWhereItWas`.

// MARK: - Helpers

/// A host over a registry the test keeps hold of, so the connector behind an id
/// can be swapped between runs — which is how "it started failing" and "it
/// started working again" are staged without a connector that changes its mind.
private func hostOver(
    _ registry: ConnectorRegistry,
    store: any SettingsStore = InMemorySettingsStore()
) -> AwtrixClockSession {
    AwtrixClockSession(
        device: AwtrixDevice(host: "10.0.0.5", transport: RecordingTransport()),
        registry: registry,
        store: store,
        audio: SpyAudio(),
        iconInstaller: StubIconInstaller()
    )
}

private func failingConnector() -> StubConnector {
    var connector = StubConnector()
    connector.error = BoomError()
    return connector
}

/// Leaves the connector with `count` failures behind it, and says so — a test
/// that asserts "the count did not move" is worthless if the count was zero to
/// begin with, so the arrangement is checked before the rule is.
private func drive(
    _ host: AwtrixClockSession, toFailureCount count: Int, registry: ConnectorRegistry
) async {
    registry.register(failingConnector())
    for _ in 0..<count { _ = await host.runOnce(tile: singleTile("stub")) }
    #expect(await host.consecutiveFailures(connectorId: "stub") == count)
}

// MARK: - The policy on its own

@Test func noFailuresMeansNoExtraDelay() {
    let policy = RetryPolicy(base: 30, cap: 1800)

    #expect(policy.delay(afterConsecutiveFailures: 0) == 0)
}

@Test func delayDoublesWithEachConsecutiveFailure() {
    let policy = RetryPolicy(base: 30, cap: 1800)

    // The first failure is worth the base, not twice it. An exponent taken
    // straight from the count instead of from the count minus one puts every
    // step one place along and is invisible in a test that starts at two.
    #expect(policy.delay(afterConsecutiveFailures: 1) == 30)
    #expect(policy.delay(afterConsecutiveFailures: 2) == 60)
    #expect(policy.delay(afterConsecutiveFailures: 3) == 120)
}

@Test func delayNeverExceedsTheCap() {
    let policy = RetryPolicy(base: 30, cap: 300)

    // Also the case that separates capping the grown delay from capping the
    // base before it grows: the second reads the same at one failure and is
    // four orders of magnitude out here.
    #expect(policy.delay(afterConsecutiveFailures: 20) == 300)
}

@Test func aHugeFailureCountStillLandsOnTheCap() {
    let policy = RetryPolicy(base: 30, cap: 1800)

    #expect(policy.delay(afterConsecutiveFailures: 4096) == 1800)
}

// MARK: - What the host counts

@Test func hostCountsConsecutiveFailuresAndResetsOnSuccess() async {
    let registry = ConnectorRegistry()
    let host = hostOver(registry)
    await drive(host, toFailureCount: 2, registry: registry)

    registry.register(StubConnector())  // replaces it with a healthy one
    #expect(await host.runOnce(tile: singleTile("stub")) == .delivered)

    #expect(await host.consecutiveFailures(connectorId: "stub") == 0)
}

// A run the app tore down is not evidence that the feed is sick. The user
// quitting, a connector being switched off mid-delivery, or a schedule being
// rebuilt all end here, and backing a healthy connector off to hours of delay
// for having been interrupted is the defect this rule exists to prevent.
@Test func aCancelledRunLeavesTheFailureCountWhereItWas() async {
    let registry = ConnectorRegistry()
    let host = hostOver(registry)
    await drive(host, toFailureCount: 2, registry: registry)

    var cancelling = StubConnector()
    cancelling.error = CancellationError()
    registry.register(cancelling)
    #expect(await host.runOnce(tile: singleTile("stub")) == .cancelled)

    // Neither advanced nor reset: the run says nothing either way.
    #expect(await host.consecutiveFailures(connectorId: "stub") == 2)
}

// The other way a torn-down run arrives: `URLSession` reports a request killed
// by its task's cancellation as `URLError(.cancelled)`, and app quit killing an
// in-flight notify is the ordinary producer of it.
@Test func aRequestKilledByCancellationLeavesTheFailureCountWhereItWas() async {
    let registry = ConnectorRegistry()
    let host = hostOver(registry)
    await drive(host, toFailureCount: 2, registry: registry)

    var cancelling = StubConnector()
    cancelling.error = URLError(.cancelled)
    registry.register(cancelling)
    #expect(await host.runOnce(tile: singleTile("stub")) == .cancelled)

    #expect(await host.consecutiveFailures(connectorId: "stub") == 2)
}

// A connector the user switched off has not failed — and it has not recovered
// either. Resetting here would clear the backoff of a connector switched off
// and straight back on, which is not a thing that fixes a feed.
@Test func aSkippedRunLeavesTheFailureCountWhereItWas() async {
    let registry = ConnectorRegistry()
    let store = InMemorySettingsStore()
    let host = hostOver(registry, store: store)
    await drive(host, toFailureCount: 2, registry: registry)

    store.save(ConnectorSettings(isEnabled: false), for: "stub")
    #expect(await host.runOnce(tile: singleTile("stub")) == .skipped)

    #expect(await host.consecutiveFailures(connectorId: "stub") == 2)
}

// An id nothing is registered under is a wiring mistake, not a feed outage.
// Nothing schedules it — the app schedules what the registry holds — so a count
// kept against it would grow on every "run now" against a stale id and never be
// read by anything. The registered connector's own count is untouched by it.
@Test func anUnknownConnectorDoesNotAccumulateFailures() async {
    let registry = ConnectorRegistry()
    let host = hostOver(registry)
    await drive(host, toFailureCount: 2, registry: registry)

    guard case .failed = await host.runOnce(tile: singleTile("ghost")) else {
        Issue.record("an unknown connector is still a failed run")
        return
    }
    _ = await host.runOnce(tile: singleTile("ghost"))

    #expect(await host.consecutiveFailures(connectorId: "ghost") == 0)
    #expect(await host.consecutiveFailures(connectorId: "stub") == 2)
}

// MARK: - What the schedule is told to wait

@Test func nextDelayGrowsWhileFailingAndReturnsToIntervalAfterSuccess() async {
    let registry = ConnectorRegistry()
    let host = hostOver(registry)
    registry.register(failingConnector())

    // Healthy: the cadence the user chose, untouched.
    #expect(await host.nextDelay(tile: singleTile("stub"), interval: 1800) == 1800)

    _ = await host.runOnce(tile: singleTile("stub"))
    #expect(await host.nextDelay(tile: singleTile("stub"), interval: 1800) == 30)
    _ = await host.runOnce(tile: singleTile("stub"))
    #expect(await host.nextDelay(tile: singleTile("stub"), interval: 1800) == 60)

    registry.register(StubConnector())
    _ = await host.runOnce(tile: singleTile("stub"))
    #expect(await host.nextDelay(tile: singleTile("stub"), interval: 1800) == 1800)
}

// The cap the spec actually names is the connector's own interval, and the
// policy's own cap is the wrong one to lean on — 1800 seconds is six times the
// shortest cadence the slider offers. Five minutes is therefore the case that
// matters: the backoff outgrows it at the fifth failure and must stop there
// rather than stretch a five-minute connector to eight.
@Test func theBackoffNeverWaitsLongerThanTheConnectorsOwnInterval() async {
    let fiveMinutes: TimeInterval = 5 * 60
    let registry = ConnectorRegistry()
    let host = hostOver(registry)

    await drive(host, toFailureCount: 4, registry: registry)
    // Still inside the interval, so the backoff is what is waited — this is the
    // half that fails if the interval is simply handed back.
    #expect(await host.nextDelay(tile: singleTile("stub"), interval: fiveMinutes) == 240)

    _ = await host.runOnce(tile: singleTile("stub"))
    #expect(await host.consecutiveFailures(connectorId: "stub") == 5)
    // 480 seconds of backoff, clipped to the cadence the user chose.
    #expect(await host.nextDelay(tile: singleTile("stub"), interval: fiveMinutes) == fiveMinutes)
}

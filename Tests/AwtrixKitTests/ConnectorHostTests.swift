import Foundation
import Testing
@testable import AwtrixKit

// MARK: - Doubles

private struct StubConnector: Connector {
    let id: String
    let displayName = "Stub"
    let defaultInterval: TimeInterval = 300
    var output: ConnectorOutput?
    var error: (any Error)?

    init(id: String = "stub") { self.id = id }

    func produce() async throws -> ConnectorOutput {
        if let error { throw error }
        return output ?? ConnectorOutput(text: "hello")
    }
}

private struct BoomError: Error {}

/// Records what it was asked to play, and what the device had already been told
/// at the moment it was asked.
///
/// Lock-guarded because `@unchecked Sendable` turns the compiler's checking off
/// and this instance is handed to an actor, which enters `play` from a task the
/// test does not own. No test here drives two `play` calls at once, so the lock
/// is not what makes any current assertion sound — every read is ordered after
/// its write by an `await`. It is the repo's standing rule for these doubles:
/// the happens-before edge is a property of how the tests are written today,
/// and relying on it means the next test that stops awaiting introduces a race
/// with nothing to catch it.
private final class SpyAudio: AudioPlaying, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[SpokenClip]] = []
    private var snapshots: [[String]] = []
    private let deviceLog: @Sendable () -> [String]

    init(deviceLog: @escaping @Sendable () -> [String] = { [] }) {
        self.deviceLog = deviceLog
    }

    var played: [[SpokenClip]] { lock.withLock { recorded } }

    /// One entry per `play` call: the device endpoints already hit when it began.
    var deviceLogAtPlayTime: [[String]] { lock.withLock { snapshots } }

    func play(_ clips: [SpokenClip]) async {
        // Read before taking this lock: the log reaches for the transport's own
        // lock, and nesting two of them is how a deadlock gets written.
        let seen = deviceLog()
        lock.withLock {
            recorded.append(clips)
            snapshots.append(seen)
        }
    }
}

/// A one-shot gate: callers park in `enter()` until the test calls `open()`.
///
/// A continuation rather than a sleep, and deliberately not cancellation-aware.
/// A sleep throws `CancellationError`, which would answer the question these
/// tests ask — is this classified as a cancellation? — before the code under
/// test ever gets to. The shipped collaborators being stood in for here are the
/// same: neither a blocking audio player nor the sidecar's synchronous read
/// loop notices a cancelled task.
///
/// Every waiter is kept, not just the newest. A single slot would drop a
/// continuation the moment the behaviour under test broke — leaking it instead
/// of failing an assertion, which reports the defect as a crash in the harness.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    private var entered = 0

    var enteredCount: Int { lock.withLock { entered } }

    func open() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            opened = true
            let all = waiting
            waiting = []
            return all
        }
        held.forEach { $0.resume() }
    }

    func enter() async {
        lock.withLock { entered += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let alreadyOpen = lock.withLock { () -> Bool in
                if opened { return true }
                waiting.append(continuation)
                return false
            }
            if alreadyOpen { continuation.resume() }
        }
    }
}

/// Parks inside `play`, so two deliveries can be caught overlapping.
private final class GatedAudio: AudioPlaying, Sendable {
    private let gate = Gate()

    var enteredCount: Int { gate.enteredCount }
    func open() { gate.open() }

    func play(_ clips: [SpokenClip]) async { await gate.enter() }
}

/// Parks inside `produce`, so a run can be cancelled before it reaches the
/// device rather than while it is already inside the audio.
private final class GatedConnector: Connector, Sendable {
    let id = "gated"
    let displayName = "Gated"
    let defaultInterval: TimeInterval = 300

    private let gate = Gate()

    var enteredCount: Int { gate.enteredCount }
    func open() { gate.open() }

    func produce() async throws -> ConnectorOutput {
        await gate.enter()
        return ConnectorOutput(text: "hi")
    }
}

private struct StubIconInstaller: IconInstalling {
    func ensureInstalled(_ ref: IconReference) async throws -> String {
        switch ref {
        case let .installed(name): return name
        case let .catalogue(id): return String(id)
        }
    }
}

private struct FailingIconInstaller: IconInstalling {
    let error: any Error
    func ensureInstalled(_ ref: IconReference) async throws -> String { throw error }
}

/// Fails the way `URLSession` does when the surrounding task has been
/// cancelled, so a run can be torn down mid-delivery the way app quit tears one
/// down. A request that is not cancelled succeeds and is recorded.
private final class CancellationAwareTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if Task.isCancelled { throw URLError(.cancelled) }
        lock.withLock { recorded.append(request) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data("OK".utf8), response)
    }
}

/// Throws one error for every request, so a transport-level fault can be aimed
/// at the delivery path the way `SpyMaintainingConnector(failure:)` aims one at
/// the background path.
///
/// A struct with no recording: what is under test is how the error is
/// classified, and the run never gets far enough for the request log to say
/// anything the result does not.
private struct FaultingTransport: Transport {
    let error: any Error & Sendable

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        throw error
    }
}

/// Serves a server error for one endpoint and success for every other, so a
/// failure can be aimed at a single step of the delivery.
private final class PathFailingTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let failingPath: String

    init(failingPath: String) { self.failingPath = failingPath }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let failing = lock.withLock { () -> Bool in
            recorded.append(request)
            return request.url?.path == failingPath
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: failing ? 500 : 200,
            httpVersion: nil, headerFields: nil
        )!
        return (Data("OK".utf8), response)
    }
}

/// Blocks inside `produce` until cancelled — a refill queued behind a running
/// batch looks exactly like this from the host's side.
private final class BlockingConnector: Connector, @unchecked Sendable {
    let id = "blocking"
    let displayName = "Blocking"
    let defaultInterval: TimeInterval = 300

    private let lock = NSLock()
    private var entered = false

    var hasStarted: Bool { lock.withLock { entered } }

    func produce() async throws -> ConnectorOutput {
        lock.withLock { entered = true }
        // Long enough that a run which ignores cancellation is unmistakable
        // rather than merely slow.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return ConnectorOutput(text: "never")
    }
}

private final class SpyMaintainingConnector: Connector, ConnectorMaintaining, @unchecked Sendable {
    let id = "maintaining"
    let displayName = "Maintaining"
    let defaultInterval: TimeInterval = 300

    private let lock = NSLock()
    private var calls = 0
    private let failure: (any Error)?

    init(failure: (any Error)? = nil) { self.failure = failure }

    var maintenanceCount: Int { lock.withLock { calls } }

    func produce() async throws -> ConnectorOutput { ConnectorOutput(text: "hi") }

    func maintain() async throws {
        lock.withLock { calls += 1 }
        if let failure { throw failure }
    }
}

// MARK: - Helpers

private func makeHost(
    connector: any Connector,
    transport: any Transport = RecordingTransport(),
    store: any SettingsStore = InMemorySettingsStore(),
    audio: any AudioPlaying = SpyAudio(),
    iconInstaller: any IconInstalling = StubIconInstaller()
) -> ConnectorHost {
    let registry = ConnectorRegistry()
    registry.register(connector)
    return ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: transport),
        registry: registry,
        store: store,
        audio: audio,
        iconInstaller: iconInstaller
    )
}

/// Every transport double here records; this is how a test reads what reached
/// the device without caring which double it is holding.
private protocol RequestRecording {
    var requests: [URLRequest] { get }
}

extension RecordingTransport: RequestRecording {}
extension PathFailingTransport: RequestRecording {}
extension CancellationAwareTransport: RequestRecording {}

private func paths(_ transport: any RequestRecording) -> [String] {
    transport.requests.compactMap { $0.url?.path }
}

/// A result the probing task can publish before anyone awaits it.
///
/// Polled rather than awaited on purpose: what is under test is whether the
/// answer arrives BEFORE the delivery ahead of it finishes, and awaiting the
/// task would simply wait for it and prove nothing. This one genuinely needs
/// its lock — the write happens on the probe's task and the read on the test's,
/// with no `await` ordering them.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RunResult?

    var value: RunResult? { lock.withLock { stored } }
    func record(_ result: RunResult) { lock.withLock { stored = result } }
}

private func jsonBody(_ request: URLRequest) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
}

private func clip(_ path: String = "/tmp/a.wav") -> SpokenClip {
    SpokenClip(url: URL(fileURLWithPath: path))
}

/// Polls rather than sleeps a fixed span, so a fast machine is not made to wait
/// and a slow one is not made to flake.
///
/// For a condition that must NOT come true, use `staysFalse(for:_:)` — this one
/// times out silently, which is the wrong shape for an assertion and makes the
/// passing case pay the whole budget.
private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
}

/// Answers whether a condition stayed false for the whole window.
///
/// The inverse of `waitUntil`, and worth its own name: the passing case here is
/// the one that runs to the deadline, so the budget is small and the result is
/// handed back to be asserted rather than swallowed by a silent timeout.
private func staysFalse(
    for duration: Duration = .milliseconds(100),
    _ condition: @Sendable () -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + duration
    while ContinuousClock.now < deadline {
        if condition() { return false }
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    return true
}

// MARK: - Delivery

@Test func runOnceDeliversTextToTheDevice() async {
    let transport = RecordingTransport()
    let host = makeHost(connector: StubConnector(), transport: transport)

    let result = await host.runOnce(connectorId: "stub")

    #expect(result == .delivered)
    #expect(paths(transport) == ["/api/notify"])
}

@Test func runOnceResolvesTheIconBeforeNotifying() async throws {
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", icon: .catalogue(9039))
    let transport = RecordingTransport()
    let host = makeHost(connector: connector, transport: transport)

    _ = await host.runOnce(connectorId: "stub")

    let request = try #require(transport.requests.first { $0.url?.path == "/api/notify" })
    #expect(jsonBody(request)["icon"] as? String == "9039")
}

@Test func runOnceSendsTheJingleAlongsideTheText() async throws {
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", jingle: "nokia:d=4,o=5,b=225:8e6")
    let transport = RecordingTransport()
    let host = makeHost(connector: connector, transport: transport)

    _ = await host.runOnce(connectorId: "stub")

    let request = try #require(transport.requests.first)
    #expect(jsonBody(request)["rtttl"] as? String == "nokia:d=4,o=5,b=225:8e6")
}

@Test func runOncePlaysLocalAudio() async {
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", localAudio: [clip()])
    let audio = SpyAudio()
    let host = makeHost(connector: connector, audio: audio)

    _ = await host.runOnce(connectorId: "stub")

    #expect(audio.played == [[clip()]])
}

// MARK: - Holding the banner for the speech

// The clock cannot decode audio, so the banner is the only thing standing in
// for a thirty-second anecdote. Without `hold` the firmware scrolls it for its
// own default duration and takes it down on its own, long before the speech
// ends — and the dismiss below then arrives at a notification that is already
// gone. `hold` is the half that makes `holdUntilAudioEnds` mean anything.
@Test func aHeldBannerStaysUpForTheAudioAndIsDismissedAfterwards() async throws {
    let transport = RecordingTransport()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport)

    #expect(await host.runOnce(connectorId: "stub") == .delivered)

    let notify = try #require(transport.requests.first)
    #expect(jsonBody(notify)["hold"] as? Bool == true)
    #expect(paths(transport) == ["/api/notify", "/api/notify/dismiss"])
}

// A held banner is released by the dismiss that follows the audio, and by
// nothing else. Hold it with no audio to end and the clock sits on that banner
// until somebody walks over and presses the middle button.
@Test func aBannerIsNotHeldWhenThereIsNoAudioToEndIt() async throws {
    let transport = RecordingTransport()
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", holdUntilAudioEnds: true)
    let host = makeHost(connector: connector, transport: transport)

    #expect(await host.runOnce(connectorId: "stub") == .delivered)

    let notify = try #require(transport.requests.first)
    #expect(jsonBody(notify)["hold"] == nil)
    #expect(paths(transport) == ["/api/notify"])
}

@Test func aBannerThatWasNotHeldIsNotDismissed() async throws {
    let transport = RecordingTransport()
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", localAudio: [clip()])
    let host = makeHost(connector: connector, transport: transport)

    _ = await host.runOnce(connectorId: "stub")

    let notify = try #require(transport.requests.first)
    #expect(jsonBody(notify)["hold"] == nil)
    #expect(paths(transport) == ["/api/notify"])
}

// Order is the whole point of the banner: it has to be up while the Mac speaks
// and down once it stops. Asserting the final request list cannot see that —
// notify, dismiss reads the same whether the audio ran between them or after
// both.
@Test func theBannerGoesUpBeforeTheAudioAndComesDownAfterIt() async {
    let transport = RecordingTransport()
    let audio = SpyAudio(deviceLog: { paths(transport) })
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    _ = await host.runOnce(connectorId: "stub")

    #expect(audio.deviceLogAtPlayTime == [["/api/notify"]])
    #expect(paths(transport) == ["/api/notify", "/api/notify/dismiss"])
}

// MARK: - Containment

@Test func aThrowingConnectorFailsWithoutPropagating() async {
    var connector = StubConnector()
    connector.error = BoomError()
    let transport = RecordingTransport()
    let host = makeHost(connector: connector, transport: transport)

    let result = await host.runOnce(connectorId: "stub")

    guard case .failed = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(transport.requests.isEmpty)
}

// Speech with no banner is worse than nothing: the anecdote has already been
// retired by `produce()`, so it is spent either way, and a voice coming out of
// the Mac with nothing on the clock has no explanation.
@Test func aDeviceThatRejectsTheNotifyLeavesTheAudioUnplayed() async {
    let transport = RecordingTransport()
    transport.status = 500
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", localAudio: [clip()])
    let audio = SpyAudio()
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let result = await host.runOnce(connectorId: "stub")

    guard case .failed = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(audio.played.isEmpty)
}

// The audio played and the banner is stuck on the clock. That is a delivery
// that went wrong, not a clean one, and reporting it as `.delivered` would hide
// the one state a user has to walk over and fix by hand.
@Test func aDismissThatFailsIsReportedEvenThoughTheAudioPlayed() async {
    let transport = PathFailingTransport(failingPath: "/api/notify/dismiss")
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let audio = SpyAudio()
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let result = await host.runOnce(connectorId: "stub")

    guard case .failed = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(audio.played.count == 1)
}

// An icon that cannot be installed stops the run rather than degrading to a
// bannerless-icon delivery: `ensureInstalled` returns the name the payload has
// to carry, and without it there is no honest way to send what the connector
// asked for.
@Test func anIconThatCannotBeInstalledStopsTheRunBeforeItNotifies() async {
    var connector = StubConnector()
    connector.output = ConnectorOutput(text: "hi", icon: .catalogue(9039))
    let transport = RecordingTransport()
    let host = makeHost(
        connector: connector, transport: transport,
        iconInstaller: FailingIconInstaller(error: BoomError())
    )

    let result = await host.runOnce(connectorId: "stub")

    guard case .failed = result else {
        Issue.record("expected .failed, got \(result)")
        return
    }
    #expect(transport.requests.isEmpty)
}

@Test func aDisabledConnectorIsSkipped() async {
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: "stub")
    let transport = RecordingTransport()
    let host = makeHost(connector: StubConnector(), transport: transport, store: store)

    #expect(await host.runOnce(connectorId: "stub") == .skipped)
    #expect(transport.requests.isEmpty)
}

@Test func anUnknownConnectorFailsRatherThanCrashing() async {
    let host = makeHost(connector: StubConnector())

    guard case .failed = await host.runOnce(connectorId: "nope") else {
        Issue.record("expected .failed for unknown connector")
        return
    }
}

// MARK: - Cancellation

// A cancelled run is not a failed one. `produce()` refills an empty queue, and
// that refill throws `CancellationError` when the caller goes away — reporting
// it as `.failed` puts a fault in front of the user for something that was
// asked to stop.
@Test func aConnectorThatThrowsCancellationIsNotAFailedRun() async {
    var connector = StubConnector()
    connector.error = CancellationError()
    let host = makeHost(connector: connector)

    #expect(await host.runOnce(connectorId: "stub") == .cancelled)
}

// Cancellation has to reach the connector, not just be recognised once it comes
// back. The host runs each delivery in an unstructured task so deliveries
// serialise, and an unstructured task inherits nothing: without the
// cancellation forwarded by hand this run keeps going for its full two seconds
// and reports success to a caller that stopped waiting.
@Test func cancellingARunStopsTheConnectorAndReportsCancelled() async throws {
    let connector = BlockingConnector()
    let transport = RecordingTransport()
    let host = makeHost(connector: connector, transport: transport)

    let run = Task { await host.runOnce(connectorId: "blocking") }
    try await waitUntil { connector.hasStarted }
    #expect(connector.hasStarted)

    let cancelledAt = ContinuousClock.now
    run.cancel()
    let result = await run.value

    #expect(result == .cancelled)
    #expect(ContinuousClock.now - cancelledAt < .seconds(1))
    #expect(transport.requests.isEmpty)
}

// MARK: - One delivery at a time

// `dismissNotification` is global to the device: it takes down whatever banner
// is showing, not the one this run put up. Two overlapping deliveries therefore
// have the first one's dismiss cancel the second one's banner while its audio
// is still playing, and both anecdotes speak over each other. A timer tick and
// a "run now" from the menu are exactly the two callers that produce it.
@Test func twoRunsDoNotOverlapOnTheDevice() async throws {
    let transport = RecordingTransport()
    let audio = GatedAudio()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let first = Task { await host.runOnce(connectorId: "stub") }
    try await waitUntil { audio.enteredCount == 1 }

    let second = Task { await host.runOnce(connectorId: "stub") }
    // An unserialised second run reaches `/api/notify` before it reaches the
    // gate, so a moment is enough for it to show up.
    #expect(try await staysFalse {
        paths(transport).filter { $0 == "/api/notify" }.count > 1
    })
    #expect(audio.enteredCount == 1)

    audio.open()
    #expect(await first.value == .delivered)
    #expect(await second.value == .delivered)
    #expect(paths(transport) == [
        "/api/notify", "/api/notify/dismiss", "/api/notify", "/api/notify/dismiss",
    ])
}

// Cancelling a run that has not started yet, because the delivery ahead of it
// is still speaking. Cancellation cannot break the wait for that predecessor,
// so without a check on the far side of it the cancelled run wakes up and puts
// a banner on the clock that nobody is waiting for any more.
@Test func cancellingAQueuedRunStopsItBeforeItReachesTheDevice() async throws {
    let transport = RecordingTransport()
    let audio = GatedAudio()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let first = Task { await host.runOnce(connectorId: "stub") }
    try await waitUntil { audio.enteredCount == 1 }

    let queued = Task { await host.runOnce(connectorId: "stub") }
    // Long enough for the queued run to claim its place behind the first.
    // Claiming is a single actor-isolated step with no suspension inside it,
    // and the actor is free while the first run waits on its audio.
    try await Task.sleep(nanoseconds: 20_000_000)
    queued.cancel()
    audio.open()

    #expect(await queued.value == .cancelled)
    #expect(await first.value == .delivered)
    // Only the first delivery reached the clock.
    #expect(paths(transport) == ["/api/notify", "/api/notify/dismiss"])
    #expect(audio.enteredCount == 1)
}

// MARK: - The guards answer without waiting for the chain

// A typo in an id, answered while an anecdote is still playing. Behind the
// serialisation chain this waits out the whole delivery — half a minute of a
// menu that has not answered — to say a name does not exist, which no registry
// lookup needs the device for.
@Test func anUnknownConnectorAnswersWhileADeliveryIsStillPlaying() async throws {
    let transport = RecordingTransport()
    let audio = GatedAudio()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let playing = Task { await host.runOnce(connectorId: "stub") }
    try await waitUntil { audio.enteredCount == 1 }

    let answer = ResultBox()
    let probe = Task { answer.record(await host.runOnce(connectorId: "nope")) }
    try await waitUntil { answer.value != nil }

    // Asserted rather than awaited: awaiting would wait out the delivery and
    // report a pass, which is the defect.
    guard case .failed = answer.value else {
        Issue.record("expected .failed while the gate was still shut, got \(String(describing: answer.value))")
        audio.open()
        _ = await (probe.value, playing.value)
        return
    }
    #expect(paths(transport) == ["/api/notify"])

    audio.open()
    _ = await probe.value
    #expect(await playing.value == .delivered)
}

// The same for enablement, and it doubles as the record that enablement is read
// when the run is asked for rather than when it reaches the front of the queue.
@Test func aDisabledConnectorAnswersWhileADeliveryIsStillPlaying() async throws {
    let transport = RecordingTransport()
    let audio = GatedAudio()
    let store = InMemorySettingsStore()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(
        connector: connector, transport: transport, store: store, audio: audio
    )

    let playing = Task { await host.runOnce(connectorId: "stub") }
    try await waitUntil { audio.enteredCount == 1 }
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: "stub")

    let answer = ResultBox()
    let probe = Task { answer.record(await host.runOnce(connectorId: "stub")) }
    try await waitUntil { answer.value != nil }

    #expect(answer.value == .skipped)

    audio.open()
    _ = await probe.value
    #expect(await playing.value == .delivered)
}

// MARK: - Tearing a run down mid-delivery

// `hold: true` is a promise the device keeps until something dismisses it. App
// quit cancels the timer, and a dismiss sent on the cancelled task never leaves
// the Mac — so the banner outlives the app and sits on the clock until somebody
// presses the middle button. The release has to survive the teardown that
// triggered it.
@Test func aCancelledRunStillTakesTheHeldBannerDown() async throws {
    let transport = CancellationAwareTransport()
    let audio = GatedAudio()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let run = Task { await host.runOnce(connectorId: "stub") }
    try await waitUntil { audio.enteredCount == 1 }
    run.cancel()
    audio.open()

    #expect(await run.value == .cancelled)
    #expect(paths(transport) == ["/api/notify", "/api/notify/dismiss"])
}

// A real fault raised while the run happens to be cancelled is still a fault.
// Classifying by "was this task cancelled" rather than by the error itself is
// exactly how a rejected dismiss disappears into `.cancelled` and a stuck
// banner is reported as an orderly shutdown.
@Test func aRejectedDismissDuringACancelledRunIsStillAFailure() async throws {
    let transport = PathFailingTransport(failingPath: "/api/notify/dismiss")
    let audio = GatedAudio()
    var connector = StubConnector()
    connector.output = ConnectorOutput(
        text: "hi", localAudio: [clip()], holdUntilAudioEnds: true
    )
    let host = makeHost(connector: connector, transport: transport, audio: audio)

    let run = Task { await host.runOnce(connectorId: "stub") }
    try await waitUntil { audio.enteredCount == 1 }
    run.cancel()
    audio.open()

    guard case let .failed(message) = await run.value else {
        Issue.record("a 500 on the dismiss is a fault, not a cancellation")
        return
    }
    // Named, not merely "not cancelled". The whole non-masking claim is that a
    // device fault arrives as `AwtrixError.http` and so cannot be confused with
    // the transport's own cancellation, and this is where that is measured.
    #expect(message.contains("HTTP 500"))
}

// The transport naming cancellation rather than the ambient task state. App
// quit cancels the timer while a request is in flight and `URLSession` reports
// that as `URLError(.cancelled)`; reporting it as a fault would back a
// connector off for having been interrupted, which is the same defect as
// counting cancellation as a failure.
@Test func aRequestKilledByCancellationIsNotAFailedRun() async throws {
    let transport = CancellationAwareTransport()
    let connector = GatedConnector()
    let host = makeHost(connector: connector, transport: transport)

    let run = Task { await host.runOnce(connectorId: "gated") }
    try await waitUntil { connector.enteredCount == 1 }
    // Cancelled while producing, so the cancellation is already in force by the
    // time the notify reaches the transport. Nothing throws `CancellationError`
    // on this path — the gate does not notice cancellation, exactly as the
    // shipped collaborators do not.
    run.cancel()
    connector.open()

    #expect(await run.value == .cancelled)
    #expect(transport.requests.isEmpty)
}

@Test func aBackgroundPassKilledByCancellationIsNotAFailure() async {
    let connector = SpyMaintainingConnector(failure: URLError(.cancelled))
    let host = makeHost(connector: connector)

    #expect(await host.maintain(connectorId: "maintaining") == .cancelled)
}

// The other half of the same rule, on the path the user actually sees. A
// timeout, a DNS failure or a refused connection reaching `/api/notify` is the
// clock being unreachable — an outage worth showing, not an orderly stop. Only
// the code tells the two apart: both arrive as `URLError`, so a clause matching
// the type rather than the code files an outage as a clean shutdown.
@Test func aDeliveryThatHitsARealTransportFaultStillFails() async {
    let host = makeHost(
        connector: StubConnector(),
        transport: FaultingTransport(error: URLError(.timedOut))
    )

    guard case .failed = await host.runOnce(connectorId: "stub") else {
        Issue.record("a timeout is an outage, not a cancellation")
        return
    }
}

// The same on the background path: a restock reaches the feed through the same
// transport, so the same misclassification is available there.
@Test func aBackgroundPassThatHitsARealTransportFaultStillFails() async {
    let connector = SpyMaintainingConnector(failure: URLError(.timedOut))
    let host = makeHost(connector: connector)

    guard case .failed = await host.maintain(connectorId: "maintaining") else {
        Issue.record("a timeout is an outage, not a cancellation")
        return
    }
}

// MARK: - The background pass

// `produce()` fires on a timer and is meant to be instant. Restocking costs a
// model load and a minute of synthesis, so the run that shows the banner must
// not be the one that pays for it.
@Test func runOnceDoesNotRunTheBackgroundPass() async {
    let connector = SpyMaintainingConnector()
    let host = makeHost(connector: connector)

    #expect(await host.runOnce(connectorId: "maintaining") == .delivered)
    #expect(connector.maintenanceCount == 0)
}

@Test func maintainRunsTheConnectorsBackgroundPass() async {
    let connector = SpyMaintainingConnector()
    let transport = RecordingTransport()
    let host = makeHost(connector: connector, transport: transport)

    #expect(await host.maintain(connectorId: "maintaining") == .completed)
    #expect(connector.maintenanceCount == 1)
    // A background pass is not a delivery: nothing reaches the clock.
    #expect(transport.requests.isEmpty)
}

@Test func maintainSkipsAConnectorWithNoBackgroundWork() async {
    let host = makeHost(connector: StubConnector())

    #expect(await host.maintain(connectorId: "stub") == .skipped)
}

// A connector the user switched off must not synthesize a batch in the
// background — that is a minute of CPU and 1.8 GB of model for output nobody
// will ever hear.
@Test func maintainSkipsADisabledConnector() async {
    let connector = SpyMaintainingConnector()
    let store = InMemorySettingsStore()
    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 0), for: "maintaining")
    let host = makeHost(connector: connector, store: store)

    #expect(await host.maintain(connectorId: "maintaining") == .skipped)
    #expect(connector.maintenanceCount == 0)
}

@Test func aFailingBackgroundPassIsContained() async {
    let connector = SpyMaintainingConnector(failure: BoomError())
    let host = makeHost(connector: connector)

    guard case .failed = await host.maintain(connectorId: "maintaining") else {
        Issue.record("expected .failed from a throwing background pass")
        return
    }
}

@Test func aCancelledBackgroundPassIsNotAFailure() async {
    let connector = SpyMaintainingConnector(failure: CancellationError())
    let host = makeHost(connector: connector)

    #expect(await host.maintain(connectorId: "maintaining") == .cancelled)
}

@Test func maintainingAnUnknownConnectorFailsRatherThanCrashing() async {
    let host = makeHost(connector: StubConnector())

    guard case .failed = await host.maintain(connectorId: "nope") else {
        Issue.record("expected .failed for unknown connector")
        return
    }
}

// MARK: - Settings

@Test func settingsDefaultToEnabledAtThirtyMinutes() {
    let store = InMemorySettingsStore()

    let settings = store.settings(for: "anything")

    #expect(settings.isEnabled)
    #expect(settings.interval == 30 * 60)
}

@Test func theIntervalFollowsTheScalePosition() {
    #expect(ConnectorSettings(intervalPosition: 0).interval == IntervalScale.positions[0])
    #expect(ConnectorSettings(intervalPosition: 0).interval == 5 * 60)
}

@Test func savedSettingsSurviveTheUserDefaultsStore() throws {
    let suite = "connector-host-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults: defaults)

    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 3), for: "stub")

    let read = store.settings(for: "stub")
    #expect(read.isEnabled == false)
    #expect(read.intervalPosition == 3)
}

@Test func anUnsavedConnectorReadsTheDefaultsFromTheUserDefaultsStore() throws {
    let suite = "connector-host-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults: defaults)

    #expect(store.settings(for: "never-saved") == ConnectorSettings())
}

// One key per connector. A shared key would have switching one connector off
// switch every other one off with it.
@Test func settingsAreKeptPerConnector() throws {
    let suite = "connector-host-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsSettingsStore(defaults: defaults)

    store.save(ConnectorSettings(isEnabled: false, intervalPosition: 1), for: "a")

    #expect(store.settings(for: "b") == ConnectorSettings())
}

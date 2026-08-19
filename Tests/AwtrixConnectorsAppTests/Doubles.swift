import AppKit
import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// MARK: - Connectors

struct StubConnector: Connector {
    let id: String
    let displayName: String
    let defaultInterval: TimeInterval

    init(id: String = "stub", displayName: String = "Stub", defaultInterval: TimeInterval = 5 * 60) {
        self.id = id
        self.displayName = displayName
        self.defaultInterval = defaultInterval
    }

    func produce() async throws -> ConnectorOutput { ConnectorOutput(text: "hello") }
}

// MARK: - Host

/// Records the order of what a tick asked for, and can park inside `runOnce` so
/// a quit can be caught waiting for one.
///
/// Lock-guarded because it is handed to a `@MainActor` model that calls it from
/// tasks the test does not own.
final class SpyHost: ConnectorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var delayCalls = 0
    private let parkInRun: Gate?
    private let parkInMaintain: Gate?
    private let parkInDeliver: Gate?
    /// Holds the schedule inside the question it asks before every sleep. The
    /// shipped host answers it from an actor, so a connector switched off while
    /// the answer is in flight is a state the real app reaches and a
    /// straight-through double cannot pose.
    private let parkInDelay: Gate?
    private let delay: TimeInterval?
    /// How a replay ends. A clock that is not answering is the case the History
    /// has to say something about, and a double that always succeeds cannot
    /// pose it.
    private let deliverResult: RunResult

    /// `delay` stands in for a connector that is failing: nil answers with the
    /// interval it was asked about, which is what a healthy one gets.
    init(
        parkInRun: Gate? = nil,
        parkInMaintain: Gate? = nil,
        parkInDeliver: Gate? = nil,
        parkInDelay: Gate? = nil,
        delay: TimeInterval? = nil,
        deliverResult: RunResult = .delivered
    ) {
        self.parkInRun = parkInRun
        self.parkInMaintain = parkInMaintain
        self.parkInDeliver = parkInDeliver
        self.parkInDelay = parkInDelay
        self.delay = delay
        self.deliverResult = deliverResult
    }

    /// One entry per call, in call order: `maintain:<id>` / `run:<id>` /
    /// `deliver:<text>`.
    ///
    /// A replay is keyed by what it put on the clock rather than by a connector
    /// id, because it does not have one: `deliver` takes an output and nothing
    /// else. That is also what lets a test say WHICH entry was replayed.
    ///
    /// `nextDelay` is deliberately not in here. It is asked once per turn of
    /// every schedule, including the turns that never run anything, and folding
    /// it in would make the order of a tick unreadable in the tests that are
    /// about that order. It is counted separately instead.
    var calls: [String] { lock.withLock { recorded } }

    /// How many times the schedule asked how long to wait.
    var delayQueries: Int { lock.withLock { delayCalls } }

    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval {
        lock.withLock { delayCalls += 1 }
        await parkInDelay?.enter()
        return delay ?? interval
    }

    func maintain(connectorId: String) async -> MaintenanceResult {
        lock.withLock { recorded.append("maintain:\(connectorId)") }
        // The expensive half in the real host: a refill loads the model and
        // synthesizes a batch. A double that returns instantly cannot show
        // whether the panel says anything during it.
        await parkInMaintain?.enter()
        return .completed
    }

    func runOnce(connectorId: String) async -> RunResult {
        lock.withLock { recorded.append("run:\(connectorId)") }
        await parkInRun?.enter()
        return .delivered
    }

    func deliver(_ output: ConnectorOutput) async -> RunResult {
        lock.withLock { recorded.append("deliver:\(output.text)") }
        await parkInDeliver?.enter()
        return deliverResult
    }

    /// Recorded as `restore:<id>` — or `restore:all` for the quit, which is
    /// about no connector in particular.
    func restoreDeviceState(borrowedBy connectorId: String?) async {
        lock.withLock { recorded.append("restore:\(connectorId ?? "all")") }
    }
}

/// A one-shot gate: callers park in `enter()` until the test calls `open()`.
///
/// Deliberately not cancellation-aware, like the two collaborators the quit
/// budget exists for — a held banner's release and the sidecar's blocking read
/// both keep going after the task holding them is cancelled.
final class Gate: @unchecked Sendable {
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

// MARK: - Time

/// Stands in for `Task.sleep` so one cadence can be driven a tick at a time.
///
/// Every sleeper parks until `tick()`, and a cancelled one throws exactly as the
/// real sleep does — the schedule relies on that throw to tell a quit from an
/// elapsed interval, so a fake that swallowed it would be testing a different
/// loop from the one that ships.
///
/// One per clock, never one for both. `AppModel` sleeps in two places — the
/// delivery schedule and the reachability poll — and a single metronome across
/// the two can only answer "something is asleep", which is the question neither
/// test is asking. Waiting on the aggregate let the poll answer for the
/// schedule: `tick()` released whichever sleeper was parked, a wait for
/// "something parked" returned on the poll re-parking after one `refresh()`
/// while the connector was still inside `maintain` + `runOnce`, and the
/// schedule silently lost a beat. Measured at 4 red runs in 25 before the
/// clocks were separated.
final class Metronome: @unchecked Sendable {
    private let lock = NSLock()
    private var sleepers: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var cancelled: Set<Int> = []
    private var requested: [TimeInterval] = []
    private var nextId = 0

    /// Every duration asked for, in call order.
    var durations: [TimeInterval] { lock.withLock { requested } }
    var parked: Int { lock.withLock { sleepers.count } }

    /// Releases everything currently parked, as one elapsed interval.
    func tick() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = Array(sleepers.values)
            sleepers = [:]
            return all
        }
        held.forEach { $0.resume() }
    }

    var sleep: @Sendable (TimeInterval) async throws -> Void {
        { [self] seconds in try await park(seconds) }
    }

    private func park(_ seconds: TimeInterval) async throws {
        let id = lock.withLock { () -> Int in
            nextId += 1
            requested.append(seconds)
            return nextId
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                let alreadyCancelled = lock.withLock { () -> Bool in
                    if cancelled.contains(id) { return true }
                    sleepers[id] = continuation
                    return false
                }
                if alreadyCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let held = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                cancelled.insert(id)
                return sleepers.removeValue(forKey: id)
            }
            held?.resume(throwing: CancellationError())
        }
    }
}

/// Polls `condition` until it holds or the wait runs out.
///
/// The alternative is a fixed sleep, which is either too short on a loaded
/// machine or wasted time on an idle one. Returns rather than asserting, so the
/// failure is reported by the expectation that named the rule.
///
/// Five seconds rather than two, and the number was measured rather than
/// guessed. Every caller is `@MainActor`, and so is every SwiftUI render in
/// `PanelRenderingTests`: laying out the settings surface costs 65 ms — the two
/// 24-hour pickers are 46 ms of it — and `cacheDisplay` is SYNCHRONOUS, so each
/// render is time subtracted from the budget of every poll running beside it.
/// About seventeen settings renders now happen across a suite that finishes in
/// 2.1 s, which put a two-second budget inside the noise: measured at 1 red run
/// in 5, on tests with nothing wrong with them, scattered at random.
///
/// Raising it weakens nothing. Every use is an "eventually" wait followed by a
/// synchronous read — none of them infers a negative from a timeout — so a
/// longer limit only makes a genuinely failing test slower to report, and costs
/// exactly nothing when the condition holds.
@discardableResult
@MainActor
func waitUntil(
    _ condition: @MainActor () -> Bool, limit: TimeInterval = 5
) async -> Bool {
    let deadline = Date().addingTimeInterval(limit)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(1))
    }
    return condition()
}

// MARK: - Discovery

/// A browser that reports whatever a test hands it.
///
/// A second copy of the kit's own double rather than a shared one: test targets
/// do not import each other.
@MainActor
final class FakeBonjourBrowser: BonjourBrowsing {
    private(set) var starts = 0
    private var handlers: [@MainActor (BonjourEvent) -> Void] = []

    /// Browses begun and not yet cancelled.
    var liveBrowses: Int { handlers.count }

    func start(onEvent: @escaping @MainActor (BonjourEvent) -> Void) {
        starts += 1
        handlers.append(onEvent)
    }

    func cancel() { handlers.removeAll() }

    func emit(_ event: BonjourEvent) { handlers.forEach { $0(event) } }
}

/// A `DeviceBrowser` that cannot reach the network, for tests about something
/// else.
///
/// Every `AppDelegate` in this target takes one. The initialiser has no default
/// on purpose — the default would be the real factory, and a test that later
/// called `applicationDidFinishLaunching` would browse the user's LAN from
/// inside `swift test`.
@MainActor
func inertDiscovery() -> DeviceBrowser {
    DeviceBrowser(browsing: { FakeBonjourBrowser() }, sleep: { _ in })
}

// MARK: - Device

/// Answers every request the same way, and records what it was asked.
final class StubTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let status: Int
    private let body: Data
    private let failure: (any Error)?

    init(status: Int = 200, body: Data = Data("[]".utf8), failure: (any Error)? = nil) {
        self.status = status
        self.body = body
        self.failure = failure
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        if let failure { throw failure }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

let onlineStats = Data(#"{"version":"0.96","uid":"abc","bat":77,"ram":120,"ip_address":"10.0.0.5"}"#.utf8)

// MARK: - A model with nothing real behind it

/// The clock a test did not inject: it parks rather than returning.
///
/// A no-op default turns the loop that was left uninjected into a spin — the
/// reachability poll measured 9,876 requests in 200 ms, and a delivery loop
/// 8,672 full ticks. Both awaited and yielded, so no harm was measurable, but a
/// test profile where one loop runs ten thousand times is a bad place to look
/// for a timing defect. Parking is what the real clock does between beats.
///
/// A long sleep rather than a continuation, because cancellation has to reach
/// it: `teardown` cancels these loops and expects the sleep to throw.
let parked: @Sendable (TimeInterval) async throws -> Void = { _ in
    try await Task.sleep(for: .seconds(86_400))
}

@MainActor
func testModel(
    connectors: [any Connector] = [StubConnector()],
    host: any ConnectorRunning = SpyHost(),
    store: any SettingsStore = InMemorySettingsStore(),
    // A clock that answers, because the schedule now asks. `StubTransport()`'s
    // `[]` does not decode as `DeviceStats`, so the default used to leave every
    // started model reporting the device unreachable — which, since the pause
    // landed, is a schedule that runs nothing. A test that wants an outage says
    // so with a transport of its own.
    transport: any Transport = StubTransport(body: onlineStats),
    uploads: any UploadedIconStore = InMemoryUploadedIconStore(),
    defaults: UserDefaults = UserDefaults(suiteName: "testModel-\(UUID().uuidString)")!,
    sleep: @escaping AppModel.Sleeping = parked,
    pollSleep: @escaping AppModel.Sleeping = parked,
    deviceHost: String = "10.0.0.5",
    anecdotes: (any AnecdoteReplaying)? = nil,
    // Named rather than `.general`, so no test can put anything on the
    // clipboard of whoever is running the suite.
    pasteboard: NSPasteboard = NSPasteboard(
        name: NSPasteboard.Name("testModel-\(UUID().uuidString)")
    ),
    // Recorded rather than raised. The shipped one puts a modal dialog on
    // screen and asks macOS for notification permission, and there is no
    // default on `AppModel.init` for exactly that reason.
    alerts: any BatteryWarningPresenting = SpyAlerts(),
    // Authorized and not focused, so nothing in the suite is silenced by the
    // wall clock: the quiet window is only consulted while this app is NOT
    // allowed to ask, and a default of `.notDetermined` would have every test
    // in this target pass or fail depending on the hour it was run at.
    focus: FocusGate = FocusGate(status: StubFocusStatus(access: .authorized)),
    quietHours: QuietWindow = .default,
    // Nothing capturing, so nothing in the suite is held by whatever is plugged
    // into the machine running it. A default reading the REAL inputs would have
    // every schedule test in this target answer to the always-on Thunderbolt
    // interface on this desk.
    microphone: MicrophoneGate = MicrophoneGate(inputs: StubAudioInputs()),
    watching: [WatchedMicrophone] = MicrophoneGate.defaultWatchSet,
    micSleep: @escaping AppModel.Sleeping = parked
) -> AppModel {
    let registry = ConnectorRegistry()
    for connector in connectors { registry.register(connector) }
    let device = AwtrixDevice(host: deviceHost, transport: transport)
    return AppModel(
        deviceHost: deviceHost,
        device: device,
        registry: registry,
        host: host,
        store: store,
        installer: CatalogueIconInstaller(
            device: device, transport: transport, uploads: uploads
        ),
        anecdotes: anecdotes,
        defaults: defaults,
        pasteboard: pasteboard,
        alerts: alerts,
        focus: focus,
        quietHours: quietHours,
        microphone: microphone,
        watching: watching,
        sleep: sleep,
        pollSleep: pollSleep,
        micSleep: micSleep
    )
}

// MARK: - History

/// A history the menu can browse, and an output per entry.
///
/// The shipped connector puts the SAME banner on the clock for every anecdote —
/// the joke is heard, not read — which would make two replays indistinguishable
/// in `SpyHost`'s log. This one carries the anecdote's own text instead, so a
/// test can say which entry was replayed.
final class StubAnecdotes: AnecdoteReplaying, @unchecked Sendable {
    let id: String
    private let entries: [PlayedAnecdote]

    init(id: String = "stub", history entries: [PlayedAnecdote] = []) {
        self.id = id
        self.entries = entries
    }

    func history() async -> [PlayedAnecdote] { entries }

    func output(for anecdote: PreparedAnecdote) -> ConnectorOutput {
        ConnectorOutput(text: anecdote.text, localAudio: anecdote.clips)
    }
}

/// An anecdote whose single clip really is on disk, in a directory named the
/// way the synthesizer names one — so `isPlayable` answers yes about it.
func playableAnecdote(id: String, text: String = "joke") throws -> PreparedAnecdote {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("history-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: id))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clip = directory.appendingPathComponent("turn-0.wav")
    try Data().write(to: clip)
    return PreparedAnecdote(
        id: id, text: text, clips: [SpokenClip(url: clip)], laughter: "АХАХАХА",
        preparedAt: nil, rank: nil
    )
}

/// The same record with its audio already reclaimed: the entry a history keeps
/// after the reaper has been through it.
func anecdoteWhoseClipsAreGone(id: String, text: String = "joke") -> PreparedAnecdote {
    let clip = FileManager.default.temporaryDirectory
        .appendingPathComponent("reaped-\(UUID().uuidString)")
        .appendingPathComponent("turn-0.wav")
    return PreparedAnecdote(
        id: id, text: text, clips: [SpokenClip(url: clip)], laughter: "АХАХАХА",
        preparedAt: nil, rank: nil
    )
}

/// Parks inside every request, so a button can be caught mid-flight.
final class GatedTransport: Transport, @unchecked Sendable {
    private let gate: Gate

    init(gate: Gate) { self.gate = gate }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        await gate.enter()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (Data("OK".utf8), response)
    }
}

/// Parks each `runOnce` on a gate of its own, so two runs can be finished in
/// whichever order the test needs.
final class QueueingHost: ConnectorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var gates: [Gate] = []

    var started: Int { lock.withLock { gates.count } }

    /// Lets the run that started `index`-th return.
    func finish(_ index: Int) {
        lock.withLock { gates[index] }.open()
    }

    func maintain(connectorId: String) async -> MaintenanceResult { .completed }

    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval { interval }

    func runOnce(connectorId: String) async -> RunResult {
        let gate = Gate()
        lock.withLock { gates.append(gate) }
        await gate.enter()
        return .delivered
    }

    func deliver(_ output: ConnectorOutput) async -> RunResult { .delivered }

    /// Nothing was borrowed, so there is nothing to give back. Spelled out
    /// rather than defaulted on the protocol: a default would let the SHIPPED
    /// host stop restoring and still compile.
    func restoreDeviceState(borrowedBy connectorId: String?) async {}
}

/// Answers `.cancelled` when its run is cancelled, as `ConnectorHost` does.
final class CancellingHost: ConnectorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var arrived = 0

    var entered: Int { lock.withLock { arrived } }

    func maintain(connectorId: String) async -> MaintenanceResult { .completed }

    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval { interval }

    func runOnce(connectorId: String) async -> RunResult {
        lock.withLock { arrived += 1 }
        // Sleeps until cancelled, and reports the cancellation rather than
        // throwing it — the shipped host catches `CancellationError` and turns
        // it into this case.
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return .cancelled
    }

    func deliver(_ output: ConnectorOutput) async -> RunResult { .delivered }

    func restoreDeviceState(borrowedBy connectorId: String?) async {}
}

// MARK: - A real host, with the two collaborators a background pass never uses

/// Plays nothing. `ConnectorHost.maintain` never reaches the audio path, and a
/// test that wired the shipped player in would have `swift test` speaking.
struct SilentAudioPlayer: AudioPlaying {
    func play(_ clips: [SpokenClip]) async {}
}

/// Installs nothing. Same reason: a background pass never reaches the icon
/// path, and the real installer would put this test on the network.
struct NoIconInstaller: IconInstalling {
    func ensureInstalled(_ ref: IconReference) async throws -> String { "stub" }
}

/// A feed of `count` distinct anecdotes, most popular first.
func anecdoteFeed(items count: Int) -> String {
    let entries = (1...count).map { index in
        """
        <item>
        <description><![CDATA[Анекдот номер \(index)]]></description>
        <guid>https://www.anekdot.ru/id/\(index)/</guid>
        </item>
        """
    }.joined(separator: "\n")
    return "<rss><channel>\n\(entries)\n</channel></rss>"
}

/// Polls an actor-isolated answer until it holds or the wait runs out.
///
/// `waitUntil` takes a synchronous `@MainActor` condition, which cannot await
/// `AnecdoteQueue`. Returns the last value read, so the expectation that names
/// the rule is the thing that reports the failure.
func waitForQueue(
    _ queue: AnecdoteQueue, toReach depth: Int, limit: TimeInterval = 5
) async -> Int {
    let deadline = Date().addingTimeInterval(limit)
    var ready = await queue.ready()
    while Date() < deadline, ready != depth {
        try? await Task.sleep(for: .milliseconds(5))
        ready = await queue.ready()
    }
    return ready
}

/// Polls the shipped host's failure count until it reaches `target` or the wait
/// runs out.
///
/// `waitUntil` takes a synchronous `@MainActor` condition, which cannot await
/// an actor. Returns the last value read, so the expectation that names the
/// rule is the thing that reports the failure — and waiting on the COUNT rather
/// than on the panel's line is what tells a second failure from the first: both
/// write the same words, so a wait on `lastResults` returns before the run that
/// is being waited for has started.
func waitForFailures(
    of id: String, on host: ConnectorHost, toReach target: Int, limit: TimeInterval = 2
) async -> Int {
    let deadline = Date().addingTimeInterval(limit)
    var count = await host.consecutiveFailures(connectorId: id)
    while Date() < deadline, count != target {
        try? await Task.sleep(for: .milliseconds(5))
        count = await host.consecutiveFailures(connectorId: id)
    }
    return count
}

/// Answers whatever a test tells it to for a background pass, and delivers
/// every run.
///
/// Both halves matter. The failure this stands for is a refill that cannot
/// reach the feed while the queue still has something to hand out: the runs go
/// on succeeding, so nothing else on the panel would ever say the feed is down.
final class RestockReportingHost: ConnectorRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: MaintenanceResult

    init(reporting outcome: MaintenanceResult) { self.outcome = outcome }

    func nowReports(_ outcome: MaintenanceResult) {
        lock.withLock { self.outcome = outcome }
    }

    func maintain(connectorId: String) async -> MaintenanceResult {
        lock.withLock { outcome }
    }

    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval { interval }

    func runOnce(connectorId: String) async -> RunResult { .delivered }

    func deliver(_ output: ConnectorOutput) async -> RunResult { .delivered }

    func restoreDeviceState(borrowedBy connectorId: String?) async {}
}

// MARK: - A clock that stops answering, and starts again

/// A transport whose answer a test can change while the app is running.
///
/// `StubTransport` is fixed at construction, which is enough for a clock that is
/// up or a clock that is down — but not for the thing the pause is about, which
/// is one becoming the other underneath a schedule that is already ticking.
final class SwitchableTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var failing: Bool
    private let body: Data

    init(answering: Bool = true, body: Data = onlineStats) {
        self.failing = answering == false
        self.body = body
    }

    func nowFails() { lock.withLock { failing = true } }
    func nowAnswers() { lock.withLock { failing = false } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if lock.withLock({ failing }) { throw URLError(.cannotConnectToHost) }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

/// A connector whose feed is down: it throws every time it is asked.
///
/// What it stands for is the one thing the backoff exists to describe, and the
/// one thing an outage of the clock must not be confused with.
struct BrokenConnector: Connector {
    struct FeedIsDown: Error {}

    let id: String
    let displayName: String
    let defaultInterval: TimeInterval

    init(id: String = "stub", displayName: String = "Stub", defaultInterval: TimeInterval = 5 * 60) {
        self.id = id
        self.displayName = displayName
        self.defaultInterval = defaultInterval
    }

    func produce() async throws -> ConnectorOutput { throw FeedIsDown() }
}

/// A model over the SHIPPED host, so the failure count a test reads is the real
/// one rather than a spy's idea of it.
///
/// The device is built once and handed to both, which is the whole point: the
/// monitor's reachability answer and the host's delivery go through the same
/// transport, exactly as they do in the app. A pair of them over two transports
/// could be told the clock was down while delivering to one that was up.
@MainActor
func modelOverRealHost(
    connector: any Connector = StubConnector(),
    transport: any Transport,
    anecdotes: (any AnecdoteReplaying)? = nil,
    focus: FocusGate = FocusGate(status: StubFocusStatus(access: .authorized)),
    quietHours: QuietWindow = .default,
    microphone: MicrophoneGate = MicrophoneGate(inputs: StubAudioInputs()),
    watching: [WatchedMicrophone] = MicrophoneGate.defaultWatchSet,
    sleep: @escaping AppModel.Sleeping = parked,
    pollSleep: @escaping AppModel.Sleeping = parked,
    micSleep: @escaping AppModel.Sleeping = parked
) -> (model: AppModel, host: ConnectorHost) {
    let registry = ConnectorRegistry()
    registry.register(connector)
    let store = InMemorySettingsStore()
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)
    let host = ConnectorHost(
        device: device,
        registry: registry,
        store: store,
        audio: SilentAudioPlayer(),
        iconInstaller: NoIconInstaller()
    )
    let model = AppModel(
        deviceHost: "10.0.0.5",
        device: device,
        registry: registry,
        host: host,
        store: store,
        installer: CatalogueIconInstaller(
            device: device, transport: transport, uploads: InMemoryUploadedIconStore()
        ),
        anecdotes: anecdotes,
        defaults: UserDefaults(suiteName: "realHost-\(UUID().uuidString)")!,
        pasteboard: NSPasteboard(name: NSPasteboard.Name("realHost-\(UUID().uuidString)")),
        alerts: SpyAlerts(),
        focus: focus,
        quietHours: quietHours,
        microphone: microphone,
        watching: watching,
        sleep: sleep,
        pollSleep: pollSleep,
        micSleep: micSleep
    )
    return (model, host)
}

/// Whether the poll has answered, and answered that the clock is not there.
///
/// Spelled out rather than read off `isDeviceOnline`, which is false for
/// `.unknown` as well — a wait on that would return before the poll had run at
/// all, and the pause under test is about the answered case only.
@MainActor
func isOffline(_ model: AppModel) -> Bool {
    if case .offline = model.monitor.state { return true }
    return false
}

// MARK: - Battery

/// Answers every request with the next body in the script, and repeats the last
/// one once the script runs out.
///
/// `StubTransport` cannot pose the question the trajectory exists to answer: a
/// trend needs two readings that DIFFER, and one canned body is one reading
/// repeated. Repeating the last entry rather than failing is what lets a test
/// poll as many times as it likes after the interesting pair has landed.
final class ScriptedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let bodies: [Data]
    private var served = 0

    init(bodies: [Data]) {
        precondition(bodies.isEmpty == false, "a script with no bodies answers nothing")
        self.bodies = bodies
    }

    /// How many requests have been answered.
    var responses: Int { lock.withLock { served } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = lock.withLock { () -> Data in
            let body = bodies[min(served, bodies.count - 1)]
            served += 1
            return body
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

/// One `/api/stats` body, with the two fields the trajectory reads.
func statsBody(percent: Int, raw: Int, uptime: Int = 9_000) -> Data {
    Data(
        ("{\"version\":\"0.98\",\"uid\":\"awtrix_a07f9c\",\"bat\":\(percent),"
            + "\"bat_raw\":\(raw),\"uptime\":\(uptime),\"ram\":139112,"
            + "\"ip_address\":\"10.0.0.5\"}").utf8
    )
}

/// Records the crossings a poll handed over, and raises nothing.
final class SpyAlerts: BatteryWarningPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [BatteryWarning] = []

    var warnings: [BatteryWarning] { lock.withLock { recorded } }

    @MainActor func warn(_ warning: BatteryWarning) async {
        lock.withLock { recorded.append(warning) }
    }
}

/// Records what the dialog was asked to say, instead of putting it on screen.
final class RecordingDialog: BatteryDialogPresenting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(title: String, body: String)] = []

    var shown: [(title: String, body: String)] { lock.withLock { recorded } }

    func show(title: String, body: String) {
        lock.withLock { recorded.append((title, body)) }
    }
}

/// Notification Centre, with the answer a test chooses.
///
/// `granted: false` is not a hypothetical: measured against a locally built
/// bundle, `requestAuthorization` comes back refused with `UNErrorDomain` code
/// 1 rather than prompting at all, so it is the case that ships today.
final class StubNotifications: BatteryNotificationPosting, @unchecked Sendable {
    private let lock = NSLock()
    private let granted: Bool
    private var requests = 0
    private var recorded: [(title: String, body: String)] = []

    init(granted: Bool) { self.granted = granted }

    /// How many times authorization was asked for.
    var authorizationRequests: Int { lock.withLock { requests } }
    var posted: [(title: String, body: String)] { lock.withLock { recorded } }

    func requestAuthorization() async -> Bool {
        lock.withLock { requests += 1 }
        return granted
    }

    func post(title: String, body: String) async {
        lock.withLock { recorded.append((title, body)) }
    }
}

// MARK: - Focus

/// A Focus centre whose two answers a test chooses, independently.
///
/// Independently is the point. The trap this gate exists to close is an
/// UNAUTHORIZED centre answering `isFocused == false`, which is the same answer
/// an idle Mac gives — so a double that folded the pair into one switch could
/// not pose the case at all.
final class StubFocusStatus: FocusStatusReading, @unchecked Sendable {
    private let lock = NSLock()
    private var accessValue: FocusAccess
    private var focused: Bool
    private var asks = 0

    init(access: FocusAccess = .notDetermined, isFocused: Bool = false) {
        self.accessValue = access
        self.focused = isFocused
    }

    var access: FocusAccess { lock.withLock { accessValue } }
    var isFocused: Bool { lock.withLock { focused } }
    /// How many times the gate asked macOS for access.
    var accessRequests: Int { lock.withLock { asks } }

    func requestAccess() { lock.withLock { asks += 1 } }

    /// A Focus turning on or off underneath a schedule that is already ticking.
    func nowFocused(_ value: Bool) { lock.withLock { focused = value } }

    func nowReports(access: FocusAccess) { lock.withLock { accessValue = access } }
}

/// A clock stopped at an hour, so a test can ask what the gate does at three in
/// the morning without waiting until then.
///
/// Built through `Calendar.current`, and read back through it, so the hour is
/// the one the machine running the suite would call three o'clock rather than
/// whatever UTC makes of it.
func atHour(_ hour: Int, calendar: Calendar = .current) -> Date {
    var components = calendar.dateComponents([.year, .month, .day], from: Date())
    components.hour = hour
    components.minute = 30
    components.second = 0
    return calendar.date(from: components)!
}

// MARK: - Microphones

/// The inputs on this desk, with the two facts that make the naive gate wrong.
///
/// `Universal Audio Thunderbolt` is not decoration: probed on the machine this
/// was written on, that always-on interface reports `capturing == true`
/// permanently with no meeting in progress, and it is why "is any input
/// capturing" is a permanent mute rather than a gate. Every fixture below keeps
/// at least one unwatched capturing device, or the watch-set filter is never
/// exercised and a test claiming it passes with the filter deleted.
enum Inputs {
    static let builtIn = AudioInput(
        uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone", isCapturing: false
    )
    static let phone = AudioInput(
        uid: "C1E4A019-FDA0-4A69-99C4-B06600000003", name: "iPhone Microphone",
        isCapturing: false
    )
    /// The always-on interface. Unwatched, and capturing whatever else is true.
    static let interface = AudioInput(
        uid: "com_uaudio_driver_UAD2AudioEngine:0", name: "Universal Audio Thunderbolt",
        isCapturing: true
    )
    static let virtual = AudioInput(
        uid: "VirtualAudio_UID", name: "Serato Virtual Audio", isCapturing: false
    )

    static func capturing(_ input: AudioInput) -> AudioInput {
        AudioInput(uid: input.uid, name: input.name, isCapturing: true)
    }

    static func idle(_ input: AudioInput) -> AudioInput {
        AudioInput(uid: input.uid, name: input.name, isCapturing: false)
    }
}

/// Reports whatever a test hands it, and can change its answer while the app is
/// running.
///
/// Changing it underneath a running schedule is the point: a meeting that never
/// ends cannot pose the question the deferral exists to answer.
final class StubAudioInputs: AudioInputReporting, @unchecked Sendable {
    private let lock = NSLock()
    private var reported: [AudioInput]
    private var reads = 0

    init(_ reported: [AudioInput] = [Inputs.builtIn, Inputs.phone, Inputs.interface]) {
        self.reported = reported
    }

    /// How many times the gate asked the system.
    var enumerations: Int { lock.withLock { reads } }

    func inputs() -> [AudioInput] {
        lock.withLock {
            reads += 1
            return reported
        }
    }

    func nowReports(_ reported: [AudioInput]) { lock.withLock { self.reported = reported } }
}

/// The desk as it is during a meeting: the built-in microphone hot, the
/// always-on interface hot as ever, the phone idle and present.
let duringAMeeting = [Inputs.capturing(Inputs.builtIn), Inputs.phone, Inputs.interface]

/// And after it: only the interface, which is never evidence of anything.
let afterTheMeeting = [Inputs.builtIn, Inputs.phone, Inputs.interface]

// MARK: - Weather

/// The weather service and the clock behind one door, because the app has one:
/// `Transport` is how both are reached.
///
/// A second copy of the kit's own double rather than a shared one — test
/// targets do not import each other — and a leaner one: what the app-level
/// tests read is the overlay writes, in order.
final class SkyAndClockTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let sky: Data
    private var answering = true
    /// What the clock's `OVERLAY` setting currently holds. Written by a POST
    /// and answered by a GET, as it is on the device — a double that kept
    /// answering the original would let a custody that reads the prior value
    /// after writing over it pass, with the value it promised to put back
    /// already gone.
    private var overlayOnDevice: String

    init(sky: Data = liveSky, overlayOnDevice: String = "clear") {
        self.sky = sky
        self.overlayOnDevice = overlayOnDevice
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    /// What the clock.s overlay setting holds right now.
    var currentOverlay: String { lock.withLock { overlayOnDevice } }

    /// The clock stops answering, the way one does when it is unplugged
    /// mid-quit. A refused write changes nothing on it.
    func stopAnswering() { lock.withLock { answering = false } }
    func startAnswering() { lock.withLock { answering = true } }

    /// Every overlay write that REACHED the clock, in order — including one it
    /// refused, which is what tells an attempt apart from a restore that was
    /// never made.
    var overlayWrites: [String] {
        requests
            .filter { $0.url?.path == "/api/settings" && $0.httpMethod == "POST" }
            .compactMap {
                (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()))
                    .flatMap { $0 as? [String: Any] }?["OVERLAY"] as? String
            }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try lock.withLock { () throws -> Data in
            recorded.append(request)
            guard answering else { throw URLError(.cannotConnectToHost) }
            if request.url?.host == "api.open-meteo.com" { return sky }
            if request.url?.path == "/api/stats" { return onlineStats }
            guard request.url?.path == "/api/settings" else { return Data("OK".utf8) }
            if request.httpMethod == "POST" {
                let written = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()))
                    .flatMap { $0 as? [String: Any] }?["OVERLAY"] as? String
                if let written { overlayOnDevice = written }
                return Data("OK".utf8)
            }
            return Data(#"{"BRI":2,"OVERLAY":"\#(overlayOnDevice)"}"#.utf8)
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

/// Rain over Moscow, in the shape the live service answers with.
let liveSky = Data("""
{"current":{"time":"2026-08-19T02:45","interval":900,"weather_code":61,"is_day":1,
  "precipitation":0.4,"temperature_2m":4.2,"wind_speed_10m":9.0}}
""".utf8)

let aDesk = Coordinates(latitude: 55.7558, longitude: 37.6173)

func weatherConnector(over transport: any Transport) -> WeatherConnector {
    WeatherConnector(source: OpenMeteoSource(transport: transport), location: { aDesk })
}

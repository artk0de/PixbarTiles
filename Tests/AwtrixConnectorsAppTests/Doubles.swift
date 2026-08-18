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
    private let delay: TimeInterval?

    /// `delay` stands in for a connector that is failing: nil answers with the
    /// interval it was asked about, which is what a healthy one gets.
    init(parkInRun: Gate? = nil, parkInMaintain: Gate? = nil, delay: TimeInterval? = nil) {
        self.parkInRun = parkInRun
        self.parkInMaintain = parkInMaintain
        self.delay = delay
    }

    /// One entry per call, in call order: `maintain:<id>` / `run:<id>`.
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
@discardableResult
@MainActor
func waitUntil(
    _ condition: @MainActor () -> Bool, limit: TimeInterval = 2
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
    transport: any Transport = StubTransport(),
    uploads: any UploadedIconStore = InMemoryUploadedIconStore(),
    defaults: UserDefaults = UserDefaults(suiteName: "testModel-\(UUID().uuidString)")!,
    sleep: @escaping AppModel.Sleeping = parked,
    pollSleep: @escaping AppModel.Sleeping = parked,
    deviceHost: String = "10.0.0.5"
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
        defaults: defaults,
        sleep: sleep,
        pollSleep: pollSleep
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
}

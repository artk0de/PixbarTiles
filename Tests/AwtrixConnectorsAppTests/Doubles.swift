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
    private let parkInRun: Gate?

    init(parkInRun: Gate? = nil) {
        self.parkInRun = parkInRun
    }

    /// One entry per call, in call order: `maintain:<id>` / `run:<id>`.
    var calls: [String] { lock.withLock { recorded } }

    func maintain(connectorId: String) async -> MaintenanceResult {
        lock.withLock { recorded.append("maintain:\(connectorId)") }
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

/// Stands in for `Task.sleep` so a schedule can be driven a tick at a time.
///
/// Every sleeper parks until `tick()`, and a cancelled one throws exactly as the
/// real sleep does — the schedule relies on that throw to tell a quit from an
/// elapsed interval, so a fake that swallowed it would be testing a different
/// loop from the one that ships.
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

@MainActor
func testModel(
    connectors: [any Connector] = [StubConnector()],
    host: any ConnectorRunning = SpyHost(),
    store: any SettingsStore = InMemorySettingsStore(),
    transport: any Transport = StubTransport(),
    uploads: any UploadedIconStore = InMemoryUploadedIconStore(),
    sleep: @escaping AppModel.Sleeping = { _ in }
) -> AppModel {
    let registry = ConnectorRegistry()
    for connector in connectors { registry.register(connector) }
    let device = AwtrixDevice(host: "10.0.0.5", transport: transport)
    return AppModel(
        deviceHost: "10.0.0.5",
        device: device,
        registry: registry,
        host: host,
        store: store,
        installer: CatalogueIconInstaller(
            device: device, transport: transport, uploads: uploads
        ),
        sleep: sleep
    )
}

/// Every task the model starts and owns, in one place.
///
/// A task the model starts writes to a clock, and a delivery holds a banner
/// until its release goes out — a release that is deliberately uncancellable.
/// So a teardown cannot merely cancel: it has to wait for what was in flight,
/// and it can only wait for what it can find. Before this there were eleven
/// handles and two counters spread through `AppModel`, and `teardown` had to
/// name every one of them; a twelfth added without being named there would
/// have been a banner left on the clock at quit.
///
/// Three shapes of work, the three the model has:
/// - `run`: one-off work that leaves the bag when done (a manual run, a
///   replay, a restore, a lamp push);
/// - `replace`: work under a name where a newer one supersedes the older (the
///   monitor loop, the history load, the microphone watch);
/// - `startIfIdle`: work under a name that must not run twice at once (icon
///   removal, the panel's refresh).
@MainActor
final class TaskBag {
    private var anonymous: [Int: Task<Void, Never>] = [:]
    private var nextKey = 0
    private var named: [String: (id: Int, task: Task<Void, Never>)] = [:]

    /// How many tasks are held.
    var count: Int { anonymous.count + named.count }

    func run(_ work: @escaping @MainActor () async -> Void) {
        let key = takeKey()
        anonymous[key] = Task { [weak self] in
            await work()
            self?.anonymous[key] = nil
        }
    }

    func replace(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        named[name]?.task.cancel()
        start(name, work)
    }

    @discardableResult
    func startIfIdle(_ name: String, _ work: @escaping @MainActor () async -> Void) -> Bool {
        guard named[name] == nil else { return false }
        start(name, work)
        return true
    }

    func isRunning(_ name: String) -> Bool { named[name] != nil }

    func cancel(_ name: String) {
        named[name]?.task.cancel()
        named[name] = nil
    }

    /// Cancels everything held, and `extra`, then waits for all of it.
    func cancelAndWait(also extra: [Task<Void, Never>] = []) async {
        let running = Array(anonymous.values) + named.values.map(\.task) + extra
        anonymous.removeAll()
        named.removeAll()
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    private func start(_ name: String, _ work: @escaping @MainActor () async -> Void) {
        let id = takeKey()
        let task = Task { [weak self] in
            await work()
            // Only its own entry: a replacement started meanwhile keeps its place.
            if self?.named[name]?.id == id { self?.named[name] = nil }
        }
        named[name] = (id, task)
    }

    private func takeKey() -> Int {
        defer { nextKey += 1 }
        return nextKey
    }
}

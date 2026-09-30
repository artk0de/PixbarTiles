import Foundation
import PixbarKit

/// One session per clock, each with its own delivery chain and custody — so
/// a clock that stops answering holds up only its own tiles — and, beside
/// each, the clock's own connector registry.
///
/// A registry is built once per clock and kept: its connectors read their
/// stores on every call, so one instance stays current, and rebuilding it per
/// preview would re-read the secret store on every keystroke. It goes when
/// its clock's session goes, because its connectors are closed over the
/// clock as it was.
@MainActor
final class ClockSessions {
    private var byClock: [UUID: any ConnectorRunning] = [:]
    private var registries: [UUID: ConnectorRegistry] = [:]
    private let make: @MainActor (ClockRecord) -> any ConnectorRunning
    /// How a clock's own registry is built — the one its session pushes
    /// through, closed over that clock's place, its tile's metric and its
    /// key in the secret store.
    ///
    /// Optional because a test wiring a model by hand names its connectors
    /// directly and has no per-clock story; those fall back to the app-level
    /// registry, which is what they were reading before this existed.
    private let makeRegistry: (@MainActor (ClockRecord) -> ConnectorRegistry)?

    init(
        make: @escaping @MainActor (ClockRecord) -> any ConnectorRunning,
        makeRegistry: (@MainActor (ClockRecord) -> ConnectorRegistry)?
    ) {
        self.make = make
        self.makeRegistry = makeRegistry
    }

    subscript(clockId: UUID) -> (any ConnectorRunning)? { byClock[clockId] }

    /// Every session, with its clock.
    var all: [(clockId: UUID, session: any ConnectorRunning)] { byClock.map { ($0.key, $0.value) } }

    var clockIds: Set<UUID> { Set(byClock.keys) }

    /// Builds the clock's session unless it has one.
    func open(_ clock: ClockRecord) {
        if byClock[clock.id] == nil { byClock[clock.id] = make(clock) }
    }

    /// Forgets the clock's session and its registry, handing the session back
    /// for whatever it still has to give back.
    @discardableResult
    func drop(_ clockId: UUID) -> (any ConnectorRunning)? {
        registries[clockId] = nil
        return byClock.removeValue(forKey: clockId)
    }

    /// The clock's own registry, built on first need; nil where the model has
    /// no per-clock factory.
    func registry(for clock: ClockRecord) -> ConnectorRegistry? {
        guard let makeRegistry else { return nil }
        let own = registries[clock.id] ?? makeRegistry(clock)
        registries[clock.id] = own
        return own
    }

    /// The clock's session as a TC002 host, or nil for any other.
    func ulanzi(for clockId: UUID) -> (any UlanziConnectorRunning)? {
        byClock[clockId] as? any UlanziConnectorRunning
    }
}

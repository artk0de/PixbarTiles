import Foundation
import PixelClockKit

/// The TC002 clock's slot in the schedule: the Ulanzi session behind the one
/// protocol the per-clock cadence drives.
///
/// Everything below the slot is the phase-3 session, unchanged — the upsert
/// per tile, the re-push-all recovery after an outage, the custody's start-up
/// sweep, the idle frame for a paused tile. What the slot adds is the answer
/// to the cadence, and three of those answers are flat on purpose:
///
/// - `maintain` — nothing on a TC002 restocks. A page is produced and pushed
///   in one breath; there is no queue behind it, so there is nothing to fill.
/// - `deliver(AwtrixDelivery)` — the replay path is the anecdote's, and the
///   anecdote has no page on this clock. Nothing that could replay can even
///   be placed here.
/// - `restoreDeviceState` — a TC002 owns no global setting to borrow; every
///   page it has is the app's own, and pages are given back through the
///   custody, not through a restore.
///
/// `nextDelay` is flat too, and that is a decision rather than an omission:
/// the session's own recovery rule is the outage answer — the first push that
/// gets through drags every page back — and a second clock inside the cadence
/// would shorten the retry schedule twice for one failure.
///
/// `indicators` is nil: the TC002 has no lamps, and an availability that
/// said otherwise would promise a surface the firmware does not have.
actor UlanziClockHost: ConnectorRunning, UlanziConnectorRunning, ClockPageShowing {
    private let session: UlanziClockSession
    private let registry: ConnectorRegistry
    private let store: any SettingsStore
    /// The tiles this clock's pages are for, read at the moment the start-up
    /// sweep runs rather than at wiring time — the sweep registers the live
    /// set so a recovery knows the full set, and a paused tile's page counts
    /// as live (D4: kept, held by the idle frame).
    private let liveTiles: @Sendable () -> [String]
    /// The start-up sweep runs once, before the first push. First use rather
    /// than wiring time, because wiring is synchronous and the sweep is a
    /// round trip; the cadence or the first event reaches here within moments
    /// of launch either way.
    private var swept = false

    init(
        session: UlanziClockSession,
        registry: ConnectorRegistry,
        store: any SettingsStore,
        liveTiles: @escaping @Sendable () -> [String]
    ) {
        self.session = session
        self.registry = registry
        self.store = store
        self.liveTiles = liveTiles
    }

    /// Produces the connector's TC002 face and hands it to the session's
    /// upsert, one delivery at a time.
    ///
    /// Everything is keyed by `tile.key.tileId`, the page's name: the connector
    /// built for this tile, its settings, and the page it lands on.
    func runOnce(tile: TileRecord) async -> RunResult {
        await sweepAtFirstUse()
        let tileId = tile.key.tileId
        // Both guards are answered before a place in the session's chain is
        // claimed, for the reason `AwtrixClockSession.runOnce` states: neither
        // a registry lookup nor a settings read touches the device, and a
        // "run now" against a switched-off connector must not queue behind a
        // push to hear "it's off".
        guard let connector = registry.connector(for: tile) else {
            return .failed("unknown connector \(tileId)")
        }
        guard store.settings(for: tileId).isEnabled else { return .skipped }
        // A connector with no TC002 face is not on this clock — the catalogue
        // refuses the placement — so the nil here is the belt to the
        // schedule's braces, answered as a skip and not a failure.
        let delivery: UlanziDelivery?
        do {
            delivery = try await connector.produceUlanzi()
        } catch {
            return DeliveryChain.classify(error)
        }
        guard let delivery else { return .skipped }
        return await session.deliver(delivery, toTile: tileId)
    }

    /// Nothing to restock — see the type comment.
    func maintain(tile: TileRecord) async -> MaintenanceResult { .skipped }

    /// Nothing here takes an AWTRIX delivery — see the type comment.
    func deliver(_ output: AwtrixDelivery) async -> RunResult { .skipped }

    /// The interval back, always: the recovery rule below this slot is the
    /// outage answer, and the cadence adding a backoff on top would be a
    /// second clock shortened for the same failure.
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval {
        interval
    }

    /// Nothing device-wide is ever borrowed — see the type comment.
    func restoreDeviceState(borrowedBy tileId: String?) async {}

    /// The TC002 has no lamps.
    nonisolated var indicators: IndicatorCustody? { nil }

    // MARK: the Ulanzi surface, for the model's event paths

    /// A page produced outside a run — the path the phase-3 wiring drove by
    /// hand. The session takes the scene onto its board before the wire, so
    /// a recovery carries it like any other page.
    func deliver(_ output: UlanziDelivery, toTile tileId: String) async -> RunResult {
        await sweepAtFirstUse()
        return await session.deliver(output, toTile: tileId)
    }

    /// A paused tile's page keeps its place on the idle frame (D4).
    func markIdle(tileId: String) async -> RunResult {
        await sweepAtFirstUse()
        return await session.markIdle(tileId: tileId)
    }

    /// The tile is gone: the empty-body delete, and the record without it.
    func tileRemoved(_ tileId: String) async {
        await session.tileRemoved(tileId)
    }

    /// Quit or removal: every owned page leaves the knob cycle (D4).
    func shutdown() async {
        await session.shutdown()
    }

    // MARK: showing a page on request — see `ClockPageShowing`

    func page(forTile tileId: String) async throws -> String? {
        try await session.page(forTile: tileId)
    }

    /// Always nil: the firmware cannot say which page is up.
    func currentPage() async throws -> String? {
        try await session.currentPage()
    }

    func showPage(_ page: String) async throws {
        try await session.showPage(page)
    }

    private func sweepAtFirstUse() async {
        guard swept == false else { return }
        swept = true
        await session.sweep(liveTiles: liveTiles())
    }
}

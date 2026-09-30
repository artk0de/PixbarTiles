import Foundation
import PixbarKit

/// What a tile's schedule, a restore and a display push need of the runner.
@MainActor
protocol TileRunning: AnyObject {
    func retract(_ key: TileKey)
    func pushDisplaySettings(_ key: TileKey)
}

/// Runs a tile and says how it went: the run's word, its failure, the
/// restock's complaint, the delivery a launch measures its first sleep from,
/// and the runs a meeting is holding.
@MainActor
final class TileRunner: ObservableObject, TileRunning {
    /// What each tile's last run said, in the row's words.
    @Published private(set) var tileLastResults: [TileKey: String] = [:]
    /// What each tile's last run ended in, in the raw words the transport
    /// produced, and nothing at all while the last run did not fail. Kept raw
    /// so the row's sentence and every other reader translate it themselves.
    @Published private(set) var tileLastFailures: [TileKey: String] = [:]
    /// What the last background pass had to complain about, per tile, and
    /// nothing at all when it went fine.
    @Published private(set) var tileLastMaintenanceFailure: [TileKey: String] = [:]
    /// Tiles with a display-settings push on the wire, and those whose look
    /// changed again while it was — see `pushDisplaySettings(_:)`.
    private var displayPushes: Set<TileKey> = []
    private var displayPushOwed: Set<TileKey> = []
    /// Runs still going, per connector.
    ///
    /// A count rather than a flag because two presses are two runs: 37 seconds
    /// of silence is exactly the thing that makes a person press again, and
    /// `AwtrixClockSession` serialises the pair rather than merging them. With only
    /// a flag, the first run finishing writes its outcome while the second is
    /// still in flight — the panel claiming a finished delivery during a
    /// running one, which is the lie this whole line of fixes is about.
    private var outstanding: [TileKey: Int] = [:]
    /// Connectors whose scheduled run is waiting out a meeting.
    ///
    /// A SET, and that is the rule rather than a container choice: at most one
    /// run is held per connector, so a two-hour meeting that swallows four
    /// beats releases one anecdote rather than firing four in a burst the
    /// moment it ends. A second beat arriving while one is already held inserts
    /// nothing.
    private var heldRuns: Set<TileKey> = []
    private let tiles: TileStore
    private let clockSessions: ClockSessions
    /// Nothing is sent to a clock the poll has found unreachable, and a
    /// failure against one the poll still believes in asks again at once.
    private let reachability: any ReachabilityReading
    /// The model's task bag: teardown waits on every run through it.
    private let taskBag: TaskBag

    init(
        tiles: TileStore,
        clockSessions: ClockSessions,
        reachability: any ReachabilityReading,
        taskBag: TaskBag
    ) {
        self.tiles = tiles
        self.clockSessions = clockSessions
        self.reachability = reachability
        self.taskBag = taskBag
    }

    private func session(for key: TileKey) -> (any ConnectorRunning)? { clockSessions[key.clockId] }

    /// The record a session is handed to run a tile: the stored one, so a
    /// connector built for it reads the tile's current settings, else the bare
    /// key — a tile removed while its run was in flight, or one a test names
    /// without storing. Its policy is informational there: the session reads
    /// enablement from its own store when the run is asked for.
    func runningTile(_ key: TileKey) -> TileRecord {
        tiles.all().first { $0.key == key }
            ?? TileRecord(key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 0))
    }

    /// A clock's most recent push, as the dot asks it. The run's own
    /// complaint outranks the restock's — the same precedence the row draws —
    /// and any failure on any tile outranks an older delivery: the dot says
    /// the newest evidence about the clock, not the best.
    enum PushState: Equatable, Sendable {
        case none
        case running
        case delivered
        case failed
    }

    func pushState(of clockId: UUID) -> PushState {
        let onThisClock = tiles.all().map(\.key).filter { $0.clockId == clockId }
        if onThisClock.contains(where: {
            tileLastFailures[$0] != nil || tileLastMaintenanceFailure[$0] != nil
        }) {
            return .failed
        }
        if onThisClock.contains(where: { tileLastResults[$0] == Self.runningWord }) {
            return .running
        }
        if onThisClock.contains(where: { tileLastResults[$0] == Self.deliveredWord }) {
            return .delivered
        }
        return .none
    }

    /// The row's word for a push under way, and its word for one delivered —
    /// named once because the dot reads the same words the row draws, and a
    /// word renamed in one place and not the other would silence the dot
    /// without anything going red.
    static let runningWord = "running…"
    static let deliveredWord = "delivered"

    /// One tile's row inputs, said where they are known.
    func lastResult(of key: TileKey) -> String? { tileLastResults[key] }

    /// The run's own complaint outranks the restock's: it is the newer
    /// evidence about the same feed.
    func lastFailure(of key: TileKey) -> String? {
        tileLastFailures[key] ?? tileLastMaintenanceFailure[key]
    }

    /// Takes a tile's app back off its clock now, rather than letting its
    /// lifetime expire.
    ///
    /// Through the same `taskBag` `runNow` uses, for the reason that
    /// one is: teardown can only wait for a task this model is holding.
    func retract(_ key: TileKey) {
        taskBag.run { [weak self] in
            await self?.session(for: key)?.restoreDeviceState(borrowedBy: key.tileId)
        }
    }

    /// Runs one connector now, because the user asked.
    ///
    /// The task is owned here rather than by the button's action closure, for
    /// the same reason the timers are: teardown has to be able to wait for it.
    /// A run started by hand puts the same held banner on the clock as a
    /// scheduled one, and a quit that does not wait for it kills the process
    /// during the release and leaves the banner up.
    func runNow(_ key: TileKey) {
        taskBag.run { [weak self] in
            await self?.runAndReport(key)
        }
    }

    /// Puts a tile's new look on its clock now, rather than a whole interval
    /// after the save — `reschedule` restarts the tile's sleep, so a face
    /// changed in the settings window used to wait out one full interval from
    /// the LAST change before the clock showed it.
    ///
    /// Only a change of the tile's config: the policy half (the interval, the
    /// hours, the Focus rule) moves the schedule and not the face, and the
    /// interval slider must not touch the clock. Only a tile that was running
    /// and still runs at this hour and Focus — a tile switched back on arrives
    /// through `reconcileTiles`, and a tile its rule holds keeps holding. Never
    /// an audible tile, which a settings change must not make speak.
    ///
    /// Through `runAndReport`, the "Run now" path, so the run builds the
    /// tile's connector from the record just stored. One push per tile at a
    /// time: a change landing while one is on the wire is owed ONE more push,
    /// made after it, so a slower run drawn from an older record can never be
    /// the last page on the clock.
    func pushDisplaySettings(_ key: TileKey) {
        guard displayPushes.insert(key).inserted else {
            displayPushOwed.insert(key)
            return
        }
        taskBag.run { [weak self] in
            repeat {
                self?.displayPushOwed.remove(key)
                await self?.runAndReport(key)
            } while !Task.isCancelled && self?.displayPushOwed.contains(key) == true
            self?.displayPushes.remove(key)
        }
    }

    /// Holds a scheduled run until the meeting is over — at most one per tile.
    func hold(_ key: TileKey) {
        heldRuns.insert(key)
    }

    /// Lets go of the runs a meeting held, once nothing is holding them.
    ///
    /// Gated on the whole of the schedule's hold (`stillHeld`), not only on the microphone.
    /// A run held through a meeting that ends inside a Focus would otherwise
    /// speak into the Focus; one released into a clock that is not answering
    /// would be worse still, because `produce()` retires an anecdote before the
    /// banner goes out and the user permanently loses something they never
    /// heard. Holding on costs nothing — this loop is still turning and lets it
    /// go the moment every gate is clear. Nothing here is sticky in either
    /// direction.
    ///
    /// Asked per connector, because the gates are: only what is still held for
    /// this one stays behind.
    ///
    /// Removed from the set BEFORE the runs, never after them. Not for
    /// re-entrancy — the watch loop awaits each release, so there is no second
    /// turn to defend against — but because a scheduled beat can land while a
    /// release is in flight: the meeting resumes, that beat records its own
    /// hold, and a subtraction below the loop would take the new one with it.
    func releaseHeldRuns(stillHeld: (TileKey) -> Bool) async {
        let due = heldRuns.filter { stillHeld($0) == false }
        guard due.isEmpty == false else { return }
        heldRuns.subtract(due)
        for key in due { await runAndReport(key) }
    }

    /// The scheduled path, once the schedule has found nothing holding the tile.
    func runScheduled(_ key: TileKey) async {
        // Marked before the maintain, not between it and the run. `maintain` IS
        // the expensive half — a refill loads a 1.8 GB model and synthesizes a
        // whole batch, a minute or more — and once it has run, `runOnce` finds a
        // full queue and is quick. Written after it, the marker lands exactly
        // where the wait is already over, and the panel shows the PREVIOUS run's
        // outcome for the whole minute.
        markUnderWay(key)
        // Top up BEFORE the run, never inside it. `produce()` only awaits a
        // refill when the queue is empty, so a timer that never maintains turns
        // every firing into a 70-second model load on the play path — the whole
        // reason the queue exists.
        await restock(key)
        reportOutcome(
            await session(for: key)?.runOnce(tile: runningTile(key))
                ?? .failed("no clock \(key.clockId)"),
            for: key
        )
        // And again after it, because the run is what emptied the queue. See
        // `restock(_:)`.
        await restock(key)
    }

    /// The manual path. The bracket is spelled out here as well as in `runScheduled`
    /// rather than shared, because the shared version would be a call that
    /// marks a second time — and a count that never returns to zero is a panel
    /// stuck on `running…` for good.
    ///
    /// Nothing is sent to a clock the poll has found unreachable, pressed or
    /// not. The press used to be read as consent to try, and what it bought was
    /// a red card with a transport's error dictionary in it about a clock the
    /// panel already called offline. The press is still answered — the line
    /// says why nothing happened — and the restock after it still runs, because
    /// an outage of the clock is not an outage of the feed.
    func runAndReport(_ key: TileKey) async {
        if reachability.clockIsUnreachable(key.clockId) {
            tileLastResults[key] = AppModel.deviceUnreachable
            await restock(key)
            return
        }
        markUnderWay(key)
        reportOutcome(
            await session(for: key)?.runOnce(tile: runningTile(key))
                ?? .failed("no clock \(key.clockId)"),
            for: key
        )
        await restock(key)
    }

    /// Runs a connector's background pass and keeps whatever it had to say.
    ///
    /// Called after every completed run as well as before every scheduled one,
    /// and the post-run call is the one worth arguing for: a "Run now" that
    /// drains the queue would otherwise leave it drained until the next timer,
    /// which on the shipped half-hourly cadence is half an hour of a queue one
    /// press away from empty. `maintain` returns early above the threshold, so
    /// on the passes that do not need it the extra call costs a queue read.
    ///
    /// Strictly AFTER the outcome is reported, never before or around it. A
    /// refill can be a minute of synthesis, and a run whose completion waited
    /// on it would leave the panel saying `running…` long after the anecdote
    /// had finished playing — which is the lie `markUnderWay` exists to stop.
    ///
    /// Unconditional on how the run went. A run that failed for want of
    /// anything to hand out is exactly the one that needs restocking, and
    /// `AwtrixClockSession` already answers `.skipped` for a connector the user
    /// switched off.
    func restock(_ key: TileKey) async {
        note(
            await session(for: key)?.maintain(tile: runningTile(key))
                ?? .failed("no clock \(key.clockId)"),
            for: key
        )
    }

    /// Says a delivery is under way before it says how it went.
    ///
    /// Measured on the machine this was written on: a run against an empty
    /// queue takes 37.6 s, because `produce()` refills inline when it has
    /// nothing to hand out and the first refill of a process pays a 30-second
    /// model load. Without this the panel shows nothing for all of it — the
    /// outcome is the only thing ever written, and it arrives at the end — so a
    /// "Run now" reads as a button that does nothing.
    private func markUnderWay(_ key: TileKey) {
        outstanding[key, default: 0] += 1
        tileLastResults[key] = Self.runningWord
    }

    /// Shows a result only when it is the last one outstanding.
    ///
    /// An earlier run's outcome is DISCARDED, not deferred: it is dropped here
    /// and never shown, and the line goes on describing what this connector is
    /// doing now, which is still running.
    ///
    /// That has a cost worth being plain about, because an earlier draft of this
    /// comment claimed it did not. A run that fails while a second is in flight
    /// loses its message for good, and the second one only reproduces it if it
    /// takes the same path: run 1 `.failed("feed is down")` followed by run 2
    /// `.skipped` leaves the panel reading `off`, with the outage never
    /// mentioned. Showing both wants a second line per connector rather than a
    /// word squeezed into this one, and that is a design decision nobody has
    /// asked for yet.
    private func reportOutcome(_ result: RunResult, for key: TileKey) {
        // Above the guard, never below it. What that guard decides is whose
        // outcome the panel gets to SHOW — an earlier run's word is dropped
        // while a later one is still going — and a delivery that happened is a
        // fact about the cadence whether or not there is a free line to say it
        // on. Below it, two overlapping runs would leave the first one's
        // delivery unrecorded and the next launch measuring from before it.
        if case .delivered = result { noteDelivery(key) }
        outstanding[key, default: 1] -= 1
        guard outstanding[key, default: 0] <= 0 else { return }
        record(result, for: key)
    }

    /// Keeps what a background pass complained about, and drops it when there is
    /// nothing left to complain about.
    ///
    /// A refill that cannot reach the feed is invisible otherwise: the run that
    /// follows it only fails once the queue has run dry as well, which on a
    /// stocked queue is hours later and on a well-stocked one is never. One
    /// line, deliberately — the run's own outcome keeps its slot, and this says
    /// what the restocking behind it is doing.
    ///
    /// `.cancelled` leaves whatever was there. It is not evidence: the ordinary
    /// producer is a quit part-way through a fetch, and clearing a real outage
    /// on the strength of having been interrupted is the same mistake as
    /// counting one as a failure.
    private func note(_ result: MaintenanceResult, for key: TileKey) {
        switch result {
        case .completed, .skipped: tileLastMaintenanceFailure[key] = nil
        case .cancelled: break
        case let .failed(message):
            // Raw, deliberately: `TileRowLine` is where the raw words a
            // transport produced become a sentence, and this store only keeps
            // what was complained about.
            tileLastMaintenanceFailure[key] = message
        }
    }

    /// A failure against a clock that is not answering is the clock's news,
    /// not the tile's: the panel's status line already says the clock is
    /// away, and a red card beside it only repeats that in a transport's
    /// dialect. So it is not kept — and a failure against a clock the poll
    /// still believes in asks the clock at once, because the minute until the
    /// next poll is a minute of red cards for an outage nobody has noticed yet.
    func record(_ result: RunResult, for key: TileKey) {
        switch result {
        case .delivered, .skipped: tileLastFailures[key] = nil
        // Not evidence: the same rule `note` gives its own cancellation.
        case .cancelled: break
        case .failed where reachability.clockIsUnreachable(key.clockId):
            tileLastFailures[key] = nil
            tileLastResults[key] = AppModel.deviceUnreachable
            return
        case let .failed(message):
            tileLastFailures[key] = message
            reachability.recheckClocks()
        }
        tileLastResults[key] = Self.words(for: result)
    }


    /// Drops what the tiles of an unreachable clock last failed with — the
    /// failures that were recorded before the poll learned the clock had gone.
    func forgetFailuresOfUnreachableClocks() {
        for key in tileLastFailures.keys where reachability.clockIsUnreachable(key.clockId) {
            tileLastFailures[key] = nil
            tileLastResults[key] = AppModel.deviceUnreachable
        }
    }

    /// Writes down that this connector has just put something on the clock, for
    /// the launch after this one to measure its first sleep from.
    ///
    /// Off the OUTCOME rather than off the call. A run that failed or was
    /// skipped delivered nothing, and a cadence measured from attempts would
    /// slip a whole interval every time the feed was down — the connector
    /// waiting out an hour it had already waited.
    ///
    /// Through the store and the key the slider already writes, because the two
    /// are read together: `settings(for:)` is what the schedule asks, and a
    /// record kept beside it would be a second key to write, migrate and delete
    /// in step for ever. `chosen` is updated as well as the store, not instead
    /// of it — the next `commit` builds what it saves out of `chosen`, so a
    /// toggle or a slider drag would otherwise write back a copy that had
    /// forgotten the delivery.
    ///
    /// An id with nothing resolved against it is left alone. `init` gives every
    /// registered connector an entry, so this is an id the registry does not
    /// have, and inventing a row of choices in the store for one is worse than
    /// forgetting a delivery nobody can schedule anyway.
    private func noteDelivery(_ key: TileKey) {
        guard let record = tiles.all().first(where: { $0.key == key }) else { return }
        tiles.update(record) { $0.lastDeliveredAt = Date() }
    }

    /// What a delivery's outcome is called, in the words both surfaces use.
    ///
    /// One vocabulary rather than one per surface, because it is one question
    /// asked twice: a replay IS a delivery — the same banner, the same jingle,
    /// the same classification of whatever goes wrong, literally the same code
    /// below the produce — so two lists of words would drift the first time
    /// either moved. What differs between the two callers is WHERE the answer
    /// is written, and that is decided by them.
    ///
    /// `.skipped` cannot arrive from a replay. `deliver` never reads
    /// enablement — it has no connector id to read it for — so the word belongs
    /// to the run path, and it is here because the switch is exhaustive.
    static func words(for result: RunResult) -> String {
        switch result {
        case .delivered: Self.deliveredWord
        case .skipped: "off"
        case .cancelled: "cancelled"
        case let .failed(message): "failed — \(TileRowLine.cause(from: message))"
        }
    }
}

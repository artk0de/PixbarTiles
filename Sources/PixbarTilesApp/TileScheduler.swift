import Foundation
import PixbarKit

/// What a tile's settings need of the schedule.
@MainActor
protocol TileScheduling: AnyObject {
    func reschedule(_ key: TileKey, resuming: Bool)
    func reconcileTiles()
    func unschedule(_ key: TileKey)
    func pushDisplaySettings(_ key: TileKey)
}

extension TileScheduling {
    func reschedule(_ key: TileKey) { reschedule(key, resuming: false) }
}

/// Each tile's delivery loop: when it next runs, what holds it, what a launch
/// owes the clock, and which tiles a Focus or an hour has just let in or put
/// out.
@MainActor
final class TileScheduler: ObservableObject, TileScheduling {
    /// The restock the launch fires: a minute of synthesis that a quit would
    /// otherwise kill halfway through a batch.
    static let launchRestock = "launchRestock"

    /// When each tile is next due, or what is holding it.
    @Published private(set) var tileNextRun: [TileKey: NextRun] = [:]
    private var timers: [TileKey: Task<Void, Never>] = [:]
    /// When each scheduled connector's loop will next wake, as the turn that
    /// went to sleep computed it.
    ///
    /// Kept apart from the published label, because the two answer different
    /// questions on different cadences. The due time changes once per turn of
    /// a schedule — half an hour on the shipped one. What is HOLDING that
    /// schedule changes on the reachability poll's minute, on the microphone
    /// watch's five seconds, and on the wall clock as quiet hours begin and
    /// end. Folded into one stored label, the slowest of those clocks decided
    /// all of them: the panel went on naming a microphone that had stopped
    /// capturing half an hour earlier, after the run it held had already
    /// played.
    private var scheduledDue: [TileKey: Date] = [:]
    /// The ambient connectors this launch still owes the clock's loop a first
    /// delivery, drained by the first poll that finds the clock answering.
    ///
    /// A set for the same reason `heldRuns` is one, and a debt rather than a
    /// run for a different one: what is owed here is not a beat that arrived at
    /// a bad moment but the ONLY delivery a launch makes, and losing it is ten
    /// minutes of a clock with nothing on it.
    private var launchDeliveriesOwed: Set<TileKey> = []
    /// What every tile's policy said the last time it was asked, so only a
    /// change is acted on.
    private var verdicts = TileVerdicts()
    /// The wiring of each connector id, told when a tile's window opens or
    /// closes.
    var wirings: @MainActor (String) -> (any TileKindWiring)? = { AppTileKinds.wiring(for: $0) }
    /// What those wirings may do about it; nil until the model hands it in,
    /// and until then no wiring is told.
    var tileArrivalActions: TileArrivalActions?
    /// The delivery cadence, one sleeper per scheduled connector.
    private let scheduleSleep: AppModel.Sleeping
    private let tiles: TileStore
    private let registry: ConnectorRegistry
    private let clockSessions: ClockSessions
    private let runner: TileRunner
    private let reachability: any ReachabilityReading
    /// The model's task bag: teardown waits on the launch restock through it.
    private let taskBag: TaskBag
    /// The watched microphone that is capturing right now, or nil.
    ///
    /// Asked separately from `scheduleHold` because the two answers are put to
    /// different uses: the hold decides whether to run, and this decides
    /// whether not running was a WAIT. A meeting during an outage is still a
    /// meeting, and the run it stopped is still owed.
    private let busyMicrophone: @MainActor () -> AudioInput?
    /// A tile's policy, as the model resolves it.
    private let policy: @MainActor (TileKey) -> TilePolicy?
    /// The Focus the Mac is in and the hour, as every tile's window reads them.
    private let moment: @MainActor () -> (focus: MacFocus, hour: Int)

    init(
        tiles: TileStore,
        registry: ConnectorRegistry,
        clockSessions: ClockSessions,
        runner: TileRunner,
        reachability: any ReachabilityReading,
        taskBag: TaskBag,
        sleep: @escaping AppModel.Sleeping,
        busyMicrophone: @escaping @MainActor () -> AudioInput?,
        policy: @escaping @MainActor (TileKey) -> TilePolicy?,
        moment: @escaping @MainActor () -> (focus: MacFocus, hour: Int)
    ) {
        self.tiles = tiles
        self.registry = registry
        self.clockSessions = clockSessions
        self.runner = runner
        self.reachability = reachability
        self.taskBag = taskBag
        self.scheduleSleep = sleep
        self.busyMicrophone = busyMicrophone
        self.policy = policy
        self.moment = moment
    }

    /// Starts every stored tile's loop whose clock has a session.
    ///
    /// The one caller that resumes. A cadence describes the gap BETWEEN
    /// deliveries, and every OTHER caller of `reschedule` is a settings
    /// change, where the gap the user just chose starts now. One schedule
    /// per stored tile whose clock has a session — whichever model the
    /// record names: the slot decides what a run means, an AWTRIX scene on
    /// one clock, an Ulanzi upsert on another. A tile whose connector the
    /// registry does not know gets no timer inside `reschedule`, and the
    /// VPN tiles get their own path in B18.
    func resumeAll() {
        for record in tiles.all() where clockSessions[record.key.clockId] != nil {
            reschedule(record.key, resuming: true)
        }
    }

    /// Whether this tile has a loop.
    func isScheduled(_ key: TileKey) -> Bool { timers[key] != nil }

    /// Stops this tile's loop, if it has one.
    func unschedule(_ key: TileKey) {
        timers.removeValue(forKey: key)?.cancel()
    }

    /// Stops the loops of every tile on this clock.
    func unschedule(clockId: UUID) {
        for key in timers.keys where key.clockId == clockId {
            timers.removeValue(forKey: key)?.cancel()
        }
    }

    /// Hands every loop over to be cancelled and awaited — the quit.
    func stopAll() -> [Task<Void, Never>] {
        let running = Array(timers.values)
        timers.removeAll()
        return running
    }

    /// Lets go of the runs a meeting held, once nothing else holds them.
    func releaseHeldRuns() async {
        await runner.releaseHeldRuns { [weak self] in self?.scheduleHold(for: $0) != nil }
    }

    /// Writes down which connectors this launch owes a delivery.
    ///
    /// Ambient ones and nothing else. A connector whose output is ambient is
    /// furniture in the device's own loop rather than an event: until it has
    /// delivered once, the clock does not have it at all. Measured on the
    /// hardware, the weather took sixteen minutes to appear in the loop after a
    /// launch, and shortening the cadence only shortens the wait — it does not
    /// remove it. With a `lifetime` on the output it is worse than a wait: an
    /// app that expired while the machine slept stays expired for a whole
    /// cadence more. Everything else keeps the sleep-first rule exactly,
    /// because a relaunch must not shout an anecdote at whoever just logged in.
    ///
    /// Read off `isAmbient` rather than off a flag of its own. That property
    /// already means precisely this — a connector that keeps a value fresh in
    /// the loop rather than announcing something — and a second one would be
    /// two claims about one thing with nothing to keep them in step.
    ///
    /// Switched-off connectors are left out, for the reason `restockAtLaunch`
    /// leaves them out: `AwtrixClockSession` answers `.skipped` for them anyway, so
    /// nothing would break, but a connector the user turned off is not one this
    /// app should be asking about at all.
    func noteLaunchDeliveries() {
        launchDeliveriesOwed = Set(
            tiles.all()
                .filter { record in
                    guard registry.connector(id: record.key.connectorId)?.isAmbient == true
                    else { return false }
                    return record.policy.isPaused == false
                }
                .map(\.key)
        )
    }

    /// Hands the clock what the launch owes it, once it is known to be there.
    ///
    /// Called from `poll()` rather than from `start()`, and the poll is the
    /// whole reason this is a debt instead of a call. A launch is not a licence
    /// to write to a device that is not answering — and at the instant `start()`
    /// returns the device has not answered ANYTHING yet. `DeviceState.unknown`
    /// is deliberately not a hold for a schedule, because a schedule that
    /// stopped for "not asked yet" would lose beats to a question that resolves
    /// in milliseconds; but a beat lost is followed by another one a cadence
    /// later, where this delivery has no successor at all. So it waits for an
    /// answer instead of guessing, and the poll is the turn that has one.
    ///
    /// `scheduleHold` decides, exactly as it decides a beat — nothing here is a
    /// second opinion about the same gates. Which of them can actually hold an
    /// ambient connector is worth naming, because it is not all of them: the
    /// quiet rules are about SPEAKING, and `scheduleHold` asks `isAudible`
    /// before it asks a Focus or a microphone, so a connector that draws into
    /// the loop and says nothing is held by the unreachable clock and by
    /// nothing else. It is asked through `scheduleHold` all the same rather
    /// than against `deviceIsUnreachable` directly, because `isAmbient` and
    /// `isAudible` are separate claims: an ambient connector that DID make a
    /// sound would be held through a Focus here without another line being
    /// written.
    ///
    /// Delivered through `runNow` rather than through a task of its own. It is
    /// the same run the panel's button makes — outside the schedule, owned by
    /// this model so teardown can wait for it, reported on the same line — and
    /// a second copy of that bracket is the duplication `runAndReport` already
    /// warns about.
    ///
    /// Cleared BEFORE the runs rather than after them, for the reason
    /// `releaseHeldRuns` clears before its own: the poll turns while a delivery
    /// is in flight, and a subtraction below the loop would be reading a set
    /// that a later turn may already have acted on.
    func deliverWhatTheLaunchOwes() {
        let due = launchDeliveriesOwed.filter { scheduleHold(for: $0) == nil }
        guard due.isEmpty == false else { return }
        launchDeliveriesOwed.subtract(due)
        for key in due { runner.runNow(key) }
    }

    /// Fills every enabled connector's queue, once, at launch.
    ///
    /// The schedule sleeps before its first tick — deliberately, so launching
    /// the app does not put a banner on the clock — which on a cold start leaves
    /// the first anecdote of the session waiting on a model load and a
    /// synthesis, on the play path. That is the exact cost the queue exists to
    /// avoid, and it was being paid at every launch.
    ///
    /// One task walking the connectors rather than one per connector: the
    /// background pass is not on the host's serialisation chain, so two of them
    /// would load the model twice at once.
    ///
    /// Switched-off connectors are left out rather than left to the host's own
    /// guard. The host answers `.skipped` for them either way, so nothing would
    /// break — but a connector the user turned off is not one this app should
    /// be asking about at all.
    ///
    /// Nothing here guards against a second entry, and nothing clears the handle
    /// when the pass is done. `start()` is called once, from
    /// `applicationDidFinishLaunching`, so a re-entry guard would be defending
    /// against a call that does not exist — and teardown awaiting a task that
    /// has already finished costs nothing, where a handle that nils itself is
    /// one more thing to be wrong about.
    func restockAtLaunch() {
        let due = tiles.all()
            .filter {
                registry.connector(id: $0.key.connectorId) != nil
                    && clockSessions[$0.key.clockId] != nil
                    && $0.policy.isPaused == false
            }
            .map(\.key)
        taskBag.replace(Self.launchRestock) { [weak self] in
            for key in due {
                guard let self else { return }
                await self.runner.restock(key)
            }
        }
    }

    /// Puts a Focus-gated connector where the Focus now says it belongs.
    ///
    /// Both directions, because they are not the same operation. Arriving is a
    /// delivery — the connector produces and the app goes into the loop. LEAVING
    /// has to be an explicit retraction: nothing on the clock removes an app for
    /// being un-refreshed until its lifetime runs out, so a Sleep that started
    /// at midnight would leave the number lit until a quarter past.
    ///
    /// Only a CHANGE is acted on, so the minute hand costs nothing when
    /// nothing moved. Internal rather than private so the suite can pose a
    /// switch directly; the callers are the Focus watcher, `poll()` — which is
    /// also the hour hand — and, from B19, a tile save.
    func reconcileTiles() {
        let (focus, hour) = moment()
        var now: [TileKey: Bool] = [:]
        for record in tiles.all() where record.key.connectorId != VPNConnector.id {
            guard let policy = policy(record.key), !policy.isPaused else { continue }
            now[record.key] = policy.runs(in: focus, atHour: hour)
        }
        let change = verdicts.update(now)
        for key in change.arrived where !isAudible(key.connectorId) { runner.runNow(key) }
        if let actions = tileArrivalActions {
            let records = tiles.all()
            for key in change.arrived {
                guard let record = records.first(where: { $0.key == key }) else { continue }
                wirings(key.connectorId)?.notify(record, arrived: true, actions)
            }
        }
        for key in change.left { tileLeft(key) }
        // Its page taken off without telling the kind: no window closed in
        // front of anyone, so there is no morning tile to hand the clock to —
        // only a page an earlier run may have left behind. Costs nothing when
        // there is none: custody releases only what it still records.
        for key in change.heldAtFirstLook { runner.removePage(key) }
    }

    /// Takes a tile off its clock the way its hours or Focus closing does:
    /// retracted — a TC002 page deleted outright, so it leaves the knob
    /// cycle — and its kind told, which may hand the clock on. Also the
    /// settings window's, taking back a tile it put on out of its hours.
    func tileLeft(_ key: TileKey) {
        runner.retract(key)
        guard let actions = tileArrivalActions,
            let record = tiles.all().first(where: { $0.key == key })
        else { return }
        wirings(key.connectorId)?.notify(record, arrived: false, actions)
    }

    /// Builds this tile's delivery loop, replacing whatever it had.
    ///
    /// - Parameter resuming: whether the FIRST sleep is the remainder of the
    ///   interval rather than the whole of it. Set by the launch and by nothing
    ///   else; `noteNextRun` is where the remainder is worked out and where the
    ///   argument for it lives.
    func reschedule(_ key: TileKey, resuming: Bool = false) {
        timers.removeValue(forKey: key)?.cancel()
        // Whatever the replaced schedule was going to wake at is not what the
        // new one will, and a refresh landing between here and the first
        // `noteNextRun` would otherwise publish the old loop's time.
        scheduledDue[key] = nil
        // A tile whose connector the registry does not know — the VPN among
        // them, which is not a scene connector — gets no schedule here.
        guard let connector = registry.connector(id: key.connectorId),
            clockSessions[key.clockId] != nil
        else { return }
        guard let record = tiles.all().first(where: { $0.key == key }), record.policy.isPaused == false else {
            tileNextRun[key] = .held(AppModel.switchedOff)
            return
        }

        // On the CONNECTOR's own ladder. Snapped against the general one, a
        // tile stored at a step only its connector offers — ten seconds on a
        // Coding Subscription tile — would run at the general floor instead,
        // and the picker would be offering a cadence the schedule quietly
        // refused.
        let interval = RefreshScale.snapped(
            TimeInterval(record.policy.refreshSeconds), on: connector.refreshSteps
        )
        let sleep = self.scheduleSleep
        // An ambient connector is deliberately NOT resumed, and the two halves
        // are one sentence rather than two rules: a launch owes each connector
        // one delivery, and `isAmbient` decides which mechanism pays it.
        // `deliverWhatTheLaunchOwes` pays the weather's, on the first poll that
        // finds the clock answering. Resuming it as well would owe a second
        // delivery seconds after the first — and the schedule's copy would go
        // out at the instant `start()` returns, while the device state is still
        // `.unknown`, which is exactly the write that mechanism exists to
        // refuse. Nothing is lost by letting its cadence start from the launch:
        // the reading is already on the matrix by then, which is the only thing
        // resuming would have bought it.
        let resumesFromTheLastDelivery = resuming && connector.isAmbient == false
        timers[key] = Task { [weak self] in
            // Spent by the first turn and never offered to a second. What is
            // owed is the remainder of ONE interval; a loop that kept asking
            // would measure every later beat against an instant that only gets
            // older, and would end up sleeping nothing at all for ever.
            var owesTheRemainder = resumesFromTheLastDelivery
            while !Task.isCancelled {
                // Asked every turn, not once when the schedule is built. The
                // answer is the interval until this connector starts failing,
                // and a loop that read it up front would never see the backoff
                // it exists to apply. Optional-chained rather than unwrapped so
                // a released model is not held alive across the sleep by its
                // own timer.
                guard
                    let delay = await self?.noteNextRun(
                        key, interval: interval, resuming: owesTheRemainder
                    )
                else { return }
                owesTheRemainder = false
                // The sleep comes first, so enabling a connector — or dragging
                // its interval slider, which rebuilds the schedule just the
                // same — does not fire a delivery on the spot. That rule holds
                // for every connector and is not weakened below: a relaunch
                // must not shout an anecdote at whoever just logged in, and a
                // slider drag must not touch the clock at all.
                //
                // What a LAUNCH changes is how LONG that first sleep is, never
                // whether there is one. The time since the last delivery is
                // taken off it — `noteNextRun` argues for that — so a relaunch
                // 55 minutes into an hourly cadence waits out the five that are
                // left, and one that is already past due waits out nothing. The
                // delivery still arrives the way a due beat does, out of this
                // sleep and through the tick below, where every hold is asked
                // of it unchanged. That is what a shorter sleep buys over a
                // call: an overdue relaunch against an unreachable clock is
                // held exactly as an overdue beat is.
                //
                // Which leaves one launch delivery that is NOT made from here,
                // and it is the ambient connector's — an app in the device's
                // loop is furniture rather than an event, and the clock does
                // not have it at all until one delivery has been made, however
                // little of its cadence is left. It cannot come from this task,
                // because this task is rebuilt on every settings change and a
                // first-turn delivery in this loop would fire on the two
                // gestures the first paragraph rules out. It belongs to the
                // launch, and `deliverWhatTheLaunchOwes` is where it lives —
                // which is also why it is the one kind of connector this loop
                // does not resume; see `resumesFromTheLastDelivery` above.
                do { try await sleep(delay) } catch { return }
                // Returned on, not swallowed. A cancelled sleep is the quit
                // path, and carrying on into the tick would start one more
                // delivery while the app is being torn down.
                guard let self else { return }
                await self.tick(key)
            }
        }
    }

    /// Asks how long to wait, and writes down when that lands.
    ///
    /// One question, one answer, used for both sleeping and telling the user.
    /// A label computed separately from `ConnectorSettings.interval` would agree
    /// with the schedule right up until the retry policy shortened a wait — and
    /// the occasions it then disagreed on are exactly the ones somebody opened
    /// the panel to ask about.
    ///
    /// - Parameter resuming: true on the first turn after a launch, and there
    ///   only. A cadence is a claim about the gaps BETWEEN deliveries, and a
    ///   launch that started the gap over is what made an hourly connector
    ///   inaudible to anybody who quits and reopens: measured on this machine,
    ///   five relaunches inside one hour and five fresh hours, so the first
    ///   anecdote was never reached. What is subtracted is the time since the
    ///   connector last delivered — see `whatIsLeftOf(_:for:)`.
    ///
    ///   The FIRST turn only, because it is the only one with a gap behind it
    ///   that this process did not sleep through. Every later beat is measured
    ///   from a delivery this loop itself made, and re-reading the record there
    ///   would subtract the same elapsed time twice.
    ///
    ///   And a LAUNCH only, because `reschedule` is what a settings change
    ///   calls as well: a resume that reached one would fire a delivery on the
    ///   slider drag `commit` rules out in as many words, and on the gesture
    ///   that switches a connector on.
    ///
    ///   A parameter threaded from `start()` rather than a debt written down in
    ///   the manner of `launchDeliveriesOwed`. That one is a debt because it
    ///   outlives the turn that records it and is spent by a different loop
    ///   entirely; this is spent by the first turn of the loop the same call
    ///   starts. A set would also have to be drained for the connectors that
    ///   never get a loop — a connector switched OFF at launch would keep its
    ///   entry and spend it the moment the user switched it on, which is the
    ///   one gesture this must not fire on.
    func noteNextRun(
        _ key: TileKey, interval: TimeInterval, resuming: Bool
    ) async -> TimeInterval {
        let wait = await clockSessions[key.clockId]?.nextDelay(
            tile: runner.runningTile(key), interval: interval
        ) ?? interval
        let delay = resuming ? whatIsLeftOf(wait, for: key) : wait
        // Asked even while the clock is unreachable, and the answer is still
        // slept: the pause is not sticky, the beat is kept, and the first tick
        // after the device answers delivers. What changes is only what the
        // panel is told — naming an hour for a run that will not happen is the
        // failure `.held` exists to avoid, and the user plans around it.
        //
        // The single writer of the DUE TIME, and only of that. The hold half of
        // the label has three other clocks that can change it, and they refresh
        // it themselves through `publishNextRun` below.
        scheduledDue[key] = Date().addingTimeInterval(delay)
        publishNextRun(key)
        return delay
    }

    /// How much of a wait is left, counting from this connector's last
    /// delivery.
    ///
    /// Clamped at zero rather than allowed to go negative, and that clamp IS
    /// the no-backlog rule: a laptop shut for four intervals owes one delivery,
    /// not four. Four anecdotes in a burst is a punishment for having gone
    /// away, and it is the choice this app has already made twice — a meeting
    /// that swallows four beats releases one when it ends, and an outage that
    /// swallows six replays none of them. Nothing counts the missed beats, on
    /// purpose: a count is what a backlog is made of.
    ///
    /// Never longer than the wait either, which only decides anything when the
    /// stored instant is in the FUTURE — a clock moved back, a machine restored
    /// from a backup, settings carried across a time zone. Subtracted straight,
    /// that would give a remainder longer than the cadence the user chose, and
    /// the connector would go quiet for as long as the clock was wrong.
    ///
    /// Nil is not zero. A connector that has never delivered has no gap behind
    /// it, so it waits the whole interval exactly as it did before any of this;
    /// firing at launch instead is what the sleep-first rule exists to prevent.
    /// It is also why the record is an optional instant rather than one
    /// defaulted to the epoch, which would make every fresh connector overdue.
    func whatIsLeftOf(_ wait: TimeInterval, for key: TileKey) -> TimeInterval {
        guard let delivered = tiles.all().first(where: { $0.key == key })?.lastDeliveredAt else { return wait }
        return min(wait, max(0, wait - Date().timeIntervalSince(delivered)))
    }

    /// Writes one tile's line from what is true now.
    ///
    /// The single place the label is written for a tile that has a schedule, so
    /// the label cannot disagree with itself depending on which of the three
    /// loops last ticked. A hold outranks the time, because a time named while
    /// something is in force is the lie the user plans around.
    ///
    /// A tile with no timer is one the user switched off, and that line belongs
    /// to `reschedule`: it is the only state a live clock cannot change, and
    /// overwriting it here would put an hour back on a row the user has turned
    /// off.
    func publishNextRun(_ key: TileKey) {
        guard timers[key] != nil else { return }
        if let hold = scheduleHold(for: key) {
            tileNextRun[key] = .held(hold)
        } else if let due = scheduledDue[key] {
            tileNextRun[key] = .due(due)
        }
    }

    /// Brings every scheduled tile's line up to date with the gates.
    ///
    /// Called from the two loops that already turn faster than a schedule does
    /// — the reachability poll at a minute and the microphone watch at five
    /// seconds — rather than from a clock of its own. Nothing here runs a
    /// connector or touches a gate's decision; it only re-reads the answer the
    /// panel is showing.
    func refreshScheduleLabels() {
        for key in timers.keys { publishNextRun(key) }
    }

    /// What is holding this connector's schedule right now, or nil when nothing
    /// is.
    ///
    /// One question asked in two places — before the sleep, to label the panel,
    /// and at the top of the tick, to decide — and asking it twice is the
    /// point: the state can change during a half-hour sleep, and a decision
    /// carried over from the label would act on what was true when the schedule
    /// went to bed.
    ///
    /// Ordered, and the order is what the user is told when two of them hold at
    /// once. The clock first, because an unreachable device is the one the
    /// panel's own status line is already about; the quiet rules after it,
    /// because they are about the room rather than the hardware.
    ///
    /// Per connector rather than for the app, because the two halves answer to
    /// different things. An unreachable clock stops every delivery, drawn or
    /// spoken. The quiet rules stop the app being HEARD, so they are asked only
    /// of a connector that can be — the weather draws into the device's own
    /// loop and says nothing, and silencing it froze the temperature on the
    /// matrix for the whole shipped 23:00–08:00 window while the panel blamed a
    /// microphone.
    func scheduleHold(for key: TileKey) -> String? {
        if reachability.clockIsUnreachable(key.clockId) { return AppModel.deviceUnreachable }
        switch policy(key)?.hold(in: moment().focus, atHour: moment().hour) {
        case .paused?: return AppModel.switchedOff
        case .hours?: return AppModel.duringQuietHours
        case .focus?: return AppModel.duringFocus
        case nil: break
        }
        guard isAudible(key.connectorId) else { return nil }
        return busyMicrophone().map { MicrophoneGate.inUse($0.name) }
    }

    /// Whether this tile's own hours are what holds it — the one hold the
    /// nightly refresh may not spend through.
    func inItsOwnQuietHours(_ key: TileKey) -> Bool {
        policy(key)?.hold(in: moment().focus, atHour: moment().hour) == .hours
    }

    /// Whether this connector can be heard.
    ///
    /// An id nothing is registered under answers `true`, which is the same
    /// direction `Connector`'s own default takes: the recoverable mistake is
    /// staying quiet.
    func isAudible(_ connectorId: String) -> Bool {
        registry.connector(id: connectorId)?.isAudible ?? true
    }


    func tick(_ key: TileKey) async {
        // The clock is asked before anything is spent on a delivery it cannot
        // receive. `produce()` pops an anecdote and RETIRES it before the
        // banner goes out, so a run against a device that is not answering
        // permanently consumes something the user never hears — about six of
        // them over a half-hour outage once the backoff has shortened the
        // retries, and a queue dragged under its refill threshold on top.
        //
        // Nothing is put back, deliberately: returning an undelivered anecdote
        // would mean taking its id out of `played`, and `played` is the
        // never-repeat guarantee. Not running at all removes the cost without
        // going near it.
        //
        // Only the run is held. The restock below is outside the guard on
        // purpose — an outage of the clock is not an outage of the feed or the
        // sidecar, and it is exactly when the queue should be filling so that
        // recovery has something to show immediately.
        //
        // And nothing is recorded, in either direction. `runOnce` is what moves
        // the failure count; not calling it is what leaves the backoff exactly
        // as the feed earned it. A pause is neither a failure nor a success.
        //
        // The same guard now covers the two quiet rules Task 23 added — a macOS
        // Focus, and the window that stands in for it while this app is not
        // allowed to ask. Everything above holds of them word for word: only
        // the run is held, the restock below is outside on purpose, and nothing
        // is recorded in either direction. What differs is only which words
        // reach the panel, and `noteNextRun` is the one place that writes them.
        //
        // And Task 24's microphone is a WAIT rather than a skip, which is the
        // one place the shape differs. A joke deferred by twenty minutes is
        // still a joke; one skipped is gone, and it was already paid for in
        // synthesis. So the run is written down here and released by
        // `releaseHeldRuns` when the room is quiet again — at most one per
        // connector, so a two-hour meeting does not end in a burst of four.
        //
        // And Task 26's weather is neither, because it cannot be heard at all.
        // The quiet rules are not asked of it — see `scheduleHold(for:)` — so
        // there is nothing for it to be held by here except the clock, and an
        // unreachable clock is a SKIP for a drawing exactly as it is for a
        // banner.
        //
        // One exception to "the restock is outside the guard", and it is the
        // user's own quiet hours. `topUpIfNeeded` refreshes when nothing in the
        // queue was prepared on today's calendar day, and midnight falls inside
        // every plausible quiet window — so the first beat after 00:00 loaded a
        // 1.8 GB model and synthesized a batch, with fans, on the machine of
        // somebody who had said these hours were not for making noise in. The
        // pass is not lost: the first beat after 08:00 finds the same nothing
        // prepared today and does the same work while its owner is awake.
        //
        // A Focus is deliberately NOT included, and neither is a busy
        // microphone. Both say "the user is busy right now" about somebody
        // sitting at the machine who will turn back to it — which is exactly
        // when the queue should be filling, and is the argument
        // `maintenanceStillRunsDuringFocus` already makes. The quiet window
        // says something else: nine hours on the shipped default, nobody coming
        // back to the desk at 00:30. An outage is not included either — an
        // outage of the clock is still not an outage of the feed.
        //
        // A launch inside the window still restocks, and a "Run now" inside it
        // still restocks after itself. Both are the user's own hand on the
        // machine; what this removes is the unattended one.
        guard scheduleHold(for: key) == nil else {
            if isAudible(key.connectorId), busyMicrophone() != nil { runner.hold(key) }
            if inItsOwnQuietHours(key) == false { await runner.restock(key) }
            return
        }
        await runner.runScheduled(key)
    }

    /// Puts a tile's new look on its clock now — a tile that draws rather than
    /// speaks, and runs at this moment. See `TileRunner.pushDisplaySettings`.
    func pushDisplaySettings(_ key: TileKey) {
        guard key.connectorId != VPNConnector.id, !isAudible(key.connectorId),
            policy(key)?.runs(in: moment().focus, atHour: moment().hour) == true
        else { return }
        runner.pushDisplaySettings(key)
    }

    /// Why the tile is not running now: its policy read against the room —
    /// the Focus the machine is in, the hour it is. The quiet rules stay the
    /// model's; the facade asks rather than recomputes them.
    func tileHold(of key: TileKey) -> TileHold? {
        policy(key)?.hold(in: moment().focus, atHour: moment().hour)
    }
}

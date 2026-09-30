import Foundation
import PixbarKit

/// What a tile's schedule and its runs need to know about the clocks' health:
/// whether a clock was asked and did not answer, and a way to ask again.
@MainActor
protocol ReachabilityReading: AnyObject {
    func clockIsUnreachable(_ clockId: UUID) -> Bool
    func recheckClocks()
}

/// Every clock's health, and the poll that asks them how they are.
///
/// One health per clock, of the kind its firmware needs: an AWTRIX clock's
/// `ClockHealth` (a monitor, a battery, a relocation), a TC002's
/// `UlanziClockHealth` (`/getBase` answering). A clock is in exactly one of
/// the two maps. The healths are built by the model, which holds what they are
/// wired to — the session a TC002 health puts pages back through, the handler
/// an AWTRIX clock's move is followed by — and handed here to be kept.
///
/// Whatever else a fresh answer changes — schedule labels, launch debt, the
/// tiles a Focus switches, the lamps — is the model's, reached through
/// `onPolled` after each poll and before any battery dialog.
@MainActor
final class ClockHealthMonitor: ObservableObject, ReachabilityReading {
    /// How often reachability is re-asked. Not a user setting: it costs one
    /// request and the answer drives a glyph, not a delivery.
    ///
    /// A minute, down from three requests a minute. Nothing the answer feeds
    /// moves faster than that: the glyph, the schedule's hold reason, and a
    /// battery trend measured over an hour and a half. What twenty seconds
    /// bought was 4,320 requests a day at a clock that spends them on its own
    /// battery — and the one case it really did buy, a panel showing a reading
    /// older than the person looking at it, is bought outright by
    /// `pollOnPanelOpen` for one request per open.
    static let pollInterval: TimeInterval = 60
    /// How close together two panel opens have to be to count as one.
    ///
    /// SwiftUI hands `.onAppear` out per appearance rather than per user
    /// gesture — a rebuild, or a bounce out to the settings and back, is
    /// another one — and the panel is a surface somebody opens, reads and
    /// reopens. Five seconds is long enough to swallow that and short enough
    /// that a deliberate second look still gets a reading of its own.
    static let panelRefreshFloor: TimeInterval = 5
    /// The reachability poll's loop, in the model's task bag.
    static let monitorLoop = "monitorLoop"
    /// The one-off reading a panel open asked for, still going.
    ///
    /// Owned rather than detached, for the reason every other task is:
    /// teardown can only wait for a task it holds, and this one writes
    /// `isDeviceOnline` and can raise a battery dialog. A quit that did not
    /// wait for it is a dialog arriving after the app is gone.
    static let panelRefresh = "panelRefresh"

    /// One clock's answer to "are you there", as the panel's status dot asks
    /// it: the three-valued answer both firmwares give, said in one
    /// vocabulary. `.unknown` is the state before the first poll — the one
    /// the panel drew as "Checking…", which is neither connected nor down.
    enum ClockReachability: Equatable, Sendable {
        case unknown
        case reachable
        case unreachable
    }

    /// Whether the selected clock is answering — the glyph's one answer.
    ///
    /// Mirrored from the healths rather than read through them, because the
    /// poll is what learns the answer and a view that wants only the glyph
    /// should not have to observe a second object to get it.
    @Published private(set) var isDeviceOnline = false
    /// Bumped whenever any clock's health has moved: a poll answered, a
    /// health was built or dropped. The panel's dot hangs off per-clock
    /// health, which is otherwise silent — a `DeviceMonitor` is a nested
    /// observable no `objectWillChange` of the model carries, and a TC002's
    /// answering state is a plain field. The facade subscribes to this and
    /// rebuilds its sections off it.
    @Published private(set) var healthRevision = 0
    /// Which clock the glyph is about. The glyph answers when the selection
    /// moves — not at the next poll (D7).
    var selectedClockId: UUID? {
        didSet { isDeviceOnline = answerForSelectedClock() }
    }
    /// Everything else a poll's answers change, run after each poll.
    var onPolled: @MainActor () -> Void = {}

    /// One health per AWTRIX clock: its own monitor, its own unanswered-poll
    /// count.
    private var healths: [UUID: ClockHealth] = [:]
    /// One TC002 health per clock: its own `/getBase` probe, its own answer —
    /// a different object, for a firmware with nothing to say beyond whether
    /// it is there.
    private var ulanziHealths: [UUID: UlanziClockHealth] = [:]
    /// The monitor handed out when no clock is selected, over the app's own
    /// device.
    private let device: AwtrixDevice
    /// The reachability cadence, one sleeper for the whole app. Separate from
    /// the schedules' because they are two clocks, not one: a fixed poll and a
    /// per-connector interval the user chooses and the retry policy bends.
    /// Kept apart so that whoever drives one can say which one they meant — an
    /// aggregate cannot, and a test waiting on "something is asleep" gets
    /// whichever loop won the race.
    private let pollSleep: AppModel.Sleeping
    /// Where a threshold crossing goes.
    ///
    /// A collaborator rather than a call into AppKit, and it has no default for
    /// the reason `AppDelegate.discovery` has none: the real one raises a modal
    /// dialog and asks macOS for notification permission, and a default would
    /// put both in front of whoever is running `swift test`.
    private let alerts: any BatteryWarningPresenting
    /// The model's task bag: teardown waits on what is in it.
    private let taskBag: TaskBag
    /// When the last panel open was honoured, or nil while none has been.
    ///
    /// The instant rather than a flag, because "already running" is not the
    /// question: the request takes milliseconds against a healthy clock, so a
    /// guard on the task alone would let a panel opened twice in a second
    /// through twice.
    private var lastPanelRefresh: Date?

    init(
        device: AwtrixDevice,
        pollSleep: @escaping AppModel.Sleeping,
        alerts: any BatteryWarningPresenting,
        taskBag: TaskBag
    ) {
        self.device = device
        self.pollSleep = pollSleep
        self.alerts = alerts
        self.taskBag = taskBag
    }

    func track(_ health: ClockHealth) {
        healths[health.clockId] = health
    }

    func track(_ health: UlanziClockHealth) {
        ulanziHealths[health.clockId] = health
    }

    /// Brings the healths in line with the clocks as stored: a clock gone from
    /// the store has no answer left to give, and a TC002 new to it probes from
    /// the next poll on. (An AWTRIX clock added live still gets no health — its
    /// monitor needs the battery history wiring the model's init does, and
    /// that debt is 5b's, not this one's.)
    func followClocks(_ stored: [ClockRecord], making: (ClockRecord) -> UlanziClockHealth?) {
        let kept = Set(stored.map(\.id))
        for id in healths.keys where !kept.contains(id) { healths[id] = nil }
        for id in ulanziHealths.keys where !kept.contains(id) { ulanziHealths[id] = nil }
        for clock in stored
        where clock.model == .ulanziTC002 && ulanziHealths[clock.id] == nil {
            if let health = making(clock) { ulanziHealths[clock.id] = health }
        }
        // The health list moved, and the panel's dots hang off it.
        healthRevision += 1
    }

    /// The named clock's monitor, or one over the app's own device when no
    /// AWTRIX clock is named.
    func monitor(of clockId: UUID?) -> DeviceMonitor {
        clockId.flatMap { healths[$0] }?.monitor
            ?? DeviceMonitor(device: device, history: InMemoryBatteryHistoryStore())
    }

    /// The clock's reachability, from its own health: a TC002 by `/getBase`
    /// answering, an AWTRIX one by the monitor's stats poll. One answer per
    /// firmware is what lets one dot stand for either.
    func reachability(of clockId: UUID) -> ClockReachability {
        if let ulanzi = ulanziHealths[clockId] {
            switch ulanzi.answering {
            case .notAsked: return .unknown
            case .answering: return .reachable
            case .unreachable: return .unreachable
            }
        }
        guard let health = healths[clockId] else { return .unknown }
        switch health.monitor.state {
        case .unknown: return .unknown
        case .online: return .reachable
        case .offline: return .unreachable
        }
    }

    /// A clock's reachability, as the Clocks section's row says it. The same
    /// three words for both firmwares, from the one answer the dot reads.
    func statusLine(of clock: ClockRecord) -> String {
        DeviceStatusLine.title(for: reachability(of: clock.id))
    }

    /// A clock's battery, as the panel's statistics line says it — or nil for
    /// a clock that has never answered, and for a TC002 whose firmware is not
    /// one the memory read knows. A clock that went away keeps showing its
    /// last known charge: the panel is the clocks' glance, and a battery that
    /// vanishes every time the Wi-Fi blips is a figure nobody plans around.
    func batteryLine(of clock: ClockRecord) -> String? {
        BatteryLine.text(for: battery(of: clock))
    }

    /// The reading behind that line, for a surface that draws the charge
    /// rather than saying it — the panel's cards.
    ///
    /// A clock is in exactly one of the two health maps, so this is a
    /// fall-through rather than a merge.
    func battery(of clock: ClockRecord) -> BatteryReading? {
        if let ulanzi = ulanziHealths[clock.id] { return ulanzi.lastKnownBattery }
        return healths[clock.id]?.monitor.lastKnownBattery
    }

    /// Whether this clock has been asked and did not answer.
    ///
    /// Read off the named clock's own health, rather than off the
    /// `isDeviceOnline` mirror the glyph draws from. `.unknown` is not online
    /// there either, so a schedule gated on that mirror would run nothing at
    /// all between launch and the first poll landing — and "not asked yet" is
    /// not "not there", which is the conflation `DeviceState` exists to
    /// prevent. Each clock answers for its own tiles only.
    func clockIsUnreachable(_ clockId: UUID) -> Bool {
        if let ulanzi = ulanziHealths[clockId] {
            if case .unreachable = ulanzi.answering { return true }
            return false
        }
        guard let health = healths[clockId] else { return false }
        if case .offline = health.monitor.state { return true }
        return false
    }

    /// Polls now, in the panel refresh's slot: one in flight is enough, and
    /// teardown already waits on it.
    func recheckClocks() {
        taskBag.startIfIdle(Self.panelRefresh) { [weak self] in
            await self?.poll()
        }
    }

    func startMonitoring() {
        taskBag.replace(Self.monitorLoop) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                do { try await self.pollSleep(Self.pollInterval) } catch { return }
            }
        }
    }

    /// Cancelled, not awaited: a poll in flight writes nothing to a clock.
    func stopMonitoring() {
        taskBag.cancel(Self.monitorLoop)
    }

    /// Asks for one reading because the panel is about to need it.
    ///
    /// The poll is a minute apart, so what the panel draws about the clock can
    /// be fifty-nine seconds old by the time somebody reads it. This buys the
    /// freshness back for one request per open, which is what makes the minute
    /// affordable in the first place.
    ///
    /// It does NOT restart the poll: a loop restarted on every open is a loop
    /// per open until one of them is cancelled, and the cadence the whole
    /// change is about would be whatever the last gesture set it to.
    ///
    /// Coalesced on the wall clock rather than on whether one is still in
    /// flight. Against a healthy clock the request is over in milliseconds, so
    /// an in-flight guard alone would let two opens a second apart through as
    /// two requests — while an unreachable one takes the transport's full
    /// fifteen, which is exactly when a second task must not be started.
    /// Checking both is one guard each and covers both ends.
    func pollOnPanelOpen() {
        let now = Date()
        if let last = lastPanelRefresh, now.timeIntervalSince(last) < Self.panelRefreshFloor {
            return
        }
        guard !taskBag.isRunning(Self.panelRefresh) else { return }
        lastPanelRefresh = now
        taskBag.startIfIdle(Self.panelRefresh) { [weak self] in
            await self?.poll()
        }
    }

    /// One clock's threshold crossing out of the poll: which clock it was
    /// about, and what it crossed.
    private struct Crossing: Sendable {
        let clock: String
        let warning: BatteryWarning?
    }

    /// Asks every clock how it is, once, and hands on everything those answers
    /// change.
    ///
    /// Lifted out of the loop rather than duplicated into `pollOnPanelOpen`,
    /// because the reading is only half of what a poll is: the glyph's mirror,
    /// the schedules' hold reasons and the battery dialog all hang off it, and
    /// a second caller that took the reading alone would leave a panel showing
    /// a fresh percentage beside a stale hold reason.
    func poll() async {
        let now = Date()
        // Every clock concurrently: a clock inside its 15-second timeout does
        // not hold up the others' readings. Each health's poll carries its own
        // follow-up — the identity write and, when one is due, the move. One
        // task per health rather than a task group, whose isolation checker
        // this pattern otherwise trips a compiler bug in. Both health kinds
        // poll in the same fan-out: an AWTRIX one returns a battery warning
        // with its reading, a TC002 one always nil — nothing to cross.
        var polls: [Task<(String, BatteryWarning?), Never>] = []
        polls.append(
            contentsOf: healths.values.map { health in
                Task { @MainActor in (health.name, await health.poll(at: now)) }
            }
        )
        polls.append(
            contentsOf: ulanziHealths.values.map { health in
                Task { @MainActor in (health.name, await health.poll(at: now)) }
            }
        )
        var crossings: [Crossing] = []
        for task in polls {
            let (name, warning) = await task.value
            if warning != nil { crossings.append(Crossing(clock: name, warning: warning)) }
        }
        healthRevision += 1
        isDeviceOnline = answerForSelectedClock()
        onPolled()
        // Awaited here rather than detached. The dialog does not block — it
        // schedules itself — and what is awaited is the authorization request,
        // which happens once. A detached task would be one more thing teardown
        // cannot wait for, for a warning that fires four times in the life of a
        // charge.
        for crossing in crossings {
            guard let warning = crossing.warning else { continue }
            await alerts.warn(warning, on: crossing.clock)
        }
    }

    /// Whether the SELECTED clock is answering, across both health kinds —
    /// the glyph reads one answer, whichever model the selection names.
    private func answerForSelectedClock() -> Bool {
        guard let id = selectedClockId else { return false }
        if let ulanzi = ulanziHealths[id] { return ulanzi.isOnline }
        return healths[id]?.isOnline ?? false
    }
}

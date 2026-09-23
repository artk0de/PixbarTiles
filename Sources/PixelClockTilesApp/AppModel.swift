// `NSPasteboard` is AppKit's, and Copy is the one thing this model does that
// leaves the app.
import AppKit
import PixelClockKit
// `ObservableObject` and `@Published` are declared in Combine; Foundation
// re-exports both, so this import names the framework that owns them.
import Combine
import Foundation

/// The calls a schedule makes into the host.
///
/// Declared here rather than in the kit because scheduling is the app's job and
/// this is the app's view of what it schedules — what to do, and how long to
/// wait before doing it; no device, no registry. `AwtrixClockSession` satisfies it as
/// written.
protocol ConnectorRunning: Sendable {
    func maintain(connectorId: String) async -> MaintenanceResult
    func runOnce(connectorId: String) async -> RunResult
    /// Plays something already produced. A replay is this and nothing else: no
    /// produce, so nothing is retired, and no outcome recorded against the
    /// connector, so the backoff is untouched.
    func deliver(_ output: AwtrixDelivery) async -> RunResult
    /// The host owns this rather than the schedule, because the answer is a
    /// function of how the last runs went and the schedule does not watch them.
    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval
    /// Puts back the device-wide state this app borrowed — the weather overlay,
    /// and anything it added to the clock's loop.
    ///
    /// On the schedule's protocol rather than on a connector, because a
    /// connector never talks to the device and the overlay it borrows is one
    /// global setting rather than a property of any one producer.
    ///
    /// - Parameter connectorId: only what this connector took, or nil for
    ///   everything outstanding, which is what a quit wants.
    func restoreDeviceState(borrowedBy connectorId: String?) async

    /// The clock's lamp custody, or nil for a clock with no lamps. VPN tiles
    /// write through it, off the delivery chain.
    var indicators: IndicatorCustody? { get }
}

extension AwtrixClockSession: ConnectorRunning {}

/// The app's view of a TC002 clock — what the panel and the settings may ask
/// of one. The event half of `UlanziClockHost`, which conforms to it where
/// the type is declared: pages go out per tile, and there is no
/// borrow-and-restore, because a TC002 owns nothing device-wide. The schedule
/// half lives on `ConnectorRunning`, which the same slot also answers.
protocol UlanziConnectorRunning: Sendable {
    func deliver(_ output: UlanziDelivery, toTile tileId: String) async -> RunResult
    func markIdle(tileId: String) async -> RunResult
    func tileRemoved(_ tileId: String) async
    func shutdown() async
}

/// The anecdotes the menu can look back over.
///
/// Declared here rather than in the kit for the reason `ConnectorRunning` is:
/// this is the APP's view of a connector — what has played, and what playing one
/// again would put on the clock. It is a connector's own two answers, and
/// `AnecdoteConnector` satisfies it as written; nothing in the kit needs the
/// pair to have a name.
///
/// `id` is on it because the panel draws every connector the registry holds and
/// only one of them has a history: the row that gets a History button is the row
/// whose connector this is.
protocol AnecdoteReplaying: Sendable {
    var id: String { get }
    func history() async -> [PlayedAnecdote]
    func output(for anecdote: PreparedAnecdote) -> AwtrixDelivery
}

extension AnecdoteConnector: AnecdoteReplaying {}

/// When a connector next runs, or what is stopping it.
///
/// The held reason is a `String` rather than a case per cause. Three more causes
/// are already scheduled — a pause while the clock is unreachable, silence
/// during a macOS Focus, a hold while a microphone is capturing — and each wants
/// to say its own words without this type being edited to admit it. Today only
/// one reason reaches it, and none of those three gates is built here.
enum NextRun: Equatable, Sendable {
    /// The schedule is asleep and will wake at this moment.
    case due(Date)
    /// Nothing is scheduled, and this is what is holding it.
    case held(String)
}

/// Where this app writes.
enum AppPaths {
    /// The directory the synthesizer writes clips into, and the root the
    /// queue's reaper is contained by.
    ///
    /// One value read at both wiring sites, because containment means nothing
    /// if the two disagree: a queue rooted anywhere else than where the clips
    /// actually land reclaims nothing and leaks every batch.
    ///
    /// A directory of this app's own, not the temporary directory itself. The
    /// reaper removes whole trees, and a root of `/tmp` would put every other
    /// process's scratch directory inside the boundary.
    static let clipRoot = FileManager.default.temporaryDirectory
        // The old name on purpose: the store records clip paths under it, and the
        // reaper reclaims nothing outside it, so a new name would orphan them all.
        .appendingPathComponent("awtrix-speech")

    /// How long a played anecdote's audio is kept before the queue's reaper may
    /// take it.
    ///
    /// Ten days. Long enough that the History the user can replay from covers
    /// more than the last evening, and short enough that a batch of clips is not
    /// a permanent tenant of the temporary directory. The window is stated here
    /// rather than inside the queue for the reason the clip root is: it is a
    /// decision about the user's disk, and this is the only place that knows
    /// what else is on it.
    static let clipRetention: TimeInterval = 10 * 24 * 60 * 60

    /// The prepared batch and the played set.
    ///
    /// Application Support rather than the temporary directory: "an anecdote is
    /// never repeated" rests on the played set, and a reboot that clears the
    /// temporary directory would make every anecdote the user has heard unheard
    /// again. The clips themselves are the opposite case — they are large,
    /// disposable, and re-synthesizable — so they stay in the temporary
    /// directory and only this file is kept.
    static let anecdoteStore: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support
            // The old name on purpose: the rename does not move this folder, and
            // moving it would put the played set at risk for the sake of a name.
            .appendingPathComponent("AwtrixConnectors")
            .appendingPathComponent("anecdotes.json")
    }()
}

/// Everything the menu shows and everything it can do, and the schedule behind
/// both.
///
/// The composition root is `live()`; every collaborator reaches this type
/// through `init`, so the wiring that only runs in the real app is one function
/// and the behaviour is not.
@MainActor
final class AppModel: ObservableObject {
    /// Injected so the schedule can be driven by a test without waiting out a
    /// real interval. The shipped value is the only one that sleeps.
    typealias Sleeping = @Sendable (TimeInterval) async throws -> Void

    /// Where an installation from before the clock records kept the address.
    /// `ClockMigration` reads it once; nothing writes it any more.
    static let deviceHostKey = "deviceHost"
    /// What a launch with no address of its own talks to.
    static let defaultDeviceHost = "192.168.1.72"
    /// Where an installation from before the clock records kept the clock's
    /// name for itself, as `/api/stats` gives it. `ClockMigration` reads it
    /// once into `ClockRecord.hardwareIdentity`, which is what relocation asks
    /// for now — the one thing that tells OUR clock from a neighbour's.
    static let deviceUIDKey = "deviceUID"

    /// One bounded attempt to find where the clock went, as one answer.
    ///
    /// A closure rather than the `DeviceRelocation` itself, for the reason
    /// every clock and sleeper here is one: what this model needs is an
    /// address, and taking the type would drag a browser, a probe and a
    /// deadline into every test that has no opinion about any of them.
    typealias RelocatingHost = @MainActor (String?) async -> String?
    /// How often reachability is re-asked. Not a user setting: it costs one
    /// request and the answer drives a glyph, not a delivery.
    ///
    /// A minute, down from three requests a minute. Nothing the answer feeds
    /// moves faster than that: the glyph, the schedule's hold reason, and a
    /// battery trend measured over an hour and a half. What twenty seconds
    /// bought was 4,320 requests a day at a clock that spends them on its own
    /// battery — and the one case it really did buy, a panel showing a reading
    /// older than the person looking at it, is bought outright by
    /// `refreshOnPanelOpen` for one request per open.
    static let monitorInterval: TimeInterval = 60
    /// How close together two panel opens have to be to count as one.
    ///
    /// SwiftUI hands `.onAppear` out per appearance rather than per user
    /// gesture — a rebuild, or a bounce out to the settings and back, is
    /// another one — and the panel is a surface somebody opens, reads and
    /// reopens. Five seconds is long enough to swallow that and short enough
    /// that a deliberate second look still gets a reading of its own.
    static let panelRefreshFloor: TimeInterval = 5
    /// How often a held run asks whether the meeting is over.
    ///
    /// Five seconds. Not a user setting, and not the schedule's interval: what
    /// this decides is how long after the microphone goes quiet the deferred
    /// anecdote arrives, and a full enumeration costs 1.36 ms measured on this
    /// machine. Polled rather than listened for, because devices come and go —
    /// a listener would need re-registering every time the phone appears, and
    /// the property it would listen to is on a device that may not exist yet.
    static let microphoneInterval: TimeInterval = 5
    /// What holds the schedule of a connector the user switched off.
    static let switchedOff = "off"
    /// What holds the schedule while the clock is not answering.
    ///
    /// The clock rather than the connector, deliberately: the feed and the
    /// sidecar are fine, the queue is still filling, and the only thing that
    /// cannot happen is the delivery. Somebody reading this on the panel is
    /// being told where to look.
    static let deviceUnreachable = "clock unreachable"
    /// What holds a tile whose Focus rule says this is not the time for it.
    /// The words the app-wide gate used, so nothing the user reads changes.
    static let duringFocus = "Focus is on"
    /// What holds a tile inside its own hours, in the same words as before.
    static let duringQuietHours = "quiet hours"

    /// The Focus the Mac is in, as every tile reads it.
    private var currentFocus: MacFocus { MacFocus(reading: focusStatus) }
    /// The hour every tile's window is read against, off the injected clock so
    /// a test can stand at three in the morning.
    private var currentHour: Int { Calendar.current.component(.hour, from: now()) }

    /// A tile's policy as stored, with anything a record from before Phase 4
    /// does not say taken from its connector's row.
    private func policy(of key: TileKey) -> TilePolicy? {
        guard let record = tiles.all().first(where: { $0.key == key }) else { return nil }
        // The VPN is not in the registry (it is not a scene connector), so its
        // row is named here.
        let row = key.connectorId == VPNConnector.id
            ? TileDefaults.vpn
            : registry.connector(id: key.connectorId)?.defaultPolicy
                ?? TilePolicy(refreshSeconds: record.policy.refreshSeconds)
        return TilePolicy(record.policy, defaults: row)
    }

    /// Where this app is talking to the clock right now.
    ///
    /// Seeded at launch from the stored address and written exactly one other
    /// way: by a relocation, when the clock stopped answering and was found
    /// again somewhere else. It used to be a `let`, on the argument that a
    /// settable address would have to rebuild the device, the monitor and the
    /// host underneath a running schedule. That argument fell to
    /// `AwtrixDevice.adopt(host:)` — the device is an actor built once and held
    /// by all three, so re-pointing it re-points them, and nothing is rebuilt.
    ///
    /// Published because the panel draws it, and a panel still naming the
    /// address that stopped answering invites somebody to fix what is already
    /// fixed.
    ///
    /// Whatever is stored, `AwtrixDevice` normalises it: the hand-written path
    /// reaches no field and no validation, so a `http://10.0.0.5` typed into a
    /// terminal has to be dealt with where the URL is built.
    @Published private(set) var deviceHost: String
    /// The app-level registry: what the menus and the catalogue read.
    ///
    /// Its instances are wired for NAMING a connector, not for running one —
    /// the z.ai copy is built with `key: { nil }`, the weather copy with the
    /// first clock's place, the Claude copy with no chosen metric. Nothing
    /// produces through it. Anything that needs a connector's real OUTPUT
    /// asks `connector(for:)` instead.
    let registry: ConnectorRegistry
    /// How a clock's own registry is built — the one its session pushes
    /// through, closed over that clock's place, its tile's metric and its
    /// key in the keychain.
    ///
    /// Optional because a test wiring a model by hand names its connectors
    /// directly and has no per-clock story; those fall back to `registry`,
    /// which is what they were reading before this existed.
    private let makeClockRegistry: (@MainActor (ClockRecord) -> ConnectorRegistry)?
    /// Built once per clock and kept: a registry's connectors read their
    /// stores on every call, so one instance stays current, and rebuilding it
    /// per preview would re-read the keychain on every keystroke.
    private var clockRegistries: [UUID: ConnectorRegistry] = [:]
    /// The selected clock's health, which is what the glyph is about.
    var monitor: DeviceMonitor {
        let id = selectedClockId ?? clock?.id
        return id.flatMap { healths[$0] }?.monitor
            ?? DeviceMonitor(device: device, history: InMemoryBatteryHistoryStore())
    }
    /// One health per clock: its own monitor, its own unanswered-poll count.
    private var healths: [UUID: ClockHealth] = [:]
    /// Held so that a relocation can re-point it, which is the whole reason
    /// this reference exists here rather than only inside the monitor.
    private let device: AwtrixDevice
    /// Which clock the panel shows and the glyph is about. Phase 5's switcher
    /// writes it; until then it is the first clock unless something set it.
    static let selectedClockKey = "selectedClockId"

    /// Every clock this app drives, as the settings list them.
    @Published private(set) var clocks: [ClockRecord]
    @Published var selectedClockId: UUID? {
        didSet {
            defaults.set(selectedClockId?.uuidString, forKey: Self.selectedClockKey)
            // The glyph answers for the selected clock alone, and it answers
            // when the selection moves — not at the next poll (D7).
            isDeviceOnline = answerForSelectedClock()
        }
    }
    /// Whether nothing is configured: the panel's "No clocks yet" state, which
    /// a fresh install reaches and the Clocks section answers.
    var hasNoClocks: Bool { clocks.isEmpty }
    /// One session per clock, each with its own delivery chain and custody —
    /// so a clock that stops answering holds up only its own tiles.
    private var sessions: [UUID: any ConnectorRunning] = [:]
    private let makeSession: @MainActor (ClockRecord) -> any ConnectorRunning
    private let tiles: TileStore
    /// Where what is learned about the clocks is written down for the next
    /// launch.
    private let clockStore: ClockStore
    /// The place this clock's weather tile reads for. Held so the settings
    /// field reads and saves through the same record the connector polls.
    private let location: StoredLocation
    private let relocate: RelocatingHost?

    @Published private(set) var tileLastResults: [TileKey: String] = [:]
    /// What each tile's last run ended in, in the raw words the transport
    /// produced, and nothing at all while the last run did not fail. Kept raw
    /// so the row's sentence and every other reader translate it themselves.
    @Published private(set) var tileLastFailures: [TileKey: String] = [:]
    /// What the last background pass had to complain about, per tile, and
    /// nothing at all when it went fine.
    @Published private(set) var tileLastMaintenanceFailure: [TileKey: String] = [:]
    /// When each tile is next due, or what is holding it.
    @Published private(set) var tileNextRun: [TileKey: NextRun] = [:]
    /// Bumped when the tiles record's ORDER changes, because the store it
    /// lives in publishes nothing: the panel's rows are drawn from the
    /// record, and a reorder has no other way to be seen.
    @Published private(set) var tileOrderRevision = 0
    /// A by-tile map, seen the way the panel still reads it: the selected
    /// clock's single tiles, by connector.
    var nextRun: [String: NextRun] { projected(tileNextRun) }
    /// The selected clock's run outcomes, failures and maintenance failures,
    /// by connector, for the same reason and until the same phase.
    var lastResults: [String: String] { projected(tileLastResults) }
    var lastFailures: [String: String] { projected(tileLastFailures) }
    var lastMaintenanceFailure: [String: String] { projected(tileLastMaintenanceFailure) }

    private func session(for key: TileKey) -> (any ConnectorRunning)? { sessions[key.clockId] }

    /// The connector a tile's OWN clock runs — the instance whose output that
    /// clock would receive.
    ///
    /// The one a preview has to ask. Reading `registry` instead was the defect
    /// the tile settings window shipped with: that copy exists to NAME
    /// connectors for the menus, and its instances are deliberately inert —
    /// z.ai's is built with `key: { nil }`, so the preview of a tile with a
    /// key saved still reported "check its key"; Claude's carries no metric,
    /// so a tile set to the day previewed the week; the weather's is closed
    /// over the FIRST clock's place, so a tile on the second clock previewed
    /// another city. Every one of those is the preview lying about the clock
    /// it claims to be showing.
    ///
    /// Falls back to the app-level registry for a clock this model has no
    /// factory for, which is every hand-wired test and the VPN tile — the
    /// latter is not a `Connector` at all and answers nil from both.
    func connector(for key: TileKey) -> (any Connector)? {
        guard let makeClockRegistry,
            let clock = clocks.first(where: { $0.id == key.clockId })
        else {
            return registry.connector(id: key.connectorId)
        }
        let own = clockRegistries[clock.id] ?? makeClockRegistry(clock)
        clockRegistries[clock.id] = own
        return own.connector(id: key.connectorId) ?? registry.connector(id: key.connectorId)
    }

    /// The selected clock's tile of this connector, which is what the panel's
    /// rows are about until Phase 5 draws tiles.
    private func selectedKey(_ connectorId: String) -> TileKey? {
        selectedClockId.map { TileKey(clockId: $0, connectorId: connectorId) }
    }

    /// A by-tile map, seen the way the panel still reads it: the selected
    /// clock's single tiles, by connector.
    private func projected<Value>(_ byTile: [TileKey: Value]) -> [String: Value] {
        var byConnector: [String: Value] = [:]
        for (key, value) in byTile where key.clockId == selectedClockId && key.instance.isEmpty {
            byConnector[key.connectorId] = value
        }
        return byConnector
    }

    /// The clock record as this launch has it, by id.
    private func clock(_ id: UUID) -> ClockRecord? {
        clocks.first { $0.id == id }
    }

    /// The clock the one shared device, monitor and installer are built on —
    /// the first, which for a one-clock install is the only one. B14 gives
    /// every clock a health of its own.
    private var clock: ClockRecord? { clocks.first }
    /// Whether the SELECTED clock is an AWTRIX one — the only kind with a
    /// battery line, a polled health or a scheduled delivery. The panel's
    /// status row reads it.
    var selectedClockIsAwtrix: Bool { selectedClock.map { $0.model == .awtrix3 } ?? false }
    /// The selected clock's address, as the panel's status block draws it.
    var selectedAddress: String { selectedClock?.address ?? "" }

    /// The clock the selection names, as this launch has it.
    private var selectedClock: ClockRecord? { selectedClockId.flatMap { clock($0) } }
    /// What is in the address field: what the NEXT launch will use, where
    /// `deviceHost` is what this one is using.
    ///
    /// Saved on every change rather than on submit. There is nothing to confirm
    /// — the value only takes effect at the next launch — so a Save button would
    /// be a step the user has to discover, and a field that looks saved and is
    /// not is worse than one that never looked saved at all.
    ///
    /// `didSet` does not run during initialization, which is what keeps seeding
    /// the field from writing this launch's address straight back to disk.
    @Published var typedHost: String {
        didSet {
            guard let clock = self.clock else { return }
            // The save rule the typed field carried, now written here because
            // the relocation path is this property's last writer: normalise,
            // refuse a blank, store on the record for the next launch.
            let trimmed = typedHost.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                let host = DeviceAddress.host(from: trimmed)
            else { return }
            clockStore.update(clock) { $0.address = host }
        }
    }
    @Published private(set) var hostNote: String?
    /// What is in the location field.
    ///
    /// Saved on every change, for the reason `typedHost` is. Unlike the
    /// address, this one takes effect at the next poll rather than at the next
    /// launch: the weather connector reads the stored pair every time it
    /// produces, so there is nothing to rebuild.
    ///
    /// `didSet` does not run during initialization, which is what keeps seeding
    /// the field from writing the stored location straight back to disk.
    @Published var typedLocation: String {
        didSet { locationNote = LocationField.save(typedLocation, to: location) }
    }
    @Published private(set) var locationNote: String?
    /// Whether the Settings window's Clocks tab is on screen. The second
    /// reason a browse runs — the list a clock seen advertising itself joins
    /// is drawn there — and it replaces the old sheet flag, which answered
    /// about a surface that no longer exists.
    @Published private(set) var clocksSectionVisible = false

    /// Told by the Clocks tab's own appearances, which is what makes the
    /// flag honest: a window closed without the view going away would leave
    /// a browse running for the life of the process.
    func clocksSectionVisibilityChanged(_ visible: Bool) { clocksSectionVisible = visible }

    /// Whether the History is showing instead of the panel.
    @Published private(set) var historyIsOpen = false
    /// What has played recently, newest first, as of the last read — and nil
    /// until a read has answered.
    ///
    /// Optional rather than an empty array standing in for both, and the merge
    /// is the reported defect rather than a nicety: "nobody has asked yet" and
    /// "the queue holds nothing" are different states, and told apart by nothing
    /// the surface says "Nothing has played yet" about a connector with plenty
    /// to list — measured, byte-identical to the real thing. Reading earlier
    /// narrows the window that is drawn in and cannot close it: it is a race,
    /// and the answer it loses is a confident wrong one rather than a slow right
    /// one.
    ///
    /// `Optional` rather than a `historyHasBeenRead` flag beside the array: one
    /// value cannot disagree with itself, and two values answering one question
    /// disagree the first time either moves. An enum of its own was the other
    /// candidate and it says nothing `Optional` does not — this class already
    /// spells "no answer yet" as nil three times over, in `replayResult`,
    /// `iconStatus` and `locationNote`.
    ///
    /// Read on opening rather than kept in step with the queue: nothing else on
    /// the panel shows it, and a run that happens while the surface is closed
    /// has no reader to tell. The list is whatever the queue still holds — the
    /// retention window bounds it, and nothing here bounds it a second time.
    ///
    /// Never put back to nil once it holds an answer. A read that has happened
    /// stays happened, so leaving the surface and returning to it draws the last
    /// list at once instead of going quiet while the same answer arrives again.
    @Published private(set) var history: [PlayedAnecdote]?
    /// How the last replay went, in the History's own words, and nil until one
    /// has been asked for.
    ///
    /// Its own line rather than the connector's. A replay is not a run: the run
    /// line describes what the SCHEDULE last did, and a failure heard from the
    /// History written over it would claim the schedule had failed. What the
    /// discarded result never stops being discarded FOR is the run line and the
    /// backoff — but discarding it altogether is what left "Play again" against
    /// an unreachable clock doing nothing at all, with no explanation.
    @Published private(set) var replayResult: String?
    @Published private(set) var iconStatus: String?
    /// Mirrored from `monitor` rather than read through it, because the poll
    /// below is what learns the answer and a view that wants only the glyph
    /// should not have to observe a second object to get it.
    @Published private(set) var isDeviceOnline = false
    /// The microphones the schedule waits for. Published because the settings'
    /// tick boxes bind to them: the defaults behind it are persistence rather
    /// than state.
    @Published private(set) var watchedMicrophones: [WatchedMicrophone]

    /// One TC002 health per clock: its own `/getBase` probe, its own answer.
    /// The AWTRIX clocks keep theirs in `healths` — a different object, for a
    /// firmware with nothing to say beyond whether it is there.
    private var ulanziHealths: [UUID: UlanziClockHealth] = [:]
    /// Builds the device a TC002 clock's health probes. The device is the
    /// same one the clock's own slot pushes through, so a health answer and a
    /// page push cannot disagree about whether the clock is there.
    private let makeUlanziDevice: @MainActor (ClockRecord) -> UlanziDevice?
    /// The TC002's battery reader, built per clock because it needs that
    /// clock's address for its own transport — adb on 5555, not the HTTP the
    /// device actor speaks. Nil where the helper did not ship or the clock is
    /// not a TC002, and nil is simply "no battery line".
    private let makeUlanziBattery: @MainActor (ClockRecord) -> UlanziBattery?

    /// The TC002 clock's slot for the named clock, or nil when that clock's
    /// slot is an AWTRIX session — the cast is the model check, kept honest by
    /// the factory that only ever builds a Ulanzi slot for a TC002 record.
    private func ulanziSession(for clockId: UUID) -> (any UlanziConnectorRunning)? {
        sessions[clockId] as? any UlanziConnectorRunning
    }
    /// The dual probe behind Add by address: whichever body decodes names the
    /// model. Nil where no caller adds by address.
    private let probe: (@Sendable (String) async -> UlanziProbe.Detection)?
    private let installer: CatalogueIconInstaller
    /// The connector whose history the menu can browse, or nil when none was
    /// wired. Optional because the panel is generic over connectors and only
    /// one of them keeps anything to look back over.
    private let anecdotes: (any AnecdoteReplaying)?
    private let defaults: UserDefaults
    /// Where Copy writes. Injected so the suite cannot put anything on the
    /// clipboard of whoever is running it.
    private let pasteboard: NSPasteboard
    /// The delivery cadence, one sleeper per scheduled connector.
    private let scheduleSleep: Sleeping
    /// The reachability cadence, one sleeper for the whole app. Separate from
    /// `scheduleSleep` because they are two clocks, not one: a fixed 20-second
    /// poll and a per-connector interval the user chooses and the retry policy
    /// bends. Kept apart so that whoever drives one can say which one they
    /// meant — an aggregate cannot, and a test waiting on "something is asleep"
    /// gets whichever loop won the race.
    private let pollSleep: Sleeping
    /// The cadence a held run is released on, one sleeper for the whole app.
    ///
    /// A third clock rather than a share of either of the two above, for the
    /// reason those two are apart: an aggregate can only answer "something is
    /// asleep", and a test that drives the release must be able to say it meant
    /// the microphone rather than the schedule — otherwise "held then released"
    /// cannot be told from "ran late", which is this feature's whole claim.
    private let micSleep: Sleeping
    /// Where a threshold crossing goes.
    ///
    /// A collaborator rather than a call into AppKit, and it has no default for
    /// the reason `AppDelegate.discovery` has none: the real one raises a modal
    /// dialog and asks macOS for notification permission, and a default would
    /// put both in front of whoever is running `swift test`.
    private let alerts: any BatteryWarningPresenting
    /// Whether macOS says the user is busy, and what to call it when it does.
    private let focusStatus: any FocusStatusReading
    /// The clock every tile's window is read against.
    private let now: @Sendable () -> Date
    /// What every tile's policy said the last time it was asked, so only a
    /// change is acted on.
    private var verdicts = TileVerdicts()
    /// Whether a microphone the user cares about is capturing.
    private let microphone: MicrophoneGate
    /// Where a tile's API key lives. The record holds the handle, this holds
    /// the secret — the split the z.ai tile's whole config is built around.
    let keychain: any TileKeyStoring
    private var timers: [TileKey: Task<Void, Never>] = [:]
    private var monitorLoop: Task<Void, Never>?
    /// The one-off reading a panel open asked for, still going.
    ///
    /// Owned rather than detached, for the reason every other task here is:
    /// teardown can only wait for a task it holds, and this one writes
    /// `isDeviceOnline` and can raise a battery dialog. A quit that did not
    /// wait for it is a dialog arriving after the app is gone.
    private var panelRefresh: Task<Void, Never>?
    /// When the last panel open was honoured, or nil while none has been.
    ///
    /// The instant rather than a flag, because "already running" is not the
    /// question: the request takes milliseconds against a healthy clock, so a
    /// guard on the task alone would let a panel opened twice in a second
    /// through twice.
    private var lastPanelRefresh: Date?
    /// Runs the user asked for, still going. Keyed by nothing meaningful: two
    /// presses of the same button are two runs, and the host queues them behind
    /// each other rather than one replacing the other.
    private var manualRuns: [Int: Task<Void, Never>] = [:]
    private var nextRunKey = 0
    /// Whether each VPN is carrying, read fresh on every trigger.
    private let vpnPresence: VPNPresence
    /// How each watched VPN is read. Built over the presence reader, which is
    /// the process table.
    private let vpn: VPNConnector
    /// The two corners of the matrix, and what they are showing.
    ///
    /// Optional because most of the suite has no opinion about indicators and
    /// should not have to supply a clock to say so — nil is an app that leaves
    /// the corners alone entirely.

    /// Writes to those corners, still going. Keyed like `manualRuns` and for
    /// the same reason: triggers overlap, the display serialises them, and
    /// teardown has to be able to wait for whichever are in flight.
    private var vpnPushes: [Int: Task<Void, Never>] = [:]
    /// The two things that say the world moved. See `startWatchingTheWorld`.
    private let networkWatcher = NetworkPathWatcher()
    private let focusWatcher = FocusAssertionsWatcher()
    /// The restock the launch fires, still going.
    ///
    /// Owned rather than detached, for the reason every other loop here is:
    /// teardown can only wait for a task it holds, and this one is a minute of
    /// synthesis that a quit would otherwise kill halfway through a batch.
    private var launchRestock: Task<Void, Never>?
    /// Replays the user asked for, still going, and the read that fills the
    /// History behind them.
    ///
    /// Owned for the reason `manualRuns` is: a replay puts the same held banner
    /// on the clock as a run, and a quit that does not wait for it kills the
    /// process during the release. Keyed by nothing meaningful — two presses of
    /// "Play again" are two replays, and the host queues them behind each other.
    private var replays: [Int: Task<Void, Never>] = [:]
    private var nextReplayKey = 0
    private var historyLoad: Task<Void, Never>?
    /// Restores the user asked for by switching a connector off, still going.
    ///
    /// Owned for the reason `replays` is: each one writes to the device, and a
    /// quit that did not wait for one would kill the process part-way through
    /// giving the clock's own overlay back.
    private var restores: [Int: Task<Void, Never>] = [:]
    private var nextRestoreKey = 0
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
    /// The ambient connectors this launch still owes the clock's loop a first
    /// delivery, drained by the first poll that finds the clock answering.
    ///
    /// A set for the same reason `heldRuns` is one, and a debt rather than a
    /// run for a different one: what is owed here is not a beat that arrived at
    /// a bad moment but the ONLY delivery a launch makes, and losing it is ten
    /// minutes of a clock with nothing on it.
    private var launchDeliveriesOwed: Set<TileKey> = []
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
    /// The loop that lets them go.
    private var microphoneWatch: Task<Void, Never>?
    private var iconRemoval: Task<Void, Never>?

    init(
        clocks: [ClockRecord],
        tiles: TileStore,
        makeSession: @MainActor @escaping (ClockRecord) -> any ConnectorRunning,
        makeDeviceAndHistory: @MainActor @escaping (ClockRecord) -> (
            device: AwtrixDevice, history: any BatteryHistoryStore
        ),
        device: AwtrixDevice,
        // Nil by default, so that no test acquires a browse it did not ask for:
        // a model built without one stays where it was put, however long the
        // clock is away.
        relocate: RelocatingHost? = nil,
        registry: ConnectorRegistry,
        // How a clock's own registry is built. `live()` hands over the very
        // factory the sessions are built from, so a preview and a push ask
        // the same instance; a test that names its connectors directly leaves
        // it nil and reads the app-level registry as before.
        makeClockRegistry: (@MainActor (ClockRecord) -> ConnectorRegistry)? = nil,
        // The device a TC002 clock's health probes — the same one its own
        // slot pushes through. Nil for a caller that drives no TC002 clock,
        // which is what every AWTRIX-only wiring answers.
        makeUlanziDevice: @MainActor @escaping (ClockRecord) -> UlanziDevice?,
        makeUlanziBattery: @MainActor @escaping (ClockRecord) -> UlanziBattery? = { _ in nil },
        // The dual probe an Add by address asks. Nil only in callers that
        // never add by address — `live()` wires the real one, over the same
        // transport every other request takes.
        probe: (@Sendable (String) async -> UlanziProbe.Detection)? = nil,
        installer: CatalogueIconInstaller,
        anecdotes: (any AnecdoteReplaying)? = nil,
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        alerts: any BatteryWarningPresenting,
        focusStatus: any FocusStatusReading,
        vpn: VPNConnector = VPNConnector(isUp: { _ in false }),
        vpnPresence: VPNPresence = VPNPresence(),
        now: @escaping @Sendable () -> Date = Date.init,
        microphone: MicrophoneGate,
        watching: [WatchedMicrophone] = MicrophoneGate.defaultWatchSet,
        // The login keychain, unless the caller names another store — the
        // suite does, because no test may touch the real one.
        keychain: any TileKeyStoring = LoginKeychainStore(),
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        pollSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        micSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.clocks = clocks
        self.tiles = tiles
        self.makeSession = makeSession
        self.clockStore = ClockStore(defaults: defaults)
        self.deviceHost = clocks.first?.address ?? ""
        self.typedHost = clocks.first?.address ?? ""
        self.device = device
        self.relocate = relocate
        self.location = StoredLocation(
            defaults: defaults, clockId: clocks.first?.id ?? UUID()
        )
        self.typedLocation = LocationField.text(for: location.current)
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.registry = registry
        self.makeClockRegistry = makeClockRegistry
        self.makeUlanziDevice = makeUlanziDevice
        self.makeUlanziBattery = makeUlanziBattery
        self.probe = probe
        self.installer = installer
        self.anecdotes = anecdotes
        self.alerts = alerts
        self.focusStatus = focusStatus
        self.vpn = vpn
        self.vpnPresence = vpnPresence
        self.now = now
        self.microphone = microphone
        self.watchedMicrophones = watching
        self.keychain = keychain
        self.scheduleSleep = sleep
        self.pollSleep = pollSleep
        self.micSleep = micSleep
        for clock in self.clocks {
            sessions[clock.id] = makeSession(clock)
            // A TC002 clock's health is its own: /getBase answering, and
            // nothing else — no battery, no relocation, no stats to carry.
            guard clock.model == .awtrix3 else {
                if let device = makeUlanziDevice(clock) {
                    ulanziHealths[clock.id] = UlanziClockHealth(
                        clockId: clock.id, name: clock.name, device: device,
                        battery: makeUlanziBattery(clock)
                    )
                }
                continue
            }
            let wired = makeDeviceAndHistory(clock)
            healths[clock.id] = ClockHealth(
                clock: clock,
                device: wired.device,
                history: wired.history,
                relocate: relocate,
                clocks: clockStore,
                didMove: { [weak self] clockId, address in
                    await self?.clockDidMove(clockId, to: address)
                }
            )
        }
        let saved = defaults.string(forKey: Self.selectedClockKey).flatMap(UUID.init(uuidString:))
        selectedClockId = clocks.contains(where: { $0.id == saved })
            ? saved : clocks.first?.id
    }

    /// The composition root: one device host in, every collaborator wired.
    ///
    /// `transport` is a parameter because it is this app's one door to the
    /// outside: naming it here is what lets the wiring below be checked without
    /// a clock on the network.
    ///
    /// The route selects per `ClockRecord.model`: an AWTRIX clock gets the
    /// phase-2 wiring, a TC002 one the Ulanzi session. One clock per launch —
    /// the choice is made once and the branch not revisited.
    static func live(
        defaults: UserDefaults = .standard,
        transport: any Transport = URLSessionTransport(),
        anecdoteStore: URL = AppPaths.anecdoteStore
    ) -> AppModel {
        // Before anything reads a record. A step that fails leaves its marker
        // unwritten and runs again at the next launch; this launch drives
        // whatever is stored — and a fresh install stores nothing, so the
        // launch drives no clock and the panel answers for that (D6).
        try? ClockMigration(defaults: defaults, fallbackHost: defaultDeviceHost).run()
        let clocks = ClockStore(defaults: defaults).all()
        let first = clocks.first
        let device = AwtrixDevice(host: first?.address ?? defaultDeviceHost, transport: transport)
        // Built here rather than inside the model so that the one door to the
        // outside stays this function's `transport` parameter: the probe below
        // is an HTTP request, and it goes through the same door every other
        // request does.
        let relocation = DeviceRelocation(
            browser: { DeviceBrowser() },
            probe: { host in
                // A device of its own, pointed at the candidate. The app's own
                // device is not re-pointed until the answer has been checked,
                // so a probe that reached the wrong clock cannot move anything
                // by having been made.
                try? await AwtrixDevice(host: host, transport: transport).stats().uid
            }
        )
        let registry = ConnectorRegistry()
        let installer = CatalogueIconInstaller(
            device: device,
            transport: transport,
            uploads: UserDefaultsUploadedIconStore(defaults: defaults)
        )

        let anecdotes = anecdoteWiring(transport: transport, storeURL: anecdoteStore)
        registry.register(anecdotes.connector)
        // The panel's own registry still holds a weather connector — its rows
        // are drawn from here — but no clock produces through this instance:
        // each clock's session builds its own, closed over that clock's place.
        let firstPlace = StoredLocation(defaults: defaults, clockId: first?.id ?? UUID())
        registry.register(
            WeatherConnector(
                source: OpenMeteoSource(transport: transport),
                location: { firstPlace.current },
                // No clock produces through this instance — its faces never
                // run, so the config it would draw with is named only for the
                // type's sake.
                config: { WeatherTileConfig(place: firstPlace.current) }
            )
        )
        // The figure is whatever Claude Code's status line last left in this
        // app's folder. Until Claude Code is connected in the settings and has
        // replied once there is no document, and the app never enters the loop.
        let focusStatus = SystemFocusStatus()
        registry.register(
            ClaudeUsageConnector(
                reporter: StatusLineClaudeUsageReporter(document: ClaudeCodePaths.document)
            )
        )
        // Offered so the Add tile menu can name it; no clock produces through
        // this instance — each clock's session builds its own, closed over
        // that clock's tile's key. The panel copy has no clock, hence no key.
        let keychain = LoginKeychainStore()
        registry.register(
            ZaiUsageConnector(
                source: ZaiUsageAPI(transport: transport, key: { nil })
            )
        )

        // After every connector is registered: one the step does not hear
        // about gets no tile, and runs on its own default until its first
        // saved choice gives it one. No clock stored, no tile owed to one.
        if let first {
            try? TileMigration(
                defaults: defaults,
                clockId: first.id,
                connectors: registry.all.map { (id: $0.id, defaultInterval: $0.defaultInterval) }
            ).run()
        }
        try? WeatherLocationMigration(defaults: defaults).run()
        BatteryHistoryMigration(defaults: defaults).run()
        BorrowedOverlayMigration(defaults: defaults).run()
        try? QuietHoursMigration(
            defaults: defaults,
            audible: Set(registry.all.filter(\.isAudible).map(\.id))
        ).run()
        try? VPNTileMigration(defaults: defaults).run()

        // One shared audio player and one shared weather source; everything
        // else below is per clock.
        let audio = SequentialAudioPlayer()
        let weather = OpenMeteoSource(transport: transport)
        // A registry per clock, so each clock's weather reads its own tile's
        // place through the one shared source — which caches per place. The
        // same registry for both models: the connectors are the app's, the
        // faces are the clock's.
        let makeRegistry: @MainActor (ClockRecord) -> ConnectorRegistry = { clock in
            let registry = ConnectorRegistry()
            registry.register(anecdotes.connector)
            let place = StoredLocation(defaults: defaults, clockId: clock.id)
            let tiles = TileStore(defaults: defaults)
            // The weather tile's own settings, read on every draw off the
            // record that holds them — a change in the tile's window reaches
            // the next poll, exactly the way the place does. The place stays
            // what a config without one falls back to.
            registry.register(
                WeatherConnector(
                    source: weather,
                    location: { place.current },
                    config: {
                        tiles.all()
                            .first {
                                $0.key.clockId == clock.id
                                    && $0.key.connectorId == WeatherConnector.appName
                            }?
                            .config?.weatherConfig
                            ?? WeatherTileConfig(place: place.current)
                    }
                )
            )
            // The Claude tile's own metric, read from its config on every run —
            // so a choice made in the detail takes effect at the next poll,
            // exactly the way the weather's place does. A tile with no choice
            // yet shows the week, which is what it drew before the choice
            // existed.
            let storedTiles = TileStore(defaults: defaults)
            registry.register(
                ClaudeUsageConnector(
                    reporter: StatusLineClaudeUsageReporter(document: ClaudeCodePaths.document),
                    metric: {
                        storedTiles.all()
                            .first {
                                $0.key.clockId == clock.id
                                    && $0.key.connectorId == ClaudeUsageConnector.id
                            }
                            .flatMap(\.config)?.claude ?? .weekly
                    },
                    // The TC002 face's two settings, off the same record at
                    // the same moment: a picker moved reaches the next poll.
                    usageFace: {
                        storedTiles.all()
                            .first {
                                $0.key.clockId == clock.id
                                    && $0.key.connectorId == ClaudeUsageConnector.id
                            }
                            .flatMap(\.config)?.usageFace ?? .standard
                    }
                )
            )
            // The key is looked up at every read, never held: a key pasted
            // into the tile's detail is on its way to the service at the next
            // poll, and one removed from it is gone just as fast.
            registry.register(
                ZaiUsageConnector(
                    source: ZaiUsageAPI(
                        transport: transport,
                        key: {
                            keychain.key(for: ZaiTileConfig.account(for: TileKey(
                                clockId: clock.id, connectorId: ZaiUsageConnector.connectorId
                            )))
                        }
                    ),
                    // The TC002 face's two settings, read off the tile's
                    // record at every draw, the way the Claude tile's are.
                    usageFace: {
                        storedTiles.all()
                            .first {
                                $0.key.clockId == clock.id
                                    && $0.key.connectorId == ZaiUsageConnector.connectorId
                            }
                            .flatMap(\.config)?.usageFace ?? .standard
                    }
                )
            )
            return registry
        }
        let buildSession: @MainActor (ClockRecord) -> any ConnectorRunning = { clock in
            // The TC002 branch of the runtime route: the schedule's slot IS
            // the Ulanzi session — the upsert per tile, the re-push-all
            // recovery, the custody's start-up sweep — behind the one protocol
            // the cadence drives. The cadence runs its pages like any other
            // clock's; the firmware differences live inside the slot.
            if clock.model == .ulanziTC002 {
                let device = UlanziDevice(host: clock.address, transport: transport)
                // Held by the closure rather than re-read: the tile list the
                // start-up sweep sees is read at sweep time, and the store is
                // the Sendable one the rest of the model already shares.
                let slotTiles = TileStore(defaults: defaults)
                return UlanziClockHost(
                    session: UlanziClockSession(
                        device: device,
                        custody: UlanziCustody(
                            device: device,
                            // Durable, for the reason DeviceCustody's borrowed
                            // overlays are durable: TC002 pages outlive this
                            // process (D9), and a record that died with it
                            // would leave the app guessing at what it owns.
                            record: UserDefaultsAppRecord(defaults: defaults),
                            clockId: clock.id.uuidString
                        )
                    ),
                    registry: makeRegistry(clock),
                    store: TileSettingsStore(defaults: defaults, clockId: clock.id),
                    liveTiles: { [slotTiles, clockId = clock.id] in
                        slotTiles.all()
                            .filter { $0.key.clockId == clockId }
                            .map(\.key.connectorId)
                    }
                )
            }
            let store = TileSettingsStore(defaults: defaults, clockId: clock.id)
            let device = AwtrixDevice(host: clock.address, transport: transport)
            return AwtrixClockSession(
                device: device,
                registry: makeRegistry(clock),
                store: store,
                audio: audio,
                iconInstaller: CatalogueIconInstaller(
                    device: device,
                    transport: transport,
                    // One record for the installation, as today. Which clock
                    // an upload went to is not recorded yet (B21 owes it).
                    uploads: UserDefaultsUploadedIconStore(defaults: defaults)
                ),
                // Durable, for the reason the uploaded-icon record is: what
                // this app did to the device is not knowable by looking at the
                // device afterwards. One exit without a teardown and an
                // in-memory record turns this app's own weather overlay into
                // the value it restores for ever.
                borrowedOverlays: UserDefaultsBorrowedOverlayStore(
                    defaults: defaults, clockId: clock.id
                )
            )
        }
        // One session per clock, built once here — the model's own
        // `makeSession` hands these back, and init builds no others.
        var sessionsByClock: [UUID: any ConnectorRunning] = [:]
        for clock in clocks {
            sessionsByClock[clock.id] = buildSession(clock)
        }
        let makeSession: @MainActor (ClockRecord) -> any ConnectorRunning = { clock in
            sessionsByClock[clock.id] ?? buildSession(clock)
        }
        let makeDeviceAndHistory: @MainActor (ClockRecord) -> (
            device: AwtrixDevice, history: any BatteryHistoryStore
        ) = { clock in
            (
                clock.id == first?.id
                    ? device : AwtrixDevice(host: clock.address, transport: transport),
                UserDefaultsBatteryHistoryStore(
                    defaults: defaults, hardwareIdentity: clock.hardwareIdentity
                )
            )
        }

        let vpn = VPNConnector(isUp: VPNPresence().isUp)

        return AppModel(
            clocks: clocks,
            tiles: TileStore(defaults: defaults),
            makeSession: makeSession,
            makeDeviceAndHistory: makeDeviceAndHistory,
            device: device,
            relocate: { remembered in await relocation.relocatedHost(remembering: remembered) },
            registry: registry,
            // The very factory the sessions are built from, so a preview and
            // a push ask the same connector instance about the same clock.
            makeClockRegistry: makeRegistry,
            makeUlanziDevice: { clock in
                UlanziDevice(host: clock.address, transport: transport)
            },
            makeUlanziBattery: { clock in
                // The helper is a prebuilt ARMv7 ELF shipped in the kit bundle.
                // No helper, no battery line — never a guessed figure.
                guard
                    let helper = UlanziBattery.bundledHelper()
                else { return nil }
                let host = clock.address
                return UlanziBattery(
                    adb: ADBClient(connect: { try await NWADBStream.connect(host: host) }),
                    helper: helper
                )
            },
            probe: { host in await UlanziProbe.detect(host: host, transport: transport) },
            installer: installer,
            anecdotes: anecdotes.connector,
            defaults: defaults,
            alerts: BatteryAlert(
                dialog: ModalBatteryDialog(), notifications: SystemBatteryNotifier()
            ),
            // The same reading of macOS the tiles' Focus rules are read from,
            // so the two cannot answer differently about the same moment.
            focusStatus: focusStatus,
            vpn: vpn,
            microphone: MicrophoneGate(inputs: SystemAudioInputs()),
            watching: WatchedMicrophone.stored(in: defaults)
        )
    }

    /// The anecdote connector, and the two collaborators whose agreement is the
    /// reaper's entire safety argument.
    ///
    /// Both of them are returned, not just the connector, because the invariant
    /// this function exists to hold — the synthesizer writes clips exactly where
    /// the queue is allowed to delete — is otherwise a fact about two arguments
    /// nobody can read back. One `clipRoot` parameter reaches both.
    ///
    /// One queue, handed to the connector and to the preparer: `refill` enqueues
    /// into the same queue `produce()` drains, so a second instance would
    /// synthesize a batch nothing ever plays.
    static func anecdoteWiring(
        transport: any Transport,
        clipRoot: URL = AppPaths.clipRoot,
        storeURL: URL = AppPaths.anecdoteStore,
        retention: TimeInterval = AppPaths.clipRetention
    ) -> (connector: AnecdoteConnector, queue: AnecdoteQueue, speech: SidecarSpeechSynthesizer) {
        let speech = SidecarSpeechSynthesizer(
            pythonPath: NSString(string: "~/.local/share/tts-voices/.venv/bin/python")
                .expandingTildeInPath,
            scriptPath: NSString(string: "~/.local/share/tts-voices/speak.py")
                .expandingTildeInPath,
            workingDirectory: NSString(string: "~/.local/share/tts-voices")
                .expandingTildeInPath,
            outputDirectory: clipRoot
        )
        let queue = AnecdoteQueue(storeURL: storeURL, clipRoot: clipRoot, retention: retention)
        return (
            AnecdoteConnector(
                queue: queue,
                preparer: AnecdotePreparer(
                    source: AnecdoteSource(transport: transport), speech: speech, queue: queue
                )
            ),
            queue,
            speech
        )
    }

    // MARK: - What the user chose

    /// The selected clock's tile of this connector, as stored.
    /// The tile's stored record, said for the surfaces that read the config
    /// it carries.
    func storedTile(_ key: TileKey) -> TileRecord? {
        tiles.all().first { $0.key == key }
    }

    /// What this connector is set to, on the selected clock's tile.
    ///
    /// A connector with no tile yet falls back to its own `defaultInterval` —
    /// the same "never configured" the settings store used to fold, now read
    /// off the connector itself.
    func settings(for connector: any Connector) -> ConnectorSettings {
        guard let key = selectedKey(connector.id), let record = storedTile(key) else {
            return ConnectorSettings(
                intervalPosition: IntervalScale.position(for: connector.defaultInterval)
            )
        }
        return Self.resolved(record)
    }

    private static func resolved(_ record: TileRecord) -> ConnectorSettings {
        ConnectorSettings(
            isEnabled: !record.policy.isPaused,
            intervalPosition: IntervalScale.position(for: TimeInterval(record.policy.refreshSeconds)),
            lastDeliveredAt: record.lastDeliveredAt
        )
    }

    func setEnabled(_ enabled: Bool, for connector: any Connector) {
        guard let key = selectedKey(connector.id), storedTile(key) != nil else { return }
        setPaused(!enabled, tile: key)
    }

    /// Pauses or resumes one tile, named by key and not by connector — the
    /// same connector sits on several clocks, and this names one tile of it.
    func setPaused(_ paused: Bool, tile key: TileKey) {
        guard let record = storedTile(key) else { return }
        let wasRunning = !record.policy.isPaused
        tiles.update(record) { $0.policy.isPaused = paused }
        reschedule(key)
        // Only on the way OFF, and only on the edge. A tile switched off
        // stops running, so nothing else will ever put back what it borrowed —
        // where switching one ON borrows nothing until its first delivery, and
        // a restore there would write a value that is already on the device.
        // Dragging the interval slider is neither, and must not touch the clock
        // at all.
        if wasRunning && paused {
            giveBackDeviceState(key)
            // On the TC002 branch a paused tile's page stays in the knob cycle
            // on the idle frame — paused, never deleted (D4). The slot names
            // the branch: an AWTRIX session fails the cast, and there the
            // restore above is what answers the pause.
            let tc002 = ulanziSession(for: key.clockId)
            Task { await tc002?.markIdle(tileId: key.connectorId) }
        }
    }

    func setIntervalPosition(_ position: Int, for connector: any Connector) {
        guard let key = selectedKey(connector.id), let record = storedTile(key) else { return }
        // The old slider's scale, until Phase 5 moves the row onto the refresh
        // scale the policy is read through.
        tiles.update(record) {
            $0.policy.refreshSeconds = Int(IntervalScale.duration(atPosition: position))
        }
        reschedule(key)
    }

    /// Puts back what one tile borrowed from its clock.
    ///
    /// The task is owned here rather than left detached, for the reason every
    /// other one is: teardown can only wait for a task it holds, and this one
    /// writes to the device. Keyed by nothing meaningful — switching a
    /// connector off twice is two restores, and the second finds nothing left
    /// to give back.
    enum TileSaveOutcome: Equatable {
        case saved
        /// Not saved, with the sentence to show beside the control that asked.
        case refused(String)
    }

    /// What the Add tile menu shows for a connector on a clock.
    func availability(of connectorId: String, on clockId: UUID) -> TileAvailability {
        guard let clock = clocks.first(where: { $0.id == clockId }),
            let candidate = candidate(for: connectorId)
        else { return .notListed }
        return TileCatalogue.availability(of: candidate, on: clock, tiles: tiles.all(), clocks: clocks)
    }

    func addTile(
        _ connectorId: String, to clockId: UUID, instance: String = "", config: TileConfig? = nil
    ) -> TileSaveOutcome {
        // A lamp tile's key carries its VPN, and a store card has no VPN to
        // give — it knows a connector. Left empty, every press landed on the
        // same key and the second one was refused as a duplicate, which is
        // why a clock could never carry more than one lamp however many VPNs
        // the catalogue held.
        if connectorId == VPNConnector.id, instance.isEmpty {
            guard let free = freeLampVPN(on: clockId) else {
                return .refused(
                    "every VPN already has a tile on \(clocks.first { $0.id == clockId }?.name ?? "this clock")"
                )
            }
            return addTile(
                connectorId, to: clockId, instance: free.id,
                config: config ?? .vpn(startingLamp(for: free, on: clockId))
            )
        }
        let key = TileKey(clockId: clockId, connectorId: connectorId, instance: instance)
        switch availability(of: connectorId, on: clockId) {
        case let .unavailable(reason):
            return .refused(reason)
        case .notListed:
            return .refused("already on \(clocks.first { $0.id == clockId }?.name ?? "this clock")")
        case .available:
            break
        }
        if tiles.all().contains(where: { $0.key == key }) {
            return .refused("already on \(clocks.first { $0.id == clockId }?.name ?? "this clock")")
        }
        var starting = connectorId == VPNConnector.id
            ? TileDefaults.vpn
            : registry.connector(id: connectorId)?.defaultPolicy ?? TileDefaults.weather
        // The user's Defaults answer, when there is one, sets the pace a new
        // tile starts at. The lamp keeps its own default — its seconds are
        // presence, not cadence.
        if connectorId != VPNConnector.id, let fixed = newTileIntervalSeconds {
            starting.refreshSeconds = fixed
        }
        // The settings a previous tile of this connector on this clock left
        // with come back here — an explicit `config` argument still wins.
        var config = config
        if config == nil,
            let data = defaults.data(forKey: Self.restoreKey(for: key)),
            let brought = try? JSONDecoder().decode(TileConfig.self, from: data) {
            config = brought
            defaults.removeObject(forKey: Self.restoreKey(for: key))
        }
        return saveTile(key: key, policy: starting, config: config)
    }

    /// Where a removed tile's settings wait for its return.
    private static func restoreKey(for key: TileKey) -> String {
        "tileConfigRestore.\(key.clockId.uuidString).\(key.connectorId).\(key.instance)"
    }

    // MARK: - The lamp tiles

    /// The first VPN in the catalogue that no tile on this clock is watching.
    ///
    /// Nil is the ceiling: a user cannot describe a bundle and its tunnel
    /// binaries, so the catalogue is written in code, and a tile per entry is
    /// as far as a clock goes.
    func freeLampVPN(on clockId: UUID) -> WatchedVPN? {
        let watched = Set(
            tiles.all()
                .filter { $0.key.clockId == clockId && $0.key.connectorId == VPNConnector.id }
                .map(\.key.instance)
        )
        return WatchedVPN.catalogue.first { !watched.contains($0.id) }
    }

    /// What a lamp tile starts as: a corner nobody has claimed, a palette
    /// colour of its own, and dark when its tunnel drops.
    ///
    /// A colour per preset rather than one for all, so two lamps added in a
    /// row are told apart on the clock before either is configured. Dark and
    /// not blinking, because a lamp added to see whether a VPN is up should
    /// not be the brightest thing in the room the moment it is not.
    private func startingLamp(for vpn: WatchedVPN, on clockId: UUID) -> VPNTileConfig {
        let taken = Set(
            tiles.all()
                .filter { $0.key.clockId == clockId && $0.key.connectorId == VPNConnector.id }
                .compactMap { $0.config?.lamp?.slot }
        )
        let index = WatchedVPN.catalogue.firstIndex { $0.id == vpn.id } ?? 0
        return VPNTileConfig(
            vpn: vpn.id,
            slot: IndicatorSlot.allCases.first { !taken.contains($0) } ?? .topRight,
            upColour: VPNTilePalette.palette[index % VPNTilePalette.palette.count].hex,
            whenDown: .off
        )
    }

    /// Points a lamp tile at another VPN — the block's Preset picker.
    ///
    /// A move and not an edit, because the VPN is the tile's identity: it is
    /// the key's instance, which is what the migration wrote, what the
    /// restore key reads, and what keeps two lamps on one clock apart. The
    /// policy, the lamp and the colour come across untouched, and the window
    /// is re-aimed at the key the tile now lives under.
    func changeLampVPN(_ key: TileKey, to vpnId: String) -> TileSaveOutcome {
        guard var lamp = storedTile(key)?.config?.lamp, let policy = storedPolicy(of: key) else {
            return .refused("this tile is no longer on the clock")
        }
        guard key.instance != vpnId else { return .saved }
        let moved = TileKey(clockId: key.clockId, connectorId: key.connectorId, instance: vpnId)
        if tiles.all().contains(where: { $0.key == moved }) {
            let name = WatchedVPN.preset(id: vpnId)?.displayName ?? vpnId
            let clock = clocks.first { $0.id == key.clockId }?.name ?? "this clock"
            return .refused("\(name) already has a tile on \(clock)")
        }
        lamp.vpn = vpnId
        // The old record goes first and without `removeTile`: that path files
        // the config away under the old key for a re-add to find, and this
        // config is not being put away — it is moving house.
        timers.removeValue(forKey: key)?.cancel()
        try? tiles.replaceAll(tiles.all().filter { $0.key != key })
        let outcome = saveTile(key: moved, policy: policy, config: .vpn(lamp))
        if case .saved = outcome, detailTileKey == key { openDetail(for: moved) }
        return outcome
    }

    /// Stores what the tile detail says, unless a VPN lamp is claimed by
    /// another tile at the same moment. A pause takes the tile's app off its
    /// clock at once; the schedule is rebuilt either way.
    func saveTile(key: TileKey, policy: TilePolicy, config: TileConfig?) -> TileSaveOutcome {

        if let lamp = config?.lamp,
            let conflict = LampConflict.check(
                LampTile(key: key, name: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn, slot: lamp.slot, policy: policy),
                against: lampTiles(on: key.clockId)
            ) {
            return .refused(conflict.message)
        }
        let wasRunning = storedPolicy(of: key).map { !$0.isPaused } ?? false
        tiles.update(TileRecord(key: key, policy: TilePolicyRecord(policy))) {
            $0.policy = TilePolicyRecord(policy)
            $0.config = config
        }

        if wasRunning && policy.isPaused { retract(key) }
        if key.connectorId == VPNConnector.id { refreshLamps() } else { reschedule(key) }
        reconcileTiles()
        return .saved
    }

    // MARK: - The z.ai key

    /// What a paste did, as the detail surface says it.
    enum ZaiKeyOutcome: Equatable {
        case saved
        case removed
        /// The store refused, and the field says so — a paste the user
        /// believes was taken must not quietly never have been.
        case refused
    }

    /// The last paste's outcome, for the field to say it out loud.
    @Published private(set) var lastZaiKeyOutcome: ZaiKeyOutcome?

    /// The key a paste put in, taken out of the record's way: it goes to the
    /// keychain under the tile's own account, and the tile record remembers
    /// only the handle. A blank paste is the removal, so the one field is how
    /// a key is both given and taken back.
    @discardableResult
    func saveZaiKey(_ typed: String, for key: TileKey) -> ZaiKeyOutcome {
        let account = ZaiTileConfig.account(for: key)
        let pasted = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let outcome: ZaiKeyOutcome
        do {
            if pasted.isEmpty {
                try keychain.removeKey(for: account)
                outcome = .removed
            } else {
                try keychain.save(pasted, for: account)
                outcome = .saved
            }
        } catch {
            outcome = .refused
        }
        lastZaiKeyOutcome = outcome

        // The policy stands; only the handle joins the record, derived the
        // same way the connector reads it back. A tile saved before any paste
        // still gets its config here — there is nothing to read first. The
        // usage face's settings the record already carries stay: a paste is
        // about the key, not about when the page shows its resets.
        if outcome != .refused, let policy = storedPolicy(of: key) {
            _ = saveTile(
                key: key, policy: policy,
                config: .zai(ZaiTileConfig(
                    keyAccount: account,
                    usageFace: storedTile(key)?.config?.usageFace ?? .standard
                ))
            )
        }
        return outcome
    }

    /// Whether a key stands behind this tile — as the field's presence line
    /// puts it, without ever saying what the key is.
    func hasZaiKey(for key: TileKey) -> Bool {
        keychain.key(for: ZaiTileConfig.account(for: key)) != nil
    }

    func removeTile(_ key: TileKey) {
        timers.removeValue(forKey: key)?.cancel()
        // The tile's own settings survive its removal: re-adding the same
        // connector to the same clock brings them back instead of the
        // shipped defaults — the remove/re-add cycle is a reset button's
        // opposite, and a person removing a tile to try again does not mean
        // their weather place.
        if let config = tiles.all().first(where: { $0.key == key })?.config,
            let data = try? JSONEncoder().encode(config) {
            defaults.set(data, forKey: Self.restoreKey(for: key))
        }
        try? tiles.replaceAll(tiles.all().filter { $0.key != key })
        if key.connectorId == VPNConnector.id {
            refreshLamps()
        } else {
            retract(key)
            // The TC002's page is the app's own doing, so removal takes it
            // back through the slot's custody — the empty-body delete that
            // is the measured contract (phase-3 A9). The cast is the model
            // check; an AWTRIX slot has nothing to take back here.
            let tc002 = ulanziSession(for: key.clockId)
            Task { await tc002?.tileRemoved(key.connectorId) }
        }
    }

    func storedPolicy(of key: TileKey) -> TilePolicy? { policy(of: key) }

    /// The connector as the store's cards see it, or nil for an id the
    /// registry does not hold and the lamp is not.
    func candidate(for connectorId: String) -> TileCandidate? {
        if connectorId == VPNConnector.id { return TileCandidate(vpn) }
        return registry.connector(id: connectorId).map { TileCandidate($0) }
    }

    private func lampTiles(on clockId: UUID) -> [LampTile] {
        tiles.all().compactMap { record in
            guard record.key.clockId == clockId, let lamp = record.config?.lamp,
                let policy = policy(of: record.key)
            else { return nil }
            return LampTile(key: record.key, name: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn, slot: lamp.slot, policy: policy)
        }
    }

    private func giveBackDeviceState(_ key: TileKey) {
        let restoreKey = nextRestoreKey
        nextRestoreKey += 1
        restores[restoreKey] = Task { [weak self] in
            await self?.session(for: key)?.restoreDeviceState(borrowedBy: key.connectorId)
            self?.restores[restoreKey] = nil
        }
    }

    /// Every input the system reports, with the watched ones marked.
    ///
    /// Asked rather than stored, because the list changes underneath the app:
    /// the phone appears and vanishes, headphones are plugged in. Costs one
    /// CoreAudio enumeration — 1.36 ms measured — and is only drawn while the
    /// settings are open.
    var microphoneListing: [MicrophoneChoice] {
        microphone.listing(watching: watchedMicrophones)
    }

    /// Adds or removes a microphone from the set the schedule waits for.
    ///
    /// Removal goes through the same `matches` rule the gate decides with, and
    /// not through equality on the stored entry: the shipped defaults carry no
    /// UID, so an entry-equality removal would leave a box that cannot be
    /// unticked.
    func setWatched(_ watched: Bool, for input: AudioInput) {
        let present = microphone.listing(watching: watchedMicrophones).map(\.input)
        var watching = watchedMicrophones.filter { $0.matches(input, among: present) == false }
        // Written with the UID this app has just SEEN, which is what upgrades a
        // shipped default from a name to an identity the moment the user
        // confirms it.
        if watched { watching.append(WatchedMicrophone(uid: input.uid, name: input.name)) }
        watchedMicrophones = watching
        WatchedMicrophone.save(watching, to: defaults)
    }

    // MARK: - What the panel's facade asks for

    /// The tile whose detail surface is open, or nil while none is. The key it
    /// was opened for travels with the surface, so the editor never has to ask
    /// which tile it is editing.
    @Published private(set) var detailTileKey: TileKey?

    func openDetail(for key: TileKey) { detailTileKey = key }
    func closeDetail() { detailTileKey = nil }

    /// Bumped whenever any clock's health has moved: a poll answered, a
    /// health was built or dropped. The panel's dot hangs off per-clock
    /// health, which is otherwise silent — a `DeviceMonitor` is a nested
    /// observable no `objectWillChange` of this model carries, and a TC002's
    /// answering state is a plain field. The facade subscribes to this and
    /// rebuilds its sections off it.
    @Published private(set) var healthRevision = 0

    /// One clock's answer to "are you there", as the panel's status dot asks
    /// it: the three-valued answer both firmwares give, said in one
    /// vocabulary. `.unknown` is the state before the first poll — the one
    /// the panel drew as "Checking…", which is neither connected nor down.
    enum ClockReachability: Equatable, Sendable {
        case unknown
        case reachable
        case unreachable
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

    /// The tiles as they are stored, in stored order — the raw material the
    /// panel's sections are built from.
    var tileRecords: [TileRecord] { tiles.all() }

    /// One tile's row inputs, said where they are known.
    func lastResult(of key: TileKey) -> String? { tileLastResults[key] }

    /// The run's own complaint outranks the restock's: it is the newer
    /// evidence about the same feed.
    func lastFailure(of key: TileKey) -> String? {
        tileLastFailures[key] ?? tileLastMaintenanceFailure[key]
    }

    /// Why the tile is not running now: its policy read against the room —
    /// the Focus the machine is in, the hour it is. The quiet rules stay the
    /// model's; the facade asks rather than recomputes them.
    func hold(of key: TileKey) -> TileHold? {
        policy(of: key)?.hold(in: currentFocus, atHour: currentHour)
    }

    /// Drag-reorder, as the panel's rows carry it: `source` is the row the
    /// drag picked up and `destination` the row it landed on. The order IS
    /// the tiles record's order — the one record every clock reads its rows
    /// from — so only the source clock's slice moves and every other clock's
    /// tiles keep their places in it.
    ///
    /// A move that changes nothing is not one: the same row under the drag,
    /// a destination on another clock (a payload is readable anywhere, and
    /// only the selected clock's rows are on this panel), a source that is
    /// gone — each arrives here as a plain refusal.
    func moveTile(_ source: TileKey, to destination: TileKey) {
        guard source.clockId == destination.clockId, source != destination else { return }
        var all = tiles.all()
        guard let fromIndex = all.firstIndex(where: { $0.key == source }),
            let destinationRow = all.firstIndex(where: { $0.key == destination })
        else { return }
        let moved = all.remove(at: fromIndex)
        // The destination's ORIGINAL index is where the dragged row lands,
        // whatever direction the drag ran: ahead of it, the removal has
        // already pulled every row between up by one; behind it, the insert
        // pushes them back down.
        all.insert(moved, at: min(destinationRow, all.count))
        try? tiles.replaceAll(all)
        tileOrderRevision += 1
    }

    /// A tile's display name: the lamp's VPN for a lamp tile, the connector's
    /// own name for every other.
    func tileName(of record: TileRecord) -> String {
        let key = record.key
        if key.connectorId == VPNConnector.id {
            return record.config?.lamp.map { WatchedVPN.preset(id: $0.vpn)?.displayName ?? $0.vpn }
                ?? "VPN"
        }
        return registry.connector(id: key.connectorId)?.displayName ?? key.connectorId
    }

    /// The detail surface's inputs for one tile, beyond the policy it edits:
    /// its display name and the config a save must carry through. Nil for a
    /// tile that is gone — there is nothing left for the surface to be open
    /// for.
    func detailValue(for key: TileKey) -> (name: String, config: TileConfig?)? {
        guard let record = storedTile(key) else { return nil }
        return (tileName(of: record), record.config)
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
    ///
    /// A clock is in exactly one of the two health maps, so this is a
    /// fall-through rather than a merge.
    func batteryLine(of clock: ClockRecord) -> String? {
        BatteryLine.text(for: battery(of: clock))
    }

    /// The reading behind that line, for a surface that draws the charge
    /// rather than saying it — the panel's cards.
    func battery(of clock: ClockRecord) -> BatteryReading? {
        if let ulanzi = ulanziHealths[clock.id] { return ulanzi.lastKnownBattery }
        return healths[clock.id]?.monitor.lastKnownBattery
    }

    /// Every connector a clock's Add tile menu can offer, in offer order:
    /// the registry's, then the lamp's — it has no face and no session of
    /// its own, so it never joined the registry, and this is where it is
    /// offered. LAST, because it is the connector a full clock can still
    /// take: the exhausted-clock menu offers it and nothing else.
    func tileCandidates() -> [(connectorId: String, name: String)] {
        registry.all.map { (connectorId: $0.id, name: $0.displayName) }
            + [(connectorId: VPNConnector.id, name: vpn.displayName)]
    }

    // MARK: - Clock actions

    enum ClockSaveOutcome: Equatable {
        case added
        /// Not added, with the sentence to show beside the control that asked.
        case refused(String)
    }

    /// Adds the clock the dual probe finds at the address. Status codes are
    /// not trusted — this firmware answers the AWTRIX stats path with a
    /// redirect — so the model is whichever body DECODES.
    func addClock(address raw: String) async -> ClockSaveOutcome {
        let outcome = await self.addOutcome(at: raw)
        // Logged where the outcome is known rather than at the button: a
        // refusal the sheet did not show (it closed, the surface switched) is
        // still diagnosable from the system log.
        AppLog.clocks.notice(
            "add by address: \(self.outcomeLine(outcome, name: raw), privacy: .public)"
        )
        return outcome
    }

    private func addOutcome(at raw: String) async -> ClockSaveOutcome {
        guard let host = DeviceAddress.host(from: raw) else {
            return .refused("not an address: \(raw)")
        }
        if clockStore.all().contains(where: { $0.address == host }) {
            return .refused("already configured at \(host)")
        }
        guard let probe else { return .refused("no probe wired for \(host)") }
        switch await probe(host) {
        case .undetermined:
            return .refused("nothing answered at \(host)")
        case .ulanzi:
            return store(ClockRecord(name: "Clock", model: .ulanziTC002, address: host))
        case .otherDevice:
            return store(ClockRecord(name: "Clock", model: .awtrix3, address: host))
        }
    }

    /// Adds a clock discovery has seen. The list already carried what the
    /// browse and the broadcasts agreed on, so the record is what it said.
    func addClock(from discovered: DiscoveredClock) -> ClockSaveOutcome {
        let name = discovered.model.lowercased()
        let model: ClockModel = name.contains("tc002") || name.contains("ulanzi")
            ? .ulanziTC002 : .awtrix3
        if clockStore.all().contains(where: { $0.address == discovered.address }) {
            let outcome = ClockSaveOutcome.refused("already configured at \(discovered.address)")
            AppLog.clocks.notice(
                "add from discovery: \(self.outcomeLine(outcome, name: discovered.name), privacy: .public)"
            )
            return outcome
        }
        let outcome = store(
            ClockRecord(name: discovered.name, model: model, address: discovered.address)
        )
        AppLog.clocks.notice(
            "add from discovery: \(self.outcomeLine(outcome, name: discovered.name), privacy: .public)"
        )
        return outcome
    }

    /// The sentence the log carries for an outcome — the same words the
    /// Clocks section says, minus the name an addition already carries.
    private func outcomeLine(
        _ outcome: ClockSaveOutcome, name: String
    ) -> String {
        ClockAddOutcomeLine.title(for: outcome, added: name)
    }

    /// A rename writes through the store and touches nothing else.
    func renameClock(_ id: UUID, to name: String) {
        guard let record = clock(id) else { return }
        clockStore.update(record) { $0.name = name }
        reloadClocks()
    }

    /// Removes the clock: every tile off it first, then the record, then the
    /// spine takes the session down — its lendings given back, its timers
    /// cancelled, and the selection moved off it if it was the one selected.
    ///
    /// The view's inline confirmation is what stands in front of this; the
    /// model does it the moment it is asked.
    func removeClock(_ id: UUID) {
        guard clock(id) != nil else { return }
        // The TC002's pages are the app's own doing: the slot's teardown
        // releases every owned name — the empty-body delete per page. The
        // slot is resolved before the reload below drops it.
        let tc002 = ulanziSession(for: id)
        Task { await tc002?.shutdown() }
        try? tiles.replaceAll(tiles.all().filter { $0.key.clockId != id })
        try? clockStore.replaceAll(clockStore.all().filter { $0.id != id })
        reloadClocks()
    }

    /// Stores a new clock and brings the sessions in line with it.
    private func store(_ record: ClockRecord) -> ClockSaveOutcome {
        var clocks = clockStore.all()
        clocks.append(record)
        do {
            try clockStore.replaceAll(clocks)
        } catch {
            return .refused("the clock could not be stored")
        }
        reloadClocks()
        return .added
    }

    // MARK: - Settings

    /// Reorders the clocks — a drag in the Clocks tab: `source` moves to the
    /// place `destination` holds. The order IS the store's, the one the
    /// panel's sections follow, and a move that changes nothing (a row
    /// dropped on itself, a clock that is gone) is not one.
    func moveClock(_ source: UUID, to destination: UUID) {
        guard source != destination else { return }
        var all = clockStore.all()
        guard let fromIndex = all.firstIndex(where: { $0.id == source }),
            let destinationRow = all.firstIndex(where: { $0.id == destination })
        else { return }
        let moved = all.remove(at: fromIndex)
        // The destination's ORIGINAL index is where the dragged row lands,
        // whatever direction the drag ran — the same rule the tile rows move
        // by.
        all.insert(moved, at: min(destinationRow, all.count))
        try? clockStore.replaceAll(all)
        reloadClocks()
    }

    /// The refresh a NEW tile starts with, when the user has fixed one in
    /// Defaults — nil leaves every connector starting from its own default,
    /// which is what the migration left and what no opinion means.
    var newTileIntervalSeconds: Int? {
        defaults.object(forKey: Self.newTileIntervalKey) as? Int
    }

    func setNewTileInterval(seconds: Int?) {
        if let seconds {
            defaults.set(seconds, forKey: Self.newTileIntervalKey)
        } else {
            defaults.removeObject(forKey: Self.newTileIntervalKey)
        }
    }

    static let newTileIntervalKey = "newTileIntervalSeconds"

    // MARK: - History

    /// Whether this connector has a history to browse.
    ///
    /// Asked of the connector rather than answered by a flag on the row,
    /// because the panel draws whatever the registry holds and only the
    /// anecdotes keep anything: a History button on a row with no history behind
    /// it is a promise the surface cannot keep.
    func hasHistory(_ connector: any Connector) -> Bool {
        anecdotes?.id == connector.id
    }

    /// Shows what has played, in place of the panel.
    ///
    /// In place of, not over: a menu bar extra's window dismisses when it loses
    /// focus and takes any sheet with it, so a sheet here is a surface that
    /// vanishes while it is being read. The settings made the same trade.
    ///
    /// The list is read on every open. Nothing else shows it, so keeping it in
    /// step with the queue between opens would be work nobody can see — and a
    /// surface opened right after a run has to show that run.
    func openHistory() {
        historyIsOpen = true
        loadHistory()
    }

    /// Asks what has played, without swapping the panel to show it.
    ///
    /// The half of `openHistory` that is about the LIST rather than about the
    /// panel. The anecdote tile's settings window shows the same history in a
    /// sheet of its own, and its button used to call `openHistory` — which
    /// flipped a flag nothing in that window reads, so the press did nothing
    /// visible there and left the menu bar's panel swapped to a surface
    /// nobody had asked it for.
    func loadHistory() {
        // Whatever the last replay said goes with the surface it was said on.
        // Opening the History is asking what has played, not asking again about
        // the last thing that was pressed — and an answer kept across the open
        // would read as having just happened.
        replayResult = nil
        readHistory()
    }

    /// Asks what has played, into `history`.
    ///
    /// Its own method because the History's own open is too late to be the only
    /// caller. The read is a round trip to an actor and the surface is drawn the
    /// instant the button is pressed, so on the FIRST open there is no answer to
    /// draw yet, while every open after that draws the entries at once off the
    /// answer the first open eventually got — which is exactly the asymmetry
    /// that was reported: the History showing what played only on the second
    /// press. Asking when the PANEL opens is what buys the first open its
    /// answer; `history` staying nil until one arrives is what keeps the gap
    /// honest when it does not.
    ///
    /// Cancelling the load in flight is what keeps the last open's answer from
    /// landing after this one's — two reads racing to write the same list, and
    /// the older one winning is a surface showing what had played a minute ago.
    private func readHistory() {
        guard let anecdotes else { return }
        historyLoad?.cancel()
        historyLoad = Task { [weak self] in
            let played = await anecdotes.history()
            guard let self, !Task.isCancelled else { return }
            self.history = played
        }
    }

    func closeHistory() { historyIsOpen = false }

    /// Puts the menu back on the panel, because the window went away.
    ///
    /// The History, and only the History. The settings used to be reset here
    /// too, back when they were a surface swapped into the panel's window —
    /// now they are the app's own window, and it closing says nothing about
    /// the panel. A menu bar item is clicked to answer "is the clock alive,
    /// and what is next"; a list of old jokes answers a question nobody
    /// asked.
    ///
    /// Not a teardown. Nothing is stopped and nothing is cancelled — the
    /// schedule, the poll and any replay in flight carry on behind a window
    /// that is not on screen, exactly as they carry on behind a surface that
    /// is.
    func windowDidClose() {
        historyIsOpen = false
    }

    /// Plays a past anecdote again.
    ///
    /// NOT a run, and every part of that is deliberate: it goes to `deliver`, so
    /// nothing is produced and nothing is retired; no outcome is recorded, so
    /// the backoff Task 15 owns is untouched; and no restock follows it, so the
    /// refill Task 18 schedules is not brought forward. Replaying something from
    /// last week cannot change what tomorrow does.
    ///
    /// An entry whose clips have been reaped is refused here, and `isPlayable`
    /// is the one thing asked — the same answer the button's own disabled state
    /// reads. Delivering it would put a held banner on the clock with audio that
    /// never arrives to end it.
    ///
    /// The task is owned rather than left to the button's action closure, for
    /// the reason `runNow`'s is: teardown can only wait for what it holds, and
    /// this puts the same held banner on the clock.
    /// Said instead of an outcome, when no clock carries the anecdotes.
    static let noClockCarriesTheAnecdotes = "No clock carries the anecdotes"

    /// The session of the clock carrying the anecdote tile.
    private var anecdoteSession: (any ConnectorRunning)? {
        guard let anecdotes else { return nil }
        return tiles.all().first { $0.key.connectorId == anecdotes.id }
            .flatMap { sessions[$0.key.clockId] }
    }

    func replay(_ anecdote: PreparedAnecdote) {
        guard let anecdotes, anecdote.isPlayable else { return }
        guard let session = anecdoteSession else {
            replayResult = Self.noClockCarriesTheAnecdotes
            return
        }
        let output = anecdotes.output(for: anecdote)
        let key = nextReplayKey
        nextReplayKey += 1
        replays[key] = Task { [weak self] in
            let result = await session.deliver(output)
            // Kept, where the run line and the failure count are still not
            // touched. Those two are what the discarded result was ever
            // discarded for; the History is a third place, and it is the one
            // the button was pressed on.
            self?.replayResult = Self.words(for: result)
            self?.replays[key] = nil
        }
    }

    /// Puts the joke on the pasteboard.
    ///
    /// The anecdote's own text — not the banner, which is the four words the
    /// clock shows, and not the laughter, which is a marker for the synthesizer.
    /// What somebody pressing Copy wants is the thing they would paste into a
    /// chat.
    func copyText(_ anecdote: PreparedAnecdote) {
        pasteboard.clearContents()
        pasteboard.setString(anecdote.text, forType: .string)
    }

    // MARK: - Running

    /// Starts the poll, the schedules, and the restock that fills the queue
    /// before the first of them fires. Separate from `init` so that
    /// constructing this type reaches neither the network nor the clock.
    func start() {
        // Once, here, and never from a gate check. Measured on this machine,
        // `INFocusStatusCenter.requestAuthorization` never calls its handler
        // back — so nothing waits on this — and a prompt raised on every beat
        // is a prompt the user learns to dismiss. What reads the answer is
        // every tile's Focus rule, on every turn of every schedule.
        focusStatus.requestAccess()
        // Recorded before the loops are started, not after them: everything in
        // this method is synchronous and no task runs until it returns, but the
        // poll is what SPENDS this debt and reading it half-written is one
        // ordering nobody should have to reason about.
        noteLaunchDeliveries()
        startMonitoring()
        startWatchingMicrophones()
        startWatchingTheWorld()
        // The one caller that resumes. A cadence describes the gap BETWEEN
        // deliveries, and every OTHER caller of `reschedule` is a settings
        // change, where the gap the user just chose starts now. One schedule
        // per stored tile whose clock has a session — whichever model the
        // record names: the slot decides what a run means, an AWTRIX scene on
        // one clock, an Ulanzi upsert on another. A tile whose connector the
        // registry does not know gets no timer inside `reschedule`, and the
        // VPN tiles get their own path in B18.
        for record in tiles.all() where sessions[record.key.clockId] != nil {
            reschedule(record.key, resuming: true)
        }
        restockAtLaunch()
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
    private func noteLaunchDeliveries() {
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
    private func deliverWhatTheLaunchOwes() {
        let due = launchDeliveriesOwed.filter { scheduleHold(for: $0) == nil }
        guard due.isEmpty == false else { return }
        launchDeliveriesOwed.subtract(due)
        for key in due { runNow(key) }
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
    private func restockAtLaunch() {
        let due = tiles.all()
            .filter {
                registry.connector(id: $0.key.connectorId) != nil
                    && sessions[$0.key.clockId] != nil
                    && $0.policy.isPaused == false
            }
            .map(\.key)
        launchRestock = Task { [weak self] in
            for key in due {
                guard let self else { return }
                await self.restock(key)
            }
        }
    }

    /// Runs one connector now, because the user asked.
    ///
    /// The task is owned here rather than by the button's action closure, for
    /// the same reason the timers are: teardown has to be able to wait for it.
    /// A run started by hand puts the same held banner on the clock as a
    /// scheduled one, and a quit that does not wait for it kills the process
    /// during the release and leaves the banner up.
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
        let focus = currentFocus
        let hour = currentHour
        var now: [TileKey: Bool] = [:]
        for record in tiles.all() where record.key.connectorId != VPNConnector.id {
            guard let policy = policy(of: record.key), !policy.isPaused else { continue }
            now[record.key] = policy.runs(in: focus, atHour: hour)
        }
        let change = verdicts.update(now)
        for key in change.left { retract(key) }
        for key in change.arrived where !isAudible(key.connectorId) { runNow(key) }
    }

    /// Starts the two watchers that make the corners follow the machine
    /// rather than a timer.
    ///
    /// Neither watcher answers anything — each says only that something moved,
    /// and `refreshVPNIndicators` works out what. That split is what lets the
    /// network watcher stay ignorant of VPNs: it fires on WiFi hiccups, on a
    /// cable, on waking, and every one of those is a fine moment to look.
    ///
    /// The Focus watch is allowed to fail. Opening the directory it reads costs
    /// Full Disk Access, and on a machine without it the app keeps exactly the
    /// behaviour it had before this existed: `poll()` notices the switch on its
    /// own minute.
    private func startWatchingTheWorld() {
        networkWatcher.start { [weak self] in
            Task { @MainActor in self?.refreshLamps() }
        }
        focusWatcher.start { [weak self] in
            Task { @MainActor in
                // Both, and in this order. The Focus decides which corners are
                // allowed to say anything at all, and it is also what every
                // tile's Focus rule is read against — which until now was
                // answered only on the poll's minute.
                self?.reconcileTiles()
                self?.refreshLamps()
            }
        }
    }

    /// Puts the clock's two VPN corners where the machine says they belong.
    ///
    /// Reads the process table on every call rather than caching it. The read
    /// is milliseconds and only happens on a change, and a cache would have to
    /// be invalidated by the very event this is already reacting to.
    /// Internal rather than private for the reason `reactToAFocusChange` is:
    /// the suite drives it directly, because the alternative is waiting on a
    /// real network event.
    func refreshLamps() {
        let focus = currentFocus
        let hour = currentHour
        let byClock = Dictionary(grouping: tiles.all().filter { $0.key.connectorId == VPNConnector.id }, by: \.key.clockId)
        for (clockId, vpnTiles) in byClock {
            guard let indicators = sessions[clockId]?.indicators else { continue }
            let vpn = self.vpn
            let key = nextRunKey
            nextRunKey += 1
            vpnPushes[key] = Task { [weak self] in
                var claims: [LampClaim] = []
                for record in vpnTiles {
                    guard let lamp = record.config?.lamp,
                        let reading = try? await vpn.read(config: lamp),
                        let policy = self?.policy(of: record.key)
                    else { continue }
                    claims.append(LampClaim(
                        key: record.key, slot: lamp.slot, policy: policy,
                        signal: VPNConnector.signal(for: reading)
                    ))
                }
                let covering = Set(vpnTiles.compactMap { $0.config?.lamp?.slot })
                for (slot, signal) in LampBoard.lamps(claims, covering: covering, in: focus, atHour: hour)
                    .sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                    await indicators.show(signal, on: slot)
                }
                self?.vpnPushes[key] = nil
            }
        }
    }

    /// Takes a tile's app back off its clock now, rather than letting its
    /// lifetime expire.
    ///
    /// Through the same `manualRuns` bracket `runNow` uses, for the reason that
    /// one is: teardown can only wait for a task this model is holding.
    private func retract(_ key: TileKey) {
        let runKey = nextRunKey
        nextRunKey += 1
        manualRuns[runKey] = Task { [weak self] in
            await self?.session(for: key)?.restoreDeviceState(borrowedBy: key.connectorId)
            self?.manualRuns[runKey] = nil
        }
    }

    func runNow(_ key: TileKey) {
        let runKey = nextRunKey
        nextRunKey += 1
        manualRuns[runKey] = Task { [weak self] in
            await self?.runAndReport(key)
            self?.manualRuns[runKey] = nil
        }
    }

    /// The panel's "Run now", still named by connector — it goes to the
    /// selected clock's tile, until Phase 5 draws tiles.
    func runNow(_ id: String) {
        if let key = selectedKey(id) { runNow(key) }
    }

    /// Takes this app's icons back off the flash, because the user asked.
    ///
    /// Owned here rather than by the button's action closure, for the same
    /// reason `runNow` is: teardown can only wait for a task it holds. One at a
    /// time — a second press while one is running would race two passes over
    /// the same record.
    func removeInstalledIcons() {
        guard iconRemoval == nil else { return }
        // Said before the work, not after it. `removeUploaded` sends one DELETE
        // per recorded icon, and against a device that has stopped answering
        // each one costs the transport's full 15 seconds — the same silence the
        // run button had, on a button one divider away.
        iconStatus = "removing…"
        iconRemoval = Task { [weak self] in
            await self?.reportIconRemoval()
            self?.iconRemoval = nil
        }
    }

    private func reportIconRemoval() async {
        do {
            let removed = try await installer.removeUploaded()
            iconStatus = removed.isEmpty
                ? "nothing this app uploaded"
                : "removed \(removed.joined(separator: ", "))"
        } catch let CatalogueIconInstaller.Failure.notRemoved(names) {
            iconStatus = "could not remove \(names.joined(separator: ", "))"
        } catch {
            iconStatus = "failed: \(String(describing: error).prefix(60))"
        }
    }

    /// Stops the schedules and waits for whatever they were in the middle of.
    ///
    /// Awaited, not merely cancelled. Cancelling a delivery does not release its
    /// caller: the banner it put on the clock is held until something dismisses
    /// it, and that dismiss is deliberately uncancellable so it still goes out.
    /// Returning here before the tick does would let the process die mid-release
    /// and leave the clock stuck on that banner until somebody walks over and
    /// presses the middle button.
    func teardown() async {
        monitorLoop?.cancel()
        monitorLoop = nil
        // Before anything is cancelled, so nothing new is scheduled behind the
        // teardown. Both fire from queues of their own, and a path change
        // landing halfway through this would enqueue a write to a clock the
        // app is in the middle of giving back.
        networkWatcher.stop()
        focusWatcher.stop()
        let running = Array(timers.values) + Array(manualRuns.values) + Array(replays.values)
            + Array(restores.values) + Array(vpnPushes.values)
            + [iconRemoval, launchRestock, historyLoad, microphoneWatch, panelRefresh]
            .compactMap { $0 }
        timers.removeAll()
        manualRuns.removeAll()
        replays.removeAll()
        restores.removeAll()
        vpnPushes.removeAll()
        iconRemoval = nil
        launchRestock = nil
        historyLoad = nil
        // Awaited with the rest, not merely cancelled: a release in flight puts
        // the same held banner on the clock as any other run.
        microphoneWatch = nil
        panelRefresh = nil
        for task in running { task.cancel() }
        for task in running { await task.value }
        // Last, and only once everything above has stopped. Every clock is
        // given back what this app borrowed — the weather overlay is a global
        // setting written to flash, and leaving it behind is the same defect as
        // leaving an icon on the device or a banner on the screen.
        //
        // After the cancellations rather than before them, or a delivery still
        // in flight would put the overlay straight back on after the restore
        // had taken it off. And unowned by any connector: a quit is not about
        // one of them.
        //
        // Every clock at once, inside the budget one clock had: a second clock
        // does not double what a quit may take. The TC002 slots take their
        // pages back instead of restoring anything — a TC002 owns no global
        // setting, and its pages are the app's own doing (D4: a quit leaves
        // the knob cycle empty of them).
        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values {
                if let tc002 = session as? any UlanziConnectorRunning {
                    group.addTask { await tc002.shutdown() }
                } else {
                    group.addTask { await session.restoreDeviceState(borrowedBy: nil) }
                }
            }
        }
        // And the corners, for the same reason and in the same breath.
        // Indicators live on the clock: the firmware holds them through this
        // process going away, so a quit while the work tunnel was down would
        // leave a red corner blinking on the desk with nothing left running
        // that could ever put it out.
        // And every lamp any VPN tile claims, lit or not, on every AWTRIX
        // clock — which is what the corner display did for its two
        // corners.
        let covered = Dictionary(grouping: tiles.all().filter { $0.key.connectorId == VPNConnector.id }, by: \.key.clockId)
        for (clockId, vpnTiles) in covered {
            guard let indicators = sessions[clockId]?.indicators else { continue }
            for slot in Set(vpnTiles.compactMap { $0.config?.lamp?.slot }).sorted(by: { $0.rawValue < $1.rawValue }) {
                await indicators.show(.off, on: slot)
            }
        }
    }

    private func startMonitoring() {
        monitorLoop?.cancel()
        monitorLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.poll()
                do { try await self.pollSleep(Self.monitorInterval) } catch { return }
            }
        }
    }

    /// Follows one clock to where it was found: the panel labels that are
    /// about the selected clock, and a session rebuilt at the new address.
    /// Each health has already re-pointed its own device and written the store.
    private func clockDidMove(_ clockId: UUID, to address: String) async {
        deviceHost = address
        if selectedClockId == clockId || selectedClockId == nil {
            typedHost = address
            // `typedHost` has a `didSet` that saves and then says so, and what
            // it says is "Saved — takes effect at next launch". Both halves are
            // wrong here: nobody typed, and it took effect at once.
            hostNote = nil
        }
        // The session's own device was built at the old address; it is dropped
        // so `reloadClocks` builds one at the new one. The clock's registry
        // goes with it, for the same reason: its connectors are closed over
        // the clock as it was.
        sessions[clockId] = nil
        clockRegistries[clockId] = nil
        reloadClocks()
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
    /// Lifted out of the loop rather than duplicated into `refreshOnPanelOpen`,
    /// because the reading is only half of what a poll is: the glyph's mirror,
    /// the schedules' hold reasons and the battery dialog all hang off it, and
    /// a second caller that took the reading alone would leave a panel showing
    /// a fresh percentage beside a stale hold reason.
    private func poll() async {
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
        // The clock going down or coming back changes what is holding every
        // schedule, and this is what learns it. Without the refresh the panel
        // kept naming an hour right through an outage until the next beat — up
        // to half an hour of a time the app had no intention of honouring. This
        // also stands in for the wall clock: quiet hours begin and end without
        // any loop being told, and a minute is close enough for a label about a
        // nine-hour window.
        refreshScheduleLabels()
        // In the same turn as the labels, and for the same reason: this is what
        // a fresh answer about the clock changes. A launch owes the device's
        // loop one delivery per ambient connector, and this is the first turn
        // that knows whether there is a device to give it to. Costs a set read
        // once the debt is settled, which is within a poll of every launch.
        deliverWhatTheLaunchOwes()
        // And in the same turn, because a Focus changes without any loop being
        // told: this poll is the minute hand the app has, and the alternative
        // is waiting out a connector's own cadence — up to five minutes to
        // appear when work starts, and a whole lifetime to leave when Sleep
        // does.
        reconcileTiles()
        // The safety net under the two watchers rather than the way the corners
        // normally move. Both of those are event-driven and neither is
        // guaranteed — a Focus watch needs Full Disk Access it may not have,
        // and a path change is macOS's notion of one — so the minute hand
        // reconciles whatever they missed. Costs nothing when they missed
        // nothing: the display writes only what moved.
        refreshLamps()
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

    /// Asks for what the panel is about to need: one reading, and what has
    /// played.
    ///
    /// The poll is a minute apart, so what the panel draws about the clock can
    /// be fifty-nine seconds old by the time somebody reads it. This buys the
    /// freshness back for one request per open, which is what makes the minute
    /// affordable in the first place.
    ///
    /// The history is here for a different reason, and it is about the surface
    /// BEHIND the panel rather than the panel itself; see the call below.
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
    func refreshOnPanelOpen() {
        // The History is opened from a button on the panel, so the panel coming
        // on screen is the last moment early enough for the first open to have
        // something to draw. Read here as well as on the History's own open —
        // not instead of it, because a run that happens while the panel is open
        // has to be in the list the History then shows.
        //
        // Ahead of the floor below rather than behind it. That floor is there to
        // stop a second panel open costing a second REQUEST to the clock; this
        // read reaches an actor in this process and no network at all, so
        // sharing the throttle would only mean an open inside the floor got no
        // history for a reason that is about the device.
        readHistory()
        let now = Date()
        if let last = lastPanelRefresh, now.timeIntervalSince(last) < Self.panelRefreshFloor {
            return
        }
        guard panelRefresh == nil else { return }
        lastPanelRefresh = now
        panelRefresh = Task { [weak self] in
            await self?.poll()
            self?.panelRefresh = nil
        }
    }

    /// Watches for the meeting being over, and lets the held run go.
    ///
    /// A loop of its own rather than a share of the reachability poll: they
    /// answer different questions on different cadences, and — the reason that
    /// decides it — a test driving one must be able to say which it meant. With
    /// the two folded together, "held then released" could not be told from
    /// "ran late", which is this feature's entire claim.
    ///
    /// The release is AWAITED inside the loop, so a long run cannot be overtaken
    /// by the next turn, and so teardown waiting on this task waits on the run
    /// as well.
    private func startWatchingMicrophones() {
        microphoneWatch?.cancel()
        microphoneWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.releaseHeldRuns()
                // After the release, not before it. The label the run was held
                // under is only stale once the run has gone out, and this is
                // the turn that sends it — so the panel stops blaming a
                // microphone in the same five seconds the anecdote is heard,
                // rather than at the next beat.
                self.refreshScheduleLabels()
                do { try await self.micSleep(Self.microphoneInterval) } catch { return }
            }
        }
    }

    /// Lets go of the runs a meeting held, once nothing is holding them.
    ///
    /// Gated on the whole of `scheduleHold(for:)`, not only on the microphone.
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
    private func releaseHeldRuns() async {
        let due = heldRuns.filter { scheduleHold(for: $0) == nil }
        guard due.isEmpty == false else { return }
        heldRuns.subtract(due)
        for key in due { await runAndReport(key) }
    }

    /// Brings the sessions in line with the clocks as stored.
    ///
    /// A clock gone from the list has its schedules stopped and everything it
    /// was lent given back through its own custody, then its session dropped.
    /// A clock new to the list gets a session and its tiles' schedules. Called
    /// by the Clocks settings (Phase 5) after every change they make.
    func reloadClocks() {
        let stored = ClockStore(defaults: defaults).all()
        let kept = Set(stored.map(\.id))
        for (id, session) in sessions where !kept.contains(id) {
            for key in timers.keys where key.clockId == id {
                timers.removeValue(forKey: key)?.cancel()
            }
            let restoreKey = nextRestoreKey
            nextRestoreKey += 1
            restores[restoreKey] = Task { [weak self] in
                await session.restoreDeviceState(borrowedBy: nil)
                self?.restores[restoreKey] = nil
            }
            sessions[id] = nil
            clockRegistries[id] = nil
        }
        // The healths follow the same list: a clock gone from the store has
        // no answer left to give, and a TC002 new to it probes from the next
        // poll on. (An AWTRIX clock added live still gets no health — its
        // monitor needs the battery history wiring init does, and that debt
        // is 5b's, not this one's.)
        for id in healths.keys where !kept.contains(id) { healths[id] = nil }
        for id in ulanziHealths.keys where !kept.contains(id) { ulanziHealths[id] = nil }
        for clock in stored
        where clock.model == .ulanziTC002 && ulanziHealths[clock.id] == nil {
            if let device = makeUlanziDevice(clock) {
                ulanziHealths[clock.id] = UlanziClockHealth(
                    clockId: clock.id, name: clock.name, device: device,
                    battery: makeUlanziBattery(clock)
                )
            }
        }
        // The health list moved, and the panel's dots hang off it.
        healthRevision += 1
        for clock in stored where sessions[clock.id] == nil {
            sessions[clock.id] = makeSession(clock)
        }
        clocks = stored
        if selectedClockId.map(kept.contains) != true { selectedClockId = stored.first?.id }
        for record in tiles.all() where timers[record.key] == nil && sessions[record.key.clockId] != nil {
            reschedule(record.key)
        }
        deviceHost = selectedClockId.flatMap { clock($0)?.address } ?? (stored.first?.address ?? "")
    }

    /// Builds this connector's delivery loop, replacing whatever it had.
    ///
    /// - Parameter resuming: whether the FIRST sleep is the remainder of the
    ///   interval rather than the whole of it. Set by the launch and by nothing
    ///   else; `noteNextRun` is where the remainder is worked out and where the
    ///   argument for it lives.
    /// Builds this tile's delivery loop, replacing whatever it had.
    ///
    /// - Parameter resuming: whether the FIRST sleep is the remainder of the
    ///   interval rather than the whole of it. Set by the launch and by nothing
    ///   else; `noteNextRun` is where the remainder is worked out and where the
    ///   argument for it lives.
    private func reschedule(_ key: TileKey, resuming: Bool = false) {
        timers.removeValue(forKey: key)?.cancel()
        // Whatever the replaced schedule was going to wake at is not what the
        // new one will, and a refresh landing between here and the first
        // `noteNextRun` would otherwise publish the old loop's time.
        scheduledDue[key] = nil
        // A tile whose connector the registry does not know — the VPN among
        // them, which is not a scene connector — gets no schedule here.
        guard let connector = registry.connector(id: key.connectorId),
            sessions[key.clockId] != nil
        else { return }
        guard let record = storedTile(key), record.policy.isPaused == false else {
            tileNextRun[key] = .held(Self.switchedOff)
            return
        }

        let interval = RefreshScale.snapped(TimeInterval(record.policy.refreshSeconds))
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
    private func noteNextRun(
        _ key: TileKey, interval: TimeInterval, resuming: Bool
    ) async -> TimeInterval {
        let wait = await session(for: key)?.nextDelay(
            connectorId: key.connectorId, interval: interval
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
    private func whatIsLeftOf(_ wait: TimeInterval, for key: TileKey) -> TimeInterval {
        guard let delivered = storedTile(key)?.lastDeliveredAt else { return wait }
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
    private func publishNextRun(_ key: TileKey) {
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
    private func refreshScheduleLabels() {
        for key in timers.keys { publishNextRun(key) }
    }

    /// Whether this tile's clock has been asked and did not answer.
    ///
    /// Read off the named clock's own health, rather than off the
    /// `isDeviceOnline` mirror the glyph draws from. `.unknown` is not online
    /// there either, so a schedule gated on that mirror would run nothing at
    /// all between launch and the first poll landing — and "not asked yet" is
    /// not "not there", which is the conflation `DeviceState` exists to
    /// prevent. Each clock answers for its own tiles only.
    /// Whether the SELECTED clock is answering, across both health kinds —
    /// the glyph reads one answer, whichever model the selection names.
    private func answerForSelectedClock() -> Bool {
        guard let id = selectedClockId else { return false }
        if let ulanzi = ulanziHealths[id] { return ulanzi.isOnline }
        return healths[id]?.isOnline ?? false
    }

    private func clockIsUnreachable(_ clockId: UUID) -> Bool {
        if let ulanzi = ulanziHealths[clockId] {
            if case .unreachable = ulanzi.answering { return true }
            return false
        }
        guard let health = healths[clockId] else { return false }
        if case .offline = health.monitor.state { return true }
        return false
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
    private func scheduleHold(for key: TileKey) -> String? {
        if clockIsUnreachable(key.clockId) { return Self.deviceUnreachable }
        switch policy(of: key)?.hold(in: currentFocus, atHour: currentHour) {
        case .paused?: return Self.switchedOff
        case .hours?: return Self.duringQuietHours
        case .focus?: return Self.duringFocus
        case nil: break
        }
        guard isAudible(key.connectorId) else { return nil }
        return busyMicrophone.map { MicrophoneGate.inUse($0.name) }
    }

    /// Whether this tile's own hours are what holds it — the one hold the
    /// nightly refresh may not spend through.
    private func inItsOwnQuietHours(_ key: TileKey) -> Bool {
        policy(of: key)?.hold(in: currentFocus, atHour: currentHour) == .hours
    }

    /// Whether this connector can be heard.
    ///
    /// An id nothing is registered under answers `true`, which is the same
    /// direction `Connector`'s own default takes: the recoverable mistake is
    /// staying quiet.
    private func isAudible(_ connectorId: String) -> Bool {
        registry.connector(id: connectorId)?.isAudible ?? true
    }

    /// The watched microphone that is capturing right now, or nil.
    ///
    /// Asked separately from `scheduleHold` because the two answers are put to
    /// different uses: the hold decides whether to run, and this decides
    /// whether not running was a WAIT. A meeting during an outage is still a
    /// meeting, and the run it stopped is still owed.
    private var busyMicrophone: AudioInput? {
        microphone.capturing(watching: watchedMicrophones)
    }

    private func tick(_ key: TileKey) async {
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
            if isAudible(key.connectorId), busyMicrophone != nil { heldRuns.insert(key) }
            if inItsOwnQuietHours(key) == false { await restock(key) }
            return
        }
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
            await session(for: key)?.runOnce(connectorId: key.connectorId)
                ?? .failed("no clock \(key.clockId)"),
            for: key
        )
        // And again after it, because the run is what emptied the queue. See
        // `restock(_:)`.
        await restock(key)
    }

    /// The manual path. The bracket is spelled out here as well as in `tick`
    /// rather than shared, because the shared version would be a call that
    /// marks a second time — and a count that never returns to zero is a panel
    /// stuck on `running…` for good.
    private func runAndReport(_ key: TileKey) async {
        markUnderWay(key)
        reportOutcome(
            await session(for: key)?.runOnce(connectorId: key.connectorId)
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
    private func restock(_ key: TileKey) async {
        note(
            await session(for: key)?.maintain(connectorId: key.connectorId)
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

    private func record(_ result: RunResult, for key: TileKey) {
        switch result {
        case .delivered, .skipped: tileLastFailures[key] = nil
        // Not evidence: the same rule `note` gives its own cancellation.
        case .cancelled: break
        case let .failed(message): tileLastFailures[key] = message
        }
        tileLastResults[key] = Self.words(for: result)
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
        guard let record = storedTile(key) else { return }
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
    private static func words(for result: RunResult) -> String {
        switch result {
        case .delivered: Self.deliveredWord
        case .skipped: "off"
        case .cancelled: "cancelled"
        case let .failed(message): "failed — \(TileRowLine.cause(from: message))"
        }
    }
}

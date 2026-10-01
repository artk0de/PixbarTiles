// `NSPasteboard` is AppKit's, and Copy is the one thing this model does that
// leaves the app.
import AppKit
import PixbarKit
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
///
/// Every call names a whole tile rather than a connector: two tiles of one
/// connector on one clock are two feeds, each with its own connector, settings
/// and backoff, all keyed by `tile.key.tileId`.
protocol ConnectorRunning: Sendable {
    func maintain(tile: TileRecord) async -> MaintenanceResult
    func runOnce(tile: TileRecord) async -> RunResult
    /// Plays something already produced. A replay is this and nothing else: no
    /// produce, so nothing is retired, and no outcome recorded against the
    /// connector, so the backoff is untouched.
    func deliver(_ output: AwtrixDelivery) async -> RunResult
    /// The host owns this rather than the schedule, because the answer is a
    /// function of how the last runs went and the schedule does not watch them.
    func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval
    /// Puts back the device-wide state this app borrowed — the weather overlay,
    /// and anything it added to the clock's loop.
    ///
    /// On the schedule's protocol rather than on a connector, because a
    /// connector never talks to the device and the overlay it borrows is one
    /// global setting rather than a property of any one producer.
    ///
    /// - Parameter tileId: only what this tile took, or nil for everything
    ///   outstanding, which is what a quit wants.
    func restoreDeviceState(borrowedBy tileId: String?) async

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

/// A clock slot whose pages run in an order the app has to keep: the TC002,
/// whose DIY pages run in the order they were created. Told when the user
/// reorders the tile list, so the clock follows at once rather than at the
/// next reachability poll (`UlanziClockSession.arrange`).
protocol UlanziPageOrdering: Sendable {
    func pagesReordered() async
}

/// A clock slot that can bring one tile's page on screen — for the paths the
/// USER starts (opening a tile's settings), never a schedule's (D3).
///
/// The model reaches it through `sessions` by a cast, as it reaches the
/// Ulanzi event half: both clock models conform, a lamp-only double does not.
protocol ClockPageShowing: Sendable {
    /// The tile's page while the clock carries it, or nil when it has none
    /// there — not delivered yet, or gone with a reboot.
    func page(forTile tileId: String) async throws -> String?
    /// The page on screen, or nil when the firmware cannot say (the TC002).
    func currentPage() async throws -> String?
    func showPage(_ page: String) async throws
}

extension AwtrixClockSession: ClockPageShowing {}

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

    /// The Focus the Mac is in and the hour every tile's window is read
    /// against — off the injected clock, so a test can stand at three in the
    /// morning.
    static func moment(
        focusStatus: any FocusStatusReading, now: @Sendable () -> Date
    ) -> (focus: MacFocus, hour: Int) {
        (MacFocus(reading: focusStatus), Calendar.current.component(.hour, from: now()))
    }


    /// The app-level registry: what the menus and the catalogue read.
    ///
    /// Its instances are wired for NAMING a connector, not for running one —
    /// the z.ai copy is built with `key: { nil }`, the weather copy with the
    /// first clock's place, the Claude copy with no chosen metric. Nothing
    /// produces through it. Anything that needs a connector's real OUTPUT
    /// asks `connector(for:)` instead.
    let registry: ConnectorRegistry
    /// The selected clock's health, which is what the glyph is about.
    var monitor: DeviceMonitor { clockHealthMonitor.monitor(of: selectedClockId ?? clockDirectory.firstClock?.id) }
    /// Every clock's health and the poll that asks them (`ClockHealthMonitor`).
    let clockHealthMonitor: ClockHealthMonitor
    /// The clocks, the selection and the Clocks tab's moves (`ClockDirectory`).
    let clockDirectory: ClockDirectory
    static let selectedClockKey = ClockDirectory.selectedClockKey
    typealias ClockSaveOutcome = ClockDirectory.ClockSaveOutcome
    var clocks: [ClockRecord] { clockDirectory.clocks }
    var selectedClockId: UUID? {
        get { clockDirectory.selectedClockId }
        set { clockDirectory.selectedClockId = newValue }
    }
    var hasNoClocks: Bool { clockDirectory.hasNoClocks }
    var deviceHost: String { clockDirectory.deviceHost }
    var selectedClockIsAwtrix: Bool { clockDirectory.selectedClockIsAwtrix }
    var selectedAddress: String { clockDirectory.selectedAddress }
    var typedHost: String {
        get { clockDirectory.typedHost }
        set { clockDirectory.typedHost = newValue }
    }
    var hostNote: String? { clockDirectory.hostNote }
    var typedLocation: String {
        get { clockDirectory.typedLocation }
        set { clockDirectory.typedLocation = newValue }
    }
    var locationNote: String? { clockDirectory.locationNote }
    var clocksSectionVisible: Bool { clockDirectory.clocksSectionVisible }
    func clocksSectionVisibilityChanged(_ visible: Bool) { clockDirectory.clocksSectionVisibilityChanged(visible) }
    func addClock(address raw: String) async -> ClockSaveOutcome { await clockDirectory.addClock(address: raw) }
    func addClock(from discovered: DiscoveredClock) -> ClockSaveOutcome { clockDirectory.addClock(from: discovered) }
    func renameClock(_ id: UUID, to name: String) { clockDirectory.renameClock(id, to: name) }
    func removeClock(_ id: UUID) { clockDirectory.removeClock(id) }
    func moveClock(_ source: UUID, to destination: UUID) { clockDirectory.moveClock(source, to: destination) }
    /// Relays each expert's changes as this model's own, for the facades that
    /// rebuild off `objectWillChange`.
    private var pulses: [AnyCancellable] = []
    /// One session per clock, and each clock's own registry (`ClockSessions`).
    private let clockSessions: ClockSessions
    private let tiles: TileStore
    /// Runs the tiles and keeps how each run went (`TileRunner`).
    let tileRunner: TileRunner
    /// Each tile's delivery loop and what holds it (`TileScheduler`).
    let tileScheduler: TileScheduler
    /// The tiles as stored and every move that changes them (`TileBook`).
    let tileBook: TileBook
    /// The keys and tokens tiles read through, and the GitHub tiles
    /// (`TileSecrets`).
    let tileSecrets: TileSecrets
    typealias ZaiKeyOutcome = TileSecrets.ZaiKeyOutcome
    typealias TokenOutcome = TileSecrets.TokenOutcome
    var lastZaiKeyOutcome: ZaiKeyOutcome? { tileSecrets.lastZaiKeyOutcome }
    var lastGitHubTokenOutcome: TokenOutcome? { tileSecrets.lastGitHubTokenOutcome }
    var hasGitHubToken: Bool { tileSecrets.hasGitHubToken }
    @discardableResult
    func saveZaiKey(_ typed: String, for key: TileKey) -> ZaiKeyOutcome { tileSecrets.saveZaiKey(typed, for: key) }
    func hasZaiKey(for key: TileKey) -> Bool { tileSecrets.hasZaiKey(for: key) }
    @discardableResult
    func saveGitHubToken(_ token: String) -> TokenOutcome { tileSecrets.saveGitHubToken(token) }
    func addGitHubTile(repo typed: String, to clockId: UUID) -> Bool { tileSecrets.addGitHubTile(repo: typed, to: clockId) }
    func changeGitHubRepo(_ key: TileKey, to typed: String) -> TileSaveOutcome { tileSecrets.changeGitHubRepo(key, to: typed) }
    func gitHubDiagnosis(of key: TileKey) -> GitHubDiagnosis? { tileSecrets.gitHubDiagnosis(of: key) }
    typealias TileSaveOutcome = TileBook.TileSaveOutcome
    static let newTileIntervalKey = TileBook.newTileIntervalKey
    var tileOrderRevision: Int { tileBook.tileOrderRevision }
    var tileRecords: [TileRecord] { tileBook.tileRecords }
    var newTileIntervalSeconds: Int? { tileBook.newTileIntervalSeconds }
    func setNewTileInterval(seconds: Int?) { tileBook.setNewTileInterval(seconds: seconds) }
    func connector(for key: TileKey) -> (any Connector)? { tileBook.connector(for: key) }
    func storedTile(_ key: TileKey) -> TileRecord? { tileBook.storedTile(key) }
    func storedPolicy(of key: TileKey) -> TilePolicy? { tileBook.storedPolicy(of: key) }
    func setPaused(_ paused: Bool, tile key: TileKey) { tileBook.setPaused(paused, tile: key) }
    func availability(of connectorId: String, on clockId: UUID) -> TileAvailability {
        tileBook.availability(of: connectorId, on: clockId)
    }
    func addTile(
        _ connectorId: String, to clockId: UUID, instance: String = "", config: TileConfig? = nil
    ) -> TileSaveOutcome {
        tileBook.addTile(connectorId, to: clockId, instance: instance, config: config)
    }
    func saveTile(key: TileKey, policy: TilePolicy, config: TileConfig?) -> TileSaveOutcome {
        tileBook.saveTile(key: key, policy: policy, config: config)
    }
    func changeLampVPN(_ key: TileKey, to vpnId: String) -> TileSaveOutcome { tileBook.changeLampVPN(key, to: vpnId) }
    func removeTile(_ key: TileKey) { tileBook.removeTile(key) }
    func candidate(for connectorId: String) -> TileCandidate? { tileBook.candidate(for: connectorId) }
    func tileCandidates() -> [(connectorId: String, name: String)] {
        tileBook.tileCandidates().filter { !unofferedKinds.contains($0.connectorId) }
    }
    func moveTile(_ source: TileKey, to destination: TileKey) { tileBook.moveTile(source, to: destination) }
    func tileName(of record: TileRecord) -> String { tileBook.tileName(of: record) }
    func tileTitle(of record: TileRecord) -> TileTitle { tileBook.tileTitle(of: record) }
    func detailValue(for key: TileKey) -> (name: String, config: TileConfig?)? { tileBook.detailValue(for: key) }
    var tileNextRun: [TileKey: NextRun] { tileScheduler.tileNextRun }
    func reconcileTiles() { tileScheduler.reconcileTiles() }
    func hold(of key: TileKey) -> TileHold? { tileScheduler.tileHold(of: key) }
    var tileLastResults: [TileKey: String] { tileRunner.tileLastResults }
    var tileLastFailures: [TileKey: String] { tileRunner.tileLastFailures }
    var tileLastMaintenanceFailure: [TileKey: String] { tileRunner.tileLastMaintenanceFailure }
    private let relocate: RelocatingHost?

    /// A by-tile map, seen the way the panel still reads it: the selected
    /// clock's single tiles, by connector.
    var nextRun: [String: NextRun] { projected(tileScheduler.tileNextRun) }
    /// The selected clock's run outcomes, failures and maintenance failures,
    /// by connector, for the same reason and until the same phase.
    var lastResults: [String: String] { projected(tileLastResults) }
    var lastFailures: [String: String] { projected(tileLastFailures) }
    var lastMaintenanceFailure: [String: String] { projected(tileLastMaintenanceFailure) }


    /// The selected clock's tile of this connector, which is what the panel's
    /// rows are about until Phase 5 draws tiles.
    private func selectedKey(_ connectorId: String) -> TileKey? {
        selectedClockId.map { TileKey(clockId: $0, connectorId: connectorId) }
    }

    /// A by-tile map, seen the way the panel still reads it: the selected
    /// clock's tiles, by tile id — which for a single tile is its connector id.
    ///
    /// Instances are listed only for a scene connector that is placed once per
    /// key. The lamp's instances stay out as before: the VPN is not in the
    /// registry, so it is never scheduled and its keys never reach these maps
    /// — and if one did, it would not be listed here.
    private func projected<Value>(_ byTile: [TileKey: Value]) -> [String: Value] {
        var byTileId: [String: Value] = [:]
        for (key, value) in byTile where key.clockId == selectedClockId {
            guard key.instance.isEmpty
                || registry.connector(id: key.connectorId)?.instancing == .perKey
            else { continue }
            byTileId[key.tileId] = value
        }
        return byTileId
    }


    /// What has played and the History that shows it (`AnecdoteHistory`).
    let anecdoteHistory: AnecdoteHistory
    /// The microphones the schedule waits for (`MicrophoneWatch`).
    let microphoneWatch: MicrophoneWatch
    /// The icons this app uploaded, taken back on request (`IconMaintenance`).
    let iconMaintenance: IconMaintenance
    /// The lamp tiles and the corners they light (`LampController`).
    let lampController: LampController
    var iconStatus: String? { iconMaintenance.iconStatus }
    func removeInstalledIcons() { iconMaintenance.removeInstalledIcons() }
    var watchedMicrophones: [WatchedMicrophone] { microphoneWatch.watchedMicrophones }
    var microphoneListing: [MicrophoneChoice] { microphoneWatch.microphoneListing }
    func setWatched(_ watched: Bool, for input: AudioInput) { microphoneWatch.setWatched(watched, for: input) }
    var historyIsOpen: Bool { anecdoteHistory.historyIsOpen }
    var history: [PlayedAnecdote]? { anecdoteHistory.history }
    var replayResult: String? { anecdoteHistory.replayResult }
    /// Whether the selected clock is answering — the glyph's one answer.
    var isDeviceOnline: Bool { clockHealthMonitor.isDeviceOnline }

    /// A clock's card refresh: asks that clock now (`ClockHealthMonitor.recheck`).
    func recheckClock(_ clockId: UUID) async -> ClockReachability {
        await clockHealthMonitor.recheck(clockId)
    }

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
        clockSessions.ulanzi(for: clockId)
    }
    private let defaults: UserDefaults
    private let unofferedKinds: Set<String>
    /// Whether macOS says the user is busy, and what to call it when it does.
    private let focusStatus: any FocusStatusReading
    /// The clock every tile's window is read against.
    private let now: @Sendable () -> Date
    /// Where a tile's API key lives. The record holds the handle, this holds
    /// the secret — the split the z.ai tile's whole config is built around.
    let secrets: any SecretStoring
    /// Every other task this model starts and owns (`TaskBag`): teardown can
    /// only wait for a task it holds. The names below are the work that runs
    /// under a name; everything else is one-off work that leaves the bag when
    /// it is done — a run the user asked for (two presses are two runs, and
    /// the host queues them), a replay (it puts the same held banner on the
    /// clock as a run), a restore (it writes the clock's own overlay back), a
    /// write to the lamps (triggers overlap and the display serialises them).
    private let taskBag: TaskBag

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
        // Kinds the Add tile menu leaves out though they stay registered —
        // `live()` passes every kind not `isOffered`; a test naming its own
        // connectors offers them all.
        unofferedKinds: Set<String> = [],
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        alerts: any BatteryWarningPresenting,
        focusStatus: any FocusStatusReading,
        vpn: VPNConnector = VPNConnector(isUp: { _ in false }),
        vpnPresence: VPNPresence = VPNPresence(),
        now: @escaping @Sendable () -> Date = Date.init,
        microphone: MicrophoneGate,
        watching: [WatchedMicrophone] = MicrophoneGate.defaultWatchSet,
        // The encrypted file, unless the caller names another store — the
        // suite does, because no test may touch the real one.
        secrets: any SecretStoring = EncryptedFileSecretStore.live(),
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        pollSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        micSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.tiles = tiles
        let clockSessions = ClockSessions(make: makeSession, makeRegistry: makeClockRegistry)
        self.clockSessions = clockSessions
        let clockStore = ClockStore(defaults: defaults)
        let taskBag = TaskBag()
        self.taskBag = taskBag
        self.clockHealthMonitor = ClockHealthMonitor(
            device: device, pollSleep: pollSleep, alerts: alerts, taskBag: taskBag
        )
        self.clockDirectory = ClockDirectory(
            clocks: clocks, clockStore: clockStore,
            location: StoredLocation(defaults: defaults, clockId: clocks.first?.id ?? UUID()),
            defaults: defaults, probe: probe, health: clockHealthMonitor,
            clockSessions: clockSessions, tiles: tiles
        )
        self.lampController = LampController(
            vpn: vpn, tiles: tiles, clockSessions: clockSessions, taskBag: taskBag,
            policy: { TileBook.policy(of: $0, in: tiles, registry: registry) },
            moment: { AppModel.moment(focusStatus: focusStatus, now: now) }
        )
        self.microphoneWatch = MicrophoneWatch(
            gate: microphone, watching: watching, defaults: defaults, sleep: micSleep, taskBag: taskBag
        )
        self.tileRunner = TileRunner(
            tiles: tiles, clockSessions: clockSessions, reachability: clockHealthMonitor, taskBag: taskBag
        )
        let microphoneWatch = self.microphoneWatch
        self.tileScheduler = TileScheduler(
            tiles: tiles, registry: registry, clockSessions: clockSessions, runner: tileRunner,
            reachability: clockHealthMonitor, taskBag: taskBag, sleep: sleep,
            busyMicrophone: { microphoneWatch.busyMicrophone },
            policy: { TileBook.policy(of: $0, in: tiles, registry: registry) },
            moment: { AppModel.moment(focusStatus: focusStatus, now: now) }
        )
        let scheduler = tileScheduler, runner = tileRunner
        let pageFollower = PageFollower(
            tiles: tiles, clockSessions: clockSessions, reachability: clockHealthMonitor,
            policy: { TileBook.policy(of: $0, in: tiles, registry: registry) },
            offHours: OffHoursPreview(
                isOffHours: { key in
                    let hold = scheduler.tileHold(of: key)
                    return (hold == .hours || hold == .focus) && !scheduler.isAudible(key.connectorId)
                },
                deliver: { await runner.runAndReport($0) },
                retract: { scheduler.tileLeft($0) }
            )
        )
        self.pageFollower = pageFollower
        self.tileBook = TileBook(
            tiles: tiles, registry: registry, defaults: defaults, clockSessions: clockSessions,
            lamps: lampController, scheduler: tileScheduler, runner: tileRunner, pages: pageFollower
        )
        self.tileSecrets = TileSecrets(secrets: secrets, defaults: defaults, book: tileBook)
        self.iconMaintenance = IconMaintenance(installer: installer, taskBag: taskBag)
        self.anecdoteHistory = AnecdoteHistory(
            anecdotes: anecdotes, pasteboard: pasteboard, taskBag: taskBag,
            reachability: clockHealthMonitor,
            clockCarrying: { connectorId in
                tiles.all().first { $0.key.connectorId == connectorId }?.key.clockId
            },
            session: { clockSessions[$0] }
        )
        self.relocate = relocate
        self.unofferedKinds = unofferedKinds
        self.defaults = defaults
        self.registry = registry
        self.makeUlanziDevice = makeUlanziDevice
        self.makeUlanziBattery = makeUlanziBattery
        self.focusStatus = focusStatus
        self.now = now
        self.secrets = secrets
        for clock in self.clocks {
            clockSessions.open(clock)
            // A TC002 clock's health is its own: /getBase answering, and
            // nothing else — no battery, no relocation, no stats to carry.
            guard clock.model == .awtrix3 else {
                if let device = makeUlanziDevice(clock) {
                    clockHealthMonitor.track(ulanziHealth(for: clock, device: device))
                }
                continue
            }
            let wired = makeDeviceAndHistory(clock)
            clockHealthMonitor.track(ClockHealth(
                clock: clock,
                device: wired.device,
                history: wired.history,
                relocate: relocate,
                clocks: clockStore,
                didMove: { [weak self] clockId, address in
                    await self?.clockDidMove(clockId, to: address)
                }
            ))
        }
        clockHealthMonitor.onPolled = { [weak self] in self?.pollAnswered() }
        relay(clockHealthMonitor)
        relay(anecdoteHistory)
        relay(microphoneWatch)
        relay(iconMaintenance)
        relay(pageFollower)
        relay(tileRunner)
        relay(tileScheduler)
        relay(tileBook)
        relay(tileSecrets)
        relay(clockDirectory)
        tileBook.clocks = { [unowned self] in self.clockDirectory.clocks }
        clockDirectory.onClocksChanged = { [unowned self] in self.reloadClocks() }
        tileScheduler.tileArrivalActions = TileArrivalActions(
            run: { [unowned self] in self.tileRunner.runNow($0) },
            show: { [unowned self] in self.pageFollower.showOnClock($0) },
            morningTile: { [unowned self] clockId, preferred, excluding in
                let candidates = self.tiles.all().filter {
                    $0.key.clockId == clockId && $0.key != excluding
                        && !$0.policy.isPaused && self.pageFollower.ownsPage($0.key)
                }
                return (candidates.first { $0.key.tileId == preferred } ?? candidates.first)?.key
            }
        )
    }

    // MARK: - What the user chose



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


    func setIntervalPosition(_ position: Int, for connector: any Connector) {
        guard let key = selectedKey(connector.id), let record = storedTile(key) else { return }
        // The old slider's scale, until Phase 5 moves the row onto the refresh
        // scale the policy is read through.
        tiles.update(record) {
            $0.policy.refreshSeconds = Int(IntervalScale.duration(atPosition: position))
        }
        tileScheduler.reschedule(key)
    }



    // MARK: - The lamp tiles

    func freeLampVPN(on clockId: UUID) -> WatchedVPN? { lampController.freeLampVPN(on: clockId) }

    /// Internal rather than private: the suite drives it directly, because the
    /// alternative is waiting on a real network event.
    func refreshLamps() { lampController.refreshLamps() }











    // MARK: - What the panel's facade asks for

    /// Which tile's page each clock shows, and the settings window's follow
    /// (`PageFollower`).
    let pageFollower: PageFollower
    var detailTileKey: TileKey? { pageFollower.detailTileKey }
    var tileOnScreen: [UUID: TileKey] { pageFollower.tileOnScreen }
    func openDetail(for key: TileKey) { pageFollower.openDetail(for: key) }
    /// Whether this Mac can tell Sleep from any other Focus: Focus access
    /// granted and the Do Not Disturb database readable (Full Disk Access).
    var canNameSleep: Bool {
        focusStatus.access == .authorized && focusStatus.activeMode != .cannotTell
    }
    func closeDetail() { pageFollower.closeDetail() }
    func pageSwitchesSettled() async { await pageFollower.pageSwitchesSettled() }
    func ownsPage(_ key: TileKey) -> Bool { pageFollower.ownsPage(key) }
    func ulanziWatcher(for clockId: UUID) -> (any UlanziClockWatching)? { pageFollower.ulanziWatcher(for: clockId) }
    func refreshTileOnScreen(clockId: UUID) { pageFollower.refreshTileOnScreen(clockId: clockId) }
    func showOnClock(_ key: TileKey) { pageFollower.showOnClock(key) }




    typealias PushState = TileRunner.PushState
    static let runningWord = TileRunner.runningWord
    static let deliveredWord = TileRunner.deliveredWord

    func pushState(of clockId: UUID) -> PushState { tileRunner.pushState(of: clockId) }
    func lastResult(of key: TileKey) -> String? { tileRunner.lastResult(of: key) }
    func lastFailure(of key: TileKey) -> String? { tileRunner.lastFailure(of: key) }
    func runNow(_ key: TileKey) { tileRunner.runNow(key) }
    static func words(for result: RunResult) -> String { TileRunner.words(for: result) }

    /// Moves once per poll and once per change to the health list.
    var healthRevision: Int { clockHealthMonitor.healthRevision }

    typealias ClockReachability = ClockHealthMonitor.ClockReachability

    /// The clock's reachability, from its own health (`ClockHealthMonitor`).
    func reachability(of clockId: UUID) -> ClockReachability {
        clockHealthMonitor.reachability(of: clockId)
    }







    /// A clock's reachability, as the Clocks section's row says it.
    func statusLine(of clock: ClockRecord) -> String { clockHealthMonitor.statusLine(of: clock) }

    /// A clock's battery, as the panel's statistics line says it.
    func batteryLine(of clock: ClockRecord) -> String? { clockHealthMonitor.batteryLine(of: clock) }

    /// The reading behind that line, for the panel's cards.
    func battery(of clock: ClockRecord) -> BatteryReading? { clockHealthMonitor.battery(of: clock) }




    /// Sends an expert's changes on as this model's own.
    private func relay(_ expert: some ObservableObject) {
        pulses.append(expert.objectWillChange.sink { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        })
    }

    // MARK: - History

    static let noClockCarriesTheAnecdotes = AnecdoteHistory.noClockCarriesTheAnecdotes

    func hasHistory(_ connector: any Connector) -> Bool {
        anecdoteHistory.hasHistory(connectorId: connector.id)
    }

    func openHistory() { anecdoteHistory.openHistory() }
    func loadHistory() { anecdoteHistory.loadHistory() }
    func closeHistory() { anecdoteHistory.closeHistory() }
    func windowDidClose() { anecdoteHistory.windowDidClose() }
    func replay(_ anecdote: PreparedAnecdote) { anecdoteHistory.replay(anecdote) }
    func copyText(_ anecdote: PreparedAnecdote) { anecdoteHistory.copyText(anecdote) }


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
        tileScheduler.noteLaunchDeliveries()
        clockHealthMonitor.startMonitoring()
        microphoneWatch.start { [weak self] in
            guard let self else { return }
            await self.tileScheduler.releaseHeldRuns()
            // After the release, not before it. The label the run was held
            // under is only stale once the run has gone out, and this is the
            // turn that sends it — so the panel stops blaming a microphone in
            // the same five seconds the anecdote is heard, rather than at the
            // next beat.
            self.tileScheduler.refreshScheduleLabels()
        }
        lampController.startWatching { [weak self] in self?.reconcileTiles() }
        tileScheduler.resumeAll()
        tileScheduler.restockAtLaunch()
    }





    /// The panel's "Run now", still named by connector — it goes to the
    /// selected clock's tile, until Phase 5 draws tiles.
    func runNow(_ id: String) {
        if let key = selectedKey(id) { runNow(key) }
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
        clockHealthMonitor.stopMonitoring()
        // Before anything is cancelled, so nothing new is scheduled behind the
        // teardown. Both fire from queues of their own, and a path change
        // landing halfway through this would enqueue a write to a clock the
        // app is in the middle of giving back.
        lampController.stopWatching()
        // Everything else is awaited, not merely cancelled — the microphone
        // watch included: a release in flight puts the same held banner on the
        // clock as any other run. The schedule's timers go with it.
        await taskBag.cancelAndWait(also: tileScheduler.stopAll())
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
            for (_, session) in clockSessions.all {
                if let tc002 = session as? any UlanziConnectorRunning {
                    group.addTask { await tc002.shutdown() }
                } else {
                    group.addTask { await session.restoreDeviceState(borrowedBy: nil) }
                }
            }
        }
        // And the corners, for the same reason and in the same breath.
        await lampController.turnOff()
    }

    /// Follows one clock to where it was found: the panel labels that are
    /// about the selected clock, and a session rebuilt at the new address.
    /// Each health has already re-pointed its own device and written the store.
    private func clockDidMove(_ clockId: UUID, to address: String) async {
        clockDirectory.clockMoved(clockId, to: address)
        // The session's own device was built at the old address; it is dropped
        // so `reloadClocks` builds one at the new one. The clock's registry
        // goes with it, for the same reason: its connectors are closed over
        // the clock as it was.
        clockSessions.drop(clockId)
        reloadClocks()
    }

    /// A TC002 clock's health, told how to reach the clock's session: its
    /// reachability poll is where a reboot is noticed, and the session is what
    /// puts the pages back. Looked up per tick — a session is rebuilt when the
    /// clock moves, and the health outlives that.
    private func ulanziHealth(for clock: ClockRecord, device: UlanziDevice) -> UlanziClockHealth {
        let clockId = clock.id
        return UlanziClockHealth(
            clockId: clock.id, name: clock.name, device: device,
            battery: makeUlanziBattery(clock),
            store: UserDefaultsUlanziBatteryStore(defaults: defaults, clockId: clock.id),
            watcher: { [weak self] in self?.ulanziWatcher(for: clockId) }
        )
    }


    /// Hands on everything a poll's answers change — run by the health
    /// monitor after each poll, before any battery dialog.
    private func pollAnswered() {
        tileRunner.forgetFailuresOfUnreachableClocks()
        // The clock going down or coming back changes what is holding every
        // schedule, and this is what learns it. Without the refresh the panel
        // kept naming an hour right through an outage until the next beat — up
        // to half an hour of a time the app had no intention of honouring. This
        // also stands in for the wall clock: quiet hours begin and end without
        // any loop being told, and a minute is close enough for a label about a
        // nine-hour window.
        tileScheduler.refreshScheduleLabels()
        // In the same turn as the labels, and for the same reason: this is what
        // a fresh answer about the clock changes. A launch owes the device's
        // loop one delivery per ambient connector, and this is the first turn
        // that knows whether there is a device to give it to. Costs a set read
        // once the debt is settled, which is within a poll of every launch.
        tileScheduler.deliverWhatTheLaunchOwes()
        // And in the same turn, because a Focus changes without any loop being
        // told: this poll is the minute hand the app has, and the alternative
        // is waiting out a connector's own cadence — up to five minutes to
        // appear when work starts, and a whole lifetime to leave when Sleep
        // does.
        tileScheduler.reconcileTiles()
        // The safety net under the two watchers rather than the way the corners
        // normally move. Both of those are event-driven and neither is
        // guaranteed — a Focus watch needs Full Disk Access it may not have,
        // and a path change is macOS's notion of one — so the minute hand
        // reconciles whatever they missed. Costs nothing when they missed
        // nothing: the display writes only what moved.
        refreshLamps()
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
        anecdoteHistory.readHistory()
        clockHealthMonitor.pollOnPanelOpen()
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
        for (id, session) in clockSessions.all where !kept.contains(id) {
            tileScheduler.unschedule(clockId: id)
            taskBag.run {
                await session.restoreDeviceState(borrowedBy: nil)
            }
            clockSessions.drop(id)
        }
        // The healths follow the same list.
        clockHealthMonitor.followClocks(stored) { [self] clock in
            makeUlanziDevice(clock).map { ulanziHealth(for: clock, device: $0) }
        }
        for clock in stored { clockSessions.open(clock) }
        clockDirectory.refresh(from: stored)
        for record in tiles.all() where !tileScheduler.isScheduled(record.key) && clockSessions[record.key.clockId] != nil {
            tileScheduler.reschedule(record.key)
        }
    }



}

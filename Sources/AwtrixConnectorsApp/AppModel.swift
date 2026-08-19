// `NSPasteboard` is AppKit's, and Copy is the one thing this model does that
// leaves the app.
import AppKit
import AwtrixKit
// `ObservableObject` and `@Published` are declared in Combine; Foundation
// re-exports both, so this import names the framework that owns them.
import Combine
import Foundation

/// The calls a schedule makes into the host.
///
/// Declared here rather than in the kit because scheduling is the app's job and
/// this is the app's view of what it schedules — what to do, and how long to
/// wait before doing it; no device, no registry. `ConnectorHost` satisfies it as
/// written.
protocol ConnectorRunning: Sendable {
    func maintain(connectorId: String) async -> MaintenanceResult
    func runOnce(connectorId: String) async -> RunResult
    /// Plays something already produced. A replay is this and nothing else: no
    /// produce, so nothing is retired, and no outcome recorded against the
    /// connector, so the backoff is untouched.
    func deliver(_ output: ConnectorOutput) async -> RunResult
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
}

extension ConnectorHost: ConnectorRunning {}

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
    func output(for anecdote: PreparedAnecdote) -> ConnectorOutput
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

    /// The defaults key the address is read from at launch, and the one the
    /// panel's address field writes for the next one.
    static let deviceHostKey = "deviceHost"
    static let defaultDeviceHost = "192.168.1.72"
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

    /// Read at launch and never written here. The gear's settings sheet edits
    /// the address through `DeviceHostField`, which writes the same defaults
    /// key `defaults write dev.artk0re.awtrix-connectors deviceHost` writes —
    /// either way the next launch picks it up. A settable property would have
    /// to rebuild the device, the monitor and the host underneath a running
    /// schedule, and nothing in the menu asks for that yet.
    ///
    /// Whatever is stored, `AwtrixDevice` normalises it: the hand-written path
    /// reaches no field and no validation, so a `http://10.0.0.5` typed into a
    /// terminal has to be dealt with where the URL is built.
    let deviceHost: String
    let registry: ConnectorRegistry
    let monitor: DeviceMonitor

    @Published private(set) var lastResults: [String: String] = [:]
    /// What the last background pass had to complain about, per connector, and
    /// nothing at all when it went fine.
    @Published private(set) var lastMaintenanceFailure: [String: String] = [:]
    /// When each connector is next due, or what is holding it.
    @Published private(set) var nextRun: [String: NextRun] = [:]
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
        didSet { hostNote = DeviceHostField.save(typedHost, to: defaults) }
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
        didSet { locationNote = LocationField.save(typedLocation, to: defaults) }
    }
    @Published private(set) var locationNote: String?
    /// Whether the settings are showing instead of the panel.
    @Published private(set) var settingsAreOpen = false
    /// Whether the History is showing instead of the panel.
    @Published private(set) var historyIsOpen = false
    /// What has played recently, newest first, as of the last time the History
    /// was opened.
    ///
    /// Read on opening rather than kept in step with the queue: nothing else on
    /// the panel shows it, and a run that happens while the surface is closed
    /// has no reader to tell. The list is whatever the queue still holds — the
    /// retention window bounds it, and nothing here bounds it a second time.
    @Published private(set) var history: [PlayedAnecdote] = []
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
    /// What the user chose, per connector, already resolved against the
    /// connector's own default. Published because the toggles and the slider
    /// bind to it; the store behind it is persistence, not state.
    @Published private var chosen: [String: ConnectorSettings] = [:]
    /// The hours the schedule stays quiet when macOS will not say whether a
    /// Focus is on. Published because the pickers bind to it; the defaults
    /// behind it are persistence, not state — the same split as `chosen`.
    @Published private(set) var quietHours: QuietWindow
    /// The microphones the schedule waits for. Published for the same reason
    /// `quietHours` is: the settings' tick boxes bind to it, and the defaults
    /// behind it are persistence rather than state.
    @Published private(set) var watchedMicrophones: [WatchedMicrophone]

    private let host: any ConnectorRunning
    private let store: any SettingsStore
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
    private let focus: FocusGate
    /// Whether a microphone the user cares about is capturing.
    private let microphone: MicrophoneGate
    private var timers: [String: Task<Void, Never>] = [:]
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
    /// `ConnectorHost` serialises the pair rather than merging them. With only
    /// a flag, the first run finishing writes its outcome while the second is
    /// still in flight — the panel claiming a finished delivery during a
    /// running one, which is the lie this whole line of fixes is about.
    private var outstanding: [String: Int] = [:]
    /// Connectors whose scheduled run is waiting out a meeting.
    ///
    /// A SET, and that is the rule rather than a container choice: at most one
    /// run is held per connector, so a two-hour meeting that swallows four
    /// beats releases one anecdote rather than firing four in a burst the
    /// moment it ends. A second beat arriving while one is already held inserts
    /// nothing.
    private var heldRuns: Set<String> = []
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
    private var scheduledDue: [String: Date] = [:]
    /// The loop that lets them go.
    private var microphoneWatch: Task<Void, Never>?
    private var iconRemoval: Task<Void, Never>?

    init(
        deviceHost: String,
        device: AwtrixDevice,
        registry: ConnectorRegistry,
        host: any ConnectorRunning,
        store: any SettingsStore,
        installer: CatalogueIconInstaller,
        anecdotes: (any AnecdoteReplaying)? = nil,
        defaults: UserDefaults = .standard,
        pasteboard: NSPasteboard = .general,
        alerts: any BatteryWarningPresenting,
        focus: FocusGate,
        quietHours: QuietWindow = .default,
        microphone: MicrophoneGate,
        watching: [WatchedMicrophone] = MicrophoneGate.defaultWatchSet,
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        pollSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        micSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.deviceHost = deviceHost
        self.typedHost = deviceHost
        self.typedLocation = LocationField.text(for: Coordinates.stored(in: defaults))
        self.defaults = defaults
        self.pasteboard = pasteboard
        self.registry = registry
        self.monitor = DeviceMonitor(device: device)
        self.host = host
        self.store = store
        self.installer = installer
        self.anecdotes = anecdotes
        self.alerts = alerts
        self.focus = focus
        self.quietHours = quietHours
        self.microphone = microphone
        self.watchedMicrophones = watching
        self.scheduleSleep = sleep
        self.pollSleep = pollSleep
        self.micSleep = micSleep
        for connector in registry.all {
            chosen[connector.id] = Self.resolved(connector, in: store)
        }
    }

    /// The composition root: one device host in, every collaborator wired.
    ///
    /// `transport` is a parameter because it is this app's one door to the
    /// outside: naming it here is what lets the wiring below be checked without
    /// a clock on the network.
    static func live(
        defaults: UserDefaults = .standard,
        transport: any Transport = URLSessionTransport(),
        anecdoteStore: URL = AppPaths.anecdoteStore
    ) -> AppModel {
        let deviceHost = defaults.string(forKey: deviceHostKey) ?? defaultDeviceHost
        let device = AwtrixDevice(host: deviceHost, transport: transport)
        let registry = ConnectorRegistry()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let installer = CatalogueIconInstaller(
            device: device,
            transport: transport,
            uploads: UserDefaultsUploadedIconStore(defaults: defaults)
        )

        let anecdotes = anecdoteWiring(transport: transport, storeURL: anecdoteStore)
        registry.register(anecdotes.connector)
        // The location is read on every produce rather than captured here, so a
        // pair typed into the settings takes effect at the next poll instead of
        // at the next launch. One source of weather for the whole app: the
        // source caches its own answers, and a second instance would poll a
        // free public service twice as often for the same reading.
        let location = StoredLocation(defaults: defaults)
        registry.register(
            WeatherConnector(
                source: OpenMeteoSource(transport: transport),
                location: { location.current }
            )
        )

        return AppModel(
            deviceHost: deviceHost,
            device: device,
            registry: registry,
            host: ConnectorHost(
                device: device,
                registry: registry,
                store: store,
                audio: SequentialAudioPlayer(),
                iconInstaller: installer,
                // Durable, for the reason the uploaded-icon record is: what
                // this app did to the device is not knowable by looking at the
                // device afterwards. One exit without a teardown and an
                // in-memory record turns this app's own weather overlay into
                // the value it restores for ever.
                borrowedOverlays: UserDefaultsBorrowedOverlayStore(defaults: defaults)
            ),
            store: store,
            installer: installer,
            anecdotes: anecdotes.connector,
            defaults: defaults,
            alerts: BatteryAlert(
                dialog: ModalBatteryDialog(), notifications: SystemBatteryNotifier()
            ),
            focus: FocusGate(status: SystemFocusStatus()),
            quietHours: QuietWindow.stored(in: defaults),
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

    /// What this connector is set to.
    ///
    /// Keyed by the connector rather than by its id, because the fallback is the
    /// connector's own `defaultInterval` and an id cannot answer that. The store
    /// folds "never configured" into `ConnectorSettings()` — thirty minutes —
    /// which is a decision it has no standing to make on a connector's behalf.
    func settings(for connector: any Connector) -> ConnectorSettings {
        chosen[connector.id] ?? Self.resolved(connector, in: store)
    }

    private static func resolved(
        _ connector: any Connector, in store: any SettingsStore
    ) -> ConnectorSettings {
        store.storedSettings(for: connector.id)
            ?? ConnectorSettings(
                intervalPosition: IntervalScale.position(for: connector.defaultInterval)
            )
    }

    func setEnabled(_ enabled: Bool, for connector: any Connector) {
        var current = settings(for: connector)
        current.isEnabled = enabled
        commit(current, for: connector)
    }

    func setIntervalPosition(_ position: Int, for connector: any Connector) {
        var current = settings(for: connector)
        current.intervalPosition = position
        commit(current, for: connector)
    }

    /// Saved from the RESOLVED settings, never from the store's own fallback: a
    /// connector whose default is five minutes would otherwise be written to
    /// disk as thirty the first time its toggle was touched, and the default it
    /// declares would never be seen again.
    private func commit(_ settings: ConnectorSettings, for connector: any Connector) {
        let wasEnabled = chosen[connector.id]?.isEnabled ?? true
        chosen[connector.id] = settings
        store.save(settings, for: connector.id)
        reschedule(connector)
        // Only on the way OFF, and only on the edge. A connector switched off
        // stops running, so nothing else will ever put back what it borrowed —
        // where switching one ON borrows nothing until its first delivery, and
        // a restore there would write a value that is already on the device.
        // Dragging the interval slider is neither, and must not touch the clock
        // at all.
        if wasEnabled && !settings.isEnabled { giveBackDeviceState(connector.id) }
    }

    /// Puts back what one connector borrowed from the clock.
    ///
    /// The task is owned here rather than left detached, for the reason every
    /// other one is: teardown can only wait for a task it holds, and this one
    /// writes to the device. Keyed by nothing meaningful — switching a
    /// connector off twice is two restores, and the second finds nothing left
    /// to give back.
    private func giveBackDeviceState(_ id: String) {
        let key = nextRestoreKey
        nextRestoreKey += 1
        restores[key] = Task { [weak self] in
            await self?.host.restoreDeviceState(borrowedBy: id)
            self?.restores[key] = nil
        }
    }

    /// Which rule decides whether the schedule may speak, right now.
    ///
    /// Asked rather than stored, because the answer changes underneath the app:
    /// a permission granted in System Settings while this is running moves it
    /// from the window to the system without anything here being told.
    var focusRule: QuietRule { focus.rule(quietHours: quietHours) }

    /// Sets the hours the schedule stays quiet while macOS will not say
    /// whether a Focus is on.
    ///
    /// Saved on every change rather than on submit, for the reason `typedHost`
    /// is: there is nothing to confirm, and a picker that looks saved and is
    /// not is worse than one that never looked saved. Unlike the address, this
    /// takes effect on the next beat rather than the next launch — the gate
    /// reads the window from here every time it is asked, so there is no second
    /// copy to keep in step.
    func setQuietHours(_ window: QuietWindow) {
        quietHours = window
        window.save(to: defaults)
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

    // MARK: - Settings

    /// Shows the settings in place of the panel.
    ///
    /// A view, not a mode. Nothing is stopped and nothing is paused: the
    /// schedule, the reachability poll and any run in flight carry on behind it,
    /// which is why this is a published flag and not a teardown.
    func openSettings() { settingsAreOpen = true }

    func closeSettings() { settingsAreOpen = false }

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
    /// instant the button is pressed, so on the FIRST open `history` is still
    /// the empty array it started as — and an empty array is what the surface
    /// draws as "Nothing has played yet", which is a wrong answer rather than a
    /// pending one. Every open after that draws the entries at once, off the
    /// answer the first open eventually got, which is exactly the asymmetry that
    /// was reported: the History showing what played only on the second press.
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
    /// Both surfaces, not one. They were consistent with each other — each
    /// outlived the window — which is how clicking away from the History and
    /// clicking back returned to the History, and consistent is not the same as
    /// right. A menu bar item is clicked to answer "is the clock alive, and
    /// what is next"; a list of old jokes answers a question nobody asked.
    ///
    /// Not a teardown. Nothing is stopped and nothing is cancelled — the
    /// schedule, the poll and any replay in flight carry on behind a window
    /// that is not on screen, exactly as they carry on behind a surface that
    /// is.
    func windowDidClose() {
        settingsAreOpen = false
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
    func replay(_ anecdote: PreparedAnecdote) {
        guard let anecdotes, anecdote.isPlayable else { return }
        let output = anecdotes.output(for: anecdote)
        let key = nextReplayKey
        nextReplayKey += 1
        replays[key] = Task { [weak self] in
            let result = await self?.host.deliver(output)
            // Kept, where the run line and the failure count are still not
            // touched. Those two are what the discarded result was ever
            // discarded for; the History is a third place, and it is the one
            // the button was pressed on.
            if let result { self?.replayResult = Self.words(for: result) }
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
        // `FocusGate.rule`, on every turn of every schedule.
        focus.requestAccess()
        startMonitoring()
        startWatchingMicrophones()
        for connector in registry.all { reschedule(connector) }
        restockAtLaunch()
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
        let due = registry.all.filter { settings(for: $0).isEnabled }.map(\.id)
        launchRestock = Task { [weak self] in
            for id in due {
                guard let self else { return }
                await self.restock(id)
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
    func runNow(_ id: String) {
        let key = nextRunKey
        nextRunKey += 1
        manualRuns[key] = Task { [weak self] in
            await self?.runAndReport(id)
            self?.manualRuns[key] = nil
        }
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
        let running = Array(timers.values) + Array(manualRuns.values) + Array(replays.values)
            + Array(restores.values)
            + [iconRemoval, launchRestock, historyLoad, microphoneWatch, panelRefresh]
            .compactMap { $0 }
        timers.removeAll()
        manualRuns.removeAll()
        replays.removeAll()
        restores.removeAll()
        iconRemoval = nil
        launchRestock = nil
        historyLoad = nil
        // Awaited with the rest, not merely cancelled: a release in flight puts
        // the same held banner on the clock as any other run.
        microphoneWatch = nil
        panelRefresh = nil
        for task in running { task.cancel() }
        for task in running { await task.value }
        // Last, and only once everything above has stopped. The clock is given
        // back what this app borrowed — the weather overlay is a global setting
        // written to flash, and leaving it behind is the same defect as leaving
        // an icon on the device or a banner on the screen.
        //
        // After the cancellations rather than before them, or a delivery still
        // in flight would put the overlay straight back on after the restore
        // had taken it off. And unowned by any connector: a quit is not about
        // one of them.
        await host.restoreDeviceState(borrowedBy: nil)
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

    /// Asks the clock how it is, once, and hands on everything that answer
    /// changes.
    ///
    /// Lifted out of the loop rather than duplicated into `refreshOnPanelOpen`,
    /// because the reading is only half of what a poll is: the glyph's mirror,
    /// the schedules' hold reasons and the battery dialog all hang off it, and
    /// a second caller that took the reading alone would leave a panel showing
    /// a fresh percentage beside a stale hold reason.
    private func poll() async {
        // The instant is spelled out here rather than defaulted inside the
        // monitor: this app is what decides when a reading was taken, and the
        // trajectory's whole answer is a function of when as much as of what.
        let crossed = await monitor.refresh(at: Date())
        isDeviceOnline = monitor.isOnline
        // The clock going down or coming back changes what is holding every
        // schedule, and this is what learns it. Without the refresh the panel
        // kept naming an hour right through an outage until the next beat — up
        // to half an hour of a time the app had no intention of honouring. This
        // also stands in for the wall clock: quiet hours begin and end without
        // any loop being told, and a minute is close enough for a label about a
        // nine-hour window.
        refreshScheduleLabels()
        // Awaited here rather than detached. The dialog does not block — it
        // schedules itself — and what is awaited is the authorization request,
        // which happens once. A detached task would be one more thing teardown
        // cannot wait for, for a warning that fires four times in the life of a
        // charge.
        if let crossed { await alerts.warn(crossed) }
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
        for id in due { await runAndReport(id) }
    }

    private func reschedule(_ connector: any Connector) {
        timers.removeValue(forKey: connector.id)?.cancel()
        // Whatever the replaced schedule was going to wake at is not what the
        // new one will, and a refresh landing between here and the first
        // `noteNextRun` would otherwise publish the old loop's time.
        scheduledDue[connector.id] = nil
        let settings = settings(for: connector)
        guard settings.isEnabled else {
            nextRun[connector.id] = .held(Self.switchedOff)
            return
        }

        let id = connector.id
        let interval = settings.interval
        let sleep = self.scheduleSleep
        timers[id] = Task { [weak self] in
            while !Task.isCancelled {
                // Asked every turn, not once when the schedule is built. The
                // answer is the interval until this connector starts failing,
                // and a loop that read it up front would never see the backoff
                // it exists to apply. Optional-chained rather than unwrapped so
                // a released model is not held alive across the sleep by its
                // own timer.
                guard
                    let delay = await self?.noteNextRun(id, interval: interval)
                else { return }
                // The sleep comes first, so enabling a connector — or launching
                // the app, which reschedules every one of them — does not fire a
                // delivery on the spot.
                do { try await sleep(delay) } catch { return }
                // Returned on, not swallowed. A cancelled sleep is the quit
                // path, and carrying on into the tick would start one more
                // delivery while the app is being torn down.
                guard let self else { return }
                await self.tick(id)
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
    private func noteNextRun(_ id: String, interval: TimeInterval) async -> TimeInterval {
        let delay = await host.nextDelay(connectorId: id, interval: interval)
        // Asked even while the clock is unreachable, and the answer is still
        // slept: the pause is not sticky, the beat is kept, and the first tick
        // after the device answers delivers. What changes is only what the
        // panel is told — naming an hour for a run that will not happen is the
        // failure `.held` exists to avoid, and the user plans around it.
        //
        // The single writer of the DUE TIME, and only of that. The hold half of
        // the label has three other clocks that can change it, and they refresh
        // it themselves through `publishNextRun` below.
        scheduledDue[id] = Date().addingTimeInterval(delay)
        publishNextRun(id)
        return delay
    }

    /// Writes one connector's line from what is true now.
    ///
    /// The single place `nextRun` is written for a connector that has a
    /// schedule, so the label cannot disagree with itself depending on which of
    /// the three loops last ticked. A hold outranks the time, because a time
    /// named while something is in force is the lie the user plans around.
    ///
    /// A connector with no timer is one the user switched off, and that line
    /// belongs to `reschedule`: it is the only state a live clock cannot
    /// change, and overwriting it here would put an hour back on a row the user
    /// has turned off.
    private func publishNextRun(_ id: String) {
        guard timers[id] != nil else { return }
        if let hold = scheduleHold(for: id) {
            nextRun[id] = .held(hold)
        } else if let due = scheduledDue[id] {
            nextRun[id] = .due(due)
        }
    }

    /// Brings every scheduled connector's line up to date with the gates.
    ///
    /// Called from the two loops that already turn faster than a schedule does
    /// — the reachability poll at a minute and the microphone watch at five
    /// seconds — rather than from a clock of its own. Nothing here runs a
    /// connector or touches a gate's decision; it only re-reads the answer the
    /// panel is showing.
    private func refreshScheduleLabels() {
        for id in timers.keys { publishNextRun(id) }
    }

    /// Whether the clock has been asked and did not answer.
    ///
    /// Read off the monitor's three-state answer rather than off the
    /// `isDeviceOnline` mirror the glyph draws from. `.unknown` is not online
    /// there either, so a schedule gated on that mirror would run nothing at
    /// all between launch and the first poll landing — and "not asked yet" is
    /// not "not there", which is the conflation `DeviceState` exists to
    /// prevent.
    private var deviceIsUnreachable: Bool {
        if case .offline = monitor.state { return true }
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
    private func scheduleHold(for connectorId: String) -> String? {
        if deviceIsUnreachable { return Self.deviceUnreachable }
        guard isAudible(connectorId) else { return nil }
        if let quiet = focus.silence(quietHours: quietHours) { return quiet }
        return busyMicrophone.map { MicrophoneGate.inUse($0.name) }
    }

    /// Whether this connector can be heard.
    ///
    /// An id nothing is registered under answers `true`, which is the same
    /// direction `Connector`'s own default takes: the recoverable mistake is
    /// staying quiet.
    private func isAudible(_ connectorId: String) -> Bool {
        registry.connector(id: connectorId)?.isAudible ?? true
    }

    /// Whether the user's own quiet hours are what is silencing the app right
    /// now.
    ///
    /// Asked apart from `scheduleHold(for:)` because it decides a different
    /// question: not whether to deliver, but whether to SPEND. Read through the
    /// gate rather than off the wall clock, so it uses the same instant every
    /// other quiet decision does.
    private var duringTheQuietWindow: Bool {
        focus.silence(quietHours: quietHours) == FocusGate.duringQuietHours
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

    private func tick(_ id: String) async {
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
        guard scheduleHold(for: id) == nil else {
            if isAudible(id), busyMicrophone != nil { heldRuns.insert(id) }
            if duringTheQuietWindow == false { await restock(id) }
            return
        }
        // Marked before the maintain, not between it and the run. `maintain` IS
        // the expensive half — a refill loads a 1.8 GB model and synthesizes a
        // whole batch, a minute or more — and once it has run, `runOnce` finds a
        // full queue and is quick. Written after it, the marker lands exactly
        // where the wait is already over, and the panel shows the PREVIOUS run's
        // outcome for the whole minute.
        markUnderWay(id)
        // Top up BEFORE the run, never inside it. `produce()` only awaits a
        // refill when the queue is empty, so a timer that never maintains turns
        // every firing into a 70-second model load on the play path — the whole
        // reason the queue exists.
        await restock(id)
        reportOutcome(await host.runOnce(connectorId: id), for: id)
        // And again after it, because the run is what emptied the queue. See
        // `restock(_:)`.
        await restock(id)
    }

    /// The manual path. The bracket is spelled out here as well as in `tick`
    /// rather than shared, because the shared version would be a call that
    /// marks a second time — and a count that never returns to zero is a panel
    /// stuck on `running…` for good.
    private func runAndReport(_ id: String) async {
        markUnderWay(id)
        reportOutcome(await host.runOnce(connectorId: id), for: id)
        await restock(id)
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
    /// `ConnectorHost` already answers `.skipped` for a connector the user
    /// switched off.
    private func restock(_ id: String) async {
        note(await host.maintain(connectorId: id), for: id)
    }

    /// Says a delivery is under way before it says how it went.
    ///
    /// Measured on the machine this was written on: a run against an empty
    /// queue takes 37.6 s, because `produce()` refills inline when it has
    /// nothing to hand out and the first refill of a process pays a 30-second
    /// model load. Without this the panel shows nothing for all of it — the
    /// outcome is the only thing ever written, and it arrives at the end — so a
    /// "Run now" reads as a button that does nothing.
    private func markUnderWay(_ id: String) {
        outstanding[id, default: 0] += 1
        lastResults[id] = "running…"
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
    private func reportOutcome(_ result: RunResult, for id: String) {
        outstanding[id, default: 1] -= 1
        guard outstanding[id, default: 0] <= 0 else { return }
        record(result, for: id)
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
    private func note(_ result: MaintenanceResult, for id: String) {
        switch result {
        case .completed, .skipped: lastMaintenanceFailure[id] = nil
        case .cancelled: break
        case let .failed(message):
            lastMaintenanceFailure[id] = "restock failed: \(message.prefix(60))"
        }
    }

    private func record(_ result: RunResult, for id: String) {
        lastResults[id] = Self.words(for: result)
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
        case .delivered: "delivered"
        case .skipped: "off"
        case .cancelled: "cancelled"
        case let .failed(message): "failed: \(message.prefix(60))"
        }
    }
}

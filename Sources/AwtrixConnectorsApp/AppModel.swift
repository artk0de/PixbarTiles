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
    /// The host owns this rather than the schedule, because the answer is a
    /// function of how the last runs went and the schedule does not watch them.
    func nextDelay(connectorId: String, interval: TimeInterval) async -> TimeInterval
}

extension ConnectorHost: ConnectorRunning {}

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
    static let monitorInterval: TimeInterval = 20
    /// What holds the schedule of a connector the user switched off.
    static let switchedOff = "off"

    /// Read at launch and never written here — the panel has no editor for it.
    /// A different clock is pointed at with
    /// `defaults write dev.artk0re.awtrix-connectors deviceHost 192.168.1.99`,
    /// which the next launch picks up. A settable property would have to rebuild
    /// the device, the monitor and the host underneath a running schedule, and
    /// nothing in the menu asks for that yet.
    let deviceHost: String
    let registry: ConnectorRegistry
    let monitor: DeviceMonitor

    @Published private(set) var lastResults: [String: String] = [:]
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
    /// Whether the settings are showing instead of the panel.
    @Published private(set) var settingsAreOpen = false
    @Published private(set) var iconStatus: String?
    /// Mirrored from `monitor` rather than read through it, because the poll
    /// below is what learns the answer and a view that wants only the glyph
    /// should not have to observe a second object to get it.
    @Published private(set) var isDeviceOnline = false
    /// What the user chose, per connector, already resolved against the
    /// connector's own default. Published because the toggles and the slider
    /// bind to it; the store behind it is persistence, not state.
    @Published private var chosen: [String: ConnectorSettings] = [:]

    private let host: any ConnectorRunning
    private let store: any SettingsStore
    private let installer: CatalogueIconInstaller
    private let defaults: UserDefaults
    /// The delivery cadence, one sleeper per scheduled connector.
    private let scheduleSleep: Sleeping
    /// The reachability cadence, one sleeper for the whole app. Separate from
    /// `scheduleSleep` because they are two clocks, not one: a fixed 20-second
    /// poll and a per-connector interval the user chooses and the retry policy
    /// bends. Kept apart so that whoever drives one can say which one they
    /// meant — an aggregate cannot, and a test waiting on "something is asleep"
    /// gets whichever loop won the race.
    private let pollSleep: Sleeping
    private var timers: [String: Task<Void, Never>] = [:]
    private var monitorLoop: Task<Void, Never>?
    /// Runs the user asked for, still going. Keyed by nothing meaningful: two
    /// presses of the same button are two runs, and the host queues them behind
    /// each other rather than one replacing the other.
    private var manualRuns: [Int: Task<Void, Never>] = [:]
    private var nextRunKey = 0
    /// Runs still going, per connector.
    ///
    /// A count rather than a flag because two presses are two runs: 37 seconds
    /// of silence is exactly the thing that makes a person press again, and
    /// `ConnectorHost` serialises the pair rather than merging them. With only
    /// a flag, the first run finishing writes its outcome while the second is
    /// still in flight — the panel claiming a finished delivery during a
    /// running one, which is the lie this whole line of fixes is about.
    private var outstanding: [String: Int] = [:]
    private var iconRemoval: Task<Void, Never>?

    init(
        deviceHost: String,
        device: AwtrixDevice,
        registry: ConnectorRegistry,
        host: any ConnectorRunning,
        store: any SettingsStore,
        installer: CatalogueIconInstaller,
        defaults: UserDefaults = .standard,
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) },
        pollSleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.deviceHost = deviceHost
        self.typedHost = deviceHost
        self.defaults = defaults
        self.registry = registry
        self.monitor = DeviceMonitor(device: device)
        self.host = host
        self.store = store
        self.installer = installer
        self.scheduleSleep = sleep
        self.pollSleep = pollSleep
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

        return AppModel(
            deviceHost: deviceHost,
            device: device,
            registry: registry,
            host: ConnectorHost(
                device: device,
                registry: registry,
                store: store,
                audio: SequentialAudioPlayer(),
                iconInstaller: installer
            ),
            store: store,
            installer: installer,
            defaults: defaults
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
        storeURL: URL = AppPaths.anecdoteStore
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
        let queue = AnecdoteQueue(storeURL: storeURL, clipRoot: clipRoot)
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
        chosen[connector.id] = settings
        store.save(settings, for: connector.id)
        reschedule(connector)
    }

    // MARK: - Settings

    /// Shows the settings in place of the panel.
    ///
    /// A view, not a mode. Nothing is stopped and nothing is paused: the
    /// schedule, the reachability poll and any run in flight carry on behind it,
    /// which is why this is a published flag and not a teardown.
    func openSettings() { settingsAreOpen = true }

    func closeSettings() { settingsAreOpen = false }

    // MARK: - Running

    /// Starts the poll and the schedules. Separate from `init` so that
    /// constructing this type reaches neither the network nor the clock.
    func start() {
        startMonitoring()
        for connector in registry.all { reschedule(connector) }
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
        let running = Array(timers.values) + Array(manualRuns.values)
            + [iconRemoval].compactMap { $0 }
        timers.removeAll()
        manualRuns.removeAll()
        iconRemoval = nil
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    private func startMonitoring() {
        monitorLoop?.cancel()
        monitorLoop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.monitor.refresh()
                self.isDeviceOnline = self.monitor.isOnline
                do { try await self.pollSleep(Self.monitorInterval) } catch { return }
            }
        }
    }

    private func reschedule(_ connector: any Connector) {
        timers.removeValue(forKey: connector.id)?.cancel()
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
        nextRun[id] = .due(Date().addingTimeInterval(delay))
        return delay
    }

    private func tick(_ id: String) async {
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
        _ = await host.maintain(connectorId: id)
        reportOutcome(await host.runOnce(connectorId: id), for: id)
    }

    /// The manual path. The bracket is spelled out here as well as in `tick`
    /// rather than shared, because the shared version would be a call that
    /// marks a second time — and a count that never returns to zero is a panel
    /// stuck on `running…` for good.
    private func runAndReport(_ id: String) async {
        markUnderWay(id)
        reportOutcome(await host.runOnce(connectorId: id), for: id)
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

    private func record(_ result: RunResult, for id: String) {
        switch result {
        case .delivered: lastResults[id] = "delivered"
        case .skipped: lastResults[id] = "off"
        case .cancelled: lastResults[id] = "cancelled"
        case let .failed(message): lastResults[id] = "failed: \(message.prefix(60))"
        }
    }
}

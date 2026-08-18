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

    static let deviceHostKey = "deviceHost"
    static let defaultDeviceHost = "192.168.1.72"
    /// How often reachability is re-asked. Not a user setting: it costs one
    /// request and the answer drives a glyph, not a delivery.
    static let monitorInterval: TimeInterval = 20

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
    private let sleep: Sleeping
    private var timers: [String: Task<Void, Never>] = [:]
    private var monitorLoop: Task<Void, Never>?
    /// Runs the user asked for, still going. Keyed by nothing meaningful: two
    /// presses of the same button are two runs, and the host queues them behind
    /// each other rather than one replacing the other.
    private var manualRuns: [Int: Task<Void, Never>] = [:]
    private var nextRunKey = 0

    init(
        deviceHost: String,
        device: AwtrixDevice,
        registry: ConnectorRegistry,
        host: any ConnectorRunning,
        store: any SettingsStore,
        installer: CatalogueIconInstaller,
        sleep: @escaping Sleeping = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.deviceHost = deviceHost
        self.registry = registry
        self.monitor = DeviceMonitor(device: device)
        self.host = host
        self.store = store
        self.installer = installer
        self.sleep = sleep
        for connector in registry.all {
            chosen[connector.id] = Self.resolved(connector, in: store)
        }
    }

    /// The composition root: one device host in, every collaborator wired.
    static func live(defaults: UserDefaults = .standard) -> AppModel {
        let deviceHost = defaults.string(forKey: deviceHostKey) ?? defaultDeviceHost
        let transport = URLSessionTransport()
        let device = AwtrixDevice(host: deviceHost, transport: transport)
        let registry = ConnectorRegistry()
        let store = UserDefaultsSettingsStore(defaults: defaults)
        let installer = CatalogueIconInstaller(
            device: device,
            transport: transport,
            uploads: UserDefaultsUploadedIconStore(defaults: defaults)
        )

        // One root, handed to the synthesizer as the place to write and to the
        // queue as the boundary its reaper may delete inside.
        let speech = SidecarSpeechSynthesizer(
            pythonPath: NSString(string: "~/.local/share/tts-voices/.venv/bin/python")
                .expandingTildeInPath,
            scriptPath: NSString(string: "~/.local/share/tts-voices/speak.py")
                .expandingTildeInPath,
            workingDirectory: NSString(string: "~/.local/share/tts-voices")
                .expandingTildeInPath,
            outputDirectory: AppPaths.clipRoot
        )
        let queue = AnecdoteQueue(storeURL: AppPaths.anecdoteStore, clipRoot: AppPaths.clipRoot)
        registry.register(
            AnecdoteConnector(
                queue: queue,
                preparer: AnecdotePreparer(
                    source: AnecdoteSource(transport: transport), speech: speech, queue: queue
                )
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
                iconInstaller: installer
            ),
            store: store,
            installer: installer
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

    func removeInstalledIcons() async {
        do {
            let removed = try await installer.removeUploaded()
            iconStatus = removed.isEmpty
                ? "nothing this app uploaded"
                : "removed \(removed.joined(separator: ", "))"
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
        timers.removeAll()
        manualRuns.removeAll()
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
                do { try await self.sleep(Self.monitorInterval) } catch { return }
            }
        }
    }

    private func reschedule(_ connector: any Connector) {
        timers.removeValue(forKey: connector.id)?.cancel()
        let settings = settings(for: connector)
        guard settings.isEnabled else { return }

        let id = connector.id
        let interval = settings.interval
        let sleep = self.sleep
        timers[id] = Task { [weak self] in
            while !Task.isCancelled {
                // Asked every turn, not once when the schedule is built. The
                // answer is the interval until this connector starts failing,
                // and a loop that read it up front would never see the backoff
                // it exists to apply. Optional-chained rather than unwrapped so
                // a released model is not held alive across the sleep by its
                // own timer.
                guard
                    let delay = await self?.host.nextDelay(
                        connectorId: id, interval: interval
                    )
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

    private func tick(_ id: String) async {
        // Top up BEFORE the run, never inside it. `produce()` only awaits a
        // refill when the queue is empty, so a timer that never maintains turns
        // every firing into a 70-second model load on the play path — the whole
        // reason the queue exists.
        _ = await host.maintain(connectorId: id)
        await runAndReport(id)
    }

    /// Says that a delivery is under way before it says how it went.
    ///
    /// Measured on the machine this was written on: a run against an empty
    /// queue takes 37.6 s, because `produce()` refills inline when it has
    /// nothing to hand out and the first refill of a process pays a 30-second
    /// model load. Without this line the panel shows nothing for all of it —
    /// the outcome is the only thing ever written, and it arrives at the end —
    /// so a "Run now" reads as a button that does nothing.
    private func runAndReport(_ id: String) async {
        lastResults[id] = "running…"
        record(await host.runOnce(connectorId: id), for: id)
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

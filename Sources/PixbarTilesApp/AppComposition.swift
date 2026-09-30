import AppKit
import PixbarKit
import Combine
import Foundation

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

/// The composition root: the one place the real app's collaborators are
/// built and handed to the model. Creator for every expert the model holds —
/// `init` wires them, this decides what they are made of.
extension AppModel {
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
        // z.ai and GitHub, offered so the Add tile menu can name them; each
        // clock's session builds its own from the tile's record.
        let secrets = EncryptedFileSecretStore.live()
        ConnectorFactories.namingInstances(transport: transport).forEach(registry.register)

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
        SecretsMigration(defaults: defaults, keychain: LoginKeychainStore(), secrets: secrets).run()

        // One shared audio player and one shared weather source; everything
        // else below is per clock.
        let audio = SequentialAudioPlayer()
        let factories = ConnectorFactories(
            transport: transport, defaults: defaults, secrets: secrets,
            weather: OpenMeteoSource(transport: transport), anecdotes: anecdotes.connector
        )
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
                    registry: factories.registry(for: clock),
                    store: TileSettingsStore(defaults: defaults, clockId: clock.id),
                    liveTiles: { [slotTiles, clockId = clock.id] in
                        slotTiles.all()
                            .filter { $0.key.clockId == clockId }
                            .map(\.key.tileId)
                    }
                )
            }
            let store = TileSettingsStore(defaults: defaults, clockId: clock.id)
            let device = AwtrixDevice(host: clock.address, transport: transport)
            return AwtrixClockSession(
                device: device,
                registry: factories.registry(for: clock),
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
            // The very factories the sessions are built from, so a preview and
            // a push build the same connector for the same tile.
            makeClockRegistry: factories.registry(for:),
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
            watching: WatchedMicrophone.stored(in: defaults),
            secrets: secrets
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
}

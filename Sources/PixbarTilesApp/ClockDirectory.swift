import Foundation
import PixbarKit

/// The clocks this app drives: the list as stored, which one is selected, the
/// address and location fields, and the moves the Clocks tab makes. Every
/// change to the list hands on to `onClocksChanged` — the model's reload,
/// which brings sessions, healths and schedules in line with it.
@MainActor
final class ClockDirectory: ObservableObject {
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
            health.selectedClockId = selectedClockId
        }
    }
    /// Whether nothing is configured: the panel's "No clocks yet" state, which
    /// a fresh install reaches and the Clocks section answers.
    var hasNoClocks: Bool { clocks.isEmpty }
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
    /// The model's reload, run after every change this directory makes to the
    /// stored list. Wired by the model after its own init.
    var onClocksChanged: @MainActor () -> Void = {}
    /// Where what is learned about the clocks is written down for the next
    /// launch.
    private let clockStore: ClockStore
    /// The place this clock's weather tile reads for. Held so the settings
    /// field reads and saves through the same record the connector polls.
    private let location: StoredLocation
    /// The dual probe behind Add by address: whichever body decodes names the
    /// model. Nil where no caller adds by address.
    private let probe: (@Sendable (String) async -> UlanziProbe.Detection)?
    private let defaults: UserDefaults
    /// Told which clock is selected: the glyph answers for it alone.
    private let health: ClockHealthMonitor
    /// A removed TC002's session takes its pages back.
    private let clockSessions: ClockSessions
    /// A removed clock's tiles go with it.
    private let tiles: TileStore

    init(
        clocks: [ClockRecord],
        clockStore: ClockStore,
        location: StoredLocation,
        defaults: UserDefaults,
        probe: (@Sendable (String) async -> UlanziProbe.Detection)?,
        health: ClockHealthMonitor,
        clockSessions: ClockSessions,
        tiles: TileStore
    ) {
        self.clocks = clocks
        self.clockStore = clockStore
        self.location = location
        self.defaults = defaults
        self.probe = probe
        self.health = health
        self.clockSessions = clockSessions
        self.tiles = tiles
        self.deviceHost = clocks.first?.address ?? ""
        self.typedHost = clocks.first?.address ?? ""
        self.typedLocation = LocationField.text(for: location.current)
        let saved = defaults.string(forKey: Self.selectedClockKey).flatMap(UUID.init(uuidString:))
        self.selectedClockId = clocks.contains(where: { $0.id == saved }) ? saved : clocks.first?.id
        health.selectedClockId = selectedClockId
    }

    /// Takes the stored list as this launch's: the selection moves off a clock
    /// that is gone, and the address label follows the selection.
    func refresh(from stored: [ClockRecord]) {
        let kept = Set(stored.map(\.id))
        clocks = stored
        if selectedClockId.map(kept.contains) != true { selectedClockId = stored.first?.id }
        deviceHost = selectedClockId.flatMap { clock($0)?.address } ?? (stored.first?.address ?? "")
    }

    /// Follows one clock to where it was found: the panel labels that are
    /// about the selected clock. The health has already written the store.
    func clockMoved(_ clockId: UUID, to address: String) {
        deviceHost = address
        if selectedClockId == clockId || selectedClockId == nil {
            typedHost = address
            // `typedHost` has a `didSet` that saves and then says so, and what
            // it says is "Saved — takes effect at next launch". Both halves are
            // wrong here: nobody typed, and it took effect at once.
            hostNote = nil
        }
    }

    /// The clock record as this launch has it, by id.
    func clock(_ id: UUID) -> ClockRecord? {
        clocks.first { $0.id == id }
    }

    /// The clock the one shared device, monitor and installer are built on —
    /// the first, which for a one-clock install is the only one. B14 gives
    /// every clock a health of its own.
    var firstClock: ClockRecord? { clocks.first }
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
            guard let clock = firstClock else { return }
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
        onClocksChanged()
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
        let tc002 = clockSessions.ulanzi(for: id)
        Task { await tc002?.shutdown() }
        try? tiles.replaceAll(tiles.all().filter { $0.key.clockId != id })
        try? clockStore.replaceAll(clockStore.all().filter { $0.id != id })
        onClocksChanged()
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
        onClocksChanged()
        return .added
    }

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
        onClocksChanged()
    }
}

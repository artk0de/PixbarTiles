import Foundation
import PixbarKit

/// The tiles as stored: what each is, where it sits in its clock's order, and
/// the moves that change them — add, save, pause, remove, re-key, reorder.
/// Every change hands on to the schedule and the runner; the book itself
/// reaches no clock.
@MainActor
final class TileBook: ObservableObject {
    /// Bumped when the tiles record's ORDER changes, because the store it
    /// lives in publishes nothing: the panel's rows are drawn from the
    /// record, and a reorder has no other way to be seen.
    @Published private(set) var tileOrderRevision = 0
    /// The clocks as this launch has them, for the names a refusal carries
    /// and the catalogue's per-clock answers. Wired by the model after its
    /// own init.
    var clocks: @MainActor () -> [ClockRecord] = { [] }
    private let tiles: TileStore
    /// The app-level registry: the connectors a tile can be.
    private let registry: ConnectorRegistry
    /// Where a removed tile's settings wait, and the new-tile interval.
    private let defaults: UserDefaults
    private let clockSessions: ClockSessions
    private let lamps: LampController
    private let scheduler: any TileScheduling
    private let runner: any TileRunning
    /// The settings window, re-aimed when its tile is re-keyed.
    private let pages: PageFollower

    init(
        tiles: TileStore,
        registry: ConnectorRegistry,
        defaults: UserDefaults,
        clockSessions: ClockSessions,
        lamps: LampController,
        scheduler: any TileScheduling,
        runner: any TileRunning,
        pages: PageFollower
    ) {
        self.tiles = tiles
        self.registry = registry
        self.defaults = defaults
        self.clockSessions = clockSessions
        self.lamps = lamps
        self.scheduler = scheduler
        self.runner = runner
        self.pages = pages
    }

    /// A tile's policy as stored, with anything a record from before Phase 4
    /// does not say taken from its connector's row.
    static func policy(of key: TileKey, in tiles: TileStore, registry: ConnectorRegistry) -> TilePolicy? {
        guard let record = tiles.all().first(where: { $0.key == key }) else { return nil }
        // The VPN is not in the registry (it is not a scene connector), so its
        // row is named here.
        let row = key.connectorId == VPNConnector.id
            ? TileDefaults.vpn
            : registry.connector(id: key.connectorId)?.defaultPolicy
                ?? TilePolicy(refreshSeconds: record.policy.refreshSeconds)
        return TilePolicy(record.policy, defaults: row)
    }

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
        guard let clock = clocks().first(where: { $0.id == key.clockId }),
            let own = clockSessions.registry(for: clock)
        else {
            return registry.connector(id: key.connectorId)
        }
        // Built for the tile's stored record, the one its clock would run: a
        // factory reads the tile's settings off it.
        return own.connector(for: tiles.all().first { $0.key == key }
            ?? TileRecord(key: key, policy: TilePolicyRecord(isPaused: false, refreshSeconds: 0))) ?? registry.connector(id: key.connectorId)
    }

    /// The tile's stored record, said for the surfaces that read the config
    /// it carries.
    func storedTile(_ key: TileKey) -> TileRecord? {
        tiles.all().first { $0.key == key }
    }

    /// Pauses or resumes one tile, named by key and not by connector — the
    /// same connector sits on several clocks, and this names one tile of it.
    func setPaused(_ paused: Bool, tile key: TileKey) {
        guard let record = storedTile(key) else { return }
        let wasRunning = !record.policy.isPaused
        tiles.update(record) { $0.policy.isPaused = paused }
        scheduler.reschedule(key)
        // Only on the way OFF, and only on the edge. A tile switched off
        // stops running, so nothing else will ever put back what it borrowed —
        // where switching one ON borrows nothing until its first delivery, and
        // a restore there would write a value that is already on the device.
        // Dragging the interval slider is neither, and must not touch the clock
        // at all.
        if wasRunning && paused {
            runner.retract(key)
            // On the TC002 branch a paused tile's page stays in the knob cycle
            // on the idle frame — paused, never deleted (D4). The slot names
            // the branch: an AWTRIX session fails the cast, and there the
            // restore above is what answers the pause.
            let tc002 = clockSessions.ulanzi(for: key.clockId)
            Task { await tc002?.markIdle(tileId: key.tileId) }
        }
    }

    enum TileSaveOutcome: Equatable {
        case saved
        /// Not saved, with the sentence to show beside the control that asked.
        case refused(String)
    }

    /// What the Add tile menu shows for a connector on a clock.
    func availability(of connectorId: String, on clockId: UUID) -> TileAvailability {
        guard let clock = clocks().first(where: { $0.id == clockId }),
            let candidate = candidate(for: connectorId)
        else { return .notListed }
        return TileCatalogue.availability(of: candidate, on: clock, tiles: tiles.all(), clocks: clocks())
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
            guard let free = lamps.freeLampVPN(on: clockId) else {
                return .refused(
                    "every VPN already has a tile on \(clocks().first { $0.id == clockId }?.name ?? "this clock")"
                )
            }
            return addTile(
                connectorId, to: clockId, instance: free.id,
                config: config ?? .vpn(lamps.startingLamp(for: free, on: clockId))
            )
        }
        let key = TileKey(clockId: clockId, connectorId: connectorId, instance: instance)
        switch availability(of: connectorId, on: clockId) {
        case let .unavailable(reason):
            return .refused(reason)
        case .notListed:
            return .refused("already on \(clocks().first { $0.id == clockId }?.name ?? "this clock")")
        case .available:
            break
        }
        if tiles.all().contains(where: { $0.key == key }) {
            return .refused("already on \(clocks().first { $0.id == clockId }?.name ?? "this clock")")
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

    /// Moves a tile to another key — the key's instance is its identity (a
    /// lamp's VPN, a GitHub tile's repository), so changing it is a move and
    /// not an edit.
    ///
    /// The tile keeps its place in the clock's order, its policy and the
    /// config it is given; the old key's schedule stops, and a tile with a
    /// page takes it back off its clock. Not through `removeTile`: that path
    /// files the config away under the old key for a re-add to find, and this
    /// config is not being put away — it is moving house. An open settings
    /// window is re-aimed at the key the tile now lives under.
    func rekey(_ key: TileKey, to moved: TileKey, config: TileConfig?) -> TileSaveOutcome {
        guard let policy = storedPolicy(of: key) else {
            return .refused("this tile is no longer on the clock")
        }
        guard tiles.all().contains(where: { $0.key == moved }) == false else {
            return .refused("already on \(clockName(key.clockId))")
        }
        scheduler.unschedule(key)
        if key.connectorId != VPNConnector.id {
            runner.retract(key)
            let tc002 = clockSessions.ulanzi(for: key.clockId)
            Task { await tc002?.tileRemoved(key.tileId) }
        }
        try? tiles.replaceAll(tiles.all().map {
            $0.key == key ? TileRecord(key: moved, policy: $0.policy, config: config) : $0
        })
        let outcome = saveTile(key: moved, policy: policy, config: config)
        if case .saved = outcome, pages.detailTileKey == key { pages.openDetail(for: moved) }
        return outcome
    }

    /// The clock's name for a refusal, or "this clock" for one that is gone.
    private func clockName(_ clockId: UUID) -> String {
        clocks().first { $0.id == clockId }?.name ?? "this clock"
    }

    /// Points a lamp tile at another VPN — the block's Preset picker.
    ///
    /// A move and not an edit, because the VPN is the tile's identity: it is
    /// the key's instance, which is what the migration wrote, what the
    /// restore key reads, and what keeps two lamps on one clock apart. The
    /// policy, the lamp and the colour come across untouched, and the window
    /// is re-aimed at the key the tile now lives under.
    func changeLampVPN(_ key: TileKey, to vpnId: String) -> TileSaveOutcome {
        guard var lamp = storedTile(key)?.config?.lamp, storedPolicy(of: key) != nil else {
            return .refused("this tile is no longer on the clock")
        }
        guard key.instance != vpnId else { return .saved }
        let moved = TileKey(clockId: key.clockId, connectorId: key.connectorId, instance: vpnId)
        if tiles.all().contains(where: { $0.key == moved }) {
            let name = WatchedVPN.preset(id: vpnId)?.displayName ?? vpnId
            let clock = clocks().first { $0.id == key.clockId }?.name ?? "this clock"
            return .refused("\(name) already has a tile on \(clock)")
        }
        lamp.vpn = vpnId
        return rekey(key, to: moved, config: .vpn(lamp))
    }

    /// Stores what the tile detail says, unless a VPN lamp is claimed by
    /// another tile at the same moment. A pause takes the tile's app off its
    /// clock at once; the schedule is rebuilt either way.
    func saveTile(key: TileKey, policy: TilePolicy, config: TileConfig?) -> TileSaveOutcome {

        if let lamp = config?.lamp,
            let conflict = LampConflict.check(
                LampTile(key: key, name: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn, slot: lamp.slot, policy: policy),
                against: lamps.lampTiles(on: key.clockId)
            ) {
            return .refused(conflict.message)
        }
        let wasRunning = storedPolicy(of: key).map { !$0.isPaused } ?? false
        let lookChanged = storedTile(key)?.config != config
        tiles.update(TileRecord(key: key, policy: TilePolicyRecord(policy))) {
            $0.policy = TilePolicyRecord(policy)
            $0.config = config
        }

        if wasRunning && policy.isPaused { runner.retract(key) }
        if key.connectorId == VPNConnector.id { lamps.refreshLamps() } else { scheduler.reschedule(key) }
        if wasRunning && lookChanged { scheduler.pushDisplaySettings(key) }
        scheduler.reconcileTiles()
        return .saved
    }

    func removeTile(_ key: TileKey) {
        scheduler.unschedule(key)
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
            lamps.refreshLamps()
        } else {
            runner.retract(key)
            // The TC002's page is the app's own doing, so removal takes it
            // back through the slot's custody — the empty-body delete that
            // is the measured contract (phase-3 A9). The cast is the model
            // check; an AWTRIX slot has nothing to take back here.
            let tc002 = clockSessions.ulanzi(for: key.clockId)
            Task { await tc002?.tileRemoved(key.tileId) }
        }
    }

    func storedPolicy(of key: TileKey) -> TilePolicy? { Self.policy(of: key, in: tiles, registry: registry) }

    /// The connector as the store's cards see it, or nil for an id the
    /// registry does not hold and the lamp is not.
    func candidate(for connectorId: String) -> TileCandidate? {
        if connectorId == VPNConnector.id { return TileCandidate(lamps.vpn) }
        return registry.connector(id: connectorId).map { TileCandidate($0) }
    }

    /// The tiles as they are stored, in stored order — the raw material the
    /// panel's sections are built from.
    var tileRecords: [TileRecord] { tiles.all() }

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
        // The TC002 runs its pages in creation order: its slot re-creates the
        // ones now out of place. After the write, so it reads the new order.
        if let ordering = clockSessions[source.clockId] as? any UlanziPageOrdering {
            Task { await ordering.pagesReordered() }
        }
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

    /// A tile's title where it is named on a card or its window: the
    /// connector's own name (the VPN tile's is "VPN") and, for an instanced
    /// tile, the name the kit gives its instance.
    func tileTitle(of record: TileRecord) -> TileTitle {
        let connectorId = record.key.connectorId
        let name = connectorId == VPNConnector.id
            ? VPNConnector(isUp: { _ in false }).displayName
            : registry.connector(id: connectorId)?.displayName ?? connectorId
        return TileTitle(name: name, secondary: TilePresentation.secondaryName(of: record))
    }

    /// The detail surface's inputs for one tile, beyond the policy it edits:
    /// its display name and the config a save must carry through. Nil for a
    /// tile that is gone — there is nothing left for the surface to be open
    /// for.
    func detailValue(for key: TileKey) -> (name: String, config: TileConfig?)? {
        guard let record = storedTile(key) else { return nil }
        // The window's title: `GitHub (TeaRAGs)`, the card's words.
        return (tileTitle(of: record).text, record.config)
    }

    /// Every connector a clock's Add tile menu can offer, in offer order:
    /// the registry's, then the lamp's — it has no face and no session of
    /// its own, so it never joined the registry, and this is where it is
    /// offered. LAST, because it is the connector a full clock can still
    /// take: the exhausted-clock menu offers it and nothing else.
    func tileCandidates() -> [(connectorId: String, name: String)] {
        registry.all.map { (connectorId: $0.id, name: $0.displayName) }
            + [(connectorId: VPNConnector.id, name: lamps.vpn.displayName)]
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
}

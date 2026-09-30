import Foundation
import PixbarKit

/// The lamp tiles: which VPN a new one watches and where it starts, and the
/// corners every clock's lamps light — kept following the machine by two
/// watchers rather than by a timer.
@MainActor
final class LampController {
    /// How each watched VPN is read. Built over the presence reader, which is
    /// the process table.
    let vpn: VPNConnector
    private let tiles: TileStore
    /// Where each clock's corners are reached: its session's indicators.
    private let clockSessions: ClockSessions
    /// The model's task bag: teardown waits on the corner writes through it.
    private let taskBag: TaskBag
    /// A tile's policy, as the model resolves it.
    private let policy: @MainActor (TileKey) -> TilePolicy?
    /// The Focus the Mac is in and the hour, as every tile's window reads them.
    private let moment: @MainActor () -> (focus: MacFocus, hour: Int)
    /// The two things that say the world moved. See `startWatchingTheWorld`.
    private let networkWatcher = NetworkPathWatcher()
    private let focusWatcher = FocusAssertionsWatcher()

    init(
        vpn: VPNConnector,
        tiles: TileStore,
        clockSessions: ClockSessions,
        taskBag: TaskBag,
        policy: @escaping @MainActor (TileKey) -> TilePolicy?,
        moment: @escaping @MainActor () -> (focus: MacFocus, hour: Int)
    ) {
        self.vpn = vpn
        self.tiles = tiles
        self.clockSessions = clockSessions
        self.taskBag = taskBag
        self.policy = policy
        self.moment = moment
    }

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
    func startingLamp(for vpn: WatchedVPN, on clockId: UUID) -> VPNTileConfig {
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

    func lampTiles(on clockId: UUID) -> [LampTile] {
        tiles.all().compactMap { record in
            guard record.key.clockId == clockId, let lamp = record.config?.lamp,
                let policy = self.policy(record.key)
            else { return nil }
            return LampTile(key: record.key, name: WatchedVPN.preset(id: lamp.vpn)?.displayName ?? lamp.vpn, slot: lamp.slot, policy: policy)
        }
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
    /// behaviour it had before this existed: the health poll notices the switch on
    /// its own minute.
    func startWatching(onFocusChange: @escaping @MainActor () -> Void) {
        networkWatcher.start { [weak self] in
            Task { @MainActor in self?.refreshLamps() }
        }
        focusWatcher.start { [weak self] in
            Task { @MainActor in
                // Both, and in this order. The Focus decides which corners are
                // allowed to say anything at all, and it is also what every
                // tile's Focus rule is read against — which until now was
                // answered only on the poll's minute.
                onFocusChange()
                self?.refreshLamps()
            }
        }
    }

    /// Stops both watchers, so nothing new is scheduled behind a teardown.
    func stopWatching() {
        networkWatcher.stop()
        focusWatcher.stop()
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
        let (focus, hour) = moment()
        let byClock = Dictionary(grouping: tiles.all().filter { $0.key.connectorId == VPNConnector.id }, by: \.key.clockId)
        for (clockId, vpnTiles) in byClock {
            guard let indicators = clockSessions[clockId]?.indicators else { continue }
            let vpn = self.vpn
            taskBag.run { [weak self] in
                var claims: [LampClaim] = []
                for record in vpnTiles {
                    guard let lamp = record.config?.lamp,
                        let reading = try? await vpn.read(config: lamp),
                        let policy = self?.policy(record.key)
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
            }
        }
    }

    /// Puts out every lamp any VPN tile claims, lit or not, on every clock.
    ///
    /// Indicators live on the clock: the firmware holds them through this
    /// process going away, so a quit while the work tunnel was down would
    /// leave a red corner blinking on the desk with nothing left running that
    /// could ever put it out.
    func turnOff() async {
        let covered = Dictionary(grouping: tiles.all().filter { $0.key.connectorId == VPNConnector.id }, by: \.key.clockId)
        for (clockId, vpnTiles) in covered {
            guard let indicators = clockSessions[clockId]?.indicators else { continue }
            for slot in Set(vpnTiles.compactMap { $0.config?.lamp?.slot }).sorted(by: { $0.rawValue < $1.rawValue }) {
                await indicators.show(.off, on: slot)
            }
        }
    }
}

import Foundation
import PixbarKit

/// The clock's session as the TC002's reachability poll reaches it, with the
/// model listening in on a return: a clock that came back has rebuilt its page
/// set, so which page the app last put up is no longer known.
private struct PageBeliefForgettingWatcher: UlanziClockWatching {
    let session: any UlanziClockWatching
    let forget: @MainActor @Sendable () -> Void

    func clockReturned() async {
        await forget()
        await session.clockReturned()
    }

    func verifyPages() async { await session.verifyPages() }
}

/// Which tile's page each clock shows, and the settings window's follow: the
/// tile whose settings are open has its page brought up on its clock, and
/// closing the window puts back the page from before — when the clock could
/// say which that was.
@MainActor
final class PageFollower: ObservableObject {
    private let tiles: TileStore
    private let clockSessions: ClockSessions
    /// Nothing is sent to a clock the poll has found unreachable.
    private let reachability: any ReachabilityReading
    /// A tile's policy, as the model resolves it.
    private let policy: @MainActor (TileKey) -> TilePolicy?

    init(
        tiles: TileStore,
        clockSessions: ClockSessions,
        reachability: any ReachabilityReading,
        policy: @escaping @MainActor (TileKey) -> TilePolicy?
    ) {
        self.tiles = tiles
        self.clockSessions = clockSessions
        self.reachability = reachability
        self.policy = policy
    }

    /// The tile whose detail surface is open, or nil while none is. The key it
    /// was opened for travels with the surface, so the editor never has to ask
    /// which tile it is editing.
    @Published private(set) var detailTileKey: TileKey?

    /// Opens the tile's settings — and brings the tile's page up on its clock,
    /// so the user sees what the controls change without turning the knob.
    /// Re-aiming an open window at another tile follows it there.
    func openDetail(for key: TileKey) {
        let previous = detailTileKey
        detailTileKey = key
        guard previous != key else { return }
        queuePageWork { [weak self] in await self?.followPage(to: key) }
    }

    /// Closes the tile's settings, and puts the clock back on the page it
    /// showed before the window first opened — when that page is known.
    func closeDetail() {
        guard detailTileKey != nil else { return }
        detailTileKey = nil
        queuePageWork { [weak self] in await self?.returnPage() }
    }

    /// Which clock the settings window has moved, the page it showed before
    /// the first move (nil when the clock cannot say — the TC002), and the
    /// page the window put up (nil until a switch landed).
    private struct PageFollow {
        let clockId: UUID
        let original: String?
        var shown: String?
    }

    private var pageFollow: PageFollow?
    /// The last of the page switches, which run one after another: an open,
    /// a re-aim and a close fired in one breath must reach the clock in that
    /// order, and each reads what the one before it left.
    private var pageWork: Task<Void, Never>?

    private func queuePageWork(_ work: @escaping @MainActor () async -> Void) {
        let previous = pageWork
        pageWork = Task { @MainActor in
            await previous?.value
            await work()
        }
    }

    /// Waits out every queued page switch. For tests, which have to know the
    /// clock has heard everything before they can say it heard nothing more.
    func pageSwitchesSettled() async {
        while let work = pageWork {
            await work.value
            if pageWork == work { return }
        }
    }

    /// Whether the tile has a page of its own to show: not the lamp, which
    /// lights a corner of whatever is up, and not a paused tile, whose page is
    /// the idle frame (TC002) or gone (AWTRIX). The card's eye is drawn for
    /// these and no others.
    func ownsPage(_ key: TileKey) -> Bool {
        guard key.connectorId != VPNConnector.id, let policy = policy(key) else { return false }
        return policy.isPaused == false
    }

    /// The slot that can show this tile's page: a tile that owns one, on a
    /// clock whose slot can switch.
    /// Nil for a clock the poll has found unreachable, like every other send.
    private func pageShowing(for key: TileKey) -> (any ClockPageShowing)? {
        guard ownsPage(key), !reachability.clockIsUnreachable(key.clockId) else { return nil }
        return clockSessions[key.clockId] as? any ClockPageShowing
    }

    /// The tile whose page each clock is showing: what the clock said, or —
    /// for a clock that cannot say (the TC002) — what this app last put up
    /// there itself (`pageBelief`). Absent on a page of the clock's own, on a
    /// clock not asked yet, and on one that returned since the app last
    /// showed a page. The tile cards' open eye.
    @Published private(set) var tileOnScreen: [UUID: TileKey] = [:]

    /// The tile whose page this app last brought up on each clock — by an eye
    /// click, the settings window's follow, or the window's restore.
    ///
    /// The TC002 cannot report its page, so without this every eye on it
    /// stayed closed, even on the tile the user had just clicked. It is a
    /// belief, not a reading: the knob can move the clock behind the app's
    /// back, so a clock that CAN say (the AWTRIX) is always read instead, and
    /// the belief only stands in where the reading is nil. Forgotten when the
    /// clock returns (`forgetPageBelief`) — a rebooted or restarted clock
    /// shows whatever it booted to.
    private var pageBelief: [UUID: TileKey] = [:]

    /// The TC002's reachability poll tells the clock's session when the clock
    /// returns; the model hears that word too, on its way to the session, and
    /// forgets which page it put up. Nil when the clock has no such session.
    func ulanziWatcher(for clockId: UUID) -> (any UlanziClockWatching)? {
        guard let session = clockSessions[clockId] as? any UlanziClockWatching else { return nil }
        return PageBeliefForgettingWatcher(session: session) { [weak self] in
            self?.forgetPageBelief(clockId: clockId)
        }
    }

    private func forgetPageBelief(clockId: UUID) {
        pageBelief[clockId] = nil
        tileOnScreen[clockId] = nil
    }

    /// Asks the clock which page is up and finds the tile it belongs to.
    /// Called when the clock's tile list appears — no polling beyond that.
    func refreshTileOnScreen(clockId: UUID) {
        queuePageWork { [weak self] in await self?.readTileOnScreen(clockId: clockId) }
    }

    /// The card's eye clicked: the tile's page brought up, by the user's own
    /// hand (D3 allows it). An open settings window stops following — the
    /// page is the user's choice now, and closing must not take it back.
    func showOnClock(_ key: TileKey) {
        queuePageWork { [weak self] in
            guard let self else { return }
            if pageFollow?.clockId == key.clockId { pageFollow = nil }
            guard let clock = pageShowing(for: key) else { return }
            do {
                guard let page = try await clock.page(forTile: key.tileId) else { return }
                try await clock.showPage(page)
                showed(key, on: key.clockId)
            } catch {
                AppLog.clocks.notice(
                    "switch to \(key.tileId, privacy: .public)'s page failed: \(String(describing: error), privacy: .public)"
                )
            }
            await readTileOnScreen(clockId: key.clockId)
        }
    }

    private func readTileOnScreen(clockId: UUID) async {
        guard !reachability.clockIsUnreachable(clockId), let clock = clockSessions[clockId] as? any ClockPageShowing else {
            tileOnScreen[clockId] = nil
            return
        }
        do {
            // A clock that cannot say is shown what this app last put up.
            guard let current = try await clock.currentPage() else {
                tileOnScreen[clockId] = pageBelief[clockId]
                return
            }
            tileOnScreen[clockId] = try await tile(showing: current, on: clockId, via: clock)
        } catch {
            tileOnScreen[clockId] = nil
            AppLog.clocks.notice(
                "page on screen unreadable: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The tile on this clock whose page is `page`, or nil for a page of the
    /// clock's own.
    private func tile(
        showing page: String, on clockId: UUID, via clock: any ClockPageShowing
    ) async throws -> TileKey? {
        for record in tiles.all() where record.key.clockId == clockId && ownsPage(record.key) {
            if try await clock.page(forTile: record.key.tileId) == page { return record.key }
        }
        return nil
    }

    private func followPage(to key: TileKey) async {
        // Another clock's window closing, as far as that clock is concerned.
        if let follow = pageFollow, follow.clockId != key.clockId { await returnPage() }
        guard let clock = pageShowing(for: key) else { return }
        do {
            guard let page = try await clock.page(forTile: key.tileId) else { return }
            if pageFollow == nil {
                let current: String?
                do {
                    current = try await clock.currentPage()
                } catch {
                    AppLog.clocks.notice(
                        "page before the tile settings unreadable: \(String(describing: error), privacy: .public)"
                    )
                    current = nil
                }
                pageFollow = PageFollow(clockId: key.clockId, original: current, shown: nil)
            }
            let onScreen = pageFollow?.shown ?? pageFollow?.original
            if onScreen != page {
                try await clock.showPage(page)
            }
            pageFollow?.shown = page
            showed(key, on: key.clockId)
        } catch {
            AppLog.clocks.notice(
                "switch to \(key.tileId, privacy: .public)'s page failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Puts back the page from before the first open — only a page the clock
    /// named, and only when the window actually moved it off that page.
    private func returnPage() async {
        guard let follow = pageFollow else { return }
        pageFollow = nil
        guard let original = follow.original, let shown = follow.shown, original != shown,
            let clock = clockSessions[follow.clockId] as? any ClockPageShowing
        else { return }
        do {
            try await clock.showPage(original)
            showed(try await tile(showing: original, on: follow.clockId, via: clock), on: follow.clockId)
        } catch {
            AppLog.clocks.notice(
                "return to page \(original, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The app has just put this tile's page up (nil: a page of the clock's
    /// own): what it believes is on screen, and the eye that opens.
    private func showed(_ key: TileKey?, on clockId: UUID) {
        pageBelief[clockId] = key
        tileOnScreen[clockId] = key
    }
}

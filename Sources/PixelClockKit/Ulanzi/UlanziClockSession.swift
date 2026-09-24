import Foundation

/// The TC002 clock's session: board, device, and custody wired together.
///
/// Pushes are event-driven only — a delivery, an idle mark, a removal, a
/// recovery. There is no loop and no timer (D1): the Mac never rotates
/// anything, and no push switches a page (D3). The one switch, `showPage`, is
/// for the user opening a tile's settings.
///
/// Its recovery rule is still blunt (D4) — after an outage the FIRST successful
/// call re-pushes every registered page — with three limits learned from a
/// clock that rebooted under load (2026-09-24):
///
/// - only the transport failing (a timeout, a refused connection) is an
///   outage. A clock that answers — a `code` refusal, an unreadable body, an
///   HTTP error status — still carries its pages;
/// - one sweep at a time, and a sweep's own failures do not start the next;
/// - a sweep that fails backs the next one off: 60 s, 120 s, then 300 s for
///   as long as they keep failing. A clean sweep resets it.
///
/// One exception to "no timer": an interruption window. A delivery that
/// carries interruptions overwrites pages for their durations and then puts
/// the board back — the TC002 has no notification surface to do it for us.
/// The board never learns about it; only the wire does.
///
/// Every upsert is compared with what the page already carries (`onDevice`):
/// a byte-identical body is not sent again. The AWTRIX session does not do the
/// same on purpose — its app payloads carry a `lifetime` the device counts down
/// from the last upsert, so a skipped re-push there lets the app expire, and a
/// text payload of a few hundred bytes is not what loads that clock.
public actor UlanziClockSession {
    private let device: UlanziDevice
    private let custody: UlanziCustody
    private let chain: DeliveryChain
    private var board = UlanziTileBoard()

    /// Every page is owed a re-push: the transport failed, and whatever the
    /// clock carries is unknown. Cleared when a sweep starts.
    private var sweepDue = false
    /// A recovery sweep is running. The calls it makes go through the same
    /// bookkeeping as any other push; this flag keeps one of their outcomes
    /// from starting a second, nested sweep.
    private var recovering = false
    /// Sweeps that ended with the transport failing again, in a row.
    private var failedSweeps = 0
    /// No sweep starts before this — the backoff after a failed one.
    private var nextSweepAt = Date.distantPast
    /// The wait after the 1st, 2nd and every later failed sweep in a row.
    static let sweepBackoff: [TimeInterval] = [60, 120, 300]
    /// Upserts on the wire right now, and upserts ever started — so a page
    /// list read around a push can tell it raced one and must not be trusted.
    private var pushesInFlight = 0
    private var pushesStarted = 0

    /// How an interruption's duration passes. Injected so a test can hold a
    /// window open and look inside it, or close it at once.
    private let sleep: @Sendable (TimeInterval) async -> Void
    /// The wall clock the sweep backoff is read against. Injected for tests.
    private let now: @Sendable () -> Date

    /// The interruptions still to play, each with the tile that delivered it —
    /// `.ownPage` means that tile's page. A delivery arriving while a window is
    /// open appends here rather than starting a second player: two players
    /// would restore each other's celebrations away.
    private var pending: [(interruption: Interruption<UlanziScene>, tileId: String)] = []
    /// Pages showing an interruption frame right now, in the order they were
    /// overwritten — the order the restore runs in. A regular push to one of
    /// them waits for the restore, which carries the newest board frame.
    private var covered: [String] = []
    /// The one task playing `pending` and restoring `covered`; nil when no
    /// window is open.
    private var player: Task<Void, Never>?

    /// What each page carries ON the device as far as this session knows: the
    /// last frame an upsert of it got through with — an interruption's frame
    /// included, so a restore is compared against the celebration it replaces
    /// rather than against the ambient the board holds.
    ///
    /// A push whose frame equals this is not sent (the TC002 decodes and
    /// replaces the whole GIF on every upsert, and an unchanged 60 s tile was
    /// most of the traffic). A page leaves this map whenever its content on
    /// the device stops being known: a failed push of it, the clock going
    /// offline, a restart or a missing page detected, the page removed. The
    /// frame itself rather than a digest of it: equality is exact, and the
    /// handful of pages a clock carries cost nothing to hold.
    private var onDevice: [String: UlanziFrame] = [:]

    public init(
        device: UlanziDevice,
        custody: UlanziCustody,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.device = device
        self.custody = custody
        self.chain = DeliveryChain()
        self.sleep = sleep
        self.now = now
    }

    // MARK: startup

    /// Runs before the first push: stale recorded names still listed on the
    /// device get their delete first (D10), live tiles keep their claims, and
    /// every live tile is registered so a recovery sweep knows the full set.
    ///
    /// Off the delivery chain, like the AWTRIX session's teardown — this is
    /// startup work the app awaits before anything else reaches the clock.
    /// A transport failure here marks the clock offline rather than throwing:
    /// the first successful push after it drags every page back (D4).
    public func sweep(liveTiles: [String]) async {
        for tile in liveTiles { board.register(tileId: tile) }
        do {
            try await custody.sweep(liveTiles: liveTiles)
            await heardAnswer(from: nil)
        } catch {
            heardFailure(error)
        }
    }

    // MARK: events

    /// A tile's page gets this delivery's scene.
    public func deliver(_ delivery: UlanziDelivery, toTile tileId: String) async -> RunResult {
        // The board takes the scene before the wire does: a push that fails
        // leaves the newest content on the board, and the recovery sweep
        // carries it out instead of whatever was there before the outage.
        board.upsert(delivery, forTile: tileId)
        guard let frame = Self.singleFrame(of: delivery.scene) else {
            return .failed("a TC002 scene is exactly one frame, got \(delivery.scene.frames.count)")
        }
        // A covered page is showing an interruption: pushing now would cut it
        // short. The board already has this scene, and the restore carries it
        // out — so the delivery has landed as far as anyone waiting on it is
        // concerned.
        //
        // A delivery that opens a window pushes its own frame even when the
        // clock already carries it: the celebration is ordered after it on the
        // wire, and this is the rare path — one page per celebration.
        let opensWindow = !delivery.interruptions.isEmpty
        let result = covered.contains(tileId)
            ? .delivered
            : await chain.deliver { [self] in await push(frame, toTile: tileId, force: opensWindow) }
        // After the delivery's own push, and never awaited: the caller's run
        // is over when its page is, not when the celebration is.
        if !delivery.interruptions.isEmpty {
            pending += delivery.interruptions.map { ($0, tileId) }
            if player == nil {
                player = Task { [self] in await playWindow() }
            }
        }
        return result
    }

    /// The tile is paused: its page keeps its place in the knob cycle on the
    /// idle frame (D4), and the next delivery overwrites it.
    public func markIdle(tileId: String) async -> RunResult {
        board.markIdle(tileId)
        // Deferred like a delivery: the restore reads the board, which says idle.
        if covered.contains(tileId) { return .delivered }
        return await chain.deliver { [self] in
            await push(UlanziScene.idle.frames[0], toTile: tileId)
        }
    }

    /// The tile is gone: its page gets the empty-body delete — the `{}` body
    /// would leave the app in the knob cycle — and the record drops it.
    public func tileRemoved(_ tileId: String) async {
        // Forgotten by the board first: a recovery sweep after this must not
        // re-create the page that was just taken back.
        board.remove(tileId: tileId)
        // Its page is deleted: the same body delivered again re-creates it.
        onDevice[tileId] = nil
        // And by the window: neither an interruption frame nor the restore may
        // bring the page back.
        covered.removeAll { $0 == tileId }
        pending.removeAll { $0.tileId == tileId && $0.interruption.scope == .ownPage }
        try? await custody.release(tileId: tileId)
    }

    /// The app is quitting: every page we own gets its delete and the record
    /// empties, so the pages leave the knob cycle (user-initiated; E4 noted in
    /// the hand-off).
    public func shutdown() async {
        // The window goes first and pushes nothing more: the pages are about
        // to be deleted, and a restore landing after the delete re-creates one.
        player?.cancel()
        player = nil
        pending = []
        covered = []
        onDevice = [:]
        try? await custody.releaseAll()
    }

    // MARK: what the reachability poll saw

    /// The clock answers again after the reachability poll found it gone. It
    /// may have rebooted in between, and a rebooted TC002 answers the next
    /// push as if nothing happened — with every page lost. So nothing on it is
    /// known any more, and one sweep is owed; it runs now unless one is
    /// already running or backing off, in which case the next answer or check
    /// after the backoff runs it.
    public func clockReturned() async {
        onDevice = [:]
        sweepDue = true
        await runOwedSweep()
    }

    /// The reachability poll's cheap look (`GET /api/customList`, ~0.1 KB):
    /// every page this session put on the clock should be listed. One that is
    /// not was lost — a firmware restart the poll never saw go down — and is
    /// pushed again from what the board holds; the listed ones are left alone.
    ///
    /// Stands down whenever its answer could mislead or its work is already
    /// someone else's: a push or a sweep on the wire (a page list read around
    /// an upsert says nothing about that upsert), a sweep owed (it covers every
    /// page — this runs it instead, if its backoff is over), or no page of ours
    /// known on the clock yet.
    public func verifyPages() async {
        if sweepDue {
            await runOwedSweep()
            return
        }
        guard pushesInFlight == 0, !recovering, !onDevice.isEmpty else { return }
        let started = pushesStarted
        guard let listed = try? await device.customApps() else { return }
        // Re-read after the round trip: the actor may have pushed meanwhile.
        guard pushesStarted == started, pushesInFlight == 0, !recovering, !sweepDue else { return }
        let names = Set(listed)
        let missing = board.tileIds.filter {
            onDevice[$0] != nil && !names.contains(UlanziCustody.pageName(forTile: $0))
        }
        for tile in missing { onDevice[tile] = nil }
        // A covered page is the restore's: it differs from nothing now, so the
        // restore pushes it.
        for tile in missing where !covered.contains(tile) {
            guard let frame = recoveryFrame(forTile: tile) else { continue }
            _ = await chain.deliver { [self] in await pushIfOnBoard(frame, toTile: tile) }
        }
    }

    /// The owed sweep, on the delivery chain so it cannot interleave with a
    /// delivery's push — when none is running and the backoff is over.
    private func runOwedSweep() async {
        _ = await chain.deliver { [self] in
            await self.sweepIfOwed()
            return .delivered
        }
    }

    private func sweepIfOwed() async {
        guard sweepDue, !recovering, now() >= nextSweepAt else { return }
        await recoverySweep(skipping: nil)
    }

    /// A restore or a recovery push, unless the tile has since been removed
    /// from the board.
    private func pushIfOnBoard(_ frame: UlanziFrame, toTile tileId: String) async -> RunResult {
        guard board.tileIds.contains(tileId) else { return .skipped }
        return await push(frame, toTile: tileId)
    }

    // MARK: showing a page on request

    /// The tile's page while the clock lists it, or nil when it has none there.
    public func page(forTile tileId: String) async throws -> String? {
        try await custody.listedPage(forTile: tileId)
    }

    /// The page on screen: always nil. The firmware cannot report which app is
    /// up or at which level the UI stands (research §0), so a caller that
    /// wanted to put the clock back afterwards has nothing to put back.
    public func currentPage() async throws -> String? { nil }

    /// Brings this page on screen. User-initiated only — see
    /// `UlanziDevice.switchToApp`. Off the delivery chain: it writes no page,
    /// and waiting behind a push would only make the switch late.
    public func showPage(_ page: String) async throws {
        try await device.switchToApp(named: page)
    }

    /// What the board says this tile's page shows — never an interruption.
    func boardFrame(forTile tileId: String) -> UlanziScene? {
        board.frame(forTile: tileId)
    }

    // MARK: interruptions

    /// Plays every pending interruption in order, each on its own scope and
    /// for its own duration, then restores every covered page from the board
    /// once. Entries appended while this runs play before the restore; any
    /// that arrive during the restore open the window again.
    ///
    /// Cancelled only by `shutdown`, which has already cleared the state —
    /// so a cancelled player leaves it alone and pushes nothing more.
    private func playWindow() async {
        while !pending.isEmpty {
            while !pending.isEmpty {
                let (interruption, tileId) = pending.removeFirst()
                guard let frame = Self.singleFrame(of: interruption.scene) else { continue }
                let targets: [String]
                switch interruption.scope {
                case .everyPage: targets = board.tileIds
                case .ownPage: targets = board.tileIds.contains(tileId) ? [tileId] : []
                }
                for tile in targets where !covered.contains(tile) { covered.append(tile) }
                for tile in targets {
                    _ = await chain.deliver { [self] in await pushInterruption(frame, toTile: tile) }
                    if Task.isCancelled { return }
                }
                await sleep(interruption.duration)
                if Task.isCancelled { return }
            }
            while !covered.isEmpty {
                let tile = covered.removeFirst()
                // Read at the moment it is queued: a delivery that lands after
                // this is behind it in the chain and pushes its own, newer frame.
                guard let scene = board.frame(forTile: tile),
                      let frame = Self.singleFrame(of: scene) else { continue }
                _ = await chain.deliver { [self] in await pushIfOnBoard(frame, toTile: tile) }
                if Task.isCancelled { return }
            }
        }
        player = nil
    }

    /// An interruption frame, unless the page left the window — a tile removed
    /// between being targeted and its turn in the chain must not be re-created.
    private func pushInterruption(_ frame: UlanziFrame, toTile tileId: String) async -> RunResult {
        guard covered.contains(tileId) else { return .skipped }
        return await push(frame, toTile: tileId)
    }


    // MARK: plumbing

    /// One upsert and the bookkeeping around it.
    ///
    /// The DIY budget refusing a claim is answered as a failure without
    /// touching the offline flag — a full page set says nothing about whether
    /// the clock is reachable (D7), and marking it would drag every page
    /// through a recovery the clock never asked for.
    ///
    /// A frame equal to what the page already carries is answered as delivered
    /// without a request — unless `force` says the caller needs it on the wire.
    private func push(_ frame: UlanziFrame, toTile tileId: String, force: Bool = false) async -> RunResult {
        if !force, onDevice[tileId] == frame { return .delivered }
        let name: String
        do {
            name = try await custody.appName(forTile: tileId)
        } catch {
            return .failed(String(describing: error))
        }
        pushesInFlight += 1
        pushesStarted += 1
        defer { pushesInFlight -= 1 }
        do {
            try await device.showApp(frame, named: name)
            onDevice[tileId] = frame
            await heardAnswer(from: tileId)
            return .delivered
        } catch {
            // What the page shows is no longer known: the next push goes out.
            onDevice[tileId] = nil
            heardFailure(error)
            return DeliveryChain.classify(error)
        }
    }

    /// Whether a failed call means the clock is gone rather than that it
    /// answered and said no. Everything `UlanziDevice` raises after a reply —
    /// a `code` refusal, an unreadable body, an HTTP error status — is an
    /// answer; a cancellation is nobody's outage.
    static func isOutage(_ error: any Error) -> Bool {
        if error is UlanziError || error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }

    /// A failed call. Only an outage owes the pages a sweep — and forgets
    /// what every page carries, since the outage may have taken any of them.
    private func heardFailure(_ error: any Error) {
        guard Self.isOutage(error) else { return }
        sweepDue = true
        onDevice = [:]
    }

    /// The clock answered. Runs the recovery sweep when one is owed and its
    /// backoff has run out; the page whose push just got through is the one
    /// tile it skips — that page is current as of the call that ended the
    /// outage.
    private func heardAnswer(from tileId: String?) async {
        guard sweepDue, !recovering, now() >= nextSweepAt else { return }
        await recoverySweep(skipping: tileId)
    }

    /// Re-pushes every registered page, once. Its own failures only set
    /// `sweepDue` again: they cannot start another sweep while this one runs,
    /// and a sweep that ends with one owed pushes the next one back by the
    /// backoff instead of starting it at the next answer.
    ///
    /// The sweep's own calls bypass the delivery chain: it runs from inside a
    /// chain job, and queueing behind itself would wait on the very job that
    /// is running it.
    private func recoverySweep(skipping tileId: String?) async {
        sweepDue = false
        recovering = true
        // A covered page is the window's to restore: re-pushing it here would
        // cut its interruption short.
        for tile in board.tileIds where tile != tileId && !covered.contains(tile) {
            guard let frame = recoveryFrame(forTile: tile) else { continue }
            _ = await push(frame, toTile: tile)
        }
        recovering = false
        if sweepDue {
            failedSweeps += 1
            let wait = Self.sweepBackoff[min(failedSweeps, Self.sweepBackoff.count) - 1]
            nextSweepAt = now().addingTimeInterval(wait)
        } else {
            failedSweeps = 0
            nextSweepAt = .distantPast
        }
    }

    /// What a recovery puts back on a tile's page: the last real scene it
    /// delivered, or the idle frame when it never delivered one.
    private func recoveryFrame(forTile tile: String) -> UlanziFrame? {
        Self.singleFrame(of: board.lastScene(forTile: tile) ?? UlanziScene.idle)
    }

    private static func singleFrame(of scene: UlanziScene) -> UlanziFrame? {
        guard scene.frames.count == 1 else { return nil }
        return scene.frames[0]
    }
}

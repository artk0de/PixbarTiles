import Foundation

/// The TC002 clock's session: board, device, and custody wired together.
///
/// Pushes are event-driven only — a delivery, an idle mark, a removal, a
/// recovery. There is no loop and no timer (D1): the Mac never rotates
/// anything, and no page switch exists here (D3).
///
/// Its one recovery rule is deliberately blunt (D4): after any failed device
/// call the clock is marked offline, and the FIRST successful call after that
/// re-pushes every registered page. Twenty-one upserts are cheap; guessing
/// which pages survived an outage or a reboot is not (E9 — the design refuses
/// to care).
///
/// One exception to "no timer": an interruption window. A delivery that
/// carries interruptions overwrites pages for their durations and then puts
/// the board back — the TC002 has no notification surface to do it for us.
/// The board never learns about it; only the wire does.
public actor UlanziClockSession {
    private let device: UlanziDevice
    private let custody: UlanziCustody
    private let chain: DeliveryChain
    private var board = UlanziTileBoard()

    /// The clock stopped answering. Set by any failed device call, cleared by
    /// the recovery sweep that the next successful call runs.
    private var offline = false
    /// A recovery sweep is running. The calls it makes go through the same
    /// bookkeeping as any other push; this flag keeps one of their outcomes
    /// from starting a second, nested sweep.
    private var recovering = false

    /// How an interruption's duration passes. Injected so a test can hold a
    /// window open and look inside it, or close it at once.
    private let sleep: @Sendable (TimeInterval) async -> Void

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

    public init(
        device: UlanziDevice,
        custody: UlanziCustody,
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.device = device
        self.custody = custody
        self.chain = DeliveryChain()
        self.sleep = sleep
    }

    // MARK: startup

    /// Runs before the first push: stale recorded names still listed on the
    /// device get their delete first (D10), live tiles keep their claims, and
    /// every live tile is registered so a recovery sweep knows the full set.
    ///
    /// Off the delivery chain, like the AWTRIX session's teardown — this is
    /// startup work the app awaits before anything else reaches the clock.
    /// A failure here marks the clock offline rather than throwing: the first
    /// successful push after it drags every page back (D4).
    public func sweep(liveTiles: [String]) async {
        for tile in liveTiles { board.register(tileId: tile) }
        do {
            try await custody.sweep(liveTiles: liveTiles)
            await heard(success: true, from: nil)
        } catch {
            await heard(success: false, from: nil)
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
        let result = covered.contains(tileId)
            ? .delivered
            : await chain.deliver { [self] in await push(frame, toTile: tileId) }
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
        try? await custody.releaseAll()
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
                _ = await chain.deliver { [self] in await pushRestore(frame, toTile: tile) }
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

    /// A restore, unless the tile has since been removed from the board.
    private func pushRestore(_ frame: UlanziFrame, toTile tileId: String) async -> RunResult {
        guard board.tileIds.contains(tileId) else { return .skipped }
        return await push(frame, toTile: tileId)
    }

    // MARK: plumbing

    /// One upsert and the bookkeeping around it.
    ///
    /// The DIY budget refusing a claim is answered as a failure without
    /// touching the offline flag — a full page set says nothing about whether
    /// the clock is reachable (D7), and marking it would drag every page
    /// through a recovery the clock never asked for.
    private func push(_ frame: UlanziFrame, toTile tileId: String) async -> RunResult {
        let name: String
        do {
            name = try await custody.appName(forTile: tileId)
        } catch {
            return .failed(String(describing: error))
        }
        do {
            try await device.showApp(frame, named: name)
            await heard(success: true, from: tileId)
            return .delivered
        } catch {
            await heard(success: false, from: tileId)
            return DeliveryChain.classify(error)
        }
    }

    /// Records how a device call went and runs the recovery sweep on the first
    /// success after a failure (D4). The page whose push just got through is
    /// the one tile the sweep skips — it is current as of the call that ended
    /// the outage; everything else re-pushes.
    ///
    /// The sweep's own calls bypass the delivery chain: it runs from inside a
    /// chain job, and queueing behind itself would wait on the very job that
    /// is running it. Upserts are idempotent, so an overlap with an unrelated
    /// push costs nothing but a duplicate frame on the wire.
    private func heard(success: Bool, from tileId: String?) async {
        guard success else {
            offline = true
            return
        }
        guard offline, !recovering else { return }
        offline = false
        recovering = true
        defer { recovering = false }
        // A covered page is the window's to restore: re-pushing it here would
        // cut its interruption short.
        for tile in board.tileIds where tile != tileId && !covered.contains(tile) {
            let scene = board.lastScene(forTile: tile) ?? UlanziScene.idle
            guard let frame = Self.singleFrame(of: scene) else { continue }
            _ = await push(frame, toTile: tile)
        }
    }

    private static func singleFrame(of scene: UlanziScene) -> UlanziFrame? {
        guard scene.frames.count == 1 else { return nil }
        return scene.frames[0]
    }
}

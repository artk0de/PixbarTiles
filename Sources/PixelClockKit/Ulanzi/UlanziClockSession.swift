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

    public init(device: UlanziDevice, custody: UlanziCustody) {
        self.device = device
        self.custody = custody
        self.chain = DeliveryChain()
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
        return await chain.deliver { [self] in await push(frame, toTile: tileId) }
    }

    /// The tile is paused: its page keeps its place in the knob cycle on the
    /// idle frame (D4), and the next delivery overwrites it.
    public func markIdle(tileId: String) async -> RunResult {
        board.markIdle(tileId)
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
        try? await custody.release(tileId: tileId)
    }

    /// The app is quitting: every page we own gets its delete and the record
    /// empties, so the pages leave the knob cycle (user-initiated; E4 noted in
    /// the hand-off).
    public func shutdown() async {
        try? await custody.releaseAll()
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
        for tile in board.tileIds where tile != tileId {
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

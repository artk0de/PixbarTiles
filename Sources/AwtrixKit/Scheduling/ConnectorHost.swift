import Foundation

/// Plays prepared audio on the Mac. The clock cannot decode audio, so every
/// spoken thing this app produces comes out of the local speakers.
public protocol AudioPlaying: Sendable {
    func play(_ clips: [SpokenClip]) async
}

public protocol IconInstalling: Sendable {
    /// Returns the name the device will accept in a notify payload.
    func ensureInstalled(_ ref: IconReference) async throws -> String
}

/// Work a connector does away from the delivery path.
///
/// Two things belong here, and they are the same pass: restocking whatever the
/// connector hands out, and confirming that what it already handed out reached
/// disk. Neither may sit inside `runOnce` — restocking can cost a model load
/// and a minute of synthesis, which is exactly the bill the timer tick must not
/// pay, and the durability question is only worth asking once the run that
/// mutated the state is over.
///
/// Optional by design: a connector that holds nothing and prepares nothing has
/// no background pass, and should not be made to declare an empty one.
public protocol ConnectorMaintaining: Sendable {
    func maintain() async throws
}

/// How one delivery went.
public enum RunResult: Sendable, Equatable {
    case delivered
    /// The user switched this connector off.
    case skipped
    /// Called off. Not a failure — nobody is waiting for the result any more,
    /// and a feed outage is a different thing entirely. Anything already put on
    /// the clock was taken back down first.
    case cancelled
    case failed(String)
}

/// How one background pass went. Separate from `RunResult` because `delivered`
/// would be a lie about a pass that never goes near the clock.
public enum MaintenanceResult: Sendable, Equatable {
    case completed
    /// Switched off, or a connector with no background work to do.
    case skipped
    case cancelled
    case failed(String)
}

/// Owns everything a connector must not care about: enablement, delivery to the
/// device, and containment of failures.
public actor ConnectorHost {
    private let device: AwtrixDevice
    private let registry: ConnectorRegistry
    private let store: any SettingsStore
    private let audio: any AudioPlaying
    private let iconInstaller: any IconInstalling
    private let retryPolicy: RetryPolicy
    /// What this app has borrowed or added on the device, and how to give it
    /// back. Here rather than on a connector, because a connector produces and
    /// returns and never talks to the device — and because the overlay it
    /// borrows is global, so the record of it belongs beside the device rather
    /// than beside any one producer.
    private let custody: DeviceCustody

    /// The last delivery to have claimed a place. Deliveries run one at a time
    /// by waiting on it — see `queued(_:)` for how, and `runOnce(connectorId:)`
    /// for why they must. Runs and replays share it, which is the whole point:
    /// two chains would be no serialisation at all.
    private var tail: Task<Void, Never>?

    /// Deliveries failed in a row, per connector. An id that is not in here has
    /// none. In memory only: a relaunch is a fresh start, and a connector that
    /// is still down earns its backoff again within a couple of intervals.
    private var failureCounts: [String: Int] = [:]

    public init(
        device: AwtrixDevice,
        registry: ConnectorRegistry,
        store: any SettingsStore,
        audio: any AudioPlaying,
        iconInstaller: any IconInstalling,
        retryPolicy: RetryPolicy = RetryPolicy(),
        // Where the borrowed overlay is written down. Defaulted to the
        // in-memory one so a test gets a record scoped to itself; the shipped
        // app passes the durable one, because a record that dies with the
        // process is what turned this app's own weather into the user's
        // original. `AppModel.live` is the only caller that must not take this
        // default, and a test at the composition root says so.
        borrowedOverlays: any BorrowedOverlayStore = InMemoryBorrowedOverlayStore()
    ) {
        self.device = device
        self.registry = registry
        self.store = store
        self.audio = audio
        self.iconInstaller = iconInstaller
        self.retryPolicy = retryPolicy
        self.custody = DeviceCustody(device: device, overlays: borrowedOverlays)
    }

    /// Puts back the device-wide state this app borrowed.
    ///
    /// - Parameter connectorId: only what this connector took, or nil for
    ///   everything outstanding — which is what a quit wants.
    ///
    /// Deliberately NOT on the delivery chain. It is what a quit runs after
    /// everything else has been cancelled and awaited, and queueing it behind a
    /// delivery that is being torn down would be waiting for the one thing that
    /// is already over.
    ///
    /// The outcome is not reported, and there is nowhere for it to go: on quit
    /// there is nobody left to tell, and on a connector switched off the row
    /// already says so. A failure is not swallowed either — `DeviceCustody`
    /// keeps what it could not give back, so the next restore still knows.
    public func restoreDeviceState(borrowedBy connectorId: String?) async {
        try? await custody.restore(borrowedBy: connectorId)
    }

    /// How many deliveries this connector has failed in a row.
    public func consecutiveFailures(connectorId: String) -> Int {
        failureCounts[connectorId] ?? 0
    }

    /// How long to wait before the next attempt: the cadence the user chose
    /// while the connector is healthy, a growing backoff while it is failing,
    /// and never longer than that cadence either way.
    ///
    /// Worth being plain about which direction this moves, because "backoff"
    /// suggests the other one: the clip is to the connector's OWN interval, so
    /// a failing connector is retried SOONER than its cadence and decays back
    /// towards it, rather than ever being pushed past it. A blip on a
    /// half-hourly feed is retried in thirty seconds instead of costing the
    /// user half an hour of blank clock; a feed that is genuinely down doubles
    /// its way back to the half hour and settles there. It is the retry
    /// interval that is capped at the cadence, which is what the spec asks for.
    public func nextDelay(connectorId: String, interval: TimeInterval) -> TimeInterval {
        let failures = consecutiveFailures(connectorId: connectorId)
        guard failures > 0 else { return interval }
        return min(retryPolicy.delay(afterConsecutiveFailures: failures), interval)
    }

    /// Reads the count off the OUTCOME, not off the path that produced it.
    ///
    /// There are three ways a run ends up `.cancelled` and they arrive from
    /// three different places — a connector throwing `CancellationError`, the
    /// transport reporting `URLError(.cancelled)`, and a delivery that got all
    /// the way through only to find the task torn down. Deciding here, on the
    /// one value all three become, is what stops the next guard added to
    /// `send` from quietly re-classifying one of them.
    private func record(_ result: RunResult, for connectorId: String) {
        switch result {
        case .delivered:
            failureCounts[connectorId] = 0
        case .failed:
            failureCounts[connectorId, default: 0] += 1
        case .cancelled:
            // Not evidence about the feed. The user quitting, a connector
            // switched off mid-delivery, a schedule rebuilt — none of them say
            // whether the source is up. Counting one would back a healthy
            // connector off for having been interrupted; resetting on one would
            // clear a real backoff for the same non-reason.
            break
        case .skipped:
            // Never actually arrives. `runOnce` answers `.skipped` from its
            // enablement guard, before there is a run to have an outcome, so
            // this branch exists because the switch is exhaustive and not
            // because it decides anything — a mutation of it changes nothing,
            // and the rule it looks like it implements is pinned on that guard
            // instead. The answer would be the same either way: a connector the
            // user switched off has not failed, and has not recovered either.
            break
        }
    }

    /// Produces, delivers and speaks, one delivery at a time.
    ///
    /// Serialised rather than left to run concurrently, because this actor is
    /// reentrant and a delivery suspends for the whole length of its audio.
    /// `dismissNotification` is global to the device — it takes down whichever
    /// banner is showing, not the one this run put up — so two overlapping
    /// deliveries end with the first one's dismiss clearing the second one's
    /// banner while its speech is still running, and both anecdotes talking
    /// over each other. A timer tick, a "run now" from the menu and a "play
    /// again" from the History are the three callers that produce it, and all
    /// three take their turn in the same chain.
    ///
    /// The background pass is deliberately NOT on this chain: it can be a
    /// minute long, and making the banner wait behind it is the trade the queue
    /// exists to avoid.
    public func runOnce(connectorId: String) async -> RunResult {
        // Answered before a place in the chain is claimed. Neither a registry
        // lookup nor a settings read touches the device, so serialising them
        // buys nothing — and behind the chain a "run now" on a switched-off
        // connector, or a typo in an id, would sit through the whole of a
        // playing anecdote before answering "it's off".
        //
        // Enablement is therefore read when the run is asked for, not when it
        // reaches the front of the queue: a connector switched off while an
        // anecdote is still playing does not retract a run already queued.
        //
        // Neither guard below is recorded against the backoff. `.skipped` is
        // not a failure at all, and an id nothing is registered under is a
        // wiring mistake rather than a feed outage — nothing schedules it, so a
        // count kept against it would grow on every "run now" against a stale
        // id and never be read by anything.
        guard let connector = registry.connector(id: connectorId) else {
            return .failed("unknown connector \(connectorId)")
        }
        guard store.settings(for: connectorId).isEnabled else { return .skipped }

        let result = await queued { [self] in await produceAndSend(connector) }
        // Awaiting a task is not interrupted by cancellation, so this is
        // reached even when the caller gave up — which is the point. A run torn
        // down still has an outcome, and the backoff has to be told it was a
        // cancellation rather than left reading the last failure.
        record(result, for: connectorId)
        return result
    }

    /// Puts something already produced on the clock and speaks it.
    ///
    /// The replay path. What it exists for is that a second anecdote heard from
    /// the History is the SAME delivery as a scheduled one — the same banner,
    /// the same jingle, the same held-banner release, the same classification of
    /// whatever goes wrong — because it is literally the same code below the
    /// produce. Anything that re-implemented delivery for replaying would drift
    /// from this one, and the drift would be silent.
    ///
    /// It is queued exactly as a run is. `dismissNotification` is global to the
    /// device and the audio path plays one thing at a time, so a replay pressed
    /// while an anecdote is speaking waits its turn rather than talking over it.
    ///
    /// What it deliberately is NOT is a run. Nothing here touches the failure
    /// counts: the backoff describes how the FEED is behaving, and hearing this
    /// morning's anecdote again is not evidence about anekdot.ru in either
    /// direction. There is no connector id to record against, and that is the
    /// point rather than an omission.
    public func deliver(_ output: ConnectorOutput) async -> RunResult {
        await queued { [self] in await send(output, from: nil) }
    }

    /// Takes a place in the delivery chain, waits for whatever is ahead, and
    /// runs `work` when it gets there.
    ///
    /// Claiming a place is a single actor-isolated step — there is no
    /// suspension between reading `tail` and writing it — so no caller can slip
    /// between the two and take the same place twice.
    ///
    /// Shared by both entry points rather than written twice, because a second
    /// copy is a second chain the moment one of them is edited, and two chains
    /// are no serialisation at all.
    private func queued(
        _ work: @escaping @Sendable () async -> RunResult
    ) async -> RunResult {
        let predecessor = tail
        let claimed = Task { () -> RunResult in
            await predecessor?.value
            // Checked on the far side of the wait. Cancellation cannot break
            // `predecessor?.value`, so without this a delivery cancelled while
            // queued goes on to put a banner up that nobody is waiting for.
            if Task.isCancelled { return .cancelled }
            return await work()
        }
        tail = Task { _ = await claimed.value }

        // `claimed` is unstructured, so it inherits neither the caller's
        // cancellation nor breaks on it when awaited. Forwarded by hand, or a
        // caller that gives up gets neither the work stopped nor itself back.
        return await withTaskCancellationHandler {
            await claimed.value
        } onCancel: {
            claimed.cancel()
        }
    }

    /// Runs a connector's background pass — restock, and confirm durability.
    ///
    /// Its own entry point rather than a tail on `runOnce`, so the app can put
    /// it on its own schedule: the pass is where the synthesis bill is paid,
    /// and the point of paying it here is that no banner is waiting on it.
    public func maintain(connectorId: String) async -> MaintenanceResult {
        guard let connector = registry.connector(id: connectorId) else {
            return .failed("unknown connector \(connectorId)")
        }
        guard store.settings(for: connectorId).isEnabled else { return .skipped }
        // A switched-off connector reaches `.skipped` first: restocking one
        // means a model load and a batch of synthesis for output nobody will
        // ever hear.
        guard let maintaining = connector as? any ConnectorMaintaining else { return .skipped }

        do {
            try await maintaining.maintain()
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            // Same rule on this path: a restock reaches the feed through the
            // same transport, so quitting mid-fetch surfaces here too. Backing
            // a connector off for having been interrupted is the same defect as
            // counting cancellation as a failure.
            return .cancelled
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// Asks the connector for something, then delivers it.
    ///
    /// The produce stays inside the chain, which is where it has always been:
    /// `AnecdoteConnector.produce()` pops an anecdote and retires it as played,
    /// and a produce that ran ahead of its turn would spend anecdotes on
    /// deliveries that had not happened yet — and, when the queue is empty,
    /// would put a whole batch of synthesis in front of the run behind it.
    private func produceAndSend(_ connector: any Connector) async -> RunResult {
        do {
            return await send(try await connector.produce(), from: connector.id)
        } catch {
            return classify(error)
        }
    }

    /// - Parameter connectorId: who this output is for, or nil on the replay
    ///   path, which has no connector to be for. Only a run can borrow device
    ///   state, because only a run has somebody to give it back on behalf of.
    private func send(_ output: ConnectorOutput, from connectorId: String?) async -> RunResult {
        do {
            var iconName: String?
            if let icon = output.icon {
                iconName = try await iconInstaller.ensureInstalled(icon)
            }

            // The backdrop before the reading. The overlay draws over
            // everything on screen, so setting it after the app has appeared is
            // a visible flicker of the old weather under the new number.
            if let wanted = output.overlay, let connectorId {
                try await custody.apply(wanted, for: connectorId)
            }

            // Held only when there is audio whose end can release it. `hold`
            // keeps the banner up until something dismisses it, and the dismiss
            // below is the only thing that will — so holding with nothing to
            // play leaves the clock stuck on that banner until somebody walks
            // over and presses the middle button.
            //
            // An app in the loop is never held: there is no banner over
            // anything, and nothing to dismiss.
            let holding = output.holdUntilAudioEnds && !output.localAudio.isEmpty
                && output.surface == .notification
            switch output.surface {
            case .notification:
                // `output.lifetime` stops here, and the asymmetry is the point:
                // a notification interrupts and then goes away by itself, so
                // there is nothing left on the clock for a lifetime to expire.
                // The firmware scopes the key to custom apps, as it scopes
                // several others to one surface or the other.
                //
                // `output.background` stops here too, and for a DIFFERENT
                // reason worth keeping apart from that one. The firmware does
                // not scope it — its property table marks `background` for
                // notifications as readily as for custom apps — so this is a
                // decision of this app's. The panel behind the text carries the
                // hour, and it is worth carrying on something glanced at later:
                // whoever is reading a banner is standing in front of the clock
                // while it scrolls, and already knows what time it is. Tinting
                // every interruption would spend the panel telling nobody
                // anything.
                try await device.notify(
                    NotifyPayload(
                        text: output.text,
                        icon: iconName,
                        duration: output.duration,
                        color: output.color,
                        rtttl: output.jingle,
                        hold: holding ? true : nil,
                        // The icon travels with the text and comes back, rather
                        // than sitting still or scrolling away for good.
                        pushIcon: 2
                    )
                )
            case let .app(name):
                // Through custody rather than straight to the device, because
                // an app added to the loop stays in it: something has to know
                // to take it out again.
                try await custody.show(
                    AppPayload(
                        text: output.text, icon: iconName,
                        color: output.color, duration: output.duration,
                        // The clock removing this app itself, for the endings
                        // this process never gets to clean up after. Custody
                        // above covers only the clean quit.
                        lifetime: output.lifetime,
                        // The panel behind the reading, which is where the hour
                        // rides. Only an app can carry one — see the notify
                        // branch above for why this app scopes it here even
                        // though the firmware would take it on either surface.
                        background: output.background
                    ),
                    named: name,
                    // Falling back to the app's own name rather than skipping
                    // the record: an output delivered outside a run has no
                    // connector to be given back on behalf of, but it is still
                    // in the loop and a quit still has to take it out.
                    for: connectorId ?? name
                )
            }

            // Strictly after the banner: the banner is the only thing standing
            // in for the speech on a clock that cannot decode audio, and a
            // voice with nothing on the display has no explanation.
            if !output.localAudio.isEmpty {
                await audio.play(output.localAudio)
                // The banner was held so it would last exactly as long as the
                // speech; nothing else knows when that is.
                if holding { try await releaseBanner() }
            }
            // Reached only when nothing threw, so this cannot turn a fault into
            // a cancellation — it says the caller stopped waiting, after the
            // banner was already taken down above.
            if Task.isCancelled { return .cancelled }
            return .delivered
        } catch {
            return classify(error)
        }
    }

    /// What a thrown error means for the delivery that raised it.
    ///
    /// One reading, shared by the produce and by the delivery, because the two
    /// halves must not classify the same error differently — a connector
    /// throwing `CancellationError` and a notify killed by the same quit are
    /// the same event seen from two places.
    ///
    /// `URLError(.cancelled)` is the transport naming this specific event
    /// rather than the ambient task state: `URLSession` reports a request
    /// killed by its task's cancellation that way, and app quit killing an
    /// in-flight notify is the ordinary producer. As typed as
    /// `CancellationError`, and it cannot swallow a device fault — those arrive
    /// as `AwtrixError.http`, never as a `URLError`.
    private func classify(_ error: any Error) -> RunResult {
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError, urlError.code == .cancelled { return .cancelled }
        return .failed(String(describing: error))
    }

    /// Takes the held banner down.
    ///
    /// `hold: true` is a promise the device keeps until something dismisses it,
    /// so the release must not ride a task that can be torn down. App quit
    /// cancelling the timer is the ordinary way that happens, and a dismiss
    /// sent on the cancelled task never leaves the Mac — leaving the clock on
    /// that banner until somebody walks over and presses the middle button.
    ///
    /// An unstructured task inherits no cancellation, and awaiting one is not
    /// interrupted by cancellation either, so the dismiss both goes out and is
    /// still reported when the device rejects it.
    private func releaseBanner() async throws {
        let release = Task { try await self.device.dismissNotification() }
        try await release.value
    }
}

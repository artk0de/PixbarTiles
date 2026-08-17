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

    /// The last delivery to have claimed a place. Deliveries run one at a time
    /// by waiting on it; see `runOnce(connectorId:)` for why they must.
    private var tail: Task<Void, Never>?

    public init(
        device: AwtrixDevice,
        registry: ConnectorRegistry,
        store: any SettingsStore,
        audio: any AudioPlaying,
        iconInstaller: any IconInstalling
    ) {
        self.device = device
        self.registry = registry
        self.store = store
        self.audio = audio
        self.iconInstaller = iconInstaller
    }

    /// Produces, delivers and speaks, one delivery at a time.
    ///
    /// Serialised rather than left to run concurrently, because this actor is
    /// reentrant and a delivery suspends for the whole length of its audio.
    /// `dismissNotification` is global to the device — it takes down whichever
    /// banner is showing, not the one this run put up — so two overlapping
    /// deliveries end with the first one's dismiss clearing the second one's
    /// banner while its speech is still running, and both anecdotes talking
    /// over each other. A timer tick and a "run now" from the menu are the two
    /// callers that produce it.
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
        guard let connector = registry.connector(id: connectorId) else {
            return .failed("unknown connector \(connectorId)")
        }
        guard store.settings(for: connectorId).isEnabled else { return .skipped }

        let predecessor = tail
        let work = Task { [self] () -> RunResult in
            await predecessor?.value
            // Checked on the far side of the wait. Cancellation cannot break
            // `predecessor?.value`, so without this a run cancelled while
            // queued goes on to put a banner up that nobody is waiting for.
            if Task.isCancelled { return .cancelled }
            return await deliver(connector)
        }
        tail = Task { _ = await work.value }

        // `work` is unstructured, so it inherits neither the caller's
        // cancellation nor breaks on it when awaited. Forwarded by hand, or a
        // caller that gives up gets neither the work stopped nor itself back.
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
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

    private func deliver(_ connector: any Connector) async -> RunResult {
        do {
            let output = try await connector.produce()
            var iconName: String?
            if let icon = output.icon {
                iconName = try await iconInstaller.ensureInstalled(icon)
            }

            // Held only when there is audio whose end can release it. `hold`
            // keeps the banner up until something dismisses it, and the dismiss
            // below is the only thing that will — so holding with nothing to
            // play leaves the clock stuck on that banner until somebody walks
            // over and presses the middle button.
            let holding = output.holdUntilAudioEnds && !output.localAudio.isEmpty
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
        } catch is CancellationError {
            return .cancelled
        } catch let error as URLError where error.code == .cancelled {
            // The transport naming this specific event, not the ambient task
            // state: `URLSession` reports a request killed by its task's
            // cancellation this way, and app quit killing an in-flight notify
            // is the ordinary producer. As typed as `CancellationError`, and it
            // cannot swallow a device fault — those arrive as
            // `AwtrixError.http`, never as a `URLError`.
            return .cancelled
        } catch {
            return .failed(String(describing: error))
        }
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

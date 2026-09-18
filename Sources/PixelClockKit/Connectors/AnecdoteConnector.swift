import Foundation

/// The laugh scales with the joke. A one-liner does not earn a long cackle, and
/// a build-up deserves more than three syllables.
public enum Laughter {
    public static let shortVariants = ["АХАХАХА", "АХАХАХАХА", "АХАХАХАХАХ ХАХА"]
    static let shortJokeWords = 12
    static let maxRepeats = 14
    static let breathAfterRepeats = 9

    public static func forAnecdote(
        _ text: String, using generator: inout some RandomNumberGenerator
    ) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words <= shortJokeWords {
            // Random so a run of quick jokes does not laugh identically.
            return shortVariants.randomElement(using: &generator) ?? shortVariants[0]
        }
        let repeats = min(4 + words / 8, maxRepeats)
        guard repeats >= breathAfterRepeats else {
            return "А" + String(repeating: "ХА", count: repeats)
        }
        // Past a certain length the laugh needs somewhere to breathe.
        return "А" + String(repeating: "ХА", count: repeats - 3)
            + " " + String(repeating: "ХА", count: 3)
    }
}

/// How much silence precedes each clip of an anecdote.
///
/// The three lead-ins are held as values rather than written into the mapping,
/// because the part that can go wrong is not the numbers but the ORDER the
/// cases are tried in — and `firstLine` and `laughter` are both tuned to 0.7 s,
/// so no assertion against the real values can tell a correct order from a
/// wrong one. Sentinels make the rule observable without disturbing timings
/// that were tuned by ear against real hardware.
struct ClipPacing: Sendable, Equatable {
    var firstLine: TimeInterval
    var betweenLines: TimeInterval
    var laughter: TimeInterval

    /// Tuned by ear: 0 before the announcement, 0.7 s before the first line,
    /// 0.25 s between dialogue lines, 0.7 s before the laughter — the last a
    /// comic beat rather than a separator.
    static let tuned = ClipPacing(firstLine: 0.7, betweenLines: 0.25, laughter: 0.7)

    /// The silence before the clip at `index` of `count`.
    ///
    /// The laughter is matched before the first line. In a two-clip anecdote —
    /// a joke whose only dialogue line is a bare marker, which the parser drops
    /// — the second clip is both "the first line" and "the last", and what it
    /// actually holds is the laughter.
    func leadIn(forClipAt index: Int, of count: Int) -> TimeInterval {
        switch index {
        case 0: return 0
        case count - 1: return laughter
        case 1: return firstLine
        default: return betweenLines
        }
    }
}

/// Fills the queue in batches. One sidecar session per batch: loading the model
/// is the entire cost of synthesis, so paying it per anecdote is the worst
/// possible trade.
public actor AnecdotePreparer {
    static let pacing = ClipPacing.tuned

    private let source: AnecdoteSource
    private let speech: any SpeechSynthesizing
    private let queue: AnecdoteQueue
    private let caster: VoiceCaster

    /// The voice every narration turn this preparer synthesizes is spoken in.
    ///
    /// Read off the caster rather than stored beside it, and readable without
    /// entering the actor because the connector in front of this has to answer
    /// `Connector.narrator` synchronously. Deriving it is what stops the
    /// connector's declared voice and the voice actually synthesized from ever
    /// being two different things — a disagreement nobody would hear until a
    /// whole batch had been spoken in the wrong character.
    public nonisolated var narrator: Voice { caster.narrator }
    /// The last refill to have claimed a place. Refills run one at a time by
    /// waiting on it; see `refill(target:)` for why they must.
    private var tail: Task<Void, Never>?

    public init(
        source: AnecdoteSource,
        speech: any SpeechSynthesizing,
        queue: AnecdoteQueue,
        caster: VoiceCaster = VoiceCaster()
    ) {
        self.source = source
        self.speech = speech
        self.queue = queue
        self.caster = caster
    }

    /// Prepare until the queue holds `target`, widening across the feed cascade
    /// when the primary feed runs dry. Returns how many were added.
    ///
    /// A feed that fails is stepped over rather than ending the refill: the
    /// cascade exists so one source cannot decide there are no anecdotes, and
    /// that has to hold for a 503 as much as for an exhausted feed. The failure
    /// is kept, and surfaces only if every feed failed and nothing was added —
    /// otherwise a network outage would be reported as an empty queue, which
    /// tells whoever has to fix it nothing at all.
    @discardableResult
    public func refill(target: Int) async throws -> Int {
        // Actors are reentrant, and this one suspends for the whole of a
        // synthesis. A second refill entering during that window computes
        // `unseen` against a `pending` the first has not written yet, gets the
        // identical list, and queues every anecdote a second time — synthesized
        // twice, played twice. Both entry points are shipped and Task 11 calls
        // both, so the overlap is a design shape rather than an accident.
        //
        // Callers queue up behind each other rather than being turned away:
        // `produce()` refills only when the queue is empty and has nothing to
        // show if it comes back empty-handed. Each one then recomputes `unseen`
        // against what its predecessor actually enqueued.
        //
        // Claiming a place is a single actor-isolated step — there is no
        // suspension between reading `tail` and writing it — so no caller can
        // slip between the two and take the same place twice.
        let predecessor = tail
        let work = Task { () -> Int in
            await predecessor?.value
            // Checked on the FAR SIDE of the wait, and only there. Cancellation
            // cannot break `predecessor?.value`, so without this a refill
            // cancelled while queued goes on to run a batch nobody is waiting
            // for. Checking BEFORE the wait would be worse than useless: this
            // task's own wrapper is what the next caller waits on, so bailing
            // out early would complete that wrapper while the predecessor is
            // still running and let the caller after us overlap it — which is
            // the reentrancy defect this chain exists to prevent.
            try Task.checkCancellation()
            return try await self.performRefill(target: target)
        }
        tail = Task { _ = try? await work.value }

        // `work` is unstructured, so it does not inherit the caller's
        // cancellation and awaiting its value does not break on it. Forwarded
        // by hand, or a host that wraps `produce()` in a timeout gets neither
        // the work stopped nor its caller back.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private func performRefill(target: Int) async throws -> Int {
        var added = 0
        var outage: (any Error)?

        for feed in AnecdoteSource.cascade {
            if await queue.ready() >= target { break }

            let fetched: [Anecdote]
            do {
                fetched = try await source.fetch(from: feed)
            } catch {
                outage = outage ?? error
                continue
            }

            for anecdote in await queue.unseen(from: fetched) {
                if await queue.ready() >= target { break }
                let prepared = try await prepare(anecdote)
                await queue.enqueue(prepared)
                added += 1
            }
        }

        if added == 0, let outage { throw outage }
        return added
    }

    private func prepare(_ anecdote: Anecdote) async throws -> PreparedAnecdote {
        var generator = SystemRandomNumberGenerator()
        let laughter = Laughter.forAnecdote(anecdote.text, using: &generator)

        // The announcement and the laughter are narration, so both land in the
        // narrator's voice without being special-cased.
        let body = DialogueParser.parse(anecdote.text)
        let turns = [Turn(speaker: .narrator, text: AnecdoteConnector.announcement)]
            + body
            + [Turn(speaker: .narrator, text: laughter)]

        // Namespaced per anecdote: a batch of ten would otherwise write ten
        // sets of turn-0.wav into the same directory.
        let urls = try await speech.synthesize(
            caster.cast(turns), namespace: PreparedAnecdote.namespace(for: anecdote.id)
        )
        let clips = urls.enumerated().map { index, url in
            SpokenClip(url: url, leadIn: Self.pacing.leadIn(forClipAt: index, of: urls.count))
        }
        // The moment is taken here rather than passed in, for the reason
        // `AnecdoteQueue.retire` takes its own: this call IS the preparing, so
        // a caller supplying an instant could only be reporting one that did
        // not happen.
        return PreparedAnecdote(
            id: anecdote.id, text: anecdote.text, clips: clips, laughter: laughter,
            preparedAt: Date(), rank: anecdote.rank
        )
    }
}

public struct AnecdoteConnector: Connector {
    public enum Failure: Error, Sendable, Equatable { case nothingPrepared }

    /// A 55-frame grinning face. The catalogue's animated flag is unreliable —
    /// it marks single-frame icons animated — so the frames were counted.
    public static let laughIcon = IconReference.catalogue(66558)
    public static let nokiaJingle =
        "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"
    /// The clock shows this, not the joke: the joke is heard, not read.
    public static let banner = "ВНИМАНИЕ, АНЕКДОТ!"
    public static let announcement = "Внимание! Анекдот!"

    public let id = "anecdotes"
    public let displayName = "Anecdotes"
    public let defaultInterval: TimeInterval = 30 * 60

    /// Answered by the preparer, which is what actually casts the turns.
    ///
    /// Not a stored property of its own. A connector is free to claim any voice
    /// it likes; only the caster inside the preparer decides what is spoken,
    /// and two answers to one question would drift the first time either was
    /// wired differently.
    public var narrator: Voice { preparer.narrator }

    /// How many prepared anecdotes a restock leaves waiting.
    public static let readyTarget = 10
    /// The depth at or below which a background pass restocks.
    ///
    /// Five rather than eight or three: a run that leaves five triggers a
    /// refill of five at a time rather than of two, and it is cheap either way
    /// because `SidecarSpeechSynthesizer` keeps the model loaded in a long-lived
    /// `--serve` process. The 70-second load is paid once per process, not once
    /// per refill, so the only thing a smaller batch buys is more of them.
    public static let lowWaterMark = 5

    private let queue: AnecdoteQueue
    private let preparer: AnecdotePreparer
    private let refillThreshold: Int
    private let batchSize: Int
    /// What the daily refresh calls today.
    ///
    /// Injected rather than read inline, because `maintain()` is declared by a
    /// protocol and cannot take an instant the way `reapExpired(now:)` does —
    /// and a rule about calendar days needs a test that can stand either side
    /// of a midnight. The shipped value is the only one that reads the clock.
    private let now: @Sendable () -> Date

    public init(
        queue: AnecdoteQueue,
        preparer: AnecdotePreparer,
        refillThreshold: Int = AnecdoteConnector.lowWaterMark,
        batchSize: Int = AnecdoteConnector.readyTarget,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.queue = queue
        self.preparer = preparer
        self.refillThreshold = refillThreshold
        self.batchSize = batchSize
        self.now = now
    }

    /// Pops an anecdote that was prepared earlier.
    ///
    /// This runs on a timer and is meant to be instant, so it does not top the
    /// queue up — `topUpIfNeeded` does, off this path. The one exception is an
    /// empty queue: with nothing to pop there is nothing else to show, so
    /// waiting for a batch buys the only anecdote there is.
    public func produce() async throws -> AwtrixDelivery {
        var anecdote = await nextPlayable()
        if anecdote == nil {
            // One, not a batch. A cold first launch would otherwise pay the
            // model load plus a whole batch of synthesis before the clock shows
            // anything; the batch is `topUpIfNeeded`'s job, off this path.
            try await preparer.refill(target: 1)
            anecdote = await nextPlayable()
        }
        guard let anecdote else { throw Failure.nothingPrepared }
        await queue.retire(anecdote)

        return output(for: anecdote)
    }

    /// What playing this anecdote puts on the clock.
    ///
    /// Its own function because the History plays one again, and a replay that
    /// built its own output would drift from this one — silently, since a
    /// missing icon or a missing hold looks like nothing at all until the
    /// banner is left up with no audio to end it. The two callers are
    /// `produce()` and the replay, and they get the same value.
    ///
    /// Nothing here touches the queue, and that is the rule rather than an
    /// accident: `retire` is what makes an anecdote played, it belongs to
    /// `produce()` above, and a replay must not spend an anecdote nobody has
    /// heard.
    public func output(for anecdote: PreparedAnecdote) -> AwtrixDelivery {
        AwtrixDelivery(
            text: Self.banner,
            icon: Self.laughIcon,
            jingle: Self.nokiaJingle,
            localAudio: anecdote.clips,
            holdUntilAudioEnds: true,
            color: "#FFD200"
        )
    }

    /// What has played recently and can still be heard again, newest first.
    ///
    /// A pass-through to the queue, which owns the record and the window that
    /// bounds it. Here rather than reached for directly, so the app has one
    /// collaborator for anecdotes instead of two — and so nothing outside this
    /// type needs to know that the History and the played set are the same file.
    public func history() async -> [PlayedAnecdote] {
        await queue.history()
    }

    /// Pops until an anecdote whose audio is still on disk turns up.
    ///
    /// A batch restored from an earlier launch may point at clips the system's
    /// temporary directory no longer holds. Handing one of those out shows a
    /// banner that waits for audio which never arrives, so the entry is dropped
    /// and the next one taken. It is left unplayed: nothing was heard, so it
    /// stays eligible to be prepared again.
    private func nextPlayable() async -> PreparedAnecdote? {
        while let anecdote = await queue.next() {
            if anecdote.isPlayable { return anecdote }
        }
        return nil
    }

    /// Tops the queue up when it runs low, and once a day whether it is low or
    /// not. The host calls this away from the play path, because a refill loads
    /// a 1.8 GB model and synthesizes a whole batch — a minute or more of work
    /// that must never sit inside `produce()`.
    ///
    /// Two reasons to restock, and the daily one is not a special case of the
    /// other. A queue holding ten of yesterday's anecdotes is full by every
    /// measure of depth and still has nothing from today, which is the thing
    /// the user actually opened the app for. Yesterday's are kept rather than
    /// discarded — they simply rank below everything new — so the fresh batch
    /// is asked for ON TOP of what is there, not up to a target the leftovers
    /// have already met.
    ///
    /// It needs no timer of its own. `maintain()` runs before and after every
    /// run, so the first pass on any day finds nothing prepared that day and
    /// the ones after it find the batch this one made.
    public func topUpIfNeeded() async throws {
        let today = now()
        let ready = await queue.ready()

        guard await queue.hasAnythingPrepared(onTheDayOf: today) else {
            try await preparer.refill(target: ready + batchSize)
            return
        }

        guard ready <= refillThreshold else { return }
        try await preparer.refill(target: batchSize)
    }
}

extension AnecdoteConnector: ConnectorMaintaining {
    /// The background pass the host schedules: make sure what was already
    /// played is on disk, then restock.
    ///
    /// The flush comes first and stops the pass when it fails, for two reasons.
    /// The played set is what the "never repeat an anecdote" requirement rests
    /// on, and re-attempting its write costs nothing next to a batch of
    /// synthesis — `retire()` cannot report a failed write itself, because it
    /// is called with the anecdote already on its way to the player and there
    /// is nothing left to undo. And a store that cannot be written cannot hold
    /// a restocked batch either, so synthesizing ten anecdotes into it would
    /// spend a minute of model time on a queue the next launch will not see.
    ///
    /// The reap sits between the two, and the order is the argument for putting
    /// it here at all. After the flush, because a store that cannot be written
    /// cannot record what the reap removed either, and a reap whose result is
    /// lost deletes clips the next launch still believes in. Before the
    /// restock, because reaping is what frees the depth the restock then reads:
    /// a queue whose whole batch has just aged out is refilled in the same pass
    /// rather than one run later.
    public func maintain() async throws {
        try await queue.flush()
        _ = await queue.reapExpired(now: now())
        try await topUpIfNeeded()
    }
}

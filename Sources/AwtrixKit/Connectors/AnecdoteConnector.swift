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

/// Fills the queue in batches. One sidecar session per batch: loading the model
/// is the entire cost of synthesis, so paying it per anecdote is the worst
/// possible trade.
public actor AnecdotePreparer {
    static let leadFirstLine: TimeInterval = 0.7
    static let leadBetweenLines: TimeInterval = 0.25
    static let leadLaughter: TimeInterval = 0.7

    private let source: AnecdoteSource
    private let speech: any SpeechSynthesizing
    private let queue: AnecdoteQueue
    private let caster: VoiceCaster
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
            return try await self.performRefill(target: target)
        }
        tail = Task { _ = try? await work.value }
        return try await work.value
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
        var clips: [SpokenClip] = []
        for (index, url) in urls.enumerated() {
            let lead: TimeInterval
            // The laughter case is matched before the first-line case, so a
            // two-clip anecdote takes the beat the code says it takes. The two
            // are the same 0.7 s today, which is exactly why retuning one of
            // them would otherwise move the other in silence.
            switch index {
            case 0: lead = 0
            case urls.count - 1: lead = Self.leadLaughter
            case 1: lead = Self.leadFirstLine
            default: lead = Self.leadBetweenLines
            }
            clips.append(SpokenClip(url: url, leadIn: lead))
        }
        return PreparedAnecdote(
            id: anecdote.id, text: anecdote.text, clips: clips, laughter: laughter
        )
    }
}

public struct AnecdoteConnector: Connector {
    public enum Failure: Error, Sendable, Equatable { case nothingPrepared }

    /// A 55-frame grinning face. The catalogue's animated flag is unreliable —
    /// it marks single-frame icons animated — so the frames were counted.
    public static let laughIcon = IconRef.catalogue(66558)
    public static let nokiaJingle =
        "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"
    /// The clock shows this, not the joke: the joke is heard, not read.
    public static let banner = "ВНИМАНИЕ, АНЕКДОТ!"
    public static let announcement = "Внимание! Анекдот!"

    public let id = "anecdotes"
    public let displayName = "Anecdotes"
    public let defaultInterval: TimeInterval = 30 * 60

    private let queue: AnecdoteQueue
    private let preparer: AnecdotePreparer
    private let refillThreshold: Int
    private let batchSize: Int

    public init(
        queue: AnecdoteQueue,
        preparer: AnecdotePreparer,
        refillThreshold: Int = 3,
        batchSize: Int = 10
    ) {
        self.queue = queue
        self.preparer = preparer
        self.refillThreshold = refillThreshold
        self.batchSize = batchSize
    }

    /// Pops an anecdote that was prepared earlier.
    ///
    /// This runs on a timer and is meant to be instant, so it does not top the
    /// queue up — `topUpIfNeeded` does, off this path. The one exception is an
    /// empty queue: with nothing to pop there is nothing else to show, so
    /// waiting for a batch buys the only anecdote there is.
    public func produce() async throws -> ConnectorOutput {
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

        return ConnectorOutput(
            text: Self.banner,
            icon: Self.laughIcon,
            jingle: Self.nokiaJingle,
            localAudio: anecdote.clips,
            holdUntilAudioEnds: true,
            color: "#FFD200"
        )
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

    /// Tops the queue up when it runs low. The host calls this away from the
    /// play path, because a refill loads a 1.8 GB model and synthesizes a whole
    /// batch — a minute or more of work that must never sit inside `produce()`.
    public func topUpIfNeeded() async throws {
        guard await queue.ready() <= refillThreshold else { return }
        try await preparer.refill(target: batchSize)
    }
}

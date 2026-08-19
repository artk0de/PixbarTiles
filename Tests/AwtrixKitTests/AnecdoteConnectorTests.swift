import Foundation
import Testing
@testable import AwtrixKit

/// Every fixture in these tests writes its clips somewhere under the temporary
/// directory, so that is the root the reaper is contained by here. It is
/// deliberately wide: a narrower one would answer the earlier guards' questions
/// for them, and a name check that never runs because containment rejected
/// first is a check nothing is testing. The tests that are ABOUT containment
/// name their own root.
private let anyTemporaryRoot = FileManager.default.temporaryDirectory

/// Nothing here reaps, so any window will do — but it has to be one no fixture
/// could reach, or a test about the connector would start failing for the
/// queue's reasons.
private let anyRetention: TimeInterval = 10 * 24 * 60 * 60

private func makeSource(_ xml: String) -> AnecdoteSource {
    let transport = RecordingTransport()
    transport.body = Data(xml.utf8)
    return AnecdoteSource(transport: transport)
}

private func temporaryStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("conn-\(UUID().uuidString).json")
}

private let dialogueFeed = """
<rss><channel><item>
<description><![CDATA[Звонок от курьера:<br>- Я подъехал...<br>- Но я вас не вижу...]]></description>
<guid>https://www.anekdot.ru/id/1/</guid>
</item></channel></rss>
"""

/// Two anecdotes with distinct guids, because the collision the namespace
/// exists to prevent only happens in a batch. A single-item feed cannot show
/// whether the second anecdote overwrote the first.
private let batchFeed = """
<rss><channel>
<item>
<description><![CDATA[Звонок от курьера:<br>- Я подъехал...<br>- Но я вас не вижу...]]></description>
<guid>https://www.anekdot.ru/id/1/</guid>
</item>
<item>
<description><![CDATA[Заходит в лифт:<br>- Вам какой этаж?<br>- Любой, лишь бы вниз.]]></description>
<guid>https://www.anekdot.ru/id/2/</guid>
</item>
</channel></rss>
"""

/// A joke whose only dialogue line is a bare marker. The parser drops the line
/// as a separator, so this reaches the preparer as no turns at all — the
/// shortest anecdote the live feed can produce.
private let markerOnlyFeed = """
<rss><channel><item>
<description><![CDATA[-]]></description>
<guid>https://www.anekdot.ru/id/3/</guid>
</item></channel></rss>
"""

/// Serves a server error for the first `failing` requests, then the body.
///
/// Lock-guarded like every other double here: the counter is touched from an
/// async call path, and a double that loses a decrement would silently turn
/// this into a test of nothing.
private final class FlakyTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingFailures: Int
    private let body: Data

    init(failing: Int, then body: Data) {
        self.remainingFailures = failing
        self.body = body
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let failing = lock.withLock { () -> Bool in
            guard remainingFailures > 0 else { return false }
            remainingFailures -= 1
            return true
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: failing ? 503 : 200,
            httpVersion: nil, headerFields: nil
        )!
        return (failing ? Data("<html>maintenance</html>".utf8) : body, response)
    }
}

/// Suspends inside `synthesize`, the way a real one does.
///
/// `StubSpeechSynthesizer` returns without ever suspending, so a preparer that
/// is unsafe across a suspension point looks correct against it. Every test
/// about overlapping work needs this one instead.
private final class SuspendingSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("suspending-speech-\(UUID().uuidString)")

    var namespaces: [String] { lock.withLock { recorded } }

    func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL] {
        lock.withLock { recorded.append(namespace) }
        // Any suspension at all opens the window; a real synthesis suspends for
        // fractions of a second per turn against an already-loaded model.
        await Task.yield()
        let directory = root.appendingPathComponent(namespace)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return try turns.indices.map { index in
            let url = directory.appendingPathComponent("stub-turn-\(index).wav")
            try Data().write(to: url)
            return url
        }
    }
}

/// Blocks in `synthesize` until cancelled, and reports when it got there.
///
/// A cancelled sleep throws, which is how a real async synthesizer surfaces
/// cancellation. The wait is long enough that a refill which ignores
/// cancellation is unmistakable rather than merely slow.
private final class BlockingSpeechSynthesizer: SpeechSynthesizing, @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    var hasStarted: Bool { lock.withLock { started } }

    func synthesize(_ turns: [VoicedTurn], namespace: String) async throws -> [URL] {
        lock.withLock { started = true }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        return []
    }
}

/// Holds the first request open until the test releases it, then serves the
/// body to everyone.
///
/// The waiting is done with a continuation rather than a sleep, because a sleep
/// throws on cancellation and that is not what the shipped code does: the real
/// `SidecarSpeechSynthesizer` is a blocking synchronous read loop with no
/// suspension point that could notice a cancelled task. A double that notices
/// would let a refill die on its own and hide whether the guard under test
/// works at all.
private final class GatedTransport: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private var gate: CheckedContinuation<Void, Never>?
    private var opened = false
    private var seen = 0
    private let body: Data

    init(body: Data) { self.body = body }

    var requestCount: Int { lock.withLock { seen } }

    func open() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            let held = gate
            gate = nil
            return held
        }
        waiting?.resume()
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let isFirst = lock.withLock { () -> Bool in
            seen += 1
            return seen == 1
        }
        if isFirst {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let alreadyOpen = lock.withLock { () -> Bool in
                    if opened { return true }
                    gate = continuation
                    return false
                }
                if alreadyOpen { continuation.resume() }
            }
        }
        let response = HTTPURLResponse(
            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
        )!
        return (body, response)
    }
}

/// Deterministic, so the short-joke draw can be asserted.
///
/// A counter rather than the constant it looks like it should be:
/// `randomElement(using:)` rejection-samples, and a generator that answers the
/// same value forever never leaves that loop. Measured on this machine — a
/// generator returning 0 hangs a three-element draw indefinitely rather than
/// returning a poor choice.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64 = 0x2545_F491_4F6C_DD1D

    mutating func next() -> UInt64 {
        // xorshift64: deterministic, never reaches zero, and terminates every
        // rejection loop because consecutive draws differ.
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

// MARK: - Laughter

@Test func laughterGrowsWithTheLengthOfTheJoke() {
    var generator = SeededGenerator()
    let short = Laughter.forAnecdote("Раз два три", using: &generator)
    let long = Laughter.forAnecdote(
        String(repeating: "слово ", count: 60), using: &generator
    )

    #expect(short.count < long.count)
    #expect(long.hasPrefix("А"))
}

@Test func aLongJokeLaughTakesABreath() {
    var generator = SeededGenerator()
    let laugh = Laughter.forAnecdote(String(repeating: "слово ", count: 100), using: &generator)

    #expect(laugh.contains(" "))
}

@Test func aShortJokeDrawsFromTheShortVariants() {
    var generator = SeededGenerator()
    let laugh = Laughter.forAnecdote("Коротко", using: &generator)

    #expect(Laughter.shortVariants.contains(laugh))
}

// MARK: - Clip pacing

// Sentinels rather than the tuned values. On real hardware `firstLine` and
// `laughter` are both 0.7 s, so a table written against the real numbers
// cannot tell the intended case order from the reverse of it — which is what
// made the end-to-end two-clip test unable to observe the rule it named.
@Test func theLeadInTableMatchesTheLaughterBeforeTheFirstLine() {
    let pacing = ClipPacing(firstLine: 1, betweenLines: 2, laughter: 3)

    // Five clips: announcement, first line, two between, laughter.
    #expect(pacing.leadIn(forClipAt: 0, of: 5) == 0)
    #expect(pacing.leadIn(forClipAt: 1, of: 5) == 1)
    #expect(pacing.leadIn(forClipAt: 2, of: 5) == 2)
    #expect(pacing.leadIn(forClipAt: 3, of: 5) == 2)
    #expect(pacing.leadIn(forClipAt: 4, of: 5) == 3)

    // Three clips: no "between" at all.
    #expect(pacing.leadIn(forClipAt: 1, of: 3) == 1)
    #expect(pacing.leadIn(forClipAt: 2, of: 3) == 3)

    // Two clips: the second is both the first line and the last, and it holds
    // the laughter. This case is the whole reason the order is what it is.
    #expect(pacing.leadIn(forClipAt: 0, of: 2) == 0)
    #expect(pacing.leadIn(forClipAt: 1, of: 2) == 3)
}

@Test func theTunedPacingIsWhatWasMeasuredByEar() {
    #expect(ClipPacing.tuned == ClipPacing(firstLine: 0.7, betweenLines: 0.25, laughter: 0.7))
}

// MARK: - Namespacing

@Test func namespacesDistinguishGuidsThatShareTheirPrefix() {
    // Every anekdot.ru guid opens with the same host and path. A key taken from
    // the front would collapse the whole feed onto one directory.
    let first = PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1622958/")
    let second = PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1622959/")

    #expect(first != second)
    #expect(first.contains("/") == false)
}

// The defect this whole namespace exists for: ten anecdotes prepared in one
// batch used to write ten sets of turn-0.wav into one directory, destroying
// nine while the queue still reported ten ready.
@Test func aBatchGivesEveryAnecdoteItsOwnClipFiles() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: speech, queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 2)
    let first = try #require(await queue.next())
    let second = try #require(await queue.next())
    let firstClips = Set(first.clips.map(\.url))
    let secondClips = Set(second.clips.map(\.url))

    // Counted as well as compared: two empty sets are also disjoint, and that
    // would pass while proving nothing.
    #expect(firstClips.count == 5)
    #expect(secondClips.count == 5)
    #expect(firstClips.isDisjoint(with: secondClips))
    #expect(Set(speech.namespaces).count == 2)
}

// MARK: - The preparer

@Test func preparerFillsTheQueueAndSynthesizesEveryTurn() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 1)                       // the fixture holds one anecdote
    #expect(await queue.ready() == 1)
    // announcement + narration + two dialogue lines + laughter
    #expect(speech.received.count == 5)
    // actor 0 says "Я подъехал" and lands male, so both actors draw from the
    // pool: arthas opens it, acolyte follows.
    #expect(speech.received.map(\.voice.id)
        == ["arthas", "arthas", "arthas", "acolyte", "arthas"])
}

// The connector's declared voice and the voice its clips are actually
// synthesized in are one answer, not two that happen to agree. A stored
// property beside the caster would satisfy `Connector.narrator` while every
// clip came out in a different character — and nobody would find out until a
// whole batch had been spoken.
@Test func theAnecdoteConnectorNarratesInTheVoiceItsCasterActuallyUses() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue,
        caster: VoiceCaster(narrator: .peon)
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await preparer.refill(target: 1)

    // Named as different from the default first: with the shipped narrator both
    // expectations below hold whether or not anything reads the caster at all.
    #expect(Voice.peon != VoiceCaster.defaultNarrator)
    #expect(connector.narrator == .peon)
    // The announcement and the laughter are the narration turns, and they
    // bracket the anecdote.
    #expect(speech.received.first?.voice == .peon)
    #expect(speech.received.last?.voice == .peon)
}

// And the shipped wiring names no voice, so the anecdotes go on sounding
// exactly as they did.
@Test func anAnecdoteConnectorWiredWithoutACasterKeepsTheDefaultNarrator() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let connector = AnecdoteConnector(
        queue: queue,
        preparer: AnecdotePreparer(
            source: makeSource(dialogueFeed), speech: StubSpeechSynthesizer(), queue: queue
        )
    )

    #expect(connector.narrator == VoiceCaster.defaultNarrator)
    #expect(connector.narrator.id == "arthas")
}

@Test func preparerSkipsAnecdotesAlreadyPlayed() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    await queue.markPlayed("https://www.anekdot.ru/id/1/")
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 0)
    #expect(speech.received.isEmpty)
}

// The cascade widens when a feed runs dry. It has to widen when one is down
// too — a single 503 collapsing the refill costs the other two feeds' ~22
// anecdotes, and the clock shows nothing for the next half hour.
@Test func aFeedOutageWidensToTheNextFeedInsteadOfCollapsing() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(
            transport: FlakyTransport(failing: 1, then: Data(dialogueFeed.utf8))
        ),
        speech: StubSpeechSynthesizer(), queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 1)
}

// Swallowing every feed error would report the outage as "nothing prepared"
// and hide the reason from whoever has to fix it.
@Test func aRefillThatReachedNoFeedAtAllReportsTheOutage() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: FlakyTransport(failing: 3, then: Data())),
        speech: StubSpeechSynthesizer(), queue: queue
    )

    await #expect(throws: AwtrixError.self) {
        _ = try await preparer.refill(target: 5)
    }
}

// Both refill entry points are shipped and Task 11 calls both: `produce()`
// refills an empty queue, `topUpIfNeeded()` refills from the host's background
// path. Overlapping them must not queue the same anecdote twice — actors are
// reentrant, so the second refill would otherwise compute `unseen` against a
// `pending` the first has not written yet and get the identical list.
@Test func twoOverlappingRefillsDoNotQueueTheSameAnecdoteTwice() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: SuspendingSpeechSynthesizer(), queue: queue
    )

    async let first = preparer.refill(target: 10)
    async let second = preparer.refill(target: 10)
    _ = try await (first, second)

    var queued: [String] = []
    while let anecdote = await queue.next() { queued.append(anecdote.id) }

    #expect(queued == ["https://www.anekdot.ru/id/1/", "https://www.anekdot.ru/id/2/"])
}

// Serialising refills through an unstructured `Task` costs the caller's
// cancellation unless it is forwarded by hand: an unstructured task does not
// inherit it, and awaiting its value does not break on it. `produce()` refills
// inside that task, so a host wrapping `produce()` in a timeout would neither
// stop the work nor get its caller back.
@Test func cancellingARefillStopsItRatherThanRunningItToCompletion() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = BlockingSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: speech, queue: queue
    )

    let refill = Task { try await preparer.refill(target: 10) }
    var waited = 0
    while !speech.hasStarted, waited < 500 {
        try await Task.sleep(nanoseconds: 1_000_000)
        waited += 1
    }
    #expect(speech.hasStarted)

    let cancelledAt = ContinuousClock.now
    refill.cancel()
    await #expect(throws: (any Error).self) { _ = try await refill.value }

    #expect(ContinuousClock.now - cancelledAt < .seconds(1))
    #expect(await queue.ready() == 0)
}

// Cancelling a refill that is still WAITING ITS TURN. `topUpIfNeeded()` can be
// a minute into a ten-anecdote batch when the timer fires, `produce()` finds an
// empty queue, and its `refill(target: 1)` lines up behind that batch. Without a
// check on the far side of the wait, the queued refill runs a batch nobody is
// waiting for any more and reports success.
//
// It still cannot return before the refill ahead of it finishes — the wait
// itself is not interruptible, by design. See `refill(target:)`.
@Test func cancellingARefillThatIsWaitingItsTurnStopsItToo() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let transport = GatedTransport(body: Data(batchFeed.utf8))
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport),
        speech: StubSpeechSynthesizer(), queue: queue
    )

    // Park a refill at the head of the chain, inside its fetch.
    let head = Task { try await preparer.refill(target: 1) }
    var waited = 0
    while transport.requestCount == 0, waited < 500 {
        try await Task.sleep(nanoseconds: 1_000_000)
        waited += 1
    }
    #expect(transport.requestCount == 1)

    let queued = Task { try await preparer.refill(target: 10) }
    await Task.yield()
    queued.cancel()
    transport.open()

    await #expect(throws: CancellationError.self) { _ = try await queued.value }

    // The refill ahead of it is untouched: cancelling a queued caller must not
    // kill the batch already running.
    let headAdded = try await head.value
    #expect(headAdded == 1)
    // Only the head's anecdote landed. The cancelled refill would have added
    // the second one had it run.
    #expect(await queue.ready() == 1)
}

// MARK: - The connector

@Test func connectorEmitsTheBannerNotTheJoke() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.text == AnecdoteConnector.banner)
    #expect(output.text.contains("курьера") == false)
    #expect(output.holdUntilAudioEnds)
    #expect(output.icon == .catalogue(66558))
    #expect(output.jingle == AnecdoteConnector.nokiaJingle)
}

@Test func connectorPacesTheClipsWithLeadIns() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.localAudio.first?.leadIn == 0)                             // announcement
    #expect(output.localAudio.last?.leadIn == AnecdotePreparer.pacing.laughter)  // punchline beat
    #expect(output.localAudio.count == 5)
}

// With no dialogue at all the announcement and the laughter are alone
// together, and the second clip is both "the first line" and "the last". It is
// the laughter, so it takes the laughter's beat. Both lead-ins are 0.7 s today,
// which is exactly what would let a retune of one silently move the other.
@Test func aTwoClipAnecdoteGivesItsLastClipTheLaughterBeat() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(markerOnlyFeed), speech: StubSpeechSynthesizer(), queue: queue
    )

    _ = try await preparer.refill(target: 1)
    let prepared = try #require(await queue.next())

    #expect(prepared.clips.count == 2)
    #expect(prepared.clips.last?.leadIn == AnecdotePreparer.pacing.laughter)
}

@Test func playingAnAnecdoteMarksItSoItNeverRepeats() async throws {
    let store = temporaryStore()
    let queue = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()

    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
}

// MARK: - Hearing one again

/// A host wired to this connector, with the two collaborators a replay would
/// otherwise put on the network and the speakers stubbed out.
private func makeAnecdoteHost(for connector: AnecdoteConnector) -> ConnectorHost {
    let registry = ConnectorRegistry()
    registry.register(connector)
    return ConnectorHost(
        device: AwtrixDevice(host: "10.0.0.5", transport: RecordingTransport()),
        registry: registry,
        store: InMemorySettingsStore(),
        audio: SpyAudio(),
        iconInstaller: StubIconInstaller()
    )
}

// What "Play again" means: the same banner, the same jingle, the same clips in
// the same order. Written as an equality against what the run itself put on the
// clock, because any second way of building the output is a way for the two to
// drift — and the drift would be silent, since a replay looks fine right up
// until the icon or the hold is missing from it.
@Test func replayingAPastAnecdotePutsExactlyWhatItsRunPutOnTheClock() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let produced = try await connector.produce()
    let played = try #require(await queue.history().first)

    #expect(connector.output(for: played.anecdote) == produced)
    // And not because both are empty: the output really carries the anecdote.
    #expect(produced.text == AnecdoteConnector.banner)
    #expect(produced.localAudio.count == 5)
    #expect(produced.icon == AnecdoteConnector.laughIcon)
}

// Rule one of the History. `retire` is what makes an anecdote played, and it
// belongs to `produce()` — the path a replay deliberately does not take. So
// replaying cannot spend an anecdote nobody has heard yet: the queue's depth,
// its history and the played set are all exactly where the run left them.
@Test func aReplayDoesNotAddToThePlayedSet() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 2)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)
    let host = makeAnecdoteHost(for: connector)

    // A run first, so what marking one played looks like is on the record here
    // rather than assumed from another test.
    #expect(await host.runOnce(connectorId: "anecdotes") == .delivered)
    let played = try #require(await queue.history().first).anecdote
    #expect(await queue.hasPlayed(played.id))
    #expect(await queue.ready() == 1)

    // The one still waiting, replayed. Which of the two the run took is the
    // play order's business, so the other one is picked rather than named.
    let waitingId = played.id == "https://www.anekdot.ru/id/1/"
        ? "https://www.anekdot.ru/id/2/"
        : "https://www.anekdot.ru/id/1/"
    let waiting = PreparedAnecdote(
        id: waitingId, text: "joke", clips: played.clips, laughter: "АХАХАХА",
        preparedAt: nil, rank: nil
    )

    #expect(await host.deliver(connector.output(for: waiting)) == .delivered)

    #expect(await queue.hasPlayed(waitingId) == false)
    #expect(await queue.ready() == 1)
    #expect(await queue.history().count == 1)
}

@Test func anEmptyQueueAndAnExhaustedFeedThrowsRatherThanShowingNothing() async {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource("<rss><channel></channel></rss>"),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    // The specific case, not any error: a decode failure or a URL error would
    // satisfy `(any Error).self` while meaning something entirely different.
    await #expect(throws: AnecdoteConnector.Failure.nothingPrepared) {
        _ = try await connector.produce()
    }
}

// MARK: - Reclaiming the disk

// Played is not spent. The user can ask to hear an anecdote again, and History
// has nothing to replay from if the audio went the moment the next one came
// due. What removes these files now is age, and only `reapExpired` does it.
@Test func producingAnAnecdoteKeepsThePreviousOnesClips() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 2)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let first = try await connector.produce()
    let firstDirectory = try #require(first.localAudio.first?.url.deletingLastPathComponent())
    // Still there while it is the one playing.
    #expect(FileManager.default.fileExists(atPath: firstDirectory.path))

    let second = try await connector.produce()
    let secondDirectory = try #require(second.localAudio.first?.url.deletingLastPathComponent())

    // Both, half an hour after the first was heard and while the second is
    // still playing.
    #expect(FileManager.default.fileExists(atPath: firstDirectory.path))
    #expect(FileManager.default.fileExists(atPath: secondDirectory.path))
}

// Through `produce()`, which is the path the app actually takes: `retire()` is
// the only write on it, and `markPlayed` has no production caller at all. A
// durability test that goes through `markPlayed` pins a method nothing calls.
@Test func anAnecdotePlayedThroughProduceIsStillPlayedAfterARestart() async throws {
    let store = temporaryStore()
    let queue = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 2)
    _ = try await AnecdoteConnector(queue: queue, preparer: preparer).produce()

    let reopened = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    #expect(await reopened.hasPlayed("https://www.anekdot.ru/id/1/"))
}

// The record has to reach disk with the clips it names, or a restart loses what
// the user replays from — and leaves the audio on disk with nothing pointing at
// it, which is the same directory leaked for good either way.
@Test func anAnecdotePlayedThroughProduceIsStillInHistoryAfterARestart() async throws {
    let store = temporaryStore()
    let speech = StubSpeechSynthesizer()
    let queue = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 2)
    let first = try await AnecdoteConnector(queue: queue, preparer: preparer).produce()
    let firstDirectory = try #require(first.localAudio.first?.url.deletingLastPathComponent())

    // Killed between two anecdotes, then relaunched onto the same store.
    let reopened = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )

    let history = await reopened.history()
    #expect(history.map(\.anecdote.id) == ["https://www.anekdot.ru/id/1/"])
    #expect(history.first?.anecdote.clips == first.localAudio)
    #expect(FileManager.default.fileExists(atPath: firstDirectory.path))
}

// A batch survives a restart; the temporary directory holding its audio may
// not. Handing out an anecdote whose clips are gone shows a banner with
// `holdUntilAudioEnds` set and no audio to end it — the clock sticks there.
@Test func anAnecdoteWhoseClipsAreGoneIsSkipped() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 2)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    try FileManager.default.removeItem(
        at: speech.root.appendingPathComponent(
            PreparedAnecdote.namespace(for: "https://www.anekdot.ru/id/1/")
        )
    )

    let output = try await connector.produce()

    #expect(output.localAudio.allSatisfy {
        FileManager.default.fileExists(atPath: $0.url.path)
    })
    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/2/"))
    // Nothing was heard, so it stays eligible to be prepared again.
    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/") == false)
}

// MARK: - Where the batch is paid for

// `produce()` fires on a timer and is supposed to be instant. Refilling inside
// it pays a 70-second model load and a whole batch of synthesis before the
// clock shows anything, which is the trade the queue exists to avoid.
@Test func produceDoesNotReachTheNetworkWhenTheQueueHasSomethingToPop() async throws {
    let transport = RecordingTransport()
    transport.body = Data(dialogueFeed.utf8)
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let fetchesToFill = transport.requests.count
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()

    #expect(transport.requests.count == fetchesToFill)
}

// The one case worth waiting for: nothing to pop means there is nothing else
// to show, so the load buys the only anecdote there is.
@Test func anEmptyQueueRefillsRatherThanShowingNothing() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.text == AnecdoteConnector.banner)
    #expect(output.localAudio.count == 5)
}

// A cold first launch shows the clock something after one synthesis, not after
// a whole batch of them on top of the model load. The batch is
// `topUpIfNeeded`'s job.
@Test func anEmptyQueuePreparesOneAnecdoteNotAWholeBatch() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: speech, queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()

    #expect(speech.namespaces.count == 1)
    #expect(await queue.ready() == 0)
}

@Test func topUpIfNeededFillsTheQueueOffThePlayPath() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    try await connector.topUpIfNeeded()

    #expect(await queue.ready() == 2)
}

// MARK: - The host's background pass

// The host reaches this connector as `any Connector` and knows nothing about
// queues or batches. `maintain()` is the one door through which the restocking
// the queue depends on actually gets called.
@Test func maintenanceRestocksTheQueue() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    try await connector.maintain()

    #expect(await queue.ready() == 2)
}

// `retire()` cannot report a failed write — it is called with the anecdote
// already on its way to the player, so there is nothing to undo. The write is
// re-attempted here instead, which is both the remedy and the only place the
// failure can be surfaced. Without it a played id that never reached disk comes
// back unplayed and the anecdote repeats.
//
// The queue is stocked past the refill threshold on purpose, so the restock is
// a no-op and the re-written file can only have come from the flush.
@Test func maintenanceRewritesTheStoreSoAPlayedAnecdoteStaysPlayed() async throws {
    let store = temporaryStore()
    let queue = AnecdoteQueue(storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention)
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 2)
    let connector = AnecdoteConnector(
        queue: queue, preparer: preparer, refillThreshold: 1, batchSize: 10
    )
    try FileManager.default.removeItem(at: store)

    try await connector.maintain()

    #expect(FileManager.default.fileExists(atPath: store.path))
    let reopened = AnecdoteQueue(
        storeURL: store, clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    #expect(await reopened.ready() == 2)
}

// A store that cannot be written is reported rather than swallowed, and it
// stops the pass before the restock: ten anecdotes synthesized into a queue
// that cannot reach disk are ten model-seconds spent on a batch the next launch
// will not see.
@Test func maintenanceReportsAStoreThatCannotBeWrittenAndDoesNotRestock() async throws {
    // A regular file where the store's parent directory should be, so the write
    // fails for a reason the code cannot talk its way around.
    let blocker = FileManager.default.temporaryDirectory
        .appendingPathComponent("blocked-\(UUID().uuidString)")
    try Data().write(to: blocker)
    let queue = AnecdoteQueue(
        storeURL: blocker.appendingPathComponent("store.json"),
        clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    await #expect(throws: (any Error).self) {
        try await connector.maintain()
    }
    #expect(await queue.ready() == 0)
}

@Test func topUpIfNeededLeavesAStockedQueueAlone() async throws {
    let transport = RecordingTransport()
    transport.body = Data(batchFeed.utf8)
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 2)
    let connector = AnecdoteConnector(
        queue: queue, preparer: preparer, refillThreshold: 1, batchSize: 10
    )
    let fetchesToFill = transport.requests.count

    try await connector.topUpIfNeeded()

    #expect(await queue.ready() == 2)
    #expect(transport.requests.count == fetchesToFill)
}

// MARK: - Ten ready, refreshed daily, played best-first

/// A feed of `count` distinct anecdotes, most popular first — the shape the
/// live one has, at whatever size a test needs.
private func feed(items count: Int) -> String {
    let entries = (1...count).map { index in
        """
        <item>
        <description><![CDATA[Анекдот номер \(index)]]></description>
        <guid>https://www.anekdot.ru/id/\(index)/</guid>
        </item>
        """
    }.joined(separator: "\n")
    return "<rss><channel>\n\(entries)\n</channel></rss>"
}

/// The first moment of today, local.
///
/// Everything below is measured from it rather than from `Date()`, because the
/// rule under test is about calendar days: a fixture built out of elapsed hours
/// can only ever observe elapsed hours, and would pass just as well against an
/// implementation that measured them.
private func startOfToday() -> Date { Calendar.current.startOfDay(for: Date()) }

/// A prepared anecdote with nothing on disk, for the tests that never play one.
private func pending(_ id: String, preparedAt: Date?, rank: Int?) -> PreparedAnecdote {
    PreparedAnecdote(
        id: id, text: "joke \(id)",
        clips: [SpokenClip(url: URL(fileURLWithPath: "/tmp/\(id).wav"))],
        laughter: "АХАХАХА", preparedAt: preparedAt, rank: rank
    )
}

/// A prepared anecdote whose single clip really exists, in a directory named
/// the way the synthesizer names one — so the reaper will accept it as its own.
private func pendingOnDisk(
    _ id: String, preparedAt: Date?, rank: Int?
) throws -> PreparedAnecdote {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("clips-\(UUID().uuidString)")
        .appendingPathComponent(PreparedAnecdote.namespace(for: id))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let clip = directory.appendingPathComponent("turn-0.wav")
    try Data().write(to: clip)
    return PreparedAnecdote(
        id: id, text: "joke \(id)", clips: [SpokenClip(url: clip)],
        laughter: "АХАХАХА", preparedAt: preparedAt, rank: rank
    )
}

// What the preparer writes down, and the only place the two sort keys enter the
// system on the production path. The queue's own ordering tests build their
// fixtures by hand, so nothing else would notice a preparer that stamped
// neither — every anecdote would land in the same nil generation at the same
// nil rank and play in whatever order it was synthesized.
@Test func theFeedsRankAndTheMomentOfPreparingReachThePreparedAnecdote() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )

    let before = Date()
    _ = try await preparer.refill(target: 2)
    let after = Date()

    let first = try #require(await queue.next())
    let second = try #require(await queue.next())
    #expect(first.id == "https://www.anekdot.ru/id/1/")
    #expect(first.rank == 0)
    #expect(second.rank == 1)
    let stamped = try #require(first.preparedAt)
    #expect(stamped >= before)
    #expect(stamped <= after)
}

// MARK: Depth — target ten, threshold five

// Five is the number the user chose over eight: a run that leaves five prepared
// restocks five at a time rather than two. It is cheap either way, because the
// sidecar keeps the model loaded in a `--serve` process and the 70-second load
// is paid once per process rather than once per refill.
//
// Driven through a real `produce()` rather than by enqueueing five, so the
// "run that leaves five" in the name is a run.
@Test func aRunThatLeavesFivePreparedTriggersARefill() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(feed(items: 12)), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 6)
    // The shipped numbers, not a test's own: an explicit threshold here would
    // pin whatever this line said rather than what the app ships with.
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()
    #expect(await queue.ready() == 5)

    try await connector.maintain()

    #expect(await queue.ready() == 10)
}

// One more in the queue and the same pass does nothing. Without this, a
// threshold of six — or of ten, or "always refill" — passes the test above.
@Test func aRunThatLeavesSixPreparedDoesNotRefill() async throws {
    let transport = RecordingTransport()
    transport.body = Data(feed(items: 12).utf8)
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 7)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()
    #expect(await queue.ready() == 6)
    let fetchesSoFar = transport.requests.count

    try await connector.maintain()

    #expect(await queue.ready() == 6)
    #expect(transport.requests.count == fetchesSoFar)
}

// The target and the threshold are two numbers, and a refill that stopped at
// the threshold would satisfy "it restocked" while leaving the queue one run
// away from doing it again.
@Test func theRefillTopsUpToTenNotToTheThreshold() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let preparer = AnecdotePreparer(
        source: makeSource(feed(items: 12)), speech: StubSpeechSynthesizer(), queue: queue
    )
    _ = try await preparer.refill(target: 5)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    try await connector.topUpIfNeeded()

    // Not five, and not the twelve the feed could supply.
    #expect(await queue.ready() == 10)
}

// MARK: The daily refresh

// A queue that is full of yesterday still has nothing from today, and the point
// of the whole feature is today's jokes. So depth is not the only thing that
// triggers a batch.
//
// The two moments are half an hour either side of midnight: one hour apart, and
// on different calendar days. An implementation that asked how long ago the
// newest anecdote was prepared would answer "an hour" and leave the queue as it
// is — which is the mutation this fixture exists to kill.
@Test func aQueueWithNothingPreparedTodayGetsAFreshBatchEvenWhenItIsFull() async throws {
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let lastNight = startOfToday().addingTimeInterval(-30 * 60)
    for index in 0..<10 {
        await queue.enqueue(pending("leftover-\(index)", preparedAt: lastNight, rank: index))
    }
    let preparer = AnecdotePreparer(
        source: makeSource(feed(items: 12)), speech: StubSpeechSynthesizer(), queue: queue
    )
    let justAfterMidnight = startOfToday().addingTimeInterval(30 * 60)
    let connector = AnecdoteConnector(
        queue: queue, preparer: preparer, now: { justAfterMidnight }
    )

    try await connector.topUpIfNeeded()

    // Ten fresh ones, and yesterday's ten still there: leftovers are kept and
    // simply rank below everything new.
    #expect(await queue.ready() == 20)
    let head = try #require(await queue.next())
    #expect(head.id.hasPrefix("leftover") == false)
}

// The other side of the same rule, and the reason the first one cannot stand
// alone: a pass that refreshed unconditionally would satisfy it. Nearly twenty
// hours apart, and the same calendar day — an implementation measuring elapsed
// time with any window short enough to fire on the test above would fire here
// too.
//
// Six prepared, so the depth rule is not what is answering: the threshold is
// five, and six is above it.
@Test func aQueueAlreadyRefreshedTodayIsNotRefreshedAgain() async throws {
    let transport = RecordingTransport()
    transport.body = Data(feed(items: 12).utf8)
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: anyRetention
    )
    let firstThingThisMorning = startOfToday().addingTimeInterval(5 * 60)
    for index in 0..<6 {
        await queue.enqueue(
            pending("today-\(index)", preparedAt: firstThingThisMorning, rank: index)
        )
    }
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: transport),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    let thisEvening = startOfToday().addingTimeInterval(20 * 60 * 60)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer, now: { thisEvening })

    try await connector.topUpIfNeeded()

    #expect(await queue.ready() == 6)
    #expect(transport.requests.isEmpty)
}

// MARK: The reaper has a caller

// Task 17 built the ten-day reaper and nothing called it, so the retention the
// user asked for was not in force and clips lived for ever. `maintain()` is the
// host: it already runs off the play path, and it is the one pass that happens
// both before and after every run.
@Test func maintenanceReapsWhatHasOutlivedTheRetentionWindow() async throws {
    let retention: TimeInterval = 60 * 60
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: retention
    )
    let stale = try pendingOnDisk(
        "https://www.anekdot.ru/id/9/",
        preparedAt: Date().addingTimeInterval(-(retention + 60)), rank: 0
    )
    let directory = try #require(stale.clips.first?.url.deletingLastPathComponent())
    await queue.enqueue(stale)
    // An empty feed, so the restock that follows the reap cannot put anything
    // back and confuse what the count below is measuring.
    let preparer = AnecdotePreparer(
        source: makeSource("<rss><channel></channel></rss>"),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    try await connector.maintain()

    #expect(await queue.ready() == 0)
    #expect(FileManager.default.fileExists(atPath: directory.path) == false)
}

// The reap runs BEFORE the restock, and this is what the order buys: a batch
// that has just aged out is replaced in the same pass rather than one run
// later. Reaped afterwards, the depth the restock reads is the depth including
// everything about to be deleted, so the pass looks at a stocked queue, does
// nothing, and then empties it.
//
// Both moments are anchored to the start of today rather than to `Date()`, so
// the batch is stale AND prepared today whatever hour the suite runs at — an
// hour that decided which of those it was would decide which rule this test
// measures.
@Test func aBatchThatHasJustExpiredIsRestockedInTheSamePass() async throws {
    let retention: TimeInterval = 60 * 60
    let queue = AnecdoteQueue(
        storeURL: temporaryStore(), clipRoot: anyTemporaryRoot, retention: retention
    )
    let thisMorning = startOfToday().addingTimeInterval(3 * 60 * 60)
    for index in 0..<6 {
        await queue.enqueue(pending("stale-\(index)", preparedAt: thisMorning, rank: index))
    }
    let preparer = AnecdotePreparer(
        source: makeSource(feed(items: 12)), speech: StubSpeechSynthesizer(), queue: queue
    )
    // Two hours after the batch was prepared, and on the same day: it is an
    // hour past the window, and it is not what the daily refresh is looking for.
    let twoHoursLater = thisMorning.addingTimeInterval(2 * 60 * 60)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer, now: { twoHoursLater })

    try await connector.maintain()

    #expect(await queue.ready() == 10)
}

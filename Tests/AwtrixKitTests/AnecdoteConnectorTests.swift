import Foundation
import Testing
@testable import AwtrixKit

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
    let queue = AnecdoteQueue(storeURL: temporaryStore())
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
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )

    let added = try await preparer.refill(target: 5)

    #expect(added == 1)                       // the fixture holds one anecdote
    #expect(await queue.ready() == 1)
    // announcement + narration + two dialogue lines + laughter
    #expect(speech.received.count == 5)
    #expect(speech.received.map(\.voice.id) == ["arthas", "arthas", "arthas", "peon", "arthas"])
}

@Test func preparerSkipsAnecdotesAlreadyPlayed() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
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
    let queue = AnecdoteQueue(storeURL: temporaryStore())
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
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let preparer = AnecdotePreparer(
        source: AnecdoteSource(transport: FlakyTransport(failing: 3, then: Data())),
        speech: StubSpeechSynthesizer(), queue: queue
    )

    await #expect(throws: AwtrixError.self) {
        _ = try await preparer.refill(target: 5)
    }
}

// MARK: - The connector

@Test func connectorEmitsTheBannerNotTheJoke() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
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
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.localAudio.first?.leadIn == 0)          // announcement leads
    #expect(output.localAudio.last?.leadIn == 0.7)         // punchline beat
    #expect(output.localAudio.count == 5)
}

// With no dialogue at all the announcement and the laughter are alone
// together, and the second clip is both "the first line" and "the last". It is
// the laughter, so it takes the laughter's beat. Both lead-ins are 0.7 s today,
// which is exactly what would let a retune of one silently move the other.
@Test func aTwoClipAnecdoteGivesItsLastClipTheLaughterBeat() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let preparer = AnecdotePreparer(
        source: makeSource(markerOnlyFeed), speech: StubSpeechSynthesizer(), queue: queue
    )

    _ = try await preparer.refill(target: 1)
    let prepared = try #require(await queue.next())

    #expect(prepared.clips.count == 2)
    #expect(prepared.clips.last?.leadIn == AnecdotePreparer.leadLaughter)
}

@Test func playingAnAnecdoteMarksItSoItNeverRepeats() async throws {
    let store = temporaryStore()
    let queue = AnecdoteQueue(storeURL: store)
    let speech = StubSpeechSynthesizer()
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: speech, queue: queue
    )
    _ = try await preparer.refill(target: 1)
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    _ = try await connector.produce()

    #expect(await queue.hasPlayed("https://www.anekdot.ru/id/1/"))
}

@Test func anEmptyQueueAndAnExhaustedFeedThrowsRatherThanShowingNothing() async {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let preparer = AnecdotePreparer(
        source: makeSource("<rss><channel></channel></rss>"),
        speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    await #expect(throws: (any Error).self) {
        _ = try await connector.produce()
    }
}

// MARK: - Where the batch is paid for

// `produce()` fires on a timer and is supposed to be instant. Refilling inside
// it pays a 70-second model load and a whole batch of synthesis before the
// clock shows anything, which is the trade the queue exists to avoid.
@Test func produceDoesNotReachTheNetworkWhenTheQueueHasSomethingToPop() async throws {
    let transport = RecordingTransport()
    transport.body = Data(dialogueFeed.utf8)
    let queue = AnecdoteQueue(storeURL: temporaryStore())
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
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let preparer = AnecdotePreparer(
        source: makeSource(dialogueFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    let output = try await connector.produce()

    #expect(output.text == AnecdoteConnector.banner)
    #expect(output.localAudio.count == 5)
}

@Test func topUpIfNeededFillsTheQueueOffThePlayPath() async throws {
    let queue = AnecdoteQueue(storeURL: temporaryStore())
    let preparer = AnecdotePreparer(
        source: makeSource(batchFeed), speech: StubSpeechSynthesizer(), queue: queue
    )
    let connector = AnecdoteConnector(queue: queue, preparer: preparer)

    try await connector.topUpIfNeeded()

    #expect(await queue.ready() == 2)
}

@Test func topUpIfNeededLeavesAStockedQueueAlone() async throws {
    let transport = RecordingTransport()
    transport.body = Data(batchFeed.utf8)
    let queue = AnecdoteQueue(storeURL: temporaryStore())
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

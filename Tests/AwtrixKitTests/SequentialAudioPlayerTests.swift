import AVFoundation
import Foundation
import Testing
@testable import AwtrixKit

// MARK: - Doubles

/// Stands in for the sound card: vends clips whose length the test chooses, and
/// records what the player did to each one, in order.
///
/// Lock-guarded for the same reason every other double in this suite is: the
/// player is an actor and drives these from a task the test does not own. Here
/// it is not only house style — `cancellingAPlayStopsTheSoundAndStartsNoMore`
/// polls `events` from the test's task while the player is writing to it.
private final class SoundCard: @unchecked Sendable {
    enum Event: Equatable {
        case started(String)
        case stopped(String)
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var loaded: [String] = []
    private var firstStart: [String: ContinuousClock.Instant] = [:]

    var events: [Event] {
        lock.withLock { recorded }
    }

    /// Kept apart from `events`, which several tests assert on whole. Loading
    /// is not something the player does TO a clip — it is how a test knows the
    /// player has reached one, without racing it on a sleep.
    var loadedNames: [String] {
        lock.withLock { loaded }
    }

    var startedNames: [String] {
        events.compactMap {
            if case let .started(name) = $0 { return name } else { return nil }
        }
    }

    /// When `name` was first started, for tests that ask what the player waited
    /// for BEFORE starting a clip rather than merely how long it took overall.
    func startInstant(of name: String) -> ContinuousClock.Instant? {
        lock.withLock { firstStart[name] }
    }

    /// Builds a loader over a table of clip name to length in seconds. A name
    /// absent from the table cannot be loaded — which is how a file that
    /// vanished between being queued and being played reaches the player.
    /// `refusing` names clips that load but will not start — what a Mac with
    /// no output route does to every one of them.
    func loader(
        _ table: [String: TimeInterval], refusing: Set<String> = []
    ) -> @Sendable (URL) throws -> any ClipPlaying {
        { [self] url in
            let name = url.lastPathComponent
            lock.withLock { loaded.append(name) }
            guard let duration = table[name] else {
                throw CocoaError(.fileNoSuchFile)
            }
            return FakeClip(
                name: name, duration: duration, startable: !refusing.contains(name), card: self
            )
        }
    }

    fileprivate func record(_ event: Event) {
        lock.withLock {
            recorded.append(event)
            if case let .started(name) = event, firstStart[name] == nil {
                firstStart[name] = .now
            }
        }
    }
}

private final class FakeClip: ClipPlaying {
    let duration: TimeInterval
    private let name: String
    private let startable: Bool
    private let card: SoundCard

    init(name: String, duration: TimeInterval, startable: Bool = true, card: SoundCard) {
        self.name = name
        self.duration = duration
        self.startable = startable
        self.card = card
    }

    func play() -> Bool {
        guard startable else { return false }
        card.record(.started(name))
        return true
    }

    func stop() {
        card.record(.stopped(name))
    }
}

private func clip(_ name: String, leadIn: TimeInterval = 0) -> SpokenClip {
    SpokenClip(url: URL(fileURLWithPath: "/dev/null/\(name)"), leadIn: leadIn)
}

private func elapsed(_ body: () async -> Void) async -> Duration {
    let start = ContinuousClock.now
    await body()
    return ContinuousClock.now - start
}

// MARK: - Sequencing

@Test func eachClipIsWaitedOutBeforeTheNextOneStarts() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["a": 0.05, "b": 0.05]))

    let took = await elapsed { await player.play([clip("a"), clip("b")]) }

    // Not merely "both were started": started in order, and each one finished
    // before the next began. Two clips fired off together would leave
    // .started("a"), .started("b") adjacent here — a dialogue with both
    // speakers talking at once.
    #expect(card.events == [.started("a"), .stopped("a"), .started("b"), .stopped("b")])
    #expect(took >= .seconds(0.1))
}

@Test func theLeadInIsWaitedOutBeforeTheClipItPrecedes() async throws {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["laugh": 0.01]))

    let start = ContinuousClock.now
    await player.play([clip("laugh", leadIn: 0.3)])

    // The silence belongs BEFORE the clip, not around it: a player that slept
    // after starting the audio would take just as long overall and get the beat
    // exactly backwards.
    let began = try #require(card.startInstant(of: "laugh"))
    #expect(began - start >= .seconds(0.3))
}

@Test func theProducersPacingIsObeyedPerClipNotAveraged() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["a": 0.01, "b": 0.01, "c": 0.01]))

    let took = await elapsed {
        await player.play([clip("a"), clip("b", leadIn: 0.15), clip("c", leadIn: 0.15)])
    }

    // 0 + 0.15 + 0.15 of silence: the player adds up what the producer set for
    // each clip and never substitutes a rhythm of its own.
    #expect(card.startedNames == ["a", "b", "c"])
    #expect(took >= .seconds(0.3))
}

// MARK: - Clips that are no longer there

@Test func aClipThatCannotBeLoadedIsSkippedAndTheRestStillPlay() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["b": 0.01]))

    await player.play([clip("a"), clip("b")])

    // The queue drops anecdotes whose clips are gone, but a file can also
    // vanish between that check and this one. Losing the punchline is bad;
    // losing everything after it because of one missing file is worse.
    #expect(card.startedNames == ["b"])
}

@Test func aSkippedClipDoesNotCostTheSilenceInFrontOfIt() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["b": 0.01]))

    let took = await elapsed { await player.play([clip("a", leadIn: 5), clip("b")]) }

    // The lead-in is the beat before a clip. With no clip there is no beat, and
    // holding the banner five seconds into silence for audio that no longer
    // exists is the worst of both.
    #expect(card.startedNames == ["b"])
    #expect(took < .seconds(1))
}

@Test func aClipThatWillNotStartIsNotWaitedOutInSilence() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["dud": 5, "b": 0.01], refusing: ["dud"]))

    let took = await elapsed { await player.play([clip("dud"), clip("b")]) }

    // The banner is held for exactly as long as this call takes, so waiting out
    // a clip that never reached the speakers would leave the joke on the clock
    // for five seconds of nothing.
    #expect(card.startedNames == ["b"])
    #expect(took < .seconds(1))
}

// MARK: - Cancellation

@Test func cancellingAPlayStopsTheSoundAndStartsNoMore() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["long": 5, "b": 0.01, "c": 0.01]))

    let running = Task { await player.play([clip("long"), clip("b"), clip("c")]) }
    while card.startedNames.isEmpty {
        await Task.yield()
    }

    let start = ContinuousClock.now
    running.cancel()
    await running.value
    let latency = ContinuousClock.now - start

    // Three separate claims, and each one fails on a different wrong player.
    // Stopping the clip that is sounding rules out a player that just walks
    // away from it; starting nothing after it rules out one that swallows the
    // cancellation and races through the rest of the list firing every clip at
    // once; and returning promptly rules out one that is not cancellable at all
    // and holds the quit for the remaining five seconds.
    #expect(card.events == [.started("long"), .stopped("long")])
    #expect(latency < .seconds(1))
}

@Test func cancellingDuringTheSilenceNeverStartsTheClipBehindIt() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["laugh": 0.01]))

    let running = Task { await player.play([clip("laugh", leadIn: 5)]) }
    // Waited for rather than slept past: once the clip is loaded the player is
    // either inside the lead-in or about to enter it, and a sleep that is
    // already cancelled when it begins throws just the same. Nothing here
    // depends on which side of that line the cancel lands on.
    while card.loadedNames.isEmpty {
        await Task.yield()
    }
    running.cancel()
    await running.value

    // The clip behind the silence is never heard. A player that noticed the
    // cancellation but went on to the next statement would start it and stop it
    // again inside a millisecond — a click out of the speakers on quit, and the
    // first thing that goes wrong on a longer lead-in than this one.
    #expect(card.startedNames.isEmpty)
}

@Test func aPlayThatIsCancelledBeforeItStartsTouchesNothing() async {
    let card = SoundCard()
    let player = SequentialAudioPlayer(load: card.loader(["a": 5]))

    let running = Task {
        // Cancelled before the actor is ever entered, which is what app quit
        // during the gap between produce and play looks like.
        while !Task.isCancelled { await Task.yield() }
        await player.play([clip("a")])
    }
    running.cancel()
    await running.value

    #expect(card.events.isEmpty)
}

// MARK: - The shipped path

/// A valid 8 kHz mono 16-bit WAVE of `seconds` of silence, built by hand so the
/// test needs no fixture and no synthesis.
private func silentWave(seconds: Double, sampleRate: Int = 8000) -> Data {
    let frames = Int(Double(sampleRate) * seconds)
    let payload = frames * 2
    func little32(_ value: UInt32) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }
    func little16(_ value: UInt16) -> Data { withUnsafeBytes(of: value.littleEndian) { Data($0) } }

    var wave = Data("RIFF".utf8)
    wave += little32(UInt32(36 + payload))
    wave += Data("WAVEfmt ".utf8)
    wave += little32(16)                        // PCM header length
    wave += little16(1)                         // format: PCM
    wave += little16(1)                         // channels
    wave += little32(UInt32(sampleRate))
    wave += little32(UInt32(sampleRate * 2))    // bytes per second
    wave += little16(2)                         // block align
    wave += little16(16)                        // bits per sample
    wave += Data("data".utf8)
    wave += little32(UInt32(payload))
    wave += Data(count: payload)
    return wave
}

@Test func theShippedPlayerWaitsOutRealAudio() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("awtrix-player-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("silence.wav")
    try silentWave(seconds: 0.2).write(to: file)

    // The one test that goes through AVAudioPlayer rather than a double: it is
    // what pins the default loader and the `ClipPlaying` conformance to the
    // real thing, both of which the doubles above route around entirely.
    let took = await elapsed {
        await SequentialAudioPlayer().play([SpokenClip(url: file, leadIn: 0.05)])
    }

    #expect(took >= .seconds(0.25))
}

import AVFoundation
import Foundation

/// One clip's playback: as much of `AVAudioPlayer` as the player below uses.
///
/// Internal, and it exists for one reason — the rules worth pinning here are
/// about ordering and cancellation, and against the real thing every one of
/// them would have to be inferred from a stopwatch and a sound card. The
/// signatures are `AVAudioPlayer`'s own, so the shipped conformance is empty.
protocol ClipPlaying: AnyObject {
    var duration: TimeInterval { get }
    /// False when playback did not start — no output route, most often.
    func play() -> Bool
    func stop()
}

extension AVAudioPlayer: ClipPlaying {}

/// Plays a connector's clips in order, so a dialogue stays a dialogue.
///
/// Nothing is stored between clips, which is what makes cancellation simple:
/// each clip's player is a local, stopped on the way out of its iteration
/// whether that exit is the end of the audio or a cancelled quit.
///
/// One caller at a time. Two overlapping `play` calls do not corrupt anything —
/// there is no shared state to corrupt — but they do talk over each other, and
/// keeping them apart belongs to whoever is scheduling deliveries. `ConnectorHost`
/// is that, and it serialises them for its own reasons.
public actor SequentialAudioPlayer: AudioPlaying {
    private let load: @Sendable (URL) throws -> any ClipPlaying

    public init() {
        self.load = { try AVAudioPlayer(contentsOf: $0) }
    }

    /// Test seam. The default above is the only loader that ships.
    init(load: @escaping @Sendable (URL) throws -> any ClipPlaying) {
        self.load = load
    }

    public func play(_ clips: [SpokenClip]) async {
        for clip in clips {
            // Cancellation between clips has no wait to interrupt.
            if Task.isCancelled { return }

            // Asked of the file rather than of `FileManager` first: a prepared
            // batch outlives the run that made it, so a clip can be gone by now
            // — and a readability check ahead of this one answers about a
            // moment that has already passed. Losing one clip is not a reason
            // to lose the rest of the anecdote.
            guard let player = try? load(clip.url) else { continue }
            // Runs on every way out of this iteration, so a cancelled quit
            // leaves nothing sounding. It is also what keeps `player` alive
            // across the waits below: without a use after the last `await`,
            // ARC is free to release it mid-clip, which stops the audio.
            defer { player.stop() }

            // The producer set this, knowing whether it is separating two
            // speakers or holding for a punchline. The player never learns.
            // After the load, so a clip that is no longer there costs neither
            // its audio nor the silence in front of it.
            //
            // Waited unconditionally, including the zero that `ClipPacing`
            // gives the announcement. A zero-length sleep still throws on a
            // cancelled task, so this doubles as the cancellation checkpoint
            // between loading a clip and starting it — a window worth about
            // 58 ms on the first load of a process, and one a quit would
            // otherwise cross to put the announcement on the speakers and take
            // it off again a moment later. Guarding it with `leadIn > 0` would
            // leave exactly the first clip of every anecdote uncovered.
            if await cancelled(waiting: clip.leadIn) { return }

            // Not waited out when it never started. The banner on the clock is
            // held for exactly as long as this call takes, so waiting here
            // would hold it over silence.
            guard player.play() else { continue }
            // `duration` rather than a delegate callback: the error is one
            // scheduling hop, and nothing on the clock resolves that finely.
            if await cancelled(waiting: player.duration) { return }
        }
    }

    /// Waits `seconds`, reporting whether cancellation cut the wait short.
    ///
    /// Reported rather than swallowed. `try?` around the sleep would drop the
    /// one fact this returns, and the statement after a cut-short lead-in is
    /// `play()` — so a quit during the silence in front of a clip would still
    /// put that clip on the speakers for as long as it takes to reach the stop.
    /// The check at the top of the loop covers the exit between clips; it does
    /// not cover this one.
    private func cancelled(waiting seconds: TimeInterval) async -> Bool {
        do {
            try await Task.sleep(for: .seconds(seconds))
            return false
        } catch {
            return true
        }
    }
}

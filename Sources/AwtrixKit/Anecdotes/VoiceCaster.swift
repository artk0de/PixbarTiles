import Foundation

/// A voice is addressed by name. The synthesis sidecar resolves the name to
/// `voices/<name>.wav` itself, so adding a third actor means dropping a file in
/// that directory — no code change here.
public struct Voice: Sendable, Equatable, Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public static let arthas = Voice(id: "arthas")
    public static let peon = Voice(id: "peon")
}

public struct VoicedTurn: Sendable, Equatable {
    public let voice: Voice
    public let text: String

    public init(voice: Voice, text: String) {
        self.voice = voice
        self.text = text
    }
}

/// Assigns a voice per speaker, stable across a single anecdote.
///
/// Narration always gets `narrator`. Each actor draws the next unused voice
/// from `pool` the first time it speaks, in first-APPEARANCE order — not by
/// its numeric index, and not disturbed by a narrator turn interleaved
/// between two actor turns (Task 5 pins that shape: actor alternation runs
/// across a mid-dialogue narration break). Every later turn from that actor
/// reuses the same voice. Running out of pool voices wraps back to the start.
public struct VoiceCaster: Sendable {
    private let narrator: Voice
    private let pool: [Voice]

    public init(narrator: Voice = .arthas, pool: [Voice] = [.arthas, .peon]) {
        self.narrator = narrator
        // An empty pool would divide by zero on the first actor turn. Falling
        // back to the narrator voice keeps casting total instead of trapping.
        self.pool = pool.isEmpty ? [narrator] : pool
    }

    public func cast(_ turns: [Turn]) -> [VoicedTurn] {
        var assigned: [Int: Voice] = [:]
        var nextPoolIndex = 0

        return turns.map { turn in
            switch turn.speaker {
            case .narrator:
                return VoicedTurn(voice: narrator, text: turn.text)
            case let .actor(index):
                if let known = assigned[index] {
                    return VoicedTurn(voice: known, text: turn.text)
                }
                let voice = pool[nextPoolIndex % pool.count]
                nextPoolIndex += 1
                assigned[index] = voice
                return VoicedTurn(voice: voice, text: turn.text)
            }
        }
    }
}

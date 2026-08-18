import Foundation

/// A voice is addressed by name. The synthesis sidecar resolves the name to
/// `voices/<name>.wav` itself, so a pack is added by dropping a file in that
/// directory and naming it here.
public struct Voice: Sendable, Equatable, Hashable {
    public let id: String

    public init(id: String) {
        self.id = id
    }

    public static let acolyte = Voice(id: "acolyte")
    public static let arthas = Voice(id: "arthas")
    public static let batrak = Voice(id: "batrak")
    public static let crystal = Voice(id: "crystal")
    public static let peon = Voice(id: "peon")

    /// Every pack installed in `voices/`, in the order that directory lists
    /// them.
    ///
    /// Written down rather than scanned. The prototype reads the directory at
    /// startup, which a shipped app cannot copy without casting differently on
    /// a machine that is mid-download and without putting the filesystem inside
    /// every test of who speaks.
    public static let installed: [Voice] = [.acolyte, .arthas, .batrak, .crystal, .peon]
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
/// Narration always gets `narrator`. An actor whose own lines reveal her female
/// gets the reserved voice, which is never in the pool — a male actor answering
/// in it is the loud failure, far worse than a woman missed. Everyone else
/// draws the next unused voice from `pool` the first time they speak, in
/// first-APPEARANCE order — not by numeric index, and not disturbed by a
/// narrator turn interleaved between two actor turns (Task 5 pins that shape:
/// actor alternation runs across a mid-dialogue narration break). Every later
/// turn from that actor reuses the same voice. Running out of pool voices wraps
/// back to the start.
public struct VoiceCaster: Sendable {
    /// The announcement, any prose line and the laughter are all narration, so
    /// all three land here without being special-cased.
    public static let defaultNarrator: Voice = .arthas

    /// Held out of the pool and handed only to a speaker detected female.
    public static let reservedFemale: Voice = .crystal

    /// The narrator's voice, then every installed pack that is neither the
    /// narrator's nor reserved.
    ///
    /// The narrator opens the pool, so the first actor shares its voice. That
    /// is audible, and it is deliberate: it is the casting every demonstration
    /// so far was approved with, so it is not changed on the way past.
    public static let defaultPool: [Voice] =
        [defaultNarrator] + Voice.installed.filter {
            $0 != defaultNarrator && $0 != reservedFemale
        }

    private let narrator: Voice
    private let female: Voice
    private let pool: [Voice]

    public init(
        narrator: Voice = VoiceCaster.defaultNarrator,
        pool: [Voice] = VoiceCaster.defaultPool,
        female: Voice = VoiceCaster.reservedFemale
    ) {
        self.narrator = narrator
        self.female = female
        // Reserved means reserved. A pool handed in with the female voice on it
        // would let a male actor draw it on a wrap — precisely what reserving
        // the voice is for — so it is taken back out rather than trusted.
        let unreserved = pool.filter { $0 != female }
        // An empty pool would divide by zero on the first actor turn. Falling
        // back to the narrator voice keeps casting total instead of trapping,
        // and a pool holding nothing but the reserved voice arrives here empty.
        self.pool = unreserved.isEmpty ? [narrator] : unreserved
    }

    public func cast(_ turns: [Turn]) -> [VoicedTurn] {
        // Read from the whole anecdote before anyone is cast: the line that
        // gives a speaker away is often not her first, and a voice cannot be
        // taken back once a clip has been synthesized with it.
        let genders = SpeakerGenders.detect(in: turns)
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
                let voice: Voice
                if genders[turn.speaker] == .female {
                    // Drawn from outside the pool, so she consumes no slot and
                    // the next actor still opens it where he would have.
                    voice = female
                } else {
                    voice = pool[nextPoolIndex % pool.count]
                    nextPoolIndex += 1
                }
                assigned[index] = voice
                return VoicedTurn(voice: voice, text: turn.text)
            }
        }
    }
}

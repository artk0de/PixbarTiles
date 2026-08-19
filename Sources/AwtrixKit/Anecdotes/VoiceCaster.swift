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

    /// The voice narration is actually spoken in, after the rules below have
    /// had their say. Readable because the connector in front of this caster
    /// has to be able to answer the same question, and a second copy of the
    /// answer would be free to disagree with the one that does the narrating.
    public let narrator: Voice
    private let female: Voice
    private let pool: [Voice]

    /// A caster that narrates in the connector's own voice.
    ///
    /// The connector names a character; what it does not get to do is disturb
    /// the casting inside the text. The pool is left exactly as it was, so the
    /// speakers of an anecdote draw the same voices in the same order whichever
    /// connector is telling it.
    public init(narrating connector: any Connector) {
        self.init(narrator: connector.narrator)
    }

    public init(
        narrator: Voice = VoiceCaster.defaultNarrator,
        pool: [Voice] = VoiceCaster.defaultPool,
        female: Voice = VoiceCaster.reservedFemale
    ) {
        // Two ways a narrator is refused, and both fall back rather than fail.
        //
        // The reserved voice, because a connector narrating in it would take the
        // one voice a female speaker has — she would answer the narrator in the
        // narrator's own voice, which is the casting defect the reservation
        // exists to prevent, arriving through the front door.
        //
        // And a voice no pack on disk answers to. The sidecar resolves a name to
        // `voices/<name>.wav` and fails the whole batch when the file is not
        // there, so a connector naming a pack somebody deleted would take the
        // anecdote down with it. It sounds wrong instead.
        let usable = narrator != female && Voice.installed.contains(narrator)
        self.narrator = usable ? narrator : Self.defaultNarrator
        self.female = female
        // Reserved means reserved. A pool handed in with the female voice on it
        // would let a male actor draw it on a wrap — precisely what reserving
        // the voice is for — so it is taken back out rather than trusted.
        let unreserved = pool.filter { $0 != female }
        // An empty pool would divide by zero on the first actor turn. Falling
        // back to the narrator voice keeps casting total instead of trapping,
        // and a pool holding nothing but the reserved voice arrives here empty.
        //
        // The RESOLVED narrator, not the one asked for: falling back to a voice
        // that was itself refused above would put a missing pack in front of
        // every actor, which is the failure the refusal exists to avoid.
        self.pool = unreserved.isEmpty ? [self.narrator] : unreserved
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

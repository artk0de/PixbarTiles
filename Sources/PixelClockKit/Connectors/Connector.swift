import Foundation

/// One audio file plus the silence that precedes it. The producer sets the
/// pacing because it knows what each clip is — an announcement, a dialogue line,
/// a punchline — and the player stays ignorant of all of that.
///
/// `Codable` because a clip outlives the run that produced it: a batch of
/// prepared audio is written to disk and read back by a later launch.
public struct SpokenClip: Sendable, Equatable, Codable {
    public let url: URL
    public let leadIn: TimeInterval

    public init(url: URL, leadIn: TimeInterval = 0) {
        self.url = url
        self.leadIn = leadIn
    }
}

/// A source of content. Reads and returns; never talks to a clock.
///
/// Two halves. `read()` goes out for a value — a feed, a service, a queue —
/// and `awtrixFace` draws that value for an AWTRIX clock without going
/// anywhere. Kept apart so every drawing can be tested against a value, and so
/// another clock model gets a face of its own over the same reading.
public protocol Connector: Sendable {
    /// What `read()` hands the faces.
    associatedtype Reading: Sendable

    var id: String { get }
    var displayName: String { get }
    var defaultInterval: TimeInterval { get }
    /// The voice this connector's narration is spoken in.
    ///
    /// A character per connector, so the weather and a broken build are told
    /// apart by ear before either has finished its first word. It says nothing
    /// about the speakers INSIDE the text — those are cast by `VoiceCaster`
    /// from its pool, and naming a narrator here does not move them.
    var narrator: Voice { get }
    /// Whether this connector can put sound in the room.
    ///
    /// What the quiet rules are FOR. A macOS Focus and a busy microphone stop
    /// the app SPEAKING — both were built because speech and the clock's
    /// jingle land in the room the user is talking in. A connector that draws
    /// into the device's own loop and says nothing has nothing to stop, and
    /// holding one through the shipped 23:00–08:00 window freezes whatever it
    /// last drew on the matrix for nine hours, with the panel blaming a
    /// microphone the reader cannot connect to a temperature.
    ///
    /// Declared rather than read off an output, because the answer is needed
    /// BEFORE `produce()` is called: not paying for the output is the whole
    /// point of a hold. It is a promise about what this connector's outputs can
    /// carry — `localAudio`, or a jingle the clock plays out loud.
    ///
    /// Says nothing about the offline pause, which applies to every connector:
    /// a clock that is not answering cannot receive a drawing any more than it
    /// can receive a banner.
    var isAudible: Bool { get }
    /// Whether this connector only keeps a value fresh, with nothing to trigger
    /// and nothing to witness.
    ///
    /// The weather is the one that is: it draws a reading into the device's own
    /// loop, so the number is on the matrix already and running it by hand asks
    /// the sky for the same number a quarter of an hour early. A menu bar panel
    /// is opened to answer "is the clock alive, and run something now", and an
    /// ambient connector answers neither.
    ///
    /// A separate claim from `isAudible`, and the separation is paid for. The
    /// panel filtered on `isAudible` first, and that reasoning was sound as far
    /// as it went: one flag cannot disagree with itself, two can drift apart
    /// with nothing anywhere to notice, and a connector calling itself silent
    /// and non-ambient gets a row whose switch no quiet rule applies to. What
    /// outweighed it is the connectors already asked for. Slack, calendar
    /// meetings and GitHub stars are all silent — nothing but the anecdotes is
    /// ever spoken — and all three are exactly what somebody opens the panel to
    /// fire by hand. Reading audibility would have hidden every one of them,
    /// and hidden them quietly. A drifted pair costs one row a reader can see
    /// and argue with; the reused flag costs three connectors that vanish.
    ///
    /// Being quiet is a CONSEQUENCE of being ambient rather than the reason for
    /// it, which is why this is not the same sentence twice. `isAudible` goes on
    /// answering its own question untouched: it is what a Focus and a busy
    /// microphone are asked before a run is held.
    var isAmbient: Bool { get }
    /// Goes out for the value this connector shows. May throw; never draws.
    func read() async throws -> Reading
    /// How the reading looks on an AWTRIX clock.
    var awtrixFace: AwtrixFace<Reading> { get }
}

extension Connector {
    /// What a connector that names no voice narrates in.
    ///
    /// Defaulted rather than required, so every connector written before this
    /// existed goes on sounding exactly as it did. A connector wanting its own
    /// character declares one and overrides this.
    public var narrator: Voice { VoiceCaster.defaultNarrator }

    /// What a connector that does not answer is assumed to be, and the
    /// direction is deliberate: one that forgets to declare itself is SILENCED
    /// during a Focus rather than left speaking through one. Being quiet when
    /// you could have spoken is recoverable; the other way round is what wakes
    /// somebody up.
    public var isAudible: Bool { true }

    /// What a connector that does not answer is assumed to be, and the
    /// direction is the OPPOSITE of `isAudible`'s just above. That is not an
    /// oversight: both defaults take the recoverable mistake, and the
    /// recoverable mistake points opposite ways. A connector wrongly assumed
    /// audible is held through a Focus it had nothing to say in — quiet when it
    /// could have spoken, and nobody is woken up. A connector wrongly assumed
    /// ambient has no row: no switch, no "Run now", no last result, and nothing
    /// anywhere saying why. A row nobody wanted is a nuisance in plain sight
    /// that somebody removes; a connector that quietly vanishes is a bug nobody
    /// thinks to report.
    ///
    /// So a connector written before this existed, and any written after it
    /// that says nothing, keeps its row. Only one that has declared itself
    /// ambient out loud loses one.
    public var isAmbient: Bool { false }

    /// What the AWTRIX session delivers for this connector: the reading,
    /// drawn.
    ///
    /// The one place the two halves meet, so a reading never reaches a clock
    /// undrawn and a face never draws without a fresh reading. A connector
    /// whose read spends something — the anecdotes retire what they pop —
    /// spends it exactly once per delivery.
    public func produce() async throws -> AwtrixDelivery {
        awtrixFace.draw(try await read())
    }
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

/// How one background pass went. Separate from `RunResult` because `delivered`
/// would be a lie about a pass that never goes near the clock.
public enum MaintenanceResult: Sendable, Equatable {
    case completed
    /// Switched off, or a connector with no background work to do.
    case skipped
    case cancelled
    case failed(String)
}

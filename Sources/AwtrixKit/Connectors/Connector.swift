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

/// Spelled out rather than `IconRef`: LaunchServices publicly declares
/// `typedef struct OpaqueIconRef* IconRef`, so that name is ambiguous in any
/// file reaching CoreServices — which is every file in the app target and every
/// file in the test target. Module qualification cannot rescue it either,
/// because this module declares an `enum AwtrixKit` that shadows its own name.
public enum IconReference: Sendable, Equatable {
    /// Already present on the device, referenced by basename.
    case installed(String)
    /// Fetched from the LaMetric catalogue by id, then installed.
    case catalogue(Int)
}

/// Where an output is drawn on the clock.
///
/// Two surfaces, and they are not settings of one thing. A notification
/// interrupts whatever the loop is showing and then goes away; an app IS the
/// loop, and stays there until it is replaced or removed. An anecdote is an
/// interruption; the weather is ambient and should be there when you glance at
/// the clock. The two coexist without arbitration — a notification draws over
/// the loop, which is exactly what it is for.
public enum DeliverySurface: Sendable, Equatable {
    case notification
    /// An app in the device's own loop, under this name.
    case app(String)
}

public struct ConnectorOutput: Sendable, Equatable {
    public var text: String
    public var icon: IconReference?
    public var jingle: String?
    public var localAudio: [SpokenClip]
    /// Keep the banner on the clock until the audio finishes, rather than for a
    /// fixed duration. The producer knows how long it will speak; the host does
    /// not, and guessing a scroll count was worse.
    public var holdUntilAudioEnds: Bool
    public var duration: Int?
    public var color: String?
    /// Where this is drawn. Defaulted to the notification, which is what every
    /// output was before there was a choice.
    public var surface: DeliverySurface
    /// Seconds without a fresh delivery after which the clock takes this off
    /// itself, or nil to stay until this app removes it.
    ///
    /// Next to `surface` because it belongs to one: an app in the loop is the
    /// only thing that outlives the delivery that made it. Defaulted to none,
    /// so a producer that says nothing about staleness behaves exactly as it
    /// did before there was anything to say.
    public var lifetime: Int?
    /// The device-wide weather layer this output wants, or nil to leave
    /// whatever is on the device alone.
    ///
    /// Carried on the output rather than written by the connector, because a
    /// connector produces and returns and never talks to the device. It is
    /// global state with one borrower and a value to put back afterwards, which
    /// is `DeviceCustody`'s job and not a producer's.
    public var overlay: DeviceOverlay?

    public init(
        text: String,
        icon: IconReference? = nil,
        jingle: String? = nil,
        localAudio: [SpokenClip] = [],
        holdUntilAudioEnds: Bool = false,
        duration: Int? = nil,
        color: String? = nil,
        surface: DeliverySurface = .notification,
        lifetime: Int? = nil,
        overlay: DeviceOverlay? = nil
    ) {
        self.text = text
        self.icon = icon
        self.jingle = jingle
        self.localAudio = localAudio
        self.holdUntilAudioEnds = holdUntilAudioEnds
        self.duration = duration
        self.color = color
        self.surface = surface
        self.lifetime = lifetime
        self.overlay = overlay
    }
}

/// A source of content. Produces and returns; never talks to the device.
public protocol Connector: Sendable {
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
    func produce() async throws -> ConnectorOutput
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
}

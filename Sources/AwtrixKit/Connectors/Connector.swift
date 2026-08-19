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

    public init(
        text: String,
        icon: IconReference? = nil,
        jingle: String? = nil,
        localAudio: [SpokenClip] = [],
        holdUntilAudioEnds: Bool = false,
        duration: Int? = nil,
        color: String? = nil
    ) {
        self.text = text
        self.icon = icon
        self.jingle = jingle
        self.localAudio = localAudio
        self.holdUntilAudioEnds = holdUntilAudioEnds
        self.duration = duration
        self.color = color
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
    func produce() async throws -> ConnectorOutput
}

extension Connector {
    /// What a connector that names no voice narrates in.
    ///
    /// Defaulted rather than required, so every connector written before this
    /// existed goes on sounding exactly as it did. A connector wanting its own
    /// character declares one and overrides this.
    public var narrator: Voice { VoiceCaster.defaultNarrator }
}

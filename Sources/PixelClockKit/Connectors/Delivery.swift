import Foundation

/// What a face hands a clock's session: the scene to draw, and the sound that
/// goes with it.
///
/// Generic over the scene because every clock model draws in its own
/// vocabulary. An AWTRIX scene cannot be handed to a TC002 session, and the
/// type is what says so. The audio is not part of any scene: the Mac plays it,
/// not the clock, and which clock a tile is on does not decide where its sound
/// comes out.
///
/// `@dynamicMemberLookup` so a delivery reads as the scene it carries —
/// `delivery.text` is `delivery.scene.text`. Read-only: a face builds a
/// delivery whole, and nothing patches one on its way to the clock.
@dynamicMemberLookup
public struct Delivery<Scene: Sendable & Equatable>: Sendable, Equatable {
    public var scene: Scene
    /// Played on the Mac, strictly after the scene is on the clock.
    public var localAudio: [SpokenClip]
    /// Keep the banner on the clock until the audio finishes, rather than for a
    /// fixed duration. The producer knows how long it will speak; the host does
    /// not, and guessing a scroll count was worse.
    public var holdUntilAudioEnds: Bool
    /// Scenes that take the clock over after this one is up, played in order,
    /// each on its own scope — see `Interruption`. Empty for an ordinary
    /// reading.
    public var interruptions: [Interruption<Scene>]

    public init(
        scene: Scene,
        localAudio: [SpokenClip] = [],
        holdUntilAudioEnds: Bool = false,
        interruptions: [Interruption<Scene>] = []
    ) {
        self.scene = scene
        self.localAudio = localAudio
        self.holdUntilAudioEnds = holdUntilAudioEnds
        self.interruptions = interruptions
    }

    public subscript<Value>(dynamicMember keyPath: KeyPath<Scene, Value>) -> Value {
        scene[keyPath: keyPath]
    }
}

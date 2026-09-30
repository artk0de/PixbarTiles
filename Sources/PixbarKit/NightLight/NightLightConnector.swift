import Foundation

/// The night light: a warm scene filling a TC002's panel, played by the clock
/// as one looping GIF.
///
/// Its reading IS its page: nothing outside the Mac is asked, so `read()`
/// draws the tile's scene on the animation engine at the tile's settings and
/// the TC002 face hands it on. A run re-delivers the same bytes, which the
/// clock session skips; a settings change reaches the panel as a new page.
public struct NightLightConnector: Connector {
    public let id = NightLightKind.id
    public let displayName = "Night light"
    /// A recheck, not a refresh: the loop plays by itself.
    public let defaultInterval: TimeInterval = 3_600
    public var isAudible: Bool { false }
    public var isAmbient: Bool { true }
    /// The tile's settings, read at every draw so a change reaches the next run.
    private let config: @Sendable () -> NightLightTileConfig
    /// Whether this Mac can tell Sleep from any other Focus — asked when a
    /// tile is added, since the answer picks the policy it starts from.
    private let canNameSleep: @Sendable () -> Bool

    public init(
        config: @escaping @Sendable () -> NightLightTileConfig,
        canNameSleep: @escaping @Sendable () -> Bool
    ) {
        self.config = config
        self.canNameSleep = canNameSleep
    }

    /// Sleep only, when Sleep can be named; the night by the clock otherwise —
    /// "any Focus" would light the panel for a Work Focus at noon.
    public var defaultPolicy: TilePolicy {
        canNameSleep() ? TileDefaults.nightLightSleep : TileDefaults.nightLightHours
    }

    public func read() async throws -> UlanziDelivery {
        let settings = config()
        return try AnimatedPage.delivery(
            settings.scene.animatedScene, speed: settings.speed.animationSpeed,
            // Only the motions the scene offers to stop: a key stored for
            // another scene, or before a switch was withdrawn, does nothing.
            stilled: settings.stilled.intersection(settings.scene.motionSwitches),
            brightness: settings.brightness
        )
    }

    /// Required of every connector, and never offered: the kind is TC002 only,
    /// so the catalogue lists this tile on no AWTRIX clock.
    public var awtrixFace: AwtrixFace<UlanziDelivery> {
        AwtrixFace { _ in AwtrixDelivery(text: "") }
    }

    public var ulanziFace: UlanziFace<UlanziDelivery>? {
        UlanziFace { $0 }
    }
}

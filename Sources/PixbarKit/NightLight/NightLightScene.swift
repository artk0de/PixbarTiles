/// The six night-light scenes, as stored in a tile's config.
public enum NightLightScene: String, CaseIterable, Codable, Sendable {
    /// In the order the picker lists them: the user's order of interest
    /// (2026-09-30).
    case glow, moon, horizon, fireplace, embers, fireflies

    public var displayName: String {
        switch self {
        case .embers: "Embers"
        case .horizon: "Warm horizon"
        case .moon: "Red moon"
        case .fireflies: "Fireflies"
        case .fireplace: "Fireplace"
        case .glow: "Soft glow"
        }
    }

    /// The motions a user may stop, in the order the settings list them.
    ///
    /// Only where a stopped motion still reads as the scene: the moon's stars
    /// and clouds, the fireflies' flight (they keep glowing). Stopping the
    /// embers' flicker, the fire or the glow left a dead picture on the panel,
    /// so those scenes offer only their speed (the user's call, 2026-09-30).
    public var motionSwitches: [String] {
        switch self {
        case .moon: ["starTwinkle", "cloudMotion"]
        case .fireflies: ["flyMotion"]
        case .embers, .horizon, .fireplace, .glow: []
        }
    }

    /// The scene on the animation engine — the port of its mockup module in
    /// `tc002-face-mockup/nightlight/`.
    public var animatedScene: AnimatedScene {
        switch self {
        case .embers: EmbersScene.scene
        case .horizon: HorizonScene.scene
        case .moon: RedMoonScene.scene
        case .fireflies: FirefliesScene.scene
        case .fireplace: FireplaceScene.scene
        case .glow: GlowScene.scene
        }
    }
}

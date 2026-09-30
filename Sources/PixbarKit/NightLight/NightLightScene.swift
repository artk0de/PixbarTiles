/// The six night-light scenes, as stored in a tile's config.
public enum NightLightScene: String, CaseIterable, Codable, Sendable {
    case embers, horizon, moon, fireflies, fireplace, glow

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

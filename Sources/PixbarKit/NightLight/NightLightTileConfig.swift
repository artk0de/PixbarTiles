import Foundation

/// How fast a night-light scene plays: the same whole cycles in twice or half
/// as many frames. The frame delay never changes.
public enum NightLightSpeed: String, CaseIterable, Codable, Sendable {
    case half, normal, double

    public var animationSpeed: AnimationSpeed {
        switch self {
        case .half: .half
        case .normal: .normal
        case .double: .double
        }
    }

    public var displayName: String {
        switch self {
        case .half: "½×"
        case .normal: "1×"
        case .double: "2×"
        }
    }
}

/// What one night-light tile needs that no other tile does.
///
/// Stored with only what differs from the defaults, so a tile nobody tuned
/// writes `{"nightlight":{}}`:
///
///   {"nightlight":{"scene":"moon","brightness":2,"speed":"double",
///                  "stilled":["cloudMotion"],"autoShow":false,"morningTileId":"weather"}}
public struct NightLightTileConfig: TileParameters {
    public static let brightnessLevels = 1...5

    public var scene: NightLightScene
    /// 1…5: the scene's colours scaled by `level / 5` inside the GIF.
    public var brightness: Int
    public var speed: NightLightSpeed
    /// The motion keys of the scene's layers drawn still.
    public var stilled: Set<String>
    /// Whether the clock is switched to this tile when its window opens, and
    /// handed back when it closes.
    public var autoShow: Bool
    /// The tile id the clock is handed back to in the morning, or nil for the
    /// first page-owning tile in the clock's order.
    public var morningTileId: String?

    public init(
        scene: NightLightScene = .embers, brightness: Int = 5, speed: NightLightSpeed = .normal,
        stilled: Set<String> = [], autoShow: Bool = true, morningTileId: String? = nil
    ) {
        self.scene = scene
        self.brightness = min(max(brightness, Self.brightnessLevels.lowerBound), Self.brightnessLevels.upperBound)
        self.speed = speed
        self.stilled = stilled
        self.autoShow = autoShow
        self.morningTileId = morningTileId
    }

    private enum Key: String, CodingKey {
        case scene, brightness, speed, stilled, autoShow, morningTileId
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let defaults = NightLightTileConfig()
        self.init(
            scene: try container.decodeIfPresent(NightLightScene.self, forKey: .scene) ?? defaults.scene,
            brightness: try container.decodeIfPresent(Int.self, forKey: .brightness) ?? defaults.brightness,
            speed: try container.decodeIfPresent(NightLightSpeed.self, forKey: .speed) ?? defaults.speed,
            stilled: try container.decodeIfPresent(Set<String>.self, forKey: .stilled) ?? defaults.stilled,
            autoShow: try container.decodeIfPresent(Bool.self, forKey: .autoShow) ?? defaults.autoShow,
            morningTileId: try container.decodeIfPresent(String.self, forKey: .morningTileId)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        let defaults = NightLightTileConfig()
        if scene != defaults.scene { try container.encode(scene, forKey: .scene) }
        if brightness != defaults.brightness { try container.encode(brightness, forKey: .brightness) }
        if speed != defaults.speed { try container.encode(speed, forKey: .speed) }
        if !stilled.isEmpty { try container.encode(stilled.sorted(), forKey: .stilled) }
        if autoShow != defaults.autoShow { try container.encode(autoShow, forKey: .autoShow) }
        try container.encodeIfPresent(morningTileId, forKey: .morningTileId)
    }
}

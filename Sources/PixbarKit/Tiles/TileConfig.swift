// Sources/PixbarKit/Tiles/TileConfig.swift
import Foundation

/// What one tile needs that no other tile does: the weather tile's place, the
/// VPN tile's VPN, lamp and colours — a kind's id and that kind's parameters.
///
/// Stored under one key naming the kind it belongs to:
///
///   {"weather":{"latitude":55.7558,"longitude":37.6173}}
///   {"vpn":{"slot":"top","upColour":"#90EE90","vpn":"pritunl",
///           "whenDown":{"colour":"#FF0000","kind":"blink"}}}
///   {"claude":{"showResetAfter":70,"showResetEvery":30}}
///   {"claude":"daily"}  — legacy: the display metric, read as the defaults
///   {"github":{"repo":"owner/name","celebrationSeconds":8}}
///
/// The kinds are listed in `TileKinds.all`; a key none of them owns is
/// refused rather than dropped, as the closed enum this used to be refused it.
public struct TileConfig: Sendable {
    /// The id of the kind these parameters belong to.
    public let kindId: String
    public let value: any TileParameters

    public init<Kind: TileKind>(_ value: Kind.Parameters, kind: Kind.Type) {
        kindId = kind.id
        self.value = value
    }

    /// The parameters as one kind's type, or nil for a tile of another kind.
    public func value<P: TileParameters>(as type: P.Type) -> P? {
        value as? P
    }

    public static func weather(_ config: WeatherTileConfig) -> TileConfig { TileConfig(config, kind: WeatherKind.self) }

    /// A weather tile's config in the shipped defaults, at this place — the
    /// form every caller that knows only the place means. Overloading the
    /// constructor keeps the pre-settings call sites, and the records they
    /// write, reading exactly as they did.
    public static func weather(_ place: Coordinates) -> TileConfig {
        .weather(WeatherTileConfig(place: place))
    }

    public static func vpn(_ config: VPNTileConfig) -> TileConfig { TileConfig(config, kind: VPNKind.self) }
    public static func zai(_ config: ZaiTileConfig) -> TileConfig { TileConfig(config, kind: ZaiKind.self) }
    public static func claude(_ config: ClaudeTileConfig) -> TileConfig { TileConfig(config, kind: ClaudeKind.self) }
    public static func github(_ config: GitHubTileConfig) -> TileConfig { TileConfig(config, kind: GitHubKind.self) }

    /// The weather tile's whole config, or nil for any other tile.
    public var weatherConfig: WeatherTileConfig? { value(as: WeatherTileConfig.self) }

    /// The weather tile's place, or nil for any other tile.
    public var location: Coordinates? { weatherConfig?.place }

    /// The VPN tile's lamp, or nil for any other tile.
    public var lamp: VPNTileConfig? { value(as: VPNTileConfig.self) }

    /// The z.ai tile's key handle, or nil for any other tile. A handle: the
    /// key itself lives in the secret store and is never stored here.
    public var key: ZaiTileConfig? { value(as: ZaiTileConfig.self) }

    /// The Claude tile's whole config, or nil for any other tile.
    public var claudeConfig: ClaudeTileConfig? { value(as: ClaudeTileConfig.self) }

    /// The GitHub tile's config, or nil for any other tile.
    public var github: GitHubTileConfig? { value(as: GitHubTileConfig.self) }

    /// The night light's config, or nil for any other tile.
    public var nightLightConfig: NightLightTileConfig? { value(as: NightLightTileConfig.self) }

    /// The coding-subscription parameters — the Claude tile's or the z.ai
    /// tile's, and the same list either way — or nil for a tile that is not one.
    public var parameters: CodeUsage.Parameters? {
        claudeConfig?.parameters ?? key?.parameters
    }
}

extension TileConfig: Equatable {
    public static func == (lhs: TileConfig, rhs: TileConfig) -> Bool {
        lhs.kindId == rhs.kindId && lhs.value.isEqual(rhs.value)
    }
}

extension TileParameters {
    /// Equality across the erased parameters: never equal to another type's.
    func isEqual(_ other: any TileParameters) -> Bool {
        (other as? Self) == self
    }

    /// Written under its kind's key, as its own type.
    func encode(into container: inout KeyedEncodingContainer<TileConfig.KindKey>, key: TileConfig.KindKey) throws {
        try container.encode(self, forKey: key)
    }
}

extension TileKind {
    /// This kind's parameters, read from under its key.
    static func decodeParameters(
        from container: KeyedDecodingContainer<TileConfig.KindKey>, key: TileConfig.KindKey
    ) throws -> any TileParameters {
        try container.decode(Parameters.self, forKey: key)
    }
}

extension TileConfig: Codable {
    struct KindKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: KindKey.self)
        // Exactly one key. Two would be a tile claiming two connectors' settings,
        // and picking one of them would be a guess about which it is.
        guard container.allKeys.count == 1, let key = container.allKeys.first else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath,
                debugDescription: "a tile config names exactly one connector"
            ))
        }
        guard let kind = TileKinds.kind(id: key.stringValue) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: decoder.codingPath + [key],
                debugDescription: "no tile kind is called \(key.stringValue)"
            ))
        }
        kindId = kind.id
        value = try kind.decodeParameters(from: container, key: key)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: KindKey.self)
        try value.encode(into: &container, key: KindKey(stringValue: kindId))
    }
}

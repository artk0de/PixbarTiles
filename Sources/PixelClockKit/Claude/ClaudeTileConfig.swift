import Foundation

/// The Claude tile's own settings: which figure the AWTRIX page shows, and the
/// two settings of the TC002's shared usage face.
///
/// Stored the way it always was while the usage settings are the defaults —
/// the metric's bare word, `{"claude":"daily"}` — and as an object only once
/// they are not: `{"claude":{"metric":"daily","showResetAfter":70,…}}`. The
/// decode reads both, so a record written before the settings existed is a
/// tile at the defaults, and nothing rewrites it.
public struct ClaudeTileConfig: Codable, Equatable, Sendable {
    public var metric: ClaudeDisplayMetric
    public var usageFace: UsageFaceConfig

    public init(metric: ClaudeDisplayMetric, usageFace: UsageFaceConfig = .standard) {
        self.metric = metric
        self.usageFace = usageFace
    }

    private enum CodingKeys: String, CodingKey {
        case metric
    }

    public init(from decoder: any Decoder) throws {
        if let word = try? decoder.singleValueContainer().decode(ClaudeDisplayMetric.self) {
            self.init(metric: word)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            metric: try container.decode(ClaudeDisplayMetric.self, forKey: .metric),
            usageFace: try UsageFaceConfig(from: decoder)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        guard usageFace != .standard else {
            var word = encoder.singleValueContainer()
            try word.encode(metric)
            return
        }
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(metric, forKey: .metric)
        try usageFace.encode(to: encoder)
    }
}

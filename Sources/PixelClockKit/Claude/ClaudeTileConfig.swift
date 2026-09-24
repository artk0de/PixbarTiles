import Foundation

/// The Claude tile's settings: the shared coding-subscription parameters, and
/// nothing else.
///
/// Nothing else because Claude's way in needs no setting — it reads a
/// status-line document this Mac already writes. `ZaiTileConfig` is the same
/// type plus the one thing that differs: where its key is filed.
///
/// It used to carry a display metric as well, choosing which of three figures
/// the AWTRIX page drew. It went for three reasons: z.ai had no counterpart, so
/// the two tiles offered different settings for one question; its "Daily limit"
/// drew the five-hour window, which is not a day; and of its three figures only
/// two are limits at all — the third was how full one session's context is,
/// which empties on every `/clear`.
///
/// Records written before the parameters existed carry the metric's bare word,
/// `{"claude":"daily"}`. That spelling still DECODES — as a tile at the
/// defaults — because the alternative is a tile that vanishes from a clock at
/// the update that removed a picker. Nothing writes it again.
public struct ClaudeTileConfig: Codable, Equatable, Sendable {
    public var parameters: CodeUsage.Parameters

    public init(parameters: CodeUsage.Parameters = .standard) {
        self.parameters = parameters
    }

    public init(from decoder: any Decoder) throws {
        // The legacy spelling: the metric's bare word, and no parameters had
        // been chosen when it was written.
        if (try? decoder.singleValueContainer().decode(String.self)) != nil {
            self.init()
            return
        }
        self.init(parameters: try CodeUsage.Parameters(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws {
        try parameters.encode(to: encoder)
    }
}

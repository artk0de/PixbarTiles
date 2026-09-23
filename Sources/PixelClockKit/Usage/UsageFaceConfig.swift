import Foundation

/// The two settings the shared TC002 usage face takes from its tile — the
/// same two on the Claude tile and the z.ai tile, because the face is one.
///
/// - `resetEvery`: how long the percentages stand before a hot row flips to
///   its reset time — the first frame's delay.
/// - `resetAfter`: from what percentage a row is hot at all. Below it the
///   page is the percentages and nothing else.
///
/// Records written before these settings existed decode as `standard`;
/// nothing rewrites them. The tile configs that carry this one leave it out of
/// their JSON while it IS `standard`, so a record nobody touched stays
/// byte-identical to the one written before the settings were.
public struct UsageFaceConfig: Codable, Equatable, Sendable {
    /// Seconds the percentages stand before a hot row shows its reset.
    public var resetEvery: TimeInterval
    /// The percentage from which a row shows its reset.
    public var resetAfter: Int

    public init(resetEvery: TimeInterval, resetAfter: Int) {
        self.resetEvery = resetEvery
        self.resetAfter = resetAfter
    }

    /// Ten seconds, eighty percent — the first warning band's own threshold,
    /// so by default a row names its reset exactly when its colour starts to
    /// warn.
    public static let standard = UsageFaceConfig(resetEvery: 10, resetAfter: 80)

    /// What "Show reset every" offers: 5 s to 5 min.
    public static let resetEverySteps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300]
    /// What "Show reset after" offers: 50 % to 100 % in fives.
    public static let resetAfterSteps: [Int] = Array(stride(from: 50, through: 100, by: 5))

    private enum CodingKeys: String, CodingKey {
        case resetEvery = "showResetEvery"
        case resetAfter = "showResetAfter"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        resetEvery = try container.decodeIfPresent(TimeInterval.self, forKey: .resetEvery)
            ?? Self.standard.resetEvery
        resetAfter = try container.decodeIfPresent(Int.self, forKey: .resetAfter)
            ?? Self.standard.resetAfter
    }
}

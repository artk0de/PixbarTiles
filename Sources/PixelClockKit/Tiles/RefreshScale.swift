// Sources/PixelClockKit/Tiles/RefreshScale.swift
import Foundation

/// How often a tile may run, from half a minute to half a day.
///
/// A refresh is stored in seconds and snapped to this scale when read, so a
/// value the scale cannot represent — a hand-edited one, a migrated one — is
/// read as the nearest step rather than honoured or refused.
public enum RefreshScale {
    /// 30 s, then 1, 2 and 3 min, in front of the interval scale the connectors
    /// have always had, which carries on behind them unchanged: 5–60 min in
    /// fives, then 2–12 h.
    public static let steps: [TimeInterval] = [30, 60, 120, 180] + IntervalScale.positions

    /// The shortest refresh a tile on the GENERAL ladder runs at, whatever is
    /// stored.
    public static var shortest: TimeInterval { steps[0] }

    /// The ladder the Coding Subscription tiles offer instead — the Claude and
    /// z.ai tiles, which report how much of a plan is spent.
    ///
    /// Ten seconds at the bottom, which the general ladder deliberately does
    /// not carry. A person watching a limit move wants it read now rather than
    /// at the top of the next interval, and the route is an account's own
    /// dashboard. The weather is the case this must NOT reach: a free forecast
    /// API answers a place about every quarter of an hour, and 360 reads an
    /// hour there is an invitation to be blocked. Which ladder a tile gets is
    /// the connector's own answer (`Connector.refreshSteps`), not a table here
    /// naming tiles.
    ///
    /// Four hours at the top rather than the general ladder's twelve: past a
    /// few hours a usage figure on a panel is a number nobody is reading.
    public static let codingSubscription: [TimeInterval] = [
        10, 15, 30, 60, 120, 300, 600, 900, 1_800, 3_600, 7_200, 14_400,
    ]

    /// The ladder the weather tile fetches on — how often the sky is READ,
    /// which is a different question from how often the face changes what it
    /// shows (`WeatherTileConfig.changeEvery`, three to fifteen seconds).
    ///
    /// A minute at the bottom rather than ten seconds: the source answers a
    /// place about every quarter of an hour and caches until it does, so a
    /// faster poll buys nothing and only asks more of a free service. Four
    /// hours at the top, where a forecast on a panel has stopped being one.
    public static let weatherFetch: [TimeInterval] = [
        60, 120, 180, 300, 600, 900, 1_800, 3_600, 7_200, 14_400,
    ]

    /// The step nearest to `seconds`, on the ladder the tile is offered.
    ///
    /// Anything under the first step reads as the first step, which is the
    /// floor. A value exactly between two steps takes the LONGER one — walked
    /// from the top, the first of two equal distances is the higher step. The
    /// tie is only reached by a value nobody chose on a slider, and the longer
    /// step is the one that asks less of a clock and of a free public API.
    public static func snapped(
        _ seconds: TimeInterval, on ladder: [TimeInterval] = steps
    ) -> TimeInterval {
        ladder.reversed().min { abs($0 - seconds) < abs($1 - seconds) }
            ?? ladder.first ?? shortest
    }

    /// One step, in the words a picker shows it in: seconds, minutes, then
    /// hours said in full. "2 h" reads as a unit symbol beside "30 min"; the
    /// hours are the far end of the ladder and are better read than decoded.
    public static func label(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<60: "\(Int(seconds)) s"
        case ..<3_600: "\(Int(seconds / 60)) min"
        case 3_600: "1 hour"
        default: "\(Int(seconds / 3_600)) hours"
        }
    }

    /// What a stored `ConnectorSettings.intervalPosition` meant, in seconds.
    ///
    /// Through `IntervalScale`, never through `steps`: the position indexes the
    /// OLD scale, and four steps in front of it move every index — position 5
    /// is thirty minutes there and ten minutes here.
    public static func seconds(migratingIntervalPosition position: Int) -> Int {
        Int(IntervalScale.duration(atPosition: position))
    }
}

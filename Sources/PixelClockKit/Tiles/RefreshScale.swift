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

    /// The shortest refresh any tile runs at, whatever is stored.
    public static var shortest: TimeInterval { steps[0] }

    /// The step nearest to `seconds`.
    ///
    /// Anything under the first step reads as the first step, which is the
    /// floor. A value exactly between two steps takes the LONGER one — walked
    /// from the top, the first of two equal distances is the higher step. The
    /// tie is only reached by a value nobody chose on a slider, and the longer
    /// step is the one that asks less of a clock and of a free public API.
    public static func snapped(_ seconds: TimeInterval) -> TimeInterval {
        steps.reversed().min { abs($0 - seconds) < abs($1 - seconds) } ?? shortest
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

import Foundation

/// Maps a slider position to a run interval.
///
/// The scale is deliberately non-linear: five-minute resolution is what matters
/// under an hour, and nobody needs it above one.
public enum IntervalScale {
    public static let positions: [TimeInterval] = {
        let minutes = stride(from: 5, through: 60, by: 5).map { TimeInterval($0 * 60) }
        let hours = stride(from: 2, through: 12, by: 1).map { TimeInterval($0 * 3600) }
        return minutes + hours
    }()

    public static func duration(atPosition position: Int) -> TimeInterval {
        positions[min(max(position, 0), positions.count - 1)]
    }

    public static func position(for duration: TimeInterval) -> Int {
        positions
            .enumerated()
            .min { abs($0.element - duration) < abs($1.element - duration) }?
            .offset ?? 0
    }

    public static func label(atPosition position: Int) -> String {
        let seconds = duration(atPosition: position)
        if seconds < 3600 {
            return "\(Int(seconds / 60)) min"
        }
        return "\(Int(seconds / 3600)) h"
    }
}

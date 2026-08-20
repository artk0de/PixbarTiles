import Foundation

/// One reading of the weekly allowance.
///
/// `utilization` is a percentage the service computed, not something derived
/// here, and it is allowed past a hundred: an overage channel keeps serving
/// after the bar is full, and a reading of a hundred and forty is a true thing
/// to say about a week.
public struct ClaudeUsageReading: Sendable, Equatable {
    public let utilization: Int
    /// When this week's bar starts again, when the service says so.
    public let resetsAt: Date?

    public init(utilization: Int, resetsAt: Date?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    /// The weekly bar out of an answer from `/api/oauth/usage`.
    ///
    /// Several bars come back — a five-hour one, the weekly one, and per-model
    /// weekly ones — so the weekly bar is found BY NAME. Picking by position
    /// would follow whatever order the service happens to send and would change
    /// meaning without anything here changing.
    ///
    /// Nil for anything that is not a weekly reading, and that is the whole
    /// point of the initialiser being failable: zero is a real reading meaning
    /// "nothing spent yet", so answering zero for an unparseable body would put
    /// a confident, calm, wrong number on the clock.
    public init?(json: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let bars = root["rate_limits"] as? [[String: Any]],
            let weekly = bars.first(where: { $0["name"] as? String == Self.weeklyBar }),
            let utilization = weekly["utilization"] as? Int
        else { return nil }

        self.utilization = utilization
        self.resetsAt = (weekly["resets_at"] as? String).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
    }

    /// The name the service gives the weekly bar. Written down once, here,
    /// because it is a wire value and not a word this app chose.
    static let weeklyBar = "seven_day"
}

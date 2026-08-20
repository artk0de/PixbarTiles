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
    /// The bars are TOP-LEVEL KEYS, not a list — `five_hour`, `seven_day`, and
    /// a set of per-model weekly ones. This was captured from a live answer
    /// rather than assumed, after a first version invented a `rate_limits`
    /// array and passed its own tests against its own invention.
    ///
    /// Three details that all have to be right at once, and each of which fails
    /// silently on its own: the per-model bars come back as explicit `null` on
    /// an account with no split, so a null has to read as absence rather than
    /// as a zero bar; `utilization` is FRACTIONAL, so reading it as an integer
    /// throws every value away; and `resets_at` carries sub-second precision
    /// and an offset, which the default ISO-8601 reader declines without a word.
    ///
    /// Nil for anything that is not a weekly reading, and that is the whole
    /// point of the initialiser being failable: zero is a real reading meaning
    /// "nothing spent yet", so answering zero for an unparseable body would put
    /// a confident, calm, wrong number on the clock.
    public init?(json: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let weekly = root[Self.weeklyBar] as? [String: Any],
            let utilization = weekly["utilization"] as? Double
        else { return nil }

        // Nearest whole percent. The bar and the number beside it are drawn from
        // this one value, so rounding here is what keeps them from disagreeing.
        self.utilization = Int(utilization.rounded())
        self.resetsAt = (weekly["resets_at"] as? String).flatMap(Self.moment(from:))
    }

    /// The name the service gives the weekly bar. Written down once, here,
    /// because it is a wire value and not a word this app chose.
    static let weeklyBar = "seven_day"

    /// The service's timestamps carry fractional seconds; some fields elsewhere
    /// do not. Both are tried rather than assumed, because the failure mode of
    /// guessing is a reset time that is silently nil.
    private static func moment(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

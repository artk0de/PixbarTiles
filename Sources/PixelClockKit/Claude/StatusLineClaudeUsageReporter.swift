import Foundation

/// The weekly figure, out of the document Claude Code's status line leaves in
/// this app's folder.
///
/// Claude Code runs its status-line command after each reply and hands it a
/// JSON document on stdin. This app's hook stores the ones that carry
/// `rate_limits`, whole, and this reads the stored one. It is a local read, so
/// it happens on every refresh and nothing watches the file.
///
/// An actor because it remembers; see `weekly`.
public actor StatusLineClaudeUsageReporter: ClaudeUsageReporting {
    private let document: URL
    private let now: @Sendable () -> Date
    /// The last value of each window this process saw.
    ///
    /// A window can be missing from any one document, and when it is, the last
    /// value seen stands in for it. Per process and in memory: a relaunch that
    /// finds a document without a week reads nothing until one arrives, which is
    /// the honest answer for a figure nobody has confirmed since.
    private var weekly: ClaudeUsageWindow?
    private var fiveHour: ClaudeUsageWindow?

    public init(document: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.document = document
        self.now = now
    }

    /// The week as Claude Code last reported it, or nil when there is none to
    /// be had: no document, no week seen yet, or a week that has reset.
    ///
    /// Nil rather than zero after a reset. The window the figure described is
    /// over and spending since then is unknown; the connector turns nil into no
    /// delivery, and the clock drops the app when its lifetime runs out.
    public func read() async throws -> ClaudeUsageReading? {
        // In front of the memory, on purpose: a deleted document is how
        // Disconnect takes the figure away.
        guard let data = try? Data(contentsOf: document) else { return nil }
        let limits = Self.rateLimits(in: data)
        if let seen = Self.window(limits["seven_day"]) { weekly = seen }
        if let seen = Self.window(limits["five_hour"]) { fiveHour = seen }

        let moment = now()
        guard let current = weekly, current.resetsAt > moment else { return nil }
        return ClaudeUsageReading(
            utilization: current.utilization,
            resetsAt: current.resetsAt,
            fiveHour: fiveHour.flatMap { $0.resetsAt > moment ? $0 : nil },
            observedAt: modificationDate()
        )
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: document.path))?[.modificationDate]
            as? Date
    }

    /// The `rate_limits` object, or an empty one for a document that has none
    /// or is not JSON at all. Both read as "every window missing".
    private static func rateLimits(in data: Data) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return root?["rate_limits"] as? [String: Any] ?? [:]
    }

    /// One window, or nil unless both of its figures are numbers. Without
    /// `resets_at` nothing can say when the figure stops being true.
    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard
            let window = value as? [String: Any],
            let used = window["used_percentage"] as? Double,
            let resets = window["resets_at"] as? Double
        else { return nil }
        // Nearest whole percent. The bar and the number beside it are drawn from
        // this one value, so rounding here is what keeps them from disagreeing.
        return ClaudeUsageWindow(
            utilization: Int(used.rounded()),
            resetsAt: Date(timeIntervalSince1970: resets)
        )
    }
}

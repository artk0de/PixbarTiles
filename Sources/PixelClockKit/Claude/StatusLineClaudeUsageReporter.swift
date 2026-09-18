import Foundation

/// The weekly figure, out of the document Claude Code's status line leaves in
/// this app's folder.
///
/// Claude Code runs its status-line command after each reply and hands it a
/// JSON document on stdin. This app's hook stores the ones that carry
/// `rate_limits`, whole, and this reads the stored one. It is a local read, so
/// it happens on every refresh and nothing watches the file.
public actor StatusLineClaudeUsageReporter: ClaudeUsageReporting {
    private let document: URL
    /// What decides that a window has reset and stopped being a reading.
    private let now: @Sendable () -> Date

    public init(document: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.document = document
        self.now = now
    }

    public func read() async throws -> ClaudeUsageReading? {
        guard let data = try? Data(contentsOf: document) else { return nil }
        let limits = Self.rateLimits(in: data)
        guard let weekly = Self.window(limits["seven_day"]) else { return nil }
        return ClaudeUsageReading(
            utilization: weekly.utilization,
            resetsAt: weekly.resetsAt,
            fiveHour: Self.window(limits["five_hour"]),
            observedAt: modificationDate()
        )
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: document.path))?[.modificationDate]
            as? Date
    }

    /// The `rate_limits` object, or an empty one for a document that has none
    /// or is not JSON at all.
    private static func rateLimits(in data: Data) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return root?["rate_limits"] as? [String: Any] ?? [:]
    }

    /// One window, or nil unless both of its figures are numbers.
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

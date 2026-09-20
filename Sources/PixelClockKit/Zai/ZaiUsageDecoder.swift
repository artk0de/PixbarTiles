// Sources/PixelClockKit/Zai/ZaiUsageDecoder.swift
import Foundation

/// The z.ai answers, taken apart.
///
/// What this decoder may pin is bounded by what has been OBSERVED, and the
/// observations are the two community trackers' (`tokn-provider-zai`'s
/// quota.rs, `zai-usage-tracker`'s zaiService.ts) — z.ai documents no usage
/// API. Therefore: every field is optional, every extra field is ignored, an
/// answer that is not JSON reads as empty rather than throwing, and the only
/// names written down are the ones a live response has shown. A field a future
/// response renames degrades to a missing field, which is the degradation this
/// whole reading is built to survive.
public enum ZaiUsageDecoder {
    /// The quota answer: level and windows, or an empty answer for one that
    /// said nothing placeable.
    public static func limits(from data: Data) -> ZaiUsageLimits {
        guard let data = unwrapped(data) else { return ZaiUsageLimits() }
        let level = data["level"] as? String
        let rawLimits = data["limits"] as? [[String: Any]] ?? []
        let windows = rawLimits.compactMap(window)
        return ZaiUsageLimits(
            level: level,
            fiveHour: windows.first { $0.kind == .fiveHour }?.window,
            weekly: windows.first { $0.kind == .weekly }?.window,
            mcpMonthly: windows.first { $0.kind == .mcpMonthly }?.window
        )
    }

    /// The model-usage answer: the period totals, or an empty answer.
    public static func totals(from data: Data) -> ZaiUsageTotals {
        guard let usage = unwrapped(data)?["totalUsage"] as? [String: Any] else {
            return ZaiUsageTotals()
        }
        return ZaiUsageTotals(
            modelCalls: whole(usage["totalModelCallCount"]),
            tokens: whole(usage["totalTokensUsage"])
        )
    }

    // MARK: - Internals

    /// The answer's payload: the envelope's `data` when it is wrapped, the
    /// object itself when it is bare — both are seen in the wild — and nil for
    /// anything that is not an object at all.
    private static func unwrapped(_ data: Data) -> [String: Any]? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (root?["data"] as? [String: Any]) ?? root
    }

    /// The two buckets a token limit can name. The unit codes and their window
    /// pair are the community trackers' observation: `unit:3, number:5` is the
    /// rolling five hours, `unit:6, number:1` the week. Any other pair — and
    /// any limit whose pair is missing — is not a window this decoder can name,
    /// so it is dropped rather than guessed at.
    private enum WindowKind {
        case fiveHour, weekly, mcpMonthly
    }

    /// One limit object, placed if it can be. The classification is the wire's
    /// own `type` plus the window pair for token buckets; a `TIME_LIMIT` is the
    /// MCP spend. A limit with no percent and no spend against a cap has no
    /// figure to carry and is dropped.
    private static func window(_ raw: [String: Any]) -> (kind: WindowKind, window: ZaiUsageWindow)? {
        let kind: WindowKind
        switch raw["type"] as? String {
        case "TOKENS_LIMIT":
            switch (whole(raw["unit"]), whole(raw["number"])) {
            case (3?, 5?): kind = .fiveHour
            case (6?, 1?): kind = .weekly
            default: return nil
            }
        case "TIME_LIMIT":
            kind = .mcpMonthly
        default:
            return nil
        }

        let percent = percentage(raw)
        guard percent != nil else { return nil }
        return (kind, ZaiUsageWindow(
            percentUsed: percent,
            usedTokens: whole(raw["currentValue"]),
            capTokens: whole(raw["usage"]),
            resetsAt: resetsAt(raw["nextResetTime"])
        ))
    }

    /// The window's figure. The explicit percent when the answer gives one;
    /// otherwise what was spent against what it allows says the same thing.
    private static func percentage(_ raw: [String: Any]) -> Int? {
        if let stated = raw["percentage"] as? Double { return Int(stated.rounded()) }
        guard let spent = whole(raw["currentValue"]), let cap = whole(raw["usage"]), cap > 0
        else { return nil }
        return Int((Double(spent) / Double(cap) * 100).rounded())
    }

    /// A whole number off the wire, whether it arrives as an integer or a
    /// decimal. Nil for anything else — the wire has shown both shapes, and a
    /// string is neither.
    private static func whole(_ value: Any?) -> Int? {
        if let integer = value as? Int { return integer }
        if let double = value as? Double { return Int(double) }
        return nil
    }

    /// When the window turns over. The wire shape is ASSUMED, not observed
    /// first-hand: the community decoder reads it as an epoch in milliseconds,
    /// and until a live answer says otherwise that is what is taken here. A
    /// shape that does not fit reads as undated rather than wrong.
    private static func resetsAt(_ value: Any?) -> Date? {
        guard let milliseconds = whole(value) else { return nil }
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

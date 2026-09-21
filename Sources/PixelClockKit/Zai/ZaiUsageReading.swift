// Sources/PixelClockKit/Zai/ZaiUsageReading.swift
import Foundation

/// One window of the plan's allowance: how much of it is gone, and what the
/// answer said about the rest.
///
/// Every field beyond the percent is optional because the route that carries
/// them is nobody's contract — see `ZaiUsageDecoder` for what has actually
/// been observed on the wire.
public struct ZaiUsageWindow: Sendable, Equatable {
    /// Nearest whole percent of the window spent. Rounded, the way the Claude
    /// figure is: the bar and the number beside it are drawn from this one
    /// value, so rounding here is what keeps them from disagreeing.
    public let percentUsed: Int
    /// What the window reports as spent, in the units it reports — tokens for
    /// the token buckets, calls for the MCP one. Nil when the answer said only
    /// the percent.
    public let usedTokens: Int?
    /// What the window allows before it turns over, same units. Nil when the
    /// answer carried no cap.
    public let capTokens: Int?
    /// When the window starts again, when the answer dated it.
    public let resetsAt: Date?

    public init(
        percentUsed: Int?, usedTokens: Int? = nil, capTokens: Int? = nil, resetsAt: Date? = nil
    ) {
        self.percentUsed = percentUsed ?? 0
        self.usedTokens = usedTokens
        self.capTokens = capTokens
        self.resetsAt = resetsAt
    }
}

/// What the quota route said: the plan level and its three windows.
///
/// All empty when the route is dead or said nothing placeable — an empty
/// answer, not a failure, because the limits are the informational half of the
/// reading.
public struct ZaiUsageLimits: Sendable, Equatable {
    /// The plan tier as the account carries it — `"PRO"`, `"MAX"` — when the
    /// answer named one.
    public let level: String?
    /// The rolling five-hour window (the wire's `unit:3, number:5` bucket).
    public let fiveHour: ZaiUsageWindow?
    /// The weekly window (`unit:6, number:1`).
    public let weekly: ZaiUsageWindow?
    /// The MCP tool spend against its monthly cap (`TIME_LIMIT`).
    public let mcpMonthly: ZaiUsageWindow?

    public init(
        level: String? = nil, fiveHour: ZaiUsageWindow? = nil,
        weekly: ZaiUsageWindow? = nil, mcpMonthly: ZaiUsageWindow? = nil
    ) {
        self.level = level
        self.fiveHour = fiveHour
        self.weekly = weekly
        self.mcpMonthly = mcpMonthly
    }
}

/// One model's share of the period, as the wire carried it: the id spelled
/// the way `modelData` keyed it, and the tokens it spent. The entry shape is
/// the one a live key has shown; anything else a model entry may one day
/// carry is extra here.
public struct ZaiUsageModelUsage: Sendable, Equatable, Hashable {
    /// The model's id as the answer spelled it — `glm-4.6`,
    /// `glm-5.3-flash[1m]` — never translated: `ZaiUsage.canonicalModel` is
    /// the one that recognises a name, and recognition gates nothing.
    public let id: String
    /// What the model spent in the period, when the answer said.
    public let tokens: Int?

    public init(id: String, tokens: Int? = nil) {
        self.id = id
        self.tokens = tokens
    }
}

/// What the model-usage route said: the period totals, and the per-model
/// breakdown beside them — every entry the answer carried, named by the
/// guide's vocabulary or not.
public struct ZaiUsageTotals: Sendable, Equatable {
    public let modelCalls: Int?
    public let tokens: Int?
    /// One entry per model the period used; the answer keys them, so no
    /// order is promised. Empty when the answer carried no breakdown.
    public let models: [ZaiUsageModelUsage]

    public init(modelCalls: Int? = nil, tokens: Int? = nil, models: [ZaiUsageModelUsage] = []) {
        self.modelCalls = modelCalls
        self.tokens = tokens
        self.models = models
    }
}

/// One reading of the z.ai coding plan: the windows, and what the period
/// spent. The reading the z.ai tile's faces draw.
public struct ZaiUsageReading: Sendable, Equatable {
    public let level: String?
    public let fiveHour: ZaiUsageWindow?
    public let weekly: ZaiUsageWindow?
    public let mcpMonthly: ZaiUsageWindow?
    public let totalModelCalls: Int?
    public let totalTokens: Int?
    /// The period's per-model usage, as the answer carried it.
    public let models: [ZaiUsageModelUsage]
    /// When the reading was taken. Nil for a reading built from answers alone.
    public let observedAt: Date?

    public init(
        limits: ZaiUsageLimits, totals: ZaiUsageTotals, observedAt: Date? = nil
    ) {
        self.level = limits.level
        self.fiveHour = limits.fiveHour
        self.weekly = limits.weekly
        self.mcpMonthly = limits.mcpMonthly
        self.totalModelCalls = totals.modelCalls
        self.totalTokens = totals.tokens
        self.models = totals.models
        self.observedAt = observedAt
    }
}

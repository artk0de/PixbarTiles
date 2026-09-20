// Sources/PixelClockKit/Zai/ZaiUsage.swift
import Foundation

/// The facts about a z.ai coding plan that are not about drawing it.
public enum ZaiUsage {
    /// The plan's blue. Every figure the z.ai faces draw carries it, so the
    /// page reads as one object — the same one-object rule Claude's orange
    /// answers to.
    public static let brandColour = "#3B5BFE"
}

extension ZaiUsageReading {
    /// The windows the answer gave, in the order the plan names them: the
    /// rolling five hours, the week, the MCP month. This list is the payload
    /// the shared three-row usage face draws — a window the quota route did
    /// not name leaves a row out rather than standing in for one, and an
    /// answer with no windows at all carries none.
    public var usageRows: [ZaiUsageWindow] {
        [fiveHour, weekly, mcpMonthly].compactMap { $0 }
    }
}

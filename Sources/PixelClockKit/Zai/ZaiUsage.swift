// Sources/PixelClockKit/Zai/ZaiUsage.swift
import Foundation

/// The facts about a z.ai coding plan that are not about drawing it.
public enum ZaiUsage {
    /// The plan's blue. Every figure the z.ai faces draw carries it, so the
    /// page reads as one object — the same one-object rule Claude's orange
    /// answers to.
    public static let brandColour = "#3B5BFE"
}

extension ZaiUsage {
    /// The GLM model ids a usage answer can be keyed by, lowercase the way
    /// the guide's settings example writes them: `glm-5.3` and
    /// `glm-5.3-flash` are the Claude Code guide's own configuration
    /// (docs.z.ai/devpack), `glm-4.7` through `glm-5.2` the older generations
    /// its overview names, and `glm-4.6` the one id a live `modelData` key
    /// has shown. The one place a model name is written down without the wire
    /// having shown it first.
    public static let documentedModels: Set<String> = [
        "glm-4.6", "glm-4.7", "glm-5.1", "glm-5.2", "glm-5.3", "glm-5.3-flash",
    ]

    /// The canonical name for a model id as some layer spelled it: the guide
    /// prose's uppercase folds to the settings' lowercase, and the `[1m]`
    /// context suffix — Claude Code's, not a model of its own — comes off.
    /// Nil for a model the vocabulary does not carry. Recognition only:
    /// nothing anywhere gates a model on being named here.
    public static func canonicalModel(_ raw: String) -> String? {
        let spelled = raw.lowercased()
        let withoutContext = spelled.hasSuffix("[1m]") ? String(spelled.dropLast(4)) : spelled
        return documentedModels.contains(withoutContext) ? withoutContext : nil
    }
}

extension ZaiUsageReading {
    /// The windows the answer gave, in the order the plan names them: the
    /// rolling five hours, the week, the MCP month. This list is the payload
    /// the AWTRIX page's one line draws — a window the quota route did not
    /// name leaves a figure out rather than standing in for one, and an
    /// answer with no windows at all carries none.
    public var usageRows: [ZaiUsageWindow] {
        [fiveHour, weekly, mcpMonthly].compactMap { $0 }
    }
}

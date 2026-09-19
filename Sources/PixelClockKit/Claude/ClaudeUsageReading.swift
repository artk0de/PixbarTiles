// Sources/PixelClockKit/Claude/ClaudeUsageReading.swift
import Foundation

/// One reading of the weekly allowance.
///
/// `utilization` is a percentage Claude Code reported, not something derived
/// here, and it is allowed past a hundred: an overage channel keeps serving
/// after the bar is full, and a reading of a hundred and forty is a true thing
/// to say about a week. `StatusLineClaudeUsageReporter` is where it is read.
public struct ClaudeUsageReading: Sendable, Equatable {
    public let utilization: Int
    /// When this week's bar starts again, when the source says so.
    public let resetsAt: Date?
    /// The rolling five-hour window, when the source reported one. Carried, and
    /// drawn by no face yet.
    public let fiveHour: ClaudeUsageWindow?
    /// When the document this came from was written: its modification time.
    /// Nil for a reading that did not come from a document.
    public let observedAt: Date?

    /// The two newer fields default to nil, so a reading built from a figure
    /// alone — every drawing test, every face — reads as it always did.
    public init(
        utilization: Int,
        resetsAt: Date?,
        fiveHour: ClaudeUsageWindow? = nil,
        observedAt: Date? = nil
    ) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.fiveHour = fiveHour
        self.observedAt = observedAt
    }
}

/// One of Claude Code's rate-limit windows: how much of it is gone, and when it
/// starts again.
public struct ClaudeUsageWindow: Sendable, Equatable {
    public let utilization: Int
    public let resetsAt: Date

    public init(utilization: Int, resetsAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}

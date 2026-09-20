// Sources/PixelClockKit/Claude/ClaudeDisplayMetric.swift
import Foundation

/// Which of the reading's figures a Claude tile shows.
///
/// A plain type, like `TileRowLine` and `AddTileMenuItem`: the connector's
/// faces read it, the tile detail's picker writes it into the tile's config,
/// and neither knows the other exists. It lives in the config as the case's
/// own word — `{"claude":"daily"}` — because a metric is a whole value, not a
/// struct waiting for fields that have not arrived.
public enum ClaudeDisplayMetric: String, Codable, Sendable, Equatable, CaseIterable {
    /// The rolling five-hour window — the limit a day is made of.
    case daily
    /// The seven-day window, the reading's own figure.
    case weekly
    /// The current session's context window.
    case session

    /// What the picker calls it.
    public var displayName: String {
        switch self {
        case .daily: "Daily limit"
        case .weekly: "Weekly window"
        case .session: "Current session"
        }
    }

    /// The figure this metric shows in one reading, or nil when the reading
    /// does not carry it. Nil is the honest answer — the connector turns it
    /// into no delivery, never into a zero invented for a missing window.
    public func percentage(in reading: ClaudeUsageReading) -> Int? {
        switch self {
        case .daily: reading.fiveHour?.utilization
        case .weekly: reading.utilization
        case .session: reading.contextWindow
        }
    }
}

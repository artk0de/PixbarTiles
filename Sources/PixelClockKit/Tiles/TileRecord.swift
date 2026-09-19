import Foundation

/// One connector on one clock, which is what a tile is.
public struct TileKey: Codable, Sendable, Hashable {
    public let clockId: UUID
    public let connectorId: String
    /// Empty for a connector that sits on a clock once; the watched key for
    /// one that sits there once per key. Empty rather than optional, so a
    /// second tile of a single connector on one clock would have the first
    /// one's key.
    public let instance: String

    public init(clockId: UUID, connectorId: String, instance: String = "") {
        self.clockId = clockId
        self.connectorId = connectorId
        self.instance = instance
    }
}

/// The stored half of a tile's policy — the part the schedule reads today.
///
/// A record, not the policy: what a tile's policy decides is `TilePolicy`'s
/// to say. Phase 4 adds the Focus and the hours here, as optional keys.
public struct TilePolicyRecord: Codable, Sendable, Equatable {
    public var isPaused: Bool
    /// Seconds between runs. Seconds rather than a position on the slider's
    /// scale, so the scale can gain steps without moving what is stored.
    public var refreshSeconds: Int
    /// The Focuses the tile does not work in, or nil for a record written
    /// before Phase 4 — read as the connector's own defaults row.
    public var focus: FocusRule?
    /// The hours the tile keeps, or nil for a record written before Phase 4.
    public var window: TileWindow?

    public init(
        isPaused: Bool, refreshSeconds: Int, focus: FocusRule? = nil, window: TileWindow? = nil
    ) {
        self.isPaused = isPaused
        self.refreshSeconds = refreshSeconds
        self.focus = focus
        self.window = window
    }
}

public struct TileRecord: Codable, Sendable, Equatable {
    public let key: TileKey
    public var policy: TilePolicyRecord
    /// When this tile last put something on its clock, or nil while it never
    /// has. The cadence is measured from it across launches.
    public var lastDeliveredAt: Date?
    /// What this tile needs that no other tile does, or nil for a connector
    /// that needs nothing. Optional, so every record Phase 1 wrote decodes.
    public var config: TileConfig?

    public init(
        key: TileKey, policy: TilePolicyRecord, lastDeliveredAt: Date? = nil,
        config: TileConfig? = nil
    ) {
        self.key = key
        self.policy = policy
        self.lastDeliveredAt = lastDeliveredAt
        self.config = config
    }
}

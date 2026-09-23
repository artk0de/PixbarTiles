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

    /// The key's name on the wire and in custody: the connector id alone for
    /// a single tile — every page already on a clock keeps the name it was
    /// delivered under — else "<connectorId>-<slug>-<hash>". Both clocks put
    /// the name into `/api/custom?name=` unencoded (`AwtrixDevice`,
    /// `UlanziDevice`) and a repository key carries '/' and '.', so an
    /// instanced name is built from [a-z0-9-] only: the slug keeps it readable
    /// in a device's page list, the hash of the whole instance keeps two
    /// instances that slug alike ("a.b", "a-b") apart on one clock.
    public var tileId: String {
        guard !instance.isEmpty else { return connectorId }
        let hash = String(format: "%06x", Self.fnv1a(instance) & 0xFF_FFFF)
        let slug = Self.slug(instance)
        return slug.isEmpty ? "\(connectorId)-\(hash)" : "\(connectorId)-\(slug)-\(hash)"
    }

    /// Lowercased, every run outside [a-z0-9] collapsed to one '-', trimmed of
    /// '-' at both ends, at most 24 characters.
    private static func slug(_ text: String) -> String {
        var slug = ""
        for scalar in text.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        return String(slug.prefix(24)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// 32-bit FNV-1a over the UTF-8 bytes: stable across launches and
    /// platforms, which `Hasher` is not.
    private static func fnv1a(_ text: String) -> UInt32 {
        text.utf8.reduce(0x811C_9DC5 as UInt32) { hash, byte in
            (hash ^ UInt32(byte)) &* 0x0100_0193
        }
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

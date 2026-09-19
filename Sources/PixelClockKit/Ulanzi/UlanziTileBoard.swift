import Foundation

/// Pure per-tile state (D1): what each tile's page shows right now, and what
/// its page last showed for real. Nothing here ticks — no timer, no dwell, no
/// rotation; the user turns the knob, and this answers what each page holds.
public struct UlanziTileBoard: Sendable, Equatable {
    private enum Current: Equatable {
        case idle
        case showing(UlanziScene)
    }

    /// Known tiles in the order they arrived — the order re-pushes run in.
    public private(set) var tileIds: [String] = []

    private var current: [String: Current] = [:]
    /// The last scene a real delivery carried. Survives `markIdle`: a recovery
    /// re-push puts the page's own content back, never the pause marker.
    private var lastDelivered: [String: UlanziScene] = [:]

    public init() {}

    /// A fresh tile starts on the idle frame — the page exists before any
    /// content has arrived for it.
    public mutating func register(tileId: String) {
        guard current[tileId] == nil else { return }
        tileIds.append(tileId)
        current[tileId] = .idle
    }

    /// The tile's page now shows this delivery's scene.
    public mutating func upsert(_ delivery: UlanziDelivery, forTile id: String) {
        if current[id] == nil { tileIds.append(id) }
        current[id] = .showing(delivery.scene)
        lastDelivered[id] = delivery.scene
    }

    /// The tile is paused: its page keeps its place in the knob cycle on the
    /// idle frame (D4). The last delivery is kept for the recovery re-push.
    public mutating func markIdle(_ id: String) {
        if current[id] == nil { tileIds.append(id) }
        current[id] = .idle
    }

    /// What this tile's page shows right now: the last delivery's scene, the
    /// idle frame while paused, or nil for a tile this board has never heard of.
    public func frame(forTile id: String) -> UlanziScene? {
        switch current[id] {
        case .idle: return UlanziScene.idle
        case let .showing(scene): return scene
        case nil: return nil
        }
    }

    /// The recovery re-push source: the last real scene this tile delivered,
    /// or nil when only the idle marker has ever been here.
    public func lastScene(forTile id: String) -> UlanziScene? {
        lastDelivered[id]
    }

    /// Board tiles that are no longer live — the names whose pages get their
    /// empty-body delete.
    public func removedTiles(given liveIds: [String]) -> [String] {
        let live = Set(liveIds)
        return tileIds.filter { !live.contains($0) }
    }
}

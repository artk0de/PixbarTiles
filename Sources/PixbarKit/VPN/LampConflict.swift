// Sources/PixbarKit/VPN/LampConflict.swift
import Foundation

/// A VPN tile as the save-time refusal sees it.
public struct LampTile: Equatable, Sendable {
    public let key: TileKey
    /// The VPN's display name.
    public let name: String
    public let slot: IndicatorSlot
    public let policy: TilePolicy

    public init(key: TileKey, name: String, slot: IndicatorSlot, policy: TilePolicy) {
        self.key = key
        self.name = name
        self.slot = slot
        self.policy = policy
    }
}

/// Two VPN tiles on one clock claiming one lamp at the same moment.
public struct LampConflict: Equatable, Sendable {
    /// The tile already saved.
    public let existing: String
    /// The tile being saved, which is refused.
    public let saving: String
    public let slot: IndicatorSlot
    public let overlap: PolicyGrid

    /// `Pritunl and WireGuard both claim the middle lamp: Work, 10:00–19:00`.
    public var message: String {
        "\(existing) and \(saving) both claim the \(slot.lampName) lamp: \(overlap.summary)"
    }

    /// The first tile on the same clock and the same lamp whose grid meets
    /// this one's, or nil when the save may go ahead.
    ///
    /// Exact, because the grids are the whole of both policies: tiles taking
    /// turns — one in Work, one in Personal, or one before 13:00 and one after
    /// — share a lamp; tiles that would both light it at any moment do not.
    /// A paused tile claims nothing, and unpausing it is a save that is asked
    /// the same question.
    public static func check(_ saving: LampTile, against others: [LampTile]) -> LampConflict? {
        for other in others
        where other.key != saving.key
            && other.key.clockId == saving.key.clockId
            && other.slot == saving.slot {
            let overlap = saving.policy.grid.overlap(with: other.policy.grid)
            if !overlap.isEmpty {
                return LampConflict(
                    existing: other.name, saving: saving.name, slot: saving.slot, overlap: overlap
                )
            }
        }
        return nil
    }
}

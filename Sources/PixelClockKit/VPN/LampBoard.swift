// Sources/PixelClockKit/VPN/LampBoard.swift
import Foundation

/// One VPN tile's bid for its lamp.
public struct LampClaim: Equatable, Sendable {
    public let key: TileKey
    public let slot: IndicatorSlot
    public let policy: TilePolicy
    /// What the tile's face shows for its latest reading.
    public let signal: IndicatorSignal

    public init(key: TileKey, slot: IndicatorSlot, policy: TilePolicy, signal: IndicatorSignal) {
        self.key = key
        self.slot = slot
        self.policy = policy
        self.signal = signal
    }
}

/// Who owns each lamp of one clock at this moment.
public enum LampBoard {
    /// Every slot named by a claim or in `covering`, and what it shows: the
    /// signal of the first claim whose policy runs now, or `.off` when none
    /// does.
    ///
    /// One answer per slot, worked out before anything is written. A lamp
    /// handed from one tile to another on a Focus switch therefore goes
    /// straight from the old colour to the new one, never through the old tile
    /// letting go first.
    ///
    /// Only the slots in play. A lamp no VPN tile has claimed is left to
    /// whatever else lit it; `covering` names the ones this app lit before and
    /// must now put out, because their last claim went away.
    ///
    /// "First" is a tie-break for a state the save-time refusal keeps out —
    /// two claims on one lamp running at once — so that if one ever arrives,
    /// by a migration or a hand-edited file, the lamp shows one steady answer
    /// rather than whichever write landed last.
    public static func lamps(
        _ claims: [LampClaim],
        covering: Set<IndicatorSlot> = [],
        in focus: MacFocus,
        atHour hour: Int
    ) -> [IndicatorSlot: IndicatorSignal] {
        let slots = covering.union(claims.map(\.slot))
        return Dictionary(uniqueKeysWithValues: slots.map { slot in
            let owner = claims.first { $0.slot == slot && $0.policy.runs(in: focus, atHour: hour) }
            return (slot, owner?.signal ?? .off)
        })
    }
}

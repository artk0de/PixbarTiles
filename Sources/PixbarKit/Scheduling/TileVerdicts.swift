// Sources/PixbarKit/Scheduling/TileVerdicts.swift
import Foundation

/// Which tiles' policies changed their answer since the last look.
///
/// What a Focus switch or an hour boundary acts on. Only a CHANGE is news:
/// asking every minute and acting on the answer would re-push an unchanged app
/// sixty times an hour and re-retract one already gone.
public struct TileVerdicts: Sendable {
    private var last: [TileKey: Bool] = [:]

    public init() {}

    /// Records whether each tile's policy lets it run now, and returns the
    /// tiles that started and stopped being allowed since the last call.
    ///
    /// A tile seen for the first time is not a change — a launch, or a tile
    /// just added, already delivers what it owes by its own route, and counting
    /// its first look would push it twice or retract what was just delivered.
    /// A tile missing from `current` is forgotten, so one removed and added
    /// again starts fresh.
    ///
    /// A first look that finds the tile held is reported apart, as
    /// `heldAtFirstLook`: not a change, but a page a previous run may have
    /// left on the clock — a relaunch inside Sleep's end, a tile switched
    /// back on out of its hours — which nothing else would ever take off.
    public mutating func update(
        _ current: [TileKey: Bool]
    ) -> (arrived: Set<TileKey>, left: Set<TileKey>, heldAtFirstLook: Set<TileKey>) {
        defer { last = current }
        var arrived: Set<TileKey> = []
        var left: Set<TileKey> = []
        var heldAtFirstLook: Set<TileKey> = []
        for (key, runs) in current {
            guard let before = last[key] else {
                if !runs { heldAtFirstLook.insert(key) }
                continue
            }
            guard before != runs else { continue }
            if runs {
                arrived.insert(key)
            } else {
                left.insert(key)
            }
        }
        return (arrived, left, heldAtFirstLook)
    }
}

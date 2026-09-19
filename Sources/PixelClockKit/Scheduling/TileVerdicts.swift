// Sources/PixelClockKit/Scheduling/TileVerdicts.swift
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
    public mutating func update(
        _ current: [TileKey: Bool]
    ) -> (arrived: Set<TileKey>, left: Set<TileKey>) {
        defer { last = current }
        var arrived: Set<TileKey> = []
        var left: Set<TileKey> = []
        for (key, runs) in current {
            guard let before = last[key], before != runs else { continue }
            if runs {
                arrived.insert(key)
            } else {
                left.insert(key)
            }
        }
        return (arrived, left)
    }
}

// Sources/PixbarKit/Tiles/PolicyGrid.swift
import Foundation

/// Where a policy lets its tile run: every Focus state by every hour of the
/// day, 144 cells.
///
/// A policy is a function of those two values and nothing else, so its grid
/// is the whole of it. That is what makes two checks exact rather than
/// heuristic — two tiles claiming one lamp, and the tests, which enumerate it.
public struct PolicyGrid: Equatable, Sendable {
    public struct Cell: Hashable, Sendable {
        public let focus: MacFocus
        public let hour: Int

        public init(focus: MacFocus, hour: Int) {
            self.focus = focus
            self.hour = hour
        }
    }

    /// The cells the tile runs in.
    public let running: Set<Cell>

    public init(_ policy: TilePolicy) {
        var running = Set<Cell>()
        for focus in MacFocus.allCases {
            for hour in 0..<24 where policy.runs(in: focus, atHour: hour) {
                running.insert(Cell(focus: focus, hour: hour))
            }
        }
        self.running = running
    }

    init(running: Set<Cell>) {
        self.running = running
    }

    public var isEmpty: Bool { running.isEmpty }

    public func runs(in focus: MacFocus, atHour hour: Int) -> Bool {
        running.contains(Cell(focus: focus, hour: hour))
    }
}

extension TilePolicy {
    public var grid: PolicyGrid { PolicyGrid(self) }
}

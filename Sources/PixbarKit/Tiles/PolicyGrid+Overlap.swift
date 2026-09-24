// Sources/PixbarKit/Tiles/PolicyGrid+Overlap.swift
import Foundation

extension PolicyGrid {
    /// The cells both grids run in: where two tiles would both want the same
    /// lamp at the same moment. Exact — the grids are the whole of both
    /// policies.
    public func overlap(with other: PolicyGrid) -> PolicyGrid {
        PolicyGrid(running: running.intersection(other.running))
    }

    /// The cells as a person reads them — `Work, 10:00–19:00`.
    ///
    /// States that run over the same hours are named together, and all six at
    /// once as "any Focus"; a stretch across midnight is one stretch; the whole
    /// day is "all day". Empty for an empty grid.
    public var summary: String {
        var groups: [(focuses: [MacFocus], hours: Set<Int>)] = []
        for focus in MacFocus.allCases {
            let hours = Set((0..<24).filter { runs(in: focus, atHour: $0) })
            guard !hours.isEmpty else { continue }
            if let index = groups.firstIndex(where: { $0.hours == hours }) {
                groups[index].focuses.append(focus)
            } else {
                groups.append((focuses: [focus], hours: hours))
            }
        }
        return groups
            .map { "\(Self.naming($0.focuses)), \(Self.stretches(of: $0.hours))" }
            .joined(separator: "; ")
    }

    private static func naming(_ focuses: [MacFocus]) -> String {
        guard focuses.count < MacFocus.allCases.count else { return "any Focus" }
        let names = focuses.map(\.displayName)
        guard let last = names.last, names.count > 1 else { return names[0] }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Each unbroken run of hours, walked round the clock so that 23:00 and
    /// 00:00 belong to the same stretch.
    private static func stretches(of hours: Set<Int>) -> String {
        guard hours.count < 24 else { return "all day" }
        let starts = hours.filter { !hours.contains(($0 + 23) % 24) }.sorted()
        return starts
            .map { start in
                var last = start
                while hours.contains((last + 1) % 24) { last = (last + 1) % 24 }
                return HourWindow(startHour: start, endHour: last + 1).label
            }
            .joined(separator: " and ")
    }
}

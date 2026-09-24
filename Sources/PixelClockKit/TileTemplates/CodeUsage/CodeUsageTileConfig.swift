import Foundation

/// The parameters a coding-subscription tile offers.
///
/// The SAME list on the Claude tile and the z.ai tile — that is the rule this
/// type exists to hold. What a vendor differs by is its mark and its colours
/// (`CodeUsage.Vendor`) and how the tile reaches its account; a parameter one
/// vendor's tile offers and the other's does not is a tile that drifted.
///
/// - `resetEvery`: the dwell. What it is spent ON depends on the layout —
///   Compact stands on the percentages for it before a hot row flips to its
///   reset time, Circle gives it to one window's whole turn. `Layout
///   .dwellLabel` is what the settings window calls it in each.
/// - `resetAfter`: from what percentage a row is hot at all. Below it the
///   page is the percentages and nothing else.
/// - `layout`: which face draws the page.
/// - `windows`: which windows the Circle rotates through. Compact draws both
///   rows always — it has a place for each and no reason to leave one empty.
///
/// Records written before these settings existed decode as `standard`;
/// nothing rewrites them. The tile configs that carry this one leave it out of
/// their JSON while it IS `standard`, so a record nobody touched stays
/// byte-identical to the one written before the settings were — and a setting
/// still at its default writes no key at all, so adding one here never
/// rewrites a record that never chose it.
public extension CodeUsage {
    struct Parameters: Codable, Equatable, Sendable {
        /// Seconds of one dwell — the percentages in Compact, one window's turn
        /// in Circle.
        public var resetEvery: TimeInterval
        /// The percentage from which a row shows its reset.
        public var resetAfter: Int
        /// Which face draws the page.
        public var layout: Layout
        /// Which windows the Circle shows, in the order it shows them.
        ///
        /// Never empty: a tile showing no window has nothing to draw, and a
        /// panel drawing nothing reads as a broken tile rather than as a
        /// setting. The setter and the decoder both hold that.
        public var windows: [WindowKind] {
            didSet { windows = Self.ordered(windows) }
        }

        /// Which way round the week's reset date reads.
        public var dateOrder: DateOrder

        public init(
            resetEvery: TimeInterval, resetAfter: Int,
            layout: Layout = .compact, windows: [WindowKind] = WindowKind.allCases,
            dateOrder: DateOrder = .dayFirst
        ) {
            self.resetEvery = resetEvery
            self.resetAfter = resetAfter
            self.layout = layout
            self.windows = Self.ordered(windows)
            self.dateOrder = dateOrder
        }

        /// Sorted by the period each measures and de-duplicated, and both
        /// windows when the list names none — the panel shows them shortest
        /// first whatever order a record or a row of checkboxes produced.
        private static func ordered(_ windows: [WindowKind]) -> [WindowKind] {
            let chosen = WindowKind.allCases.filter(windows.contains)
            return chosen.isEmpty ? WindowKind.allCases : chosen
        }

        /// Whether the dwell picker has anything to set. The Circle spends it
        /// on the move from one window to the next, so with one window
        /// selected nothing changes and the picker is disabled; Compact's
        /// "Show reset every" stands whatever is selected.
        public var dwellIsAdjustable: Bool {
            layout == .compact || windows.count > 1
        }

        /// Ten seconds, eighty percent — the first warning band's own threshold,
        /// so by default a row names its reset exactly when its colour starts to
        /// warn.
        public static let standard = Parameters(resetEvery: 10, resetAfter: 80)

        /// What the dwell picker offers: 5 s to 5 min.
        public static let resetEverySteps: [TimeInterval] = [5, 10, 15, 30, 60, 120, 300]
        /// What "Show reset after" offers: 0 % to 100 % in fives (the user's
        /// call of 2026-09-24; it was 50 % up). Every value stored under the
        /// old range is still on this one, and nothing clamps a stored value —
        /// the faces compare against it as it is.
        public static let resetAfterSteps: [Int] = Array(stride(from: 0, through: 100, by: 5))

        private enum CodingKeys: String, CodingKey {
            case resetEvery = "showResetEvery"
            case resetAfter = "showResetAfter"
            case layout
            case windows
            case dateOrder
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            resetEvery = try container.decodeIfPresent(TimeInterval.self, forKey: .resetEvery)
                ?? Self.standard.resetEvery
            resetAfter = try container.decodeIfPresent(Int.self, forKey: .resetAfter)
                ?? Self.standard.resetAfter
            // Compact, because it is the face every existing tile already draws.
            layout = try container.decodeIfPresent(Layout.self, forKey: .layout) ?? .compact
            windows = Self.ordered(
                try container.decodeIfPresent([WindowKind].self, forKey: .windows) ?? []
            )
            dateOrder = try container.decodeIfPresent(DateOrder.self, forKey: .dateOrder)
                ?? .dayFirst
        }

        /// Written by hand rather than synthesised, so a setting still at its
        /// default writes no key: the record a tile wrote before the layout
        /// existed is the record it writes after, byte for byte.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(resetEvery, forKey: .resetEvery)
            try container.encode(resetAfter, forKey: .resetAfter)
            if layout != .compact {
                try container.encode(layout, forKey: .layout)
            }
            if windows != WindowKind.allCases {
                try container.encode(windows, forKey: .windows)
            }
            if dateOrder != .dayFirst {
                try container.encode(dateOrder, forKey: .dateOrder)
            }
        }
    }
}

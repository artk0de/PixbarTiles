import Foundation

public extension CodeUsage {
    /// Which face a coding-subscription tile draws.
    ///
    /// The two answer different questions and neither is the other's fallback:
    /// Compact says where BOTH windows stand in one glance, Circle says where
    /// ONE window stands and spends the whole panel saying it. A reader who
    /// budgets against the week wants the second; a reader watching a session
    /// burn wants the first.
    ///
    /// Offered on both vendors' tiles, like every other parameter — a layout
    /// Claude's tile has and z.ai's has not is the drift the substrate exists
    /// to prevent.
    enum Layout: String, Codable, Sendable, CaseIterable, Identifiable {
        /// Both windows at once: a row each, label, figure and a one-pixel bar.
        case compact
        /// One window at a time, its reading unrolled around the panel's rim.
        case circle

        public var id: String { rawValue }

        /// What the settings window calls it.
        public var displayName: String {
            switch self {
            case .compact: "Compact"
            case .circle: "Circle"
            }
        }

        /// What the dwell MEANS in this layout, as the settings window says it.
        ///
        /// One stored number, because the panel only has one: Compact stands on
        /// the percentages for it and then flips a hot row to its reset; Circle
        /// spends it on one window's whole turn and then moves to the next. The
        /// label has to say which, or the same picker reads as two settings.
        public var dwellLabel: String {
            switch self {
            case .compact: "Show reset every"
            case .circle: "Change every"
            }
        }
    }

    /// Which way round a reset's date reads.
    ///
    /// A reader's setting, not a vendor's or a locale's: half the world reads
    /// the day first and half the month, and a panel that guesses from the
    /// Mac's region gets it wrong for everyone who set that region for some
    /// other reason. Neither spelling carries a comma or an "at" — the panel
    /// has room for neither at 52 columns.
    ///
    /// The two are the same glyphs moved, so they are exactly as wide as one
    /// another. Nothing about how a reset is fitted or scrolled depends on
    /// which is chosen.
    enum DateOrder: String, Codable, Sendable, CaseIterable, Identifiable {
        /// `26 sep 15:00`
        case dayFirst
        /// `sep 26 15:00`
        case monthFirst

        public var id: String { rawValue }

        /// What the settings window shows: the spelling itself, on a date that
        /// tells the two apart at a glance.
        public var displayName: String {
            switch self {
            case .dayFirst: "26 sep 15:00"
            case .monthFirst: "sep 26 15:00"
            }
        }
    }
}

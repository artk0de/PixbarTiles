import Foundation

public extension CodeUsage {
    /// Which window a reading is OF — and, on a face that shows one at a time,
    /// what the panel calls it.
    ///
    /// Two, and no third. The five-hour session limit and the seven-day one are
    /// what both plans actually meter: daily limits are gone from Claude and
    /// z.ai alike, and z.ai's monthly MCP allowance meters tool calls rather
    /// than the subscription being spent.
    enum WindowKind: String, Codable, Sendable, CaseIterable, Identifiable, Comparable {
        /// The rolling five-hour window — the session limit.
        case fiveHour
        /// The seven-day window.
        case weekly

        public var id: String { rawValue }

        /// What the panel prints. The PERIOD each measures, which is what a
        /// reader needs to know to place the figure beside it.
        ///
        /// Drawn in the five-row proportional face rather than the 3×5 one: in
        /// the small table `w` is three columns holding four strokes, which
        /// comes out as a v, and `e` is two solid rows, which comes out as a
        /// blob. "week" was unreadable at three columns a glyph.
        public var name: String {
            switch self {
            case .fiveHour: "5h"
            case .weekly: "week"
            }
        }

        /// What the settings window calls it.
        public var displayName: String {
            switch self {
            case .fiveHour: "5-hour limit"
            case .weekly: "Weekly limit"
            }
        }

        /// How this window's reset is spelled on the panel.
        ///
        /// The session names a TIME — the next one is always within five hours,
        /// so a date would be noise. The week names a date and a time, because
        /// "09:00" seven days out says nothing about which day, in whichever
        /// order the tile was told to read it.
        ///
        /// Reset times are INSTANTS, said in the zone the face is drawn in — the
        /// Mac's — whatever zone the vendor's server keeps (z.ai's is
        /// Asia/Shanghai).
        public func reset(
            _ date: Date, in timeZone: TimeZone, order: CodeUsage.DateOrder = .dayFirst
        ) -> String {
            switch self {
            case .fiveHour: CodeUsage.sessionReset(date, in: timeZone)
            case .weekly: CodeUsage.weeklyReset(date, in: timeZone, order: order)
            }
        }

        /// Ordered as the windows are shown: the shorter period first, because
        /// it is the one that moves.
        public static func < (lhs: Self, rhs: Self) -> Bool {
            allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
        }
    }

    // MARK: - Reset spellings

    /// `rst 14:30` — the session's reset, in `timeZone`, 24-hour.
    static func sessionReset(_ date: Date, in timeZone: TimeZone) -> String {
        "rst " + clock(components(of: date, in: timeZone))
    }

    /// `rst 1 oct 09:00`, or `rst oct 1 09:00` — the week's reset, in
    /// `timeZone`: the day without a leading zero, the month's three lowercase
    /// letters, no comma, in the order the tile was told to read.
    ///
    /// No comma and no "at", and that was checked rather than assumed:
    /// Foundation's en_US template for a day, a month and a time is
    /// `May 5 at 18:00` — the comma only appears once a year is in it. The
    /// panel has room for neither.
    ///
    /// The two orders are the same glyphs moved, so they are the same width:
    /// a reset that fits its area still fits, and one that marquees takes the
    /// same frames to pass. That is what lets one set of recorded frames stand
    /// for both.
    static func weeklyReset(
        _ date: Date, in timeZone: TimeZone, order: DateOrder = .dayFirst
    ) -> String {
        let parts = components(of: date, in: timeZone)
        let month = months[(parts.month ?? 1) - 1]
        let day = "\(parts.day ?? 1)"
        let date = switch order {
        case .dayFirst: "\(day) \(month)"
        case .monthFirst: "\(month) \(day)"
        }
        return "rst \(date) " + clock(parts)
    }

    /// English abbreviations spelled out rather than asked of a formatter: a
    /// locale's own abbreviation can carry a dot or a letter the face has no
    /// glyph for, and this one must be exactly what the panel can draw.
    private static var months: [String] {
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
    }

    private static func components(of date: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.month, .day, .hour, .minute], from: date)
    }

    private static func clock(_ parts: DateComponents) -> String {
        String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

import Foundation

/// The substrate under every coding-subscription tile: Claude's and z.ai's.
///
/// Both tiles answer the same question — how much of a paid coding allowance
/// is gone, and when it starts again — so they are ONE tile with two sources.
/// What a vendor is allowed to differ by is `Vendor`, and that list is the
/// whole of it: a mark, the colours it is drawn in, and what to call it. Every
/// other thing a reader sees — the page, the ramp, the reset spellings, the
/// parameters the tile offers — belongs here and is the same for both.
///
/// The two halves that were NOT the same when this was extracted, and what
/// each cost:
///
/// - The AWTRIX page. Claude drew a figure, its mark and a band-coloured bar;
///   z.ai drew its windows as a joined line with no mark and no bar. Two pages
///   for one question, differing in everything except the question.
/// - The tile's parameters. Claude carried a display metric z.ai had no
///   counterpart for, whose "Daily limit" read the five-hour window, and
///   z.ai's tile went without the Focus rule that keeps a lit figure off the
///   panel under Do Not Disturb.
///
/// Layering: this is L2 — a template shared by a family of tiles, standing on
/// the general components (`PixelCanvas`, `AwtrixDelivery`, `Connector`) and
/// stood on by the two implementations in `Claude/` and `Zai/`.
public enum CodeUsage {}

public extension CodeUsage {
    /// Everything one vendor is allowed to differ by.
    ///
    /// Deliberately a closed list rather than a protocol with room to grow: a
    /// vendor that can override the page is a vendor that will, and then there
    /// are two pages again. A new vendor supplies these fields and gets the
    /// whole tile.
    struct Vendor: Sendable, Equatable {
        /// The connector's id, the tile key's connector half, and the name the
        /// app lives under in the device's own loop — one string, so the three
        /// cannot drift apart.
        public let id: String
        /// What the Add-tile menu and the settings window call it.
        public let displayName: String
        /// The mark as rows of `#` (lit) and `.`, at most 8 × 5 — the TC002
        /// panel's own copy of it.
        public let logo: [String]
        /// What the mark is drawn in on the panel.
        public let logoColour: UlanziColour
        /// `#RRGGBB`, what `Band.fillColour(brand:)` answers below the first
        /// warning, and what the AWTRIX page's text is drawn in.
        public let brand: String
        /// The mark again, as the 8 × 8 art the AWTRIX page shows beside its
        /// figure — art this app carries and uploads to the clock's flash.
        ///
        /// z.ai's is DRAWN from `logo` by `Scripts/make_usage_icons.py`, so the
        /// mark has one definition and the panel and the matrix cannot come to
        /// disagree about it. Claude's star predates the substrate and is not a
        /// rendering of its `logo`; it is left as the art it is rather than
        /// replaced by a crab-shaped approximation of itself.
        ///
        /// `UsageIconTests` holds both to shipping: art renamed on one side
        /// only fails the suite, where the clock would answer it by drawing the
        /// app with nothing beside it — which reads as an ordinary banner.
        public let icon: IconReference

        public init(
            id: String, displayName: String, logo: [String],
            logoColour: UlanziColour, brand: String, icon: IconReference
        ) {
            self.id = id
            self.displayName = displayName
            self.logo = logo
            self.logoColour = logoColour
            self.brand = brand
            self.icon = icon
        }

        /// The Claude crab, in Claude's orange.
        public static let claude = Vendor(
            id: "claude",
            displayName: "Claude usage",
            logo: [
                ".######.",
                ".#.##.#.",
                "########",
                ".######.",
                ".##..##.",
            ],
            logoColour: UlanziColour(hex: ClaudeUsage.brandColour),
            brand: ClaudeUsage.brandColour,
            icon: .bundled("ClaudeStar")
        )

        /// z.ai's "Z", in near-white: the plan's blue is the figures' colour,
        /// and a blue mark beside blue figures would read as one more figure.
        public static let zai = Vendor(
            id: "zai",
            displayName: "z.ai usage",
            logo: [
                "#######",
                "....##.",
                "..###..",
                ".##....",
                "#######",
            ],
            logoColour: UlanziColour(value: 0xE8_E8_E8),
            brand: ZaiUsage.brandColour,
            icon: .bundled("ZaiZ")
        )
    }

    /// One window's reading: how much of it is gone — past a hundred is
    /// allowed, and drawn as a hundred — and when it starts again, when the
    /// source said so.
    struct Window: Sendable, Equatable {
        public let percent: Int
        public let resetsAt: Date?

        public init(percent: Int, resetsAt: Date?) {
            self.percent = percent
            self.resetsAt = resetsAt
        }
    }

    /// One picture of a page's timeline, and how long the panel shows it.
    ///
    /// Shared by every face the substrate carries: Compact and Circle differ in
    /// what they draw, never in what a frame IS.
    struct Frame: Sendable, Equatable {
        public let canvas: PixelCanvas
        public let milliseconds: Int

        public init(canvas: PixelCanvas, milliseconds: Int) {
            self.canvas = canvas
            self.milliseconds = milliseconds
        }
    }

    /// What a source reports, in the shape the tile draws.
    ///
    /// Both windows optional, and that symmetry is the point: Claude's weekly
    /// figure used to be non-optional because its document always carries one,
    /// which made the two vendors' readings different shapes for a reason that
    /// belongs to a document format rather than to the tile. A window nobody
    /// reported is a window the page leaves blank, whichever vendor it is.
    ///
    /// Two windows and no third. The five-hour session limit and the seven-day
    /// one are what both plans actually meter; daily limits are gone from both,
    /// and z.ai's monthly MCP allowance is not a coding window at all.
    struct Reading: Sendable, Equatable {
        public let fiveHour: Window?
        public let weekly: Window?

        public init(fiveHour: Window?, weekly: Window?) {
            self.fiveHour = fiveHour
            self.weekly = weekly
        }

        /// The figure a single-number surface shows: the WEEKLY window, and
        /// the five-hour one only when there is no weekly reading.
        ///
        /// The week is the allowance a person budgets against — a five-hour
        /// window empties and refills several times inside one, so a page that
        /// showed it would swing between readings that are both true and mean
        /// nothing together.
        public var headline: Window? { weekly ?? fiveHour }

        /// The reading for one window, asked for by NAME.
        ///
        /// A face that rotates through whichever windows a tile selected has a
        /// list of `WindowKind` and no business knowing which property holds
        /// which period.
        public func window(_ kind: WindowKind) -> Window? {
            switch kind {
            case .fiveHour: fiveHour
            case .weekly: weekly
            }
        }
    }
}

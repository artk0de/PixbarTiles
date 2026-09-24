// Sources/PixbarKit/Tiles/TileDefaults.swift
import Foundation

/// The policy each connector's new tile starts from — the design's defaults
/// table, one constant per row.
///
/// Values, not a registry: a tile copies one when it is created and owns the
/// copy from then on, so changing a row here moves new tiles and never an
/// existing one.
public enum TileDefaults {
    /// Ambient and silent, so nothing about a Focus or the hour applies.
    public static let weather = TilePolicy(refreshSeconds: 600)

    /// Every coding-subscription tile — Claude's and z.ai's alike.
    ///
    /// A lit figure is not what anybody wants under Do Not Disturb or beside a
    /// bed; an unnamed Focus keeps it, because hiding on "cannot tell" is an
    /// app that never appears on a machine without Full Disk Access.
    ///
    /// ONE policy, where z.ai's used to be the bare interval with no Focus rule
    /// at all. Nothing about a z.ai figure makes it more welcome at 3 a.m. than
    /// a Claude one; the difference was neglect, not a decision.
    public static let codeUsage = TilePolicy(
        refreshSeconds: 60,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .run)
    )

    /// The one tile that speaks, so the one that holds on "cannot tell" and
    /// keeps the night.
    public static let anecdotes = TilePolicy(
        refreshSeconds: 1_800,
        focus: FocusRule(silencedIn: [.doNotDisturb, .sleep], whenUnknown: .hold),
        window: .quiet(HourWindow(startHour: 23, endHour: 8))
    )

    /// Event-driven: the sixty seconds are the recheck between events.
    public static let vpn = TilePolicy(refreshSeconds: 60)

}

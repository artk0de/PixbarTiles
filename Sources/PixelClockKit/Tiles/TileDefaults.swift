// Sources/PixelClockKit/Tiles/TileDefaults.swift
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

    /// A lit figure is not what anybody wants under Do Not Disturb or beside a
    /// bed; an unnamed Focus keeps it, because hiding on "cannot tell" is an
    /// app that never appears on a machine without Full Disk Access.
    public static let claude = TilePolicy(
        refreshSeconds: 300,
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

    /// Ambient and silent like the weather: the z.ai figure is drawn into the
    /// device's own loop and says nothing, so nothing about a Focus or the
    /// hour applies. Ten minutes is the poll the design's connector row asks
    /// for — a plan's usage moves slowly, and the route is a dashboard one.
    public static let zai = TilePolicy(refreshSeconds: 600)
}

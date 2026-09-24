// Sources/PixbarKit/Tiles/TilePolicy.swift
import Foundation

/// Which Focuses a tile does not work in.
public struct FocusRule: Equatable, Sendable {
    /// What a tile does under a Focus the app cannot name.
    public enum WhenUnknown: String, Codable, Sendable {
        case run
        case hold
    }

    /// The named states the tile stays quiet in, edited as "works in" boxes.
    ///
    /// `.unknown` is not decided here even when it is in the set:
    /// `whenUnknown` decides it, so the answer has one home and a sixth box
    /// that nobody is shown cannot contradict the menu that is.
    public var silencedIn: Set<MacFocus>
    public var whenUnknown: WhenUnknown

    public init(silencedIn: Set<MacFocus> = [], whenUnknown: WhenUnknown = .run) {
        self.silencedIn = silencedIn
        self.whenUnknown = whenUnknown
    }

    public func silences(_ focus: MacFocus) -> Bool {
        switch focus {
        case .unknown:
            whenUnknown == .hold
        default:
            silencedIn.contains(focus)
        }
    }
}

/// The hours a tile keeps: all of them, all but a quiet stretch, or only a
/// working stretch.
public enum TileWindow: Equatable, Sendable {
    case always
    /// Silent inside the window.
    case quiet(HourWindow)
    /// Silent outside the window.
    case active(HourWindow)

    public func silences(atHour hour: Int) -> Bool {
        switch self {
        case .always:
            false
        case let .quiet(window):
            window.contains(hour: hour)
        case let .active(window):
            // An empty window restricts nothing in either direction. Read as
            // "no working hours", it would be a tile that never runs again
            // because a picker landed on the hour it started from.
            !window.isEmpty && !window.contains(hour: hour)
        }
    }
}

/// Why a tile is not running at a given moment.
public enum TileHold: Equatable, Sendable {
    /// Stopped by the user, with its settings kept.
    case paused
    /// Its hours say not now — inside quiet hours, or outside working ones.
    case hours
    /// The Mac is in a Focus the tile does not work in.
    case focus
}

/// What every tile carries about when it runs, whatever its connector.
///
/// Copied from the connector's defaults when the tile is created, then the
/// tile's own.
public struct TilePolicy: Equatable, Sendable {
    public var isPaused: Bool
    /// Seconds between runs as stored — for an event-driven tile, between
    /// rechecks. Read through `refresh`, which puts it on the scale.
    public var refreshSeconds: Int
    public var focus: FocusRule
    public var window: TileWindow

    public init(
        isPaused: Bool = false,
        refreshSeconds: Int,
        focus: FocusRule = FocusRule(),
        window: TileWindow = .always
    ) {
        self.isPaused = isPaused
        self.refreshSeconds = refreshSeconds
        self.focus = focus
        self.window = window
    }

    /// Seconds between runs, on the refresh scale and never under its floor.
    public var refresh: TimeInterval {
        RefreshScale.snapped(TimeInterval(refreshSeconds))
    }

    /// What holds the tile in this Focus at this hour, or nil when it runs.
    ///
    /// Paused first, then the hours, then the Focus. The hours come before the
    /// Focus because the answer is a reason as well as a verdict: the nightly
    /// refresh reads `.hours` to decide whether it may spend, and a 3 a.m.
    /// Sleep answered as `.focus` would let it load a model and spin the fans
    /// inside the hours somebody set aside for quiet. the app-wide gate
    /// fixed that order, and it stays.
    public func hold(in current: MacFocus, atHour hour: Int) -> TileHold? {
        if isPaused { return .paused }
        if window.silences(atHour: hour) { return .hours }
        if focus.silences(current) { return .focus }
        return nil
    }

    public func runs(in current: MacFocus, atHour hour: Int) -> Bool {
        hold(in: current, atHour: hour) == nil
    }
}

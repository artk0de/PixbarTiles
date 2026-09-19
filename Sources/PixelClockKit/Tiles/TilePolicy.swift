// Sources/PixelClockKit/Tiles/TilePolicy.swift
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

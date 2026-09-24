// Sources/PixbarKit/Tiles/TilePolicy+Coding.swift
import Foundation

// The shapes of a tile policy's two optional keys, `focus` and `window`, which
// Part B adds beside `isPaused` and `refreshSeconds` in the stored
// `TilePolicyRecord`. Written out by hand rather than synthesized, so a renamed
// case or a reordered set cannot change the bytes on disk:
//
//   "focus":{"silencedIn":["doNotDisturb","sleep"],"whenUnknown":"hold"}
//   "window":{"endHour":8,"kind":"quiet","startHour":23}
//
// `window` is `{"kind":"always"}`, or `quiet` / `active` with both hours.

extension FocusRule: Codable {
    private enum Key: String, CodingKey {
        case silencedIn, whenUnknown
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        self.init(
            silencedIn: Set(try container.decode([MacFocus].self, forKey: .silencedIn)),
            whenUnknown: try container.decode(WhenUnknown.self, forKey: .whenUnknown)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        // In declaration order rather than the set's own, which changes from
        // one launch to the next: the same policy is always the same bytes.
        try container.encode(MacFocus.allCases.filter(silencedIn.contains), forKey: .silencedIn)
        try container.encode(whenUnknown, forKey: .whenUnknown)
    }
}

extension TileWindow: Codable {
    private enum Key: String, CodingKey {
        case kind, startHour, endHour
    }

    private enum Kind: String, Codable {
        case always, quiet, active
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .always:
            self = .always
        case .quiet:
            self = .quiet(try Self.hours(in: container))
        case .active:
            self = .active(try Self.hours(in: container))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .always:
            try container.encode(Kind.always, forKey: .kind)
        case let .quiet(window):
            try container.encode(Kind.quiet, forKey: .kind)
            try Self.write(window, into: &container)
        case let .active(window):
            try container.encode(Kind.active, forKey: .kind)
            try Self.write(window, into: &container)
        }
    }

    /// Through `HourWindow`'s initialiser, so a stored hour past the clock is
    /// read round it like any other.
    private static func hours(in container: KeyedDecodingContainer<Key>) throws -> HourWindow {
        HourWindow(
            startHour: try container.decode(Int.self, forKey: .startHour),
            endHour: try container.decode(Int.self, forKey: .endHour)
        )
    }

    private static func write(
        _ window: HourWindow, into container: inout KeyedEncodingContainer<Key>
    ) throws {
        try container.encode(window.startHour, forKey: .startHour)
        try container.encode(window.endHour, forKey: .endHour)
    }
}

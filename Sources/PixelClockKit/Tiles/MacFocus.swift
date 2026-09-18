import Foundation

/// Which Focus the Mac is in, as a tile's policy reads it.
///
/// Closed on purpose: the four modes macOS ships, nothing on, and everything
/// else. A Focus the user invented is `.unknown` — its name is theirs to change
/// and its identifier is generated, so nothing about it can be matched.
///
/// Not `FocusState`, which is what the design called it: SwiftUI declares a
/// `FocusState` of its own, and every view file importing both would have to
/// qualify the name through a module whose namespace enum shadows it.
public enum MacFocus: String, CaseIterable, Codable, Hashable, Sendable {
    /// Spelled out rather than `none`, which reads as `Optional`'s own case at
    /// every site that holds one of these in an optional.
    case noFocus
    case work
    case personal
    case doNotDisturb
    case sleep
    case unknown

    /// The identifiers macOS ships for its four built-in modes.
    ///
    /// Matched on these and never on the mode's name beside them, which is
    /// localised and which the user can rename.
    static let builtIn: [String: MacFocus] = [
        "com.apple.focus.work": .work,
        "com.apple.focus.personal": .personal,
        "com.apple.donotdisturb.mode.default": .doNotDisturb,
        "com.apple.sleep.sleep-mode": .sleep,
    ]

    /// The mode an asserted identifier names, or `.unknown` for one macOS did
    /// not ship. Never `.noFocus`: something IS asserted, and reading it as
    /// nothing would run a tile through what might be Sleep.
    public init(modeIdentifier: String) {
        self = Self.builtIn[modeIdentifier] ?? .unknown
    }

    /// The identifier macOS asserts for this mode, or nil for the two states
    /// that are not a mode.
    public var modeIdentifier: String? {
        Self.builtIn.first { $0.value == self }?.key
    }

    /// What the settings and the refusal messages call it.
    public var displayName: String {
        switch self {
        case .noFocus: "No Focus"
        case .work: "Work"
        case .personal: "Personal"
        case .doNotDisturb: "Do Not Disturb"
        case .sleep: "Sleep"
        case .unknown: "Other Focus"
        }
    }
}

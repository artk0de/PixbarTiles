import AwtrixKit
import Foundation

/// What the two corners of the matrix are showing.
///
/// Both lamps always, never a partial answer. The pusher compares one of these
/// against the last it sent and writes only what moved, so a lamp left out of
/// the value would be a lamp nothing ever turns off — and the failure would be
/// a red corner blinking through Sleep at three in the morning.
struct VPNLamps: Equatable, Sendable {
    var topRight: IndicatorSignal
    var bottomRight: IndicatorSignal

    static let dark = VPNLamps(topRight: .off, bottomRight: .off)
}

/// Which corner says what, given the Focus and the two tunnels.
///
/// A pure function of three values, which is the point: everything that decides
/// what the clock shows is here and testable, and everything that talks to the
/// machine or the device is somewhere else.
enum VPNIndicatorPolicy {
    /// Apple's own identifiers for the two built-in Focuses.
    ///
    /// Matched on the identifier and never on the name beside it, for the
    /// reason `DoNotDisturbDatabase.silencing` gives: the name is localised —
    /// it reads "Работа" on this machine — and the user can rename any Focus
    /// from System Settings.
    ///
    /// These two could not be verified from outside the app: naming the active
    /// Focus costs Full Disk Access, which the signed app holds and a terminal
    /// does not. If a switch into work leaves the corner dark, this is the line
    /// that is wrong and the only one.
    static let workFocus = "com.apple.focus.work"
    static let personalFocus = "com.apple.focus.personal"

    /// The work tunnel is up. Light green rather than a saturated one: this is
    /// the state things are SUPPOSED to be in, and it should read as calm at
    /// the edge of vision rather than as a second alarm.
    static let tunnelUp = "#90EE90"

    /// And is not. The only alarm in the scheme.
    static let tunnelMissing = "#FF0000"

    /// Twice a second — fast enough to catch an eye that is not looking at the
    /// clock, slow enough not to strobe a dark room.
    static let blinkMilliseconds = 500

    /// The personal tunnel is carrying.
    static let privateTunnel = "#A855F7"

    static func lamps(focus: ActiveFocusMode, pritunl: Bool, amnezia: Bool) -> VPNLamps {
        // Anything that is not one of the two named Focuses says nothing at
        // all, and `.cannotTell` falls in here with the rest. That is the
        // deliberate half of this: an indicator asserts a fact, and a machine
        // that cannot name its Focus has no fact to assert. Treating "cannot
        // tell" as "might be work" would give it a corner blinking red for
        // ever with nothing on screen to explain it.
        guard case let .mode(identifier) = focus else { return .dark }

        switch identifier {
        case Self.workFocus:
            return VPNLamps(
                // The one state worth interrupting somebody over: at work,
                // without the work tunnel.
                topRight: pritunl
                    ? .steady(Self.tunnelUp)
                    : .blinking(Self.tunnelMissing, everyMilliseconds: Self.blinkMilliseconds),
                bottomRight: amnezia ? .steady(Self.privateTunnel) : .off
            )
        case Self.personalFocus:
            return VPNLamps(
                // Nothing about the work tunnel, either way. A green lamp here
                // would be answering a question nobody is asking on their own
                // time.
                topRight: .off,
                bottomRight: amnezia ? .steady(Self.privateTunnel) : .off
            )
        default:
            return .dark
        }
    }
}

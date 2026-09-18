import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

private func lamps(
    _ focus: ActiveFocusMode, pritunl: Bool = false, amnezia: Bool = false
) -> VPNLamps {
    VPNIndicatorPolicy.lamps(focus: focus, pritunl: pritunl, amnezia: amnezia)
}

private let work = ActiveFocusMode.mode(VPNIndicatorPolicy.workFocus)
private let personal = ActiveFocusMode.mode(VPNIndicatorPolicy.personalFocus)

// MARK: - Work

// The one alarm in the whole scheme. Work without the work tunnel is the state
// worth interrupting somebody over, so it is the only lamp that blinks — and it
// blinks in firmware, so it keeps flashing whatever this app is doing.
@Test func workWithoutItsTunnelBlinksTheTopCorner() {
    let missing = lamps(work, pritunl: false)

    #expect(missing.topRight == .blinking(
        VPNIndicatorPolicy.tunnelMissing, everyMilliseconds: VPNIndicatorPolicy.blinkMilliseconds
    ))
}

@Test func workWithItsTunnelGoesQuietlyGreen() {
    #expect(lamps(work, pritunl: true).topRight == .steady(VPNIndicatorPolicy.tunnelUp))
}

// MARK: - Personal

// The personal tunnel is watched under BOTH Focuses, and it reports only the
// good news: lit when it is carrying, dark when it is not. No alarm, because
// not being on it is an ordinary way to spend an afternoon.
@Test func thePersonalTunnelIsWatchedUnderBothFocuses() {
    for focus in [work, personal] {
        #expect(lamps(focus, amnezia: true).bottomRight == .steady(VPNIndicatorPolicy.privateTunnel))
        #expect(lamps(focus, amnezia: false).bottomRight == .off)
    }
}

// Whereas the work tunnel is a work question. Under personal Focus the top
// corner says nothing about it either way — a green lamp there would be
// reporting on something nobody is asking about.
@Test func personalFocusSaysNothingAboutTheWorkTunnel() {
    #expect(lamps(personal, pritunl: true).topRight == .off)
    #expect(lamps(personal, pritunl: false).topRight == .off)
}

// MARK: - Everywhere else

@Test func everyOtherFocusLeavesBothCornersDark() {
    for focus in [
        ActiveFocusMode.mode("com.apple.sleep.sleep-mode"),
        .mode("com.apple.donotdisturb.mode.default"),
        .mode("com.apple.focus.fitness"),
        .mode("com.example.something.the.user.invented"),
        .noFocus,
    ] {
        #expect(lamps(focus, pritunl: true, amnezia: true) == .dark, "\(focus) lit something")
        #expect(lamps(focus, pritunl: false, amnezia: false) == .dark, "\(focus) lit something")
    }
}

// The case that decides whether this feature is safe to ship to a machine
// unlike this one. Naming the active Focus costs Full Disk Access; without it
// macOS says only that SOME Focus is on, and `.cannotTell` is what every launch
// gets. An indicator asserts a fact — so with no fact to assert, both corners
// stay dark.
//
// The tempting alternative is to treat "cannot tell" as "might be work" and
// blink. That produces a Mac whose top-right corner flashes red for ever,
// through every Focus and none, with nothing on screen to say why — which is
// worse than the feature simply not appearing.
@Test func aFocusThatCannotBeNamedClaimsNothing() {
    #expect(lamps(.cannotTell, pritunl: false, amnezia: false) == .dark)
    #expect(lamps(.cannotTell, pritunl: true, amnezia: true) == .dark)
}

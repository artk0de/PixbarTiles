import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// The seam between the migrated VPN tiles and the clock's lamps — the wiring
// that a green suite has been silent about before on this project, when a
// progress bar was added to the output type, tested at both ends, and never
// copied across the one line in between. The tiles carry what
// `VPNIndicatorPolicy` hard-coded; this file proves they reach the lamps.

private func machine(_ paths: String...) -> VPNPresence {
    VPNPresence(processes: FixedProcessList(paths: paths))
}

private let workTunnel = "/Applications/Pritunl.app/Contents/Resources/pritunl-openvpn"
private let personalTunnel = "/Applications/AmneziaVPN.app/Contents/MacOS/wireguard-go"

private func working(_ mode: String) -> StubFocusStatus {
    StubFocusStatus(access: .authorized, activeMode: .mode(mode))
}

private let lampClock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")

@Test @MainActor func workWithoutItsTunnelReachesTheClockAsABlinkingCorner() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focusStatus: (working("com.apple.focus.work")),
        // The personal tunnel is up and the work one is not, which is also the
        // case that catches a policy wired to the wrong boolean.
        vpnPresence: machine(personalTunnel),
        clocks: [lampClock],
        tiles: VPNTileMigration.tiles(on: lampClock.id),
        sessions: [lampClock.id: LampSession(lamps: clock)]
    )

    subject.refreshLamps()

    #expect(await waitUntil { clock.written.count == 2 })
    #expect(clock.written.contains {
        $0.slot == .topRight && $0.signal == .blinking("#FF0000", everyMilliseconds: 500)
    })
    #expect(clock.written.contains {
        $0.slot == .bottomRight && $0.signal == .steady("#A855F7")
    })
}

@Test @MainActor func bothTunnelsUnderWorkLightBothCornersSteadily() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focusStatus: (working("com.apple.focus.work")),
        vpnPresence: machine(workTunnel, personalTunnel),
        clocks: [lampClock],
        tiles: VPNTileMigration.tiles(on: lampClock.id),
        sessions: [lampClock.id: LampSession(lamps: clock)]
    )

    subject.refreshLamps()

    #expect(await waitUntil { clock.written.count == 2 })
    #expect(clock.written.allSatisfy {
        if case .steady = $0.signal { return true } else { return false }
    })
}

// Sleep is not one of the two Focuses a migrated tile works in, so neither lamp
// is claimed — including the alarm. A blinking red corner beside a bed is the
// failure this rules out.
@Test @MainActor func sleepLeavesBothCornersDark() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focusStatus: (working("com.apple.sleep.sleep-mode")),
        vpnPresence: machine(personalTunnel),
        clocks: [lampClock],
        tiles: VPNTileMigration.tiles(on: lampClock.id),
        sessions: [lampClock.id: LampSession(lamps: clock)]
    )

    subject.refreshLamps()

    #expect(await waitUntil { clock.written.count == 2 })
    #expect(clock.written.allSatisfy { $0.signal == .off })
}

@Test @MainActor func quittingPutsTheCornersOut() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focusStatus: (working("com.apple.focus.work")),
        vpnPresence: machine(personalTunnel),
        clocks: [lampClock],
        tiles: VPNTileMigration.tiles(on: lampClock.id),
        sessions: [lampClock.id: LampSession(lamps: clock)]
    )
    subject.refreshLamps()
    #expect(await waitUntil { clock.written.count == 2 })

    await subject.teardown()

    #expect(clock.written.count == 4)
    #expect(clock.written.suffix(2).allSatisfy { $0.signal == .off })
    #expect(Set(clock.written.suffix(2).map(\.slot)) == [.topRight, .bottomRight])
}

// A Focus switch hands a shared lamp from one tile to the other in one write:
// the old colour, then the new, and never dark in between.
@Test @MainActor func aSharedLampIsHandedOverInOneWrite() async {
    let lamps = RecordingLamps()
    let status = StubFocusStatus(access: .authorized, activeMode: .mode("com.apple.focus.work"))
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    let work = VPNTileMigration.tiles(on: clock.id)[0]  // Pritunl, top, Work only
    var personal = VPNTileMigration.tiles(on: clock.id)[1]  // Amnezia, moved onto the top lamp
    personal.config = .vpn(VPNTileConfig(vpn: "amnezia", slot: .topRight, upColour: "#A855F7", whenDown: .off))
    personal.policy.focus = FocusRule(silencedIn: [.noFocus, .work, .doNotDisturb, .sleep], whenUnknown: .hold)
    let subject = testModel(
        focusStatus: status,
        vpnPresence: VPNPresence(processes: FixedProcessList(paths: [
            "/Applications/Pritunl.app/Contents/Resources/pritunl-openvpn",
            "/Applications/AmneziaVPN.app/Contents/MacOS/wireguard-go",
        ])),
        now: { atHour(12) },
        clocks: [clock],
        tiles: [work, personal],
        sessions: [clock.id: LampSession(lamps: lamps)]
    )
    subject.refreshLamps()
    #expect(await waitUntil { lamps.written.count == 1 })

    status.nowIn(.mode("com.apple.focus.personal"))
    subject.refreshLamps()

    #expect(await waitUntil { lamps.written.count == 2 })
    #expect(lamps.written.map(\.signal) == [.steady("#90EE90"), .steady("#A855F7")])
}

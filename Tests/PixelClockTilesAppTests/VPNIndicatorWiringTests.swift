import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// The policy and the display are each proven on their own. This is the seam
// between them and the app — the wiring that a green suite has been silent
// about before on this project, when a progress bar was added to the output
// type, tested at both ends, and never copied across the one line in between.

private func machine(_ paths: String...) -> VPNPresence {
    VPNPresence(processes: FixedProcessList(paths: paths))
}

private let workTunnel = "/Applications/Pritunl.app/Contents/Resources/pritunl-openvpn"
private let personalTunnel = "/Applications/AmneziaVPN.app/Contents/MacOS/wireguard-go"

private func working(_ mode: String) -> StubFocusStatus {
    StubFocusStatus(access: .authorized, activeMode: .mode(mode))
}

@Test @MainActor func workWithoutItsTunnelReachesTheClockAsABlinkingCorner() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focus: focusGate(working(VPNIndicatorPolicy.workFocus)),
        vpnLamps: VPNLampDisplay(clock: clock),
        // The personal tunnel is up and the work one is not, which is also the
        // case that catches a policy wired to the wrong boolean.
        vpnPresence: machine(personalTunnel)
    )

    subject.refreshVPNIndicators()

    #expect(await waitUntil { clock.written.count == 2 })
    #expect(clock.written.contains {
        $0.slot == .topRight
            && $0.signal == .blinking(
                VPNIndicatorPolicy.tunnelMissing,
                everyMilliseconds: VPNIndicatorPolicy.blinkMilliseconds
            )
    })
    #expect(clock.written.contains {
        $0.slot == .bottomRight && $0.signal == .steady(VPNIndicatorPolicy.privateTunnel)
    })
}

@Test @MainActor func bothTunnelsUnderWorkLightBothCornersSteadily() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focus: focusGate(working(VPNIndicatorPolicy.workFocus)),
        vpnLamps: VPNLampDisplay(clock: clock),
        vpnPresence: machine(workTunnel, personalTunnel)
    )

    subject.refreshVPNIndicators()

    #expect(await waitUntil { clock.written.count == 2 })
    #expect(clock.written.allSatisfy {
        if case .steady = $0.signal { return true } else { return false }
    })
}

// Sleep is not one of the two named Focuses, so nothing is claimed — including
// the alarm. A blinking red corner beside a bed is the failure this rules out.
@Test @MainActor func sleepLeavesBothCornersDark() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focus: focusGate(working("com.apple.sleep.sleep-mode")),
        vpnLamps: VPNLampDisplay(clock: clock),
        vpnPresence: machine(personalTunnel)
    )

    subject.refreshVPNIndicators()

    #expect(await waitUntil { clock.written.count == 2 })
    #expect(clock.written.allSatisfy { $0.signal == .off })
}

@Test @MainActor func quittingPutsTheCornersOut() async {
    let clock = RecordingLamps()
    let subject = testModel(
        focus: focusGate(working(VPNIndicatorPolicy.workFocus)),
        vpnLamps: VPNLampDisplay(clock: clock),
        vpnPresence: machine(personalTunnel)
    )
    subject.refreshVPNIndicators()
    #expect(await waitUntil { clock.written.count == 2 })

    await subject.teardown()

    #expect(clock.written.count == 4)
    #expect(clock.written.suffix(2).allSatisfy { $0.signal == .off })
    #expect(Set(clock.written.suffix(2).map(\.slot)) == [.topRight, .bottomRight])
}

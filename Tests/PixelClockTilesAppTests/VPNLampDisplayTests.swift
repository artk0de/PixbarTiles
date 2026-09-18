import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

private let lit = VPNLamps(
    topRight: .steady(VPNIndicatorPolicy.tunnelUp),
    bottomRight: .steady(VPNIndicatorPolicy.privateTunnel)
)

// Nothing is assumed about what the lamps were showing before this app started.
// The clock keeps indicator state across a reconnect and across this process
// going away, so it may well be holding something a previous run left — which
// is why the first showing writes both corners rather than only the ones it
// thinks have changed.
@Test func theFirstShowingWritesBothCorners() async throws {
    let clock = RecordingLamps()
    let display = VPNLampDisplay(clock: clock)

    await display.show(lit)

    #expect(clock.written.count == 2)
    #expect(clock.written.contains { $0.slot == .topRight && $0.signal == lit.topRight })
    #expect(clock.written.contains { $0.slot == .bottomRight && $0.signal == lit.bottomRight })
}

// The triggers are deliberately noisy — a network path change fires on any WiFi
// hiccup, not only on a tunnel — so the same answer arriving repeatedly has to
// cost nothing. Without this, a flapping access point would be a POST to the
// clock every time it flapped.
@Test func showingTheSameThingAgainWritesNothing() async throws {
    let clock = RecordingLamps()
    let display = VPNLampDisplay(clock: clock)

    for _ in 0..<3 { await display.show(lit) }

    #expect(clock.written.count == 2)
}

@Test func onlyTheCornerThatMovedIsWritten() async throws {
    let clock = RecordingLamps()
    let display = VPNLampDisplay(clock: clock)
    await display.show(lit)

    var dropped = lit
    dropped.topRight = .blinking(
        VPNIndicatorPolicy.tunnelMissing, everyMilliseconds: VPNIndicatorPolicy.blinkMilliseconds
    )
    await display.show(dropped)

    #expect(clock.written.count == 3)
    #expect(clock.written.last?.slot == .topRight)
    #expect(clock.written.last?.signal == dropped.topRight)
}

// A write that did not land is not a lamp that is showing. Remembering it
// anyway is the bug this exists to prevent: the clock comes back, the answer
// has not changed, the diff says there is nothing to do, and the corner sits
// wrong until the VPN itself next moves — which on a quiet afternoon is never.
@Test func aWriteThatFailedIsNotRememberedAsShown() async throws {
    let clock = RecordingLamps()
    let display = VPNLampDisplay(clock: clock)
    clock.refuse([.topRight, .bottomRight])

    await display.show(lit)
    #expect(clock.written.isEmpty)

    clock.refuse([])
    await display.show(lit)

    #expect(clock.written.count == 2, "the retry did not reach the clock")
}

// Half a delivery is the failure worth naming, because it is the one that can
// leave the two corners disagreeing about how old they are: what landed must be
// remembered, what did not must not.
@Test func aPartialDeliveryRemembersOnlyWhatLanded() async throws {
    let clock = RecordingLamps()
    let display = VPNLampDisplay(clock: clock)
    clock.refuse([.bottomRight])

    await display.show(lit)
    await display.show(lit)

    #expect(clock.written.filter { $0.slot == .topRight }.count == 1, "the top was written twice")
    #expect(clock.written.filter { $0.slot == .bottomRight }.isEmpty)
}

// Quitting puts both corners out, whatever they were showing.
//
// Indicators live on the clock and outlive the app that set them, so without
// this a quit while the work tunnel was down leaves a red corner blinking on
// the desk with nothing left running that could ever stop it.
@Test func clearingPutsBothCornersOut() async throws {
    let clock = RecordingLamps()
    let display = VPNLampDisplay(clock: clock)
    await display.show(lit)

    await display.clear()

    #expect(clock.written.suffix(2).allSatisfy { $0.signal == .off })
    #expect(Set(clock.written.suffix(2).map(\.slot)) == [.topRight, .bottomRight])
}

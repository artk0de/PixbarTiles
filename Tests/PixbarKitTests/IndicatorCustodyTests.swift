import Foundation
import Testing
@testable import PixbarKit

// The lamps are custody like the overlay and the apps in the loop: what
// matters is what LANDED on the clock. The app's VPN tests pin the same rules
// through the two corners; these pin them on the custody alone, which is what
// VPN tiles will stand on once the app's display is gone.

/// Records what reached the lamps, and can refuse like an unplugged clock.
private final class LampLog: IndicatorLighting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(slot: IndicatorSlot, signal: IndicatorSignal)] = []
    private var refused: Set<IndicatorSlot> = []

    var written: [(slot: IndicatorSlot, signal: IndicatorSignal)] { lock.withLock { recorded } }

    func refuse(_ slots: Set<IndicatorSlot>) { lock.withLock { refused = slots } }

    func setIndicator(_ slot: IndicatorSlot, to signal: IndicatorSignal) async throws {
        try lock.withLock {
            if refused.contains(slot) { throw AwtrixError.invalidHost("nowhere") }
            recorded.append((slot, signal))
        }
    }
}

@Test func aLampIsWrittenTheFirstTimeItIsShown() async {
    let log = LampLog()
    let custody = IndicatorCustody(lamps: log)

    await custody.show(.steady("#00F0FF"), on: .middleRight)

    #expect(log.written.count == 1)
    #expect(log.written.first?.slot == .middleRight)
    #expect(log.written.first?.signal == .steady("#00F0FF"))
}

@Test func showingWhatALampAlreadyShowsWritesNothing() async {
    let log = LampLog()
    let custody = IndicatorCustody(lamps: log)

    await custody.show(.steady("#00F0FF"), on: .middleRight)
    await custody.show(.steady("#00F0FF"), on: .middleRight)
    #expect(log.written.count == 1)

    await custody.show(.off, on: .middleRight)
    #expect(log.written.count == 2)
}

@Test func aWriteTheClockRefusedIsWrittenAgainNextTime() async {
    let log = LampLog()
    let custody = IndicatorCustody(lamps: log)
    log.refuse([.topRight])

    await custody.show(.steady("#A3FF12"), on: .topRight)
    #expect(log.written.isEmpty)

    log.refuse([])
    await custody.show(.steady("#A3FF12"), on: .topRight)
    #expect(log.written.count == 1)
}

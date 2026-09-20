import AppKit
import PixelClockKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The status block is the panel's status section lifted out to serve whichever
// clock is selected. The lines inside it are already tested where they live
// (`DeviceStatusLine`, `DiscoveryStatusLine`, `BatteryLine`); what needs
// proving at the NEW seam is the wiring — a reading draws its percentage, and
// no reading draws no cell at all, which is the measured TC002 rule the block
// has to carry through the split.

@MainActor
private func drawn(battery: BatteryReading?, discovery: DiscoveryState?) -> Data? {
    let host = NSHostingView(rootView: ClockStatusBlock(
        state: online, address: "10.0.0.5", battery: battery, discovery: discovery
    ))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private let online: DeviceState = .online(try! JSONDecoder().decode(
    DeviceStats.self, from: onlineStats
))

private func reading(_ percent: Int) -> BatteryReading {
    BatteryReading(percent: percent, shownPercent: percent,
                   direction: .discharging, timeRemaining: nil)
}

@MainActor @Suite struct ClockStatusBlockTests {
    // Three pairwise drawings, not one comparison: reading != nil proves a
    // cell exists when a reading is handed in, and 77 != 55 proves the cell
    // shows the reading's OWN figure rather than any battery-shaped drawing.
    @Test func aReadingDrawsItsPercentageAndNoReadingDrawsNoCell() {
        let withReading = drawn(battery: reading(77), discovery: nil)
        #expect(withReading != nil)
        #expect(withReading != drawn(battery: nil, discovery: nil))
        #expect(withReading != drawn(battery: reading(55), discovery: nil))
    }

    // The discovery row follows the same rule the panel already holds: nil (or
    // anything that renders nothing) leaves the row off, a state with a
    // sentence draws it.
    @Test func aDiscoveryStateWithSomethingToSayIsDrawn() {
        let quiet = drawn(battery: nil, discovery: nil)
        #expect(quiet != nil)
        #expect(quiet != drawn(battery: nil, discovery: .searching))
        // `.idle` says nothing, exactly like no state at all.
        #expect(quiet == drawn(battery: nil, discovery: .idle))
    }

    // The status half answers for connectivity too — the block is the whole
    // per-clock status, and Connected against Disconnected is two drawings.
    @Test func connectedAndDisconnectedAreTwoDrawings() {
        let connected = drawn(battery: nil, discovery: nil)
        let host = NSHostingView(rootView: ClockStatusBlock(
            state: .offline("timed out"), address: "10.0.0.5",
            battery: nil, discovery: nil
        ))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        host.layoutSubtreeIfNeeded()
        guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            Issue.record("could not render")
            return
        }
        host.cacheDisplay(in: host.bounds, to: target)
        #expect(connected != target.representation(using: .png, properties: [:]))
    }
}

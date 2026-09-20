import AppKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The Clocks section's facts on the surface: every entry says what it is and
// how it is, removal says what custody will do, and a fresh install is
// offered the two ways in and nothing else. The dual-probe and the UDP
// discovery behind these rows are Task 10's to wire.

@MainActor
private func drawn(_ view: some View, height: CGFloat = 300) -> Data? {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: 320, height: height)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private func entry(
    name: String = "Kitchen", model: String = "TC002",
    address: String = "192.168.1.72", status: String = "Connected"
) -> ClockListEntry {
    ClockListEntry(id: UUID(), name: name, model: model,
                   address: address, status: status)
}

@Suite struct ClocksSettingsValueTests {
    // Removal says what custody will do, because it is irreversible from this
    // surface: every tile on the clock goes through its session's teardown.
    @Test func theRemovalQuestionNamesTheClockAndSaysWhatCustodyDoes() {
        #expect(ClocksSettings.removalQuestion(for: "Kitchen")
            == "Remove Kitchen? Every tile on it goes with it.")
    }
}

@MainActor @Suite struct ClocksSettingsSurfaceTests {
    private func section(
        entries: [ClockListEntry] = [entry()],
        discovered: [DiscoveredClock] = [],
        confirming: Bool = false
    ) -> ClocksSettings {
        ClocksSettings(
            entries: entries, discovered: discovered, confirming: confirming,
            onRename: { _, _ in }, onRemove: { _ in },
            onAddDiscovered: { _ in }, onAddByAddress: { _ in }
        )
    }

    // Each of the four answers is its own drawing: a section that dropped the
    // model, the address or the status would fail one comparison each.
    @Test func anEntryDrawsItsNameItsModelItsAddressAndItsStatus() {
        let base = drawn(section())
        #expect(base != nil)
        #expect(base != drawn(section(entries: [entry(name: "Desk")])))
        #expect(base != drawn(section(entries: [entry(model: "TC001")])))
        #expect(base != drawn(section(entries: [entry(address: "10.0.0.5")])))
        #expect(base != drawn(section(entries: [entry(status: "Disconnected")])))
    }

    // The confirmation replaces the row: with the same clock NAME the
    // drawings are EQUAL however the row's own answers differ — model,
    // address and status are gone, not pushed aside. And the question names
    // THE clock, so another name draws another question.
    @Test func removingConfirmsInPlaceAndNamesTheClock() throws {
        let confirming = drawn(section(confirming: true))
        #expect(confirming != nil)
        #expect(confirming != drawn(section()))
        #expect(confirming == drawn(
            section(entries: [entry(model: "TC001", address: "10.0.0.5",
                                   status: "Disconnected")], confirming: true)
        ))
        #expect(confirming != drawn(
            section(entries: [entry(name: "Attic")], confirming: true)
        ))
    }

    // An empty list is still a usable section: add-from-discovery and
    // add-by-address, and nothing else.
    @Test func anEmptyListOffersTheTwoWaysIn() {
        let empty = drawn(section(entries: [], discovered: []))
        #expect(empty != nil)
        // A discovered clock is offered — the row exists to be added from.
        #expect(empty != drawn(section(entries: [], discovered: [
            DiscoveredClock(name: "Attic", model: "TC002", address: "10.0.0.9"),
        ])))
        // And a configured clock's row is what the empty state lacks.
        #expect(empty != drawn(section(entries: [entry()], discovered: [])))
    }
}

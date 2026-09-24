import AppKit
import PixbarKit
import SwiftUI
import Testing
@testable import PixbarTilesApp

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
    name: String = "Kitchen", device: ClockModel = .ulanziTC002,
    address: String = "192.168.1.72", status: String = "Connected",
    dot: PanelModel.ClockDot = .green
) -> ClockListEntry {
    ClockListEntry(id: UUID(), name: name, device: device,
                   address: address, status: status, dot: dot)
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
        confirming: Bool = false,
        outcome: String? = nil
    ) -> ClocksSettings {
        ClocksSettings(
            entries: entries, discovered: discovered, confirming: confirming,
            outcome: outcome,
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
        #expect(base != drawn(section(entries: [entry(device: .awtrix3)])))
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
            section(entries: [entry(device: .awtrix3, address: "10.0.0.5",
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

@MainActor @Suite struct ClockAddOutcomeTests {
    private func section(outcome: String?) -> ClocksSettings {
        ClocksSettings(
            entries: [entry()], discovered: [],
            outcome: outcome,
            onRename: { _, _ in }, onRemove: { _ in },
            onAddDiscovered: { _ in }, onAddByAddress: { _ in }
        )
    }

    // The wording lives in one plain type, because two add paths must not
    // grow two vocabularies: an addition is said with the clock's own name,
    // and a refusal is said in its own words, verbatim.
    @Test func theOutcomeLineSaysWhatWasAddedAndRefusalsVerbatim() {
        #expect(ClockAddOutcomeLine.title(for: .added, added: "Kitchen") == "Added Kitchen.")
        #expect(
            ClockAddOutcomeLine.title(
                for: .refused("already configured at 10.0.0.5"), added: "Kitchen"
            ) == "already configured at 10.0.0.5"
        )
    }

    // The section answers the attempt: a line under it, and nothing when the
    // next attempt clears it. The user's twice-added TC002 is the case — the
    // store stayed empty both times and nothing ever said why.
    @Test func theSectionSaysTheOutcomeUntilTheNextAttemptClearsIt() {
        #expect(drawn(section(outcome: "already configured at 192.168.1.72")) != nil)
        #expect(
            drawn(section(outcome: "already configured at 192.168.1.72"))
                != drawn(section(outcome: nil))
        )
        #expect(
            drawn(section(outcome: "Added Kitchen."))
                != drawn(section(outcome: "already configured at 192.168.1.72"))
        )
    }
}

// The settings list and the panel are two views of the same two clocks, and
// they used to describe them in two vocabularies: the panel draws the device
// and reads its dot, the list wrote "TC002 · … · Connected" in grey. The row
// carries the same two facts now, so one surface cannot be read against the
// other.

// The vendor calls the device the TC-002 Pixbar, and every surface that names
// a model to a person says the vendor's name. The bare "TC002" that used to be
// here is what the clock puts in its own UDP announcement — that string is the
// device talking on the wire, not the app talking to a reader, and it stays.
@Suite struct ClockModelNameTests {
    @Test func theTC002IsNamedTheWayItsVendorNamesIt() {
        #expect(ClockModel.ulanziTC002.spokenName == "TC-002 Pixbar")
        #expect(ClockModel.awtrix3.spokenName == "AWTRIX 3")
    }
}

@MainActor @Suite struct ClockEntryProjectionTests {
    @Test func anEntryCarriesTheDeviceItIsAndTheDotItHasEarned() throws {
        let model = testModel(clocks: [
            ClockRecord(name: "Desk", model: .ulanziTC002, address: "192.168.1.72")
        ])

        let entry = try #require(SettingsModel(model: model).clockEntries.first)
        let record = try #require(model.clocks.first)

        #expect(entry.name == "Desk")
        #expect(entry.device == .ulanziTC002)
        // The record's own address, whatever a relocation has since made it —
        // the projection copies, it does not decide.
        #expect(entry.address == record.address)
        // Nothing has answered and nothing has been pushed, which is the dot's
        // middle answer — not a clock that is down.
        #expect(entry.dot == .yellow)
    }

    @Test func eachClockIsProjectedInTheStoredOrder() {
        let model = testModel(clocks: [
            ClockRecord(name: "Desk", model: .ulanziTC002, address: "192.168.1.72"),
            ClockRecord(name: "Shelf", model: .awtrix3, address: "10.0.0.5"),
        ])

        let entries = SettingsModel(model: model).clockEntries

        #expect(entries.map(\.name) == ["Desk", "Shelf"])
        #expect(entries.map(\.device) == [.ulanziTC002, .awtrix3])
    }
}

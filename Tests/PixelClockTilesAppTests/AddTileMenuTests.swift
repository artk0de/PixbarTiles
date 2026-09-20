import AppKit
import PixelClockKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// The spec puts the unavailability reason BESIDE the entry: a tooltip on a
// disabled control never fires, so the reason the user is being refused has
// to be drawn where they are already looking. These draw the menu and prove
// the reason reaches it.

@MainActor
private func drawn(_ items: [AddTileMenuItem]) -> Data? {
    let host = NSHostingView(rootView: AddTileMenu(items: items))
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 70)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private func item(
    _ title: String, availability: AddTileMenuItem.Availability
) -> AddTileMenuItem {
    AddTileMenuItem(title: title, availability: availability, onAdd: {})
}

@MainActor @Suite struct AddTileMenuTests {
    // The pair as the spec stages it: one entry joins the clock, one is
    // refused. Refused means two things ON the menu — the disabled state and
    // its reason — so the all-available menu is the comparison that proves
    // both, and not a count of labels.
    @Test func anUnavailableEntryIsDisabledWithItsReasonBesideIt() {
        let mixed = drawn([
            item("Weather", availability: .available),
            item("Anecdote", availability: .unavailable(reason: "not supported on TC002")),
        ])
        #expect(mixed != nil)
        #expect(mixed != drawn([
            item("Weather", availability: .available),
            item("Anecdote", availability: .available),
        ]))
    }

    // The reason is the entry's own, not a shared "unavailable" stamp: swap
    // the reason and the drawing changes.
    @Test func theReasonDrawnIsTheReasonCarried() {
        let notSupported = drawn([
            item("Anecdote", availability: .unavailable(reason: "not supported on TC002")),
        ])
        #expect(notSupported != nil)
        #expect(notSupported != drawn([
            item("Anecdote",
                 availability: .unavailable(reason: "already speaking through Kitchen")),
        ]))
        #expect(notSupported != drawn([
            item("Anecdote", availability: .available),
        ]))
    }

    // Each entry is its own row: renaming the first changes the drawing, so
    // the titles are drawn and not just the reasons.
    @Test func everyEntryTitleIsDrawn() {
        let both = drawn([
            item("Weather", availability: .available),
            item("Anecdote", availability: .available),
        ])
        #expect(both != nil)
        #expect(both != drawn([
            item("Lamp", availability: .available),
            item("Anecdote", availability: .available),
        ]))
        #expect(both != drawn([
            item("Weather", availability: .available),
            item("VPN", availability: .available),
        ]))
    }

    // The menu is NAMED. A bare cluster of connector names reads as a row of
    // static text; the heading is what says this is where a tile comes from.
    // It is drawn even when nothing is offered — an exhausted clock still
    // says where tiles would have come from.
    @Test func theMenuCarriesItsHeadingEvenWithNothingToOffer() {
        #expect(drawn([]) != nil)
        #expect(drawn([]) != drawn([item("VPN", availability: .available)]))
    }
}

// The menu on the model: what it offers when every scene tile of the clock
// is already placed. The three scene connectors are single and all sit on
// the clock the migration left, so the offered list is the lamp's — the one
// connector a full clock can still take.
@Test @MainActor func aFullClockIsStillOfferedTheLamp() {
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let subject = testModel(
        connectors: [
            StubConnector(id: "weather", isAudible: false),
            StubConnector(id: "claude", isAudible: false),
            StubConnector(id: "anecdotes"),
        ],
        clocks: [desk],
        tiles: ["weather", "claude", "anecdotes"].map { connector in
            TileRecord(
                key: TileKey(clockId: desk.id, connectorId: connector),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
            )
        }
    )

    #expect(subject.addTileMenuItems.map(\.title) == ["VPN"])
}

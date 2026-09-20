import AppKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// What the switcher reaches the screen with. The panel is a small window and
// the switcher decides whether the clock names are on it at all, so the tests
// draw pixels — the model-level facts (`clocks.count < 2` hides the view) are
// worth nothing if the body forgets to return them.
//
// No window and no run loop: `cacheDisplay` renders the layer tree
// synchronously, the same technique `PanelRenderingTests` uses.

@MainActor
private func drawn(clocks: [ClockSwitcher.Entry], selection: UUID) -> Data? {
    let host = NSHostingView(
        rootView: ClockSwitcher(clocks: clocks, selection: .constant(selection))
    )
    host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

private let kitchen = ClockSwitcher.Entry(id: UUID(), name: "Kitchen", model: "TC001")
private let desk = ClockSwitcher.Entry(id: UUID(), name: "Desk", model: "TC002")

@MainActor @Suite struct ClockSwitcherTests {
    // "Every name" is proven per name, not as a count: rendering the pair
    // against a pair with ONE name swapped pins each segment's own text — a
    // switcher that drew only the first name would fail the Desk comparison.
    @Test func atTwoClocksEveryNameIsDrawn() {
        let both = drawn(clocks: [kitchen, desk], selection: kitchen.id)
        #expect(both != nil)
        #expect(both != drawn(clocks: [ClockSwitcher.Entry(id: kitchen.id, name: "Annex", model: "TC001"),
                                         desk], selection: kitchen.id))
        #expect(both != drawn(clocks: [kitchen,
                                         ClockSwitcher.Entry(id: desk.id, name: "Attic", model: "TC002")],
                              selection: kitchen.id))
    }

    // One clock is hidden, and hidden means EMPTY — the same pixels as no
    // switcher at all, not a placeholder.
    @Test func withOneClockTheViewIsEmpty() {
        let one = drawn(clocks: [kitchen], selection: kitchen.id)
        let none = drawn(clocks: [], selection: kitchen.id)
        #expect(one != nil)
        #expect(one == none)
    }

    // The binding is read: which clock is selected changes what is drawn.
    @Test func theSelectionIsDrawnNotOnlyHeld() {
        let kitchenSelected = drawn(clocks: [kitchen, desk], selection: kitchen.id)
        let deskSelected = drawn(clocks: [kitchen, desk], selection: desk.id)
        #expect(kitchenSelected != deskSelected)
    }

    // The binding is written: choosing the Kitchen segment puts Kitchen's id
    // into the binding. This needs the picker's real segment, so the test
    // walks the hosted view for the AppKit control SwiftUI backs it with.
    @Test func choosingTheKitchenSegmentWritesKitchensId() throws {
        var chosen = kitchen.id
        let binding = Binding(get: { chosen }, set: { chosen = $0 })
        let host = NSHostingView(rootView: ClockSwitcher(clocks: [kitchen, desk], selection: binding))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        host.layoutSubtreeIfNeeded()

        let segmented = try #require(segmentedIn(host), "the picker is not AppKit-backed here")
        segmented.setSelected(true, forSegment: 1) // Desk — anything but the current selection
        // The binding moves when the control reports the change, not when the
        // segment is visually marked: `selectionChanged:` on SwiftUI's
        // coordinator is what carries the new id into the binding.
        segmented.sendAction(segmented.action, to: segmented.target)

        #expect(chosen == desk.id)
    }

    @MainActor
    private func segmentedIn(_ root: NSView) -> NSSegmentedControl? {
        if let segmented = root as? NSSegmentedControl { return segmented }
        for child in root.subviews where segmentedIn(child) != nil {
            return segmentedIn(child)
        }
        return nil
    }
}

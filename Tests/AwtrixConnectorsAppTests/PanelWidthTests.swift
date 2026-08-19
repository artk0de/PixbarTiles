import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AwtrixConnectorsApp

// What a person does with this feature — grab a corner and pull — needs a
// window, an active app and a pointer, and none of the three exists inside
// `swift test`. What is left is everything the drag hands off to: the clamp that
// keeps the panel recoverable, the read that survives a relaunch, and the one
// wire that joins them — that the number in the defaults is the number the panel
// is laid out at. `docs/HANDOFF.md` carries the rest, with the steps.

// MARK: - The stored width

// The width nobody has ever set is the width the surfaces were drawn at, and
// this is the launch that has to look untouched.
@Test func aPanelNobodyHasDraggedIsTheWidthTheSurfacesWereLaidOutAt() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(PanelWidth.stored(in: defaults).points == PanelWidth.designed)
}

// The whole of what was asked for: pull it wider, and find it wider. A separate
// `UserDefaults` for the same suite name is what a relaunch actually does — the
// same on-disk domain read by an instance that never saw the write.
@Test func aWidthThatWasSavedIsTheWidthTheNextLaunchOpensAt() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    PanelWidth(480).save(to: defaults)

    let relaunched = try #require(UserDefaults(suiteName: suite))
    #expect(PanelWidth.stored(in: relaunched).points == 480)
}

// The floor, and it is the rule the whole type exists for. A menu bar panel IS
// its window: dragged to nothing there is no title bar to grab, no edge to find
// and no handle left, so the app opens to a sliver every launch after and the
// only way back is `defaults delete`. The clamp is in the initialiser rather
// than at the drag, so a number that arrived some other way meets it too.
@Test func aWidthUnderTheFloorIsRaisedToIt() {
    #expect(PanelWidth(40).points == PanelWidth.smallest)
    #expect(PanelWidth(0).points == PanelWidth.smallest)
    #expect(PanelWidth(-500).points == PanelWidth.smallest)
}

// The other end of the same rule. The panel hangs off its menu bar item and
// grows across the screen, so a width past the display takes the Quit button
// with it — off the edge, on a surface that cannot be scrolled.
@Test func aWidthOverTheCeilingIsLoweredToIt() {
    #expect(PanelWidth(5_000).points == PanelWidth.largest)
    #expect(PanelWidth(PanelWidth.largest + 1).points == PanelWidth.largest)
}

// Not reachable from the handle, and reachable from a damaged plist — which is
// the point. A clamp cannot answer this one: `min(max(.nan, a), b)` is `.nan`,
// and a panel laid out at `.frame(width: .nan)` does not lay out at all. It
// would then open to nothing with the bad number still stored, so the next
// launch opens to nothing as well.
@Test func aWidthThatIsNotANumberFallsBackToTheDesignWidth() {
    #expect(PanelWidth(.nan).points == PanelWidth.designed)
    #expect(PanelWidth(.infinity).points == PanelWidth.designed)
    #expect(PanelWidth(-.infinity).points == PanelWidth.designed)
}

// `defaults write dev.artk0re.awtrix-connectors panelWidth -int 500` is how
// somebody recovers a panel they cannot reach, and it is the documented way out
// in `docs/HANDOFF.md`. Read through a cast that only accepts a double, that
// entry would be seen as a key with nothing in it and answered with 320 — the
// escape hatch silently doing nothing.
@Test func aWidthTypedByHandAsAWholeNumberIsRead() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(500, forKey: PanelWidth.storageKey)

    #expect(PanelWidth.stored(in: defaults).points == 500)
}

// A stored width is clamped on the way OUT as well as on the way in. The two are
// not the same claim: a value can reach the defaults without passing through
// `save` at all — a hand-typed one, or one left by a build whose floor was
// somewhere else — and it is the read that has to survive it.
@Test func aWidthAlreadyInTheDefaultsIsClampedWhenItIsRead() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(8.0, forKey: PanelWidth.storageKey)
    #expect(PanelWidth.stored(in: defaults).points == PanelWidth.smallest)

    defaults.set(9_000.0, forKey: PanelWidth.storageKey)
    #expect(PanelWidth.stored(in: defaults).points == PanelWidth.largest)
}

// MARK: - The width the panel is drawn at

/// The panel, laid out, with a browse that reaches no network.
@MainActor
private func hostedPanel(readingWidthFrom defaults: UserDefaults) -> NSHostingView<MenuPanel> {
    let model = testModel()
    let host = NSHostingView(
        rootView: MenuPanel(
            model: model,
            monitor: model.monitor,
            discovery: inertDiscovery(),
            defaults: defaults
        )
    )
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    return host
}

// The wire between the two halves, and the half neither the clamp tests nor a
// person at the hardware can see. Everything above proves a number goes in and
// comes back; this is the only thing that says the panel is laid out AT it. The
// literal it replaced was 320, and every one of those tests passes just as well
// against a panel that still has it.
@Test @MainActor func thePanelIsLaidOutAtTheStoredWidth() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(480.0, forKey: PanelWidth.storageKey)

    #expect(hostedPanel(readingWidthFrom: defaults).fittingSize.width == 480)
}

// Two widths rather than one, because one proves less than it looks: a panel
// hard-coded to 480 would pass the test above. What cannot be faked by a
// constant is two different stored numbers giving two different panels.
@Test @MainActor func aDifferentStoredWidthIsADifferentPanel() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(600.0, forKey: PanelWidth.storageKey)
    let wide = hostedPanel(readingWidthFrom: defaults).fittingSize.width
    defaults.set(360.0, forKey: PanelWidth.storageKey)
    let narrow = hostedPanel(readingWidthFrom: defaults).fittingSize.width

    #expect(wide == 600)
    #expect(narrow == 360)
}

// The floor where it matters, which is on the screen rather than in the type. A
// clamp that is asserted only against `PanelWidth` says nothing about a panel
// that read the defaults some other way round — and the way a panel becomes
// unrecoverable is by being DRAWN too small, not by holding a small number.
@Test @MainActor func aStoredWidthUnderTheFloorStillDrawsAPanelYouCanReach() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    defaults.set(12.0, forKey: PanelWidth.storageKey)

    #expect(hostedPanel(readingWidthFrom: defaults).fittingSize.width == PanelWidth.smallest)
}

// An app nobody has dragged is drawn at exactly what it was drawn at before this
// existed. The feature is opt-in by gesture, and this is the launch that must
// not have moved.
@Test @MainActor func aPanelNobodyHasDraggedIsDrawnAtTheWidthItAlwaysWas() throws {
    let suite = "panel-width-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(hostedPanel(readingWidthFrom: defaults).fittingSize.width == 320)
}

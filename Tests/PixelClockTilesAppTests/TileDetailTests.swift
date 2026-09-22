import AppKit
import PixelClockKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

// Two layers, tested the two ways the suite already trusts: the editor's
// policy semantics at value level — the boxes, the hours, the slider's
// mapping through `RefreshScale` — and the surface's drawings as bitmaps,
// because a checkbox that mutates nothing and a header that never draws are
// the two failures a value test each cannot see.

// MARK: - The editor's policy semantics, at value level

@Suite struct TilePolicyEditorValueTests {
    @Test func uncheckingAFocusAddsItToSilencedIn() {
        var policy = TilePolicy(refreshSeconds: 300)
        TilePolicyEditor.set(focus: .work, checked: false, in: &policy)
        #expect(policy.focus.silencedIn == [.work])
        // And back: ticking it again lets the tile work in Work.
        TilePolicyEditor.set(focus: .work, checked: true, in: &policy)
        #expect(policy.focus.silencedIn.isEmpty)
    }

    // The boxes are the Focuses the app can NAME. `.unknown` is decided by the
    // when-unknown picker, so it is never a sixth box.
    @Test func theBoxesAreTheNamedFocusesAndNeverTheUnknownOne() {
        #expect(TilePolicyEditor.worksInBoxes
            == [MacFocus.noFocus, .work, .personal, .doNotDisturb, .sleep])
        #expect(!TilePolicyEditor.worksInBoxes.contains(.unknown))
    }

    @Test func switchingHoursKeepsTheWindow() {
        var policy = TilePolicy(
            refreshSeconds: 300,
            window: .active(HourWindow(startHour: 10, endHour: 19))
        )
        TilePolicyEditor.setHours(.quiet, in: &policy)
        #expect(policy.window == .quiet(HourWindow(startHour: 10, endHour: 19)))
        TilePolicyEditor.setHours(.always, in: &policy)
        #expect(policy.window == .always)
    }

    @Test func theSliderMapsThroughTheScaleInBothDirections() {
        for (index, step) in RefreshScale.steps.enumerated() {
            #expect(TilePolicyEditor.position(forSeconds: step) == Double(index))
            #expect(TilePolicyEditor.seconds(atPosition: Double(index)) == step)
        }
    }

    // A stored 45 s is a value the scale cannot show: the slider READS the
    // snapped step (45 sits exactly between 30 and 60, and the longer one
    // wins), and reading it writes nothing back — the stored seconds move
    // only when the slider does.
    @Test func aStoredValueTheScaleCannotShowReadsSnappedWithoutBeingWrittenBack() {
        #expect(TilePolicyEditor.position(forSeconds: 45)
            == TilePolicyEditor.position(forSeconds: 60))

        var policy = TilePolicy(refreshSeconds: 45)
        _ = TilePolicyEditor.position(forSeconds: TimeInterval(policy.refreshSeconds))
        #expect(policy.refreshSeconds == 45)

        TilePolicyEditor.set(secondsAtPosition: 1, in: &policy)
        #expect(policy.refreshSeconds == 60)
    }

    // The whole round trip: a policy carried through the box, the hours and
    // the slider lands as the policy that was asked for.
    @Test func anEditedPolicyComesOutWhole() {
        var policy = TilePolicy(refreshSeconds: 60)
        TilePolicyEditor.set(focus: .sleep, checked: false, in: &policy)
        TilePolicyEditor.setHours(.quiet, in: &policy)
        TilePolicyEditor.set(secondsAtPosition: 0, in: &policy)
        policy.focus.whenUnknown = .hold

        // Hours switched onto `.quiet` from `.always` start from the shipped
        // quiet window — the one stretch of day the app already knows.
        #expect(policy == TilePolicy(
            refreshSeconds: 30,
            focus: FocusRule(silencedIn: [.sleep], whenUnknown: .hold),
            window: .quiet(HourWindow(startHour: 23, endHour: 8))
        ))
    }
}

// MARK: - On the surface

@MainActor
private func drawn(_ view: some View, width: CGFloat = 320, height: CGFloat = 420) -> Data? {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

@MainActor
private func editor(_ policy: TilePolicy) -> some View {
    TilePolicyEditor(policy: .constant(policy))
}

@MainActor @Suite struct TilePolicyEditorSurfaceTests {
    // `theHeaderNamesTheTileAndTheClock` stood beside this one and drew
    // `TileDetail`'s header. That surface is gone — `TileSettingsWindow`
    // replaced it, and names the tile and its clock in its own headline —
    // so the claim moved with the surface rather than being held here
    // against a view nothing builds.

    // The when-unknown answer is on the surface, not only in the policy: a
    // tile that holds under an unnamed Focus draws differently from one that
    // runs. Drawn against the editor itself, which is what carries the
    // picker and is what both the old surface and the window put on screen.
    @Test func theWhenUnknownPickerIsDrawnNotOnlyHeld() {
        let runs = drawn(
            editor(TilePolicy(refreshSeconds: 300, focus: FocusRule(whenUnknown: .run)))
        )
        let holds = drawn(
            editor(TilePolicy(refreshSeconds: 300, focus: FocusRule(whenUnknown: .hold)))
        )
        #expect(runs != nil)
        #expect(runs != holds)
    }
}

// MARK: - Each connector block on its own tile

@MainActor @Suite struct TileConnectorBlockTests {
    // The location field is the weather tile's own block: the stored pair is
    // what the box opens with, and another pair draws differently.
    @Test func theWeatherBlockOpensWithTheStoredPlace() {
        let base = drawn(WeatherTileBlock(
            place: Coordinates(latitude: 55.7558, longitude: 37.6173),
            onSave: { _ in }
        ))
        #expect(base != nil)
        #expect(base != drawn(WeatherTileBlock(
            place: Coordinates(latitude: 59.3293, longitude: 18.0686),
            onSave: { _ in }
        )))
    }

    // The History button is the anecdote tile's own block, and it is drawn —
    // against an empty block of the same size, which is the comparison that
    // cannot pass on layout alone.
    @Test func theAnecdoteBlockCarriesTheHistoryButton() {
        let history = drawn(AnecdoteTileBlock(onHistory: {}))
        #expect(history != nil)
        #expect(history != drawn(AnyView(EmptyView()), width: 300, height: 60))
    }

    @Test func theVPNBlockDrawsItsPresetItsSlotAndItsDownBehaviour() {
        func vpn(
            preset: String = "Pritunl", slot: String = "Top right",
            colour: Color = VPNTilePalette.palette[0].colour,
            down: VPNTileBlock.DownBehaviour = .off
        ) -> VPNTileBlock {
            VPNTileBlock(
                presets: ["Pritunl", "Amnezia"], preset: preset,
                slots: ["Top right", "Bottom right"], slot: slot,
                colour: colour, downBehaviour: down
            )
        }
        let base = drawn(vpn())
        #expect(base != nil)
        #expect(base != drawn(vpn(preset: "Amnezia")))
        #expect(base != drawn(vpn(slot: "Bottom right")))
        #expect(base != drawn(vpn(down: .blink)))
        // And the chosen palette colour is drawn, not only held.
        #expect(base != drawn(vpn(colour: VPNTilePalette.palette[7].colour)))
    }

    // The palette is the spec's saturated eight, in code, with names —
    // checked against the table the spec pins, because a renamed or replaced
    // entry here is a different tile than the design drew.
    @Test func thePaletteIsTheSpecsSaturatedEight() {
        #expect(VPNTilePalette.palette.map(\.name) == [
            "Electric Lime", "Cyber Cyan", "Hot Magenta", "Ultraviolet",
            "Neon Mint", "Sunset Orange", "Solar Yellow", "Alarm Red",
        ])
        #expect(VPNTilePalette.palette.map(\.hex) == [
            "#A3FF12", "#00F0FF", "#FF2BD6", "#8B5CF6",
            "#3DFFB0", "#FF6B1A", "#FFE600", "#FF1744",
        ])
    }

    // The Claude block is the display selector: the stored metric is what the
    // picker opens with, and another metric draws differently.
    @Test func theClaudeBlockOpensWithTheStoredMetric() {
        func block(_ metric: ClaudeDisplayMetric) -> ClaudeTileBlock {
            ClaudeTileBlock(metric: metric, onMetric: { _ in })
        }

        let base = drawn(block(.weekly))
        #expect(base != nil)
        #expect(base != drawn(block(.daily)))
        #expect(base != drawn(block(.session)))
    }
}

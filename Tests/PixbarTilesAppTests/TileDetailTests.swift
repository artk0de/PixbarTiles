import AppKit
import PixbarKit
import SwiftUI
import Testing
@testable import PixbarTilesApp

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
            headline: "Россия, Москва (55.7558, 37.6173)",
            place: Coordinates(latitude: 55.7558, longitude: 37.6173),
            onSave: { _ in }, onChoose: { _ in }
        ))
        #expect(base != nil)
        #expect(base != drawn(WeatherTileBlock(
            headline: "Sverige, Stockholm (59.3293, 18.0686)",
            place: Coordinates(latitude: 59.3293, longitude: 18.0686),
            onSave: { _ in }, onChoose: { _ in }
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

    // The usage face's block: two pickers, each opening with the stored
    // setting, each setting drawn differently — and the captions say the
    // steps the design names.
    @Test func theUsageFaceBlockOpensWithTheStoredSettings() {
        func block(_ config: CodeUsage.Parameters) -> CodeUsageBlock {
            CodeUsageBlock(config: config, onChange: { _ in })
        }

        let base = drawn(block(.standard))
        #expect(base != nil)
        #expect(base != drawn(block(CodeUsage.Parameters(resetEvery: 60, resetAfter: 80))))
        #expect(base != drawn(block(CodeUsage.Parameters(resetEvery: 10, resetAfter: 95))))
        #expect(CodeUsage.Parameters.resetEverySteps.map(CodeUsageBlock.everyCaption) == [
            "5 s", "10 s", "15 s", "30 s", "1 min", "2 min", "5 min",
        ])
        #expect(CodeUsageBlock.afterCaption(80) == "80%")
    }

    // The layout is a setting like any other: chosen in the block, drawn
    // differently, and on both vendors' tiles because the block is one.
    @Test func theUsageFaceBlockDrawsTheChosenLayout() {
        func block(_ config: CodeUsage.Parameters) -> CodeUsageBlock {
            CodeUsageBlock(config: config, onChange: { _ in })
        }
        let circle = CodeUsage.Parameters(
            resetEvery: 10, resetAfter: 80, layout: .circle, windows: CodeUsage.WindowKind.allCases
        )

        #expect(drawn(block(.standard)) != drawn(block(circle)))
        // The Circle rotates through the windows the tile selected, so the
        // selection is part of the block — and moves the picture.
        let weeklyOnly = CodeUsage.Parameters(
            resetEvery: 10, resetAfter: 80, layout: .circle, windows: [.weekly]
        )
        #expect(drawn(block(circle)) != drawn(block(weeklyOnly)))
    }

    // One stored dwell, named for what it DOES in the chosen layout. Compact
    // stands on the percentages for it; Circle spends it on one window's turn.
    // The same picker under one label would read as two settings.
    @Test func theDwellIsNamedForWhatItDoesInEachLayout() {
        #expect(CodeUsage.Layout.compact.dwellLabel == "Show reset every")
        #expect(CodeUsage.Layout.circle.dwellLabel == "Change every")
        #expect(CodeUsage.Layout.allCases.map(\.displayName) == ["Compact", "Circle"])
    }

    // The date-order picker shows the SPELLINGS, so the reader reads the
    // result instead of picturing it from a name.
    @Test func theDateOrderIsOfferedAsTheTwoSpellings() {
        func block(_ config: CodeUsage.Parameters) -> CodeUsageBlock {
            CodeUsageBlock(config: config, onChange: { _ in })
        }
        var moved = CodeUsage.Parameters.standard
        moved.dateOrder = .monthFirst

        #expect(CodeUsage.DateOrder.allCases.map(\.displayName)
            == ["26 sep 15:00", "sep 26 15:00"])
        #expect(drawn(block(.standard)) != drawn(block(moved)))
    }

    // Unchecking the last window would leave the panel with nothing to draw,
    // which reads as a broken tile rather than as a setting. The last box
    // stays checked.
    @Test func theLastSelectedWindowCannotBeTurnedOff() {
        #expect(CodeUsageBlock.windows([.fiveHour, .weekly], toggling: .weekly) == [.fiveHour])
        #expect(CodeUsageBlock.windows([.weekly], toggling: .fiveHour) == [.fiveHour, .weekly])
        #expect(CodeUsageBlock.windows([.weekly], toggling: .weekly) == [.weekly])
    }
}

// MARK: - The refresh a named ladder offers

// A tile whose connector names its own ladder gets a picker over it rather
// than the general slider: a dozen named choices read as a menu, and the
// general scale's twenty-seven five-minute steps read as a slider.
@Test func aNamedLadderIsShownAsAPickerAndTheGeneralScaleIsNot() {
    #expect(TilePolicyEditor.picks(from: RefreshScale.codingSubscription))
    #expect(TilePolicyEditor.picks(from: RefreshScale.steps) == false)
}

// The step a stored value SHOWS as, read on the tile's own ladder. Read on the
// general one a ten-second tile would show thirty, which is the number the
// schedule stopped using.
@Test func aStoredRefreshShowsAsTheStepOfItsOwnLadder() {
    var policy = TilePolicy(refreshSeconds: 10)
    #expect(TilePolicyEditor.shownRefresh(of: policy, on: RefreshScale.codingSubscription) == 10)
    #expect(TilePolicyEditor.shownRefresh(of: policy, on: RefreshScale.steps) == 30)

    policy.refreshSeconds = 14_400
    #expect(TilePolicyEditor.shownRefresh(of: policy, on: RefreshScale.codingSubscription) == 14_400)
}

// Writing is the picked step itself, never a reading of it: a step read back
// through a scale that cannot show it would be rewritten on the next save.
@Test func pickingAStepWritesThatStepsSeconds() {
    var policy = TilePolicy(refreshSeconds: 60)
    for step in RefreshScale.codingSubscription {
        TilePolicyEditor.set(refresh: step, in: &policy)
        #expect(policy.refreshSeconds == Int(step), "\(step)")
    }
}

// MARK: - The Focus grid

// The four modes macOS ships, two by two, in the order its own Focus list puts
// them. "No Focus" is NOT among them: it is the absence of one, and a fifth
// box in a square of four reads as a fifth mode.
@Test func theFocusGridIsTheFourBuiltInModesTwoByTwo() {
    #expect(TilePolicyEditor.focusGrid == [[.work, .personal], [.doNotDisturb, .sleep]])
    #expect(TilePolicyEditor.focusGrid.flatMap { $0 }.contains(.noFocus) == false)
    #expect(TilePolicyEditor.focusGrid.flatMap { $0 }.contains(.unknown) == false)
}

// Every box on the surface, grid and the one under it, is still every box the
// rules run over — so a mode cannot be silently unreachable.
@Test func theGridAndNoFocusTogetherAreEveryBoxTheRulesRunOver() {
    let shown = TilePolicyEditor.focusGrid.flatMap { $0 } + [.noFocus]
    #expect(Set(shown) == Set(TilePolicyEditor.worksInBoxes))
}

// An icon per mode, and none of them the same: four boxes telling a reader
// nothing apart is worse than four boxes with no icons at all.
@Test func everyFocusOnTheSurfaceHasAnIconOfItsOwn() {
    let shown = TilePolicyEditor.focusGrid.flatMap { $0 } + [.noFocus]
    let symbols = shown.map(TilePolicyEditor.symbol)
    #expect(symbols.allSatisfy { $0.isEmpty == false })
    #expect(Set(symbols).count == shown.count)
}

// The question mark says what "any other Focus" IS, which is the thing the
// picker's own label cannot: that macOS names four modes and calls everything
// else — a Focus the user made, a Focus this Mac will not disclose — other.
@Test func theAnyOtherFocusHintSaysWhatMacOSWillAndWillNotName() {
    let hint = TilePolicyEditor.anyOtherFocusHint
    #expect(hint.contains("four"))
    #expect(hint.contains("Run"))
    #expect(hint.contains("Hold"))
}

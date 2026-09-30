import Foundation
import Testing
@testable import PixbarTilesApp

/// A window opened from the menu bar comes to the front even when macOS
/// refuses the polite activation.
@MainActor
@Suite struct WindowFocusActivationTests {
    @Test func aRefusedPoliteActivationFallsBackToTheForcedOne() {
        var forced = 0
        WindowFocus.activate(polite: { false }, force: { forced += 1 })
        #expect(forced == 1)
    }

    @Test func aGrantedPoliteActivationIsLeftAtThat() {
        var forced = 0
        WindowFocus.activate(polite: { true }, force: { forced += 1 })
        #expect(forced == 0)
    }
}

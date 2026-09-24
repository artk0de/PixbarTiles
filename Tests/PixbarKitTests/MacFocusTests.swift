import Foundation
import Testing
@testable import PixbarKit

// Six states and no more. The grid every tile policy is drawn over is these by
// twenty-four hours, so a seventh state would be a column nothing tests.

@Test func theStatesAreTheSixTheGridIsDrawnOver() {
    #expect(MacFocus.allCases == [.noFocus, .work, .personal, .doNotDisturb, .sleep, .unknown])
}

// Matched on the identifiers macOS ships and nobody can edit — never on the
// name, which reads "Работа" on the machine this was written on.
@Test func theFourBuiltInModesAreMatchedOnTheIdentifiersMacOSShips() {
    #expect(MacFocus(modeIdentifier: "com.apple.focus.work") == .work)
    #expect(MacFocus(modeIdentifier: "com.apple.focus.personal") == .personal)
    #expect(MacFocus(modeIdentifier: "com.apple.donotdisturb.mode.default") == .doNotDisturb)
    #expect(MacFocus(modeIdentifier: "com.apple.sleep.sleep-mode") == .sleep)
}

// Something is asserted, so it is not "nothing is on". Read as `.noFocus`, a
// Focus the user invented would run every tile that stays quiet in unnamed
// Focuses.
@Test func anIdentifierMacOSDidNotShipIsUnknownRatherThanNoFocus() {
    #expect(MacFocus(modeIdentifier: "com.apple.focus.fitness") == .unknown)
    #expect(MacFocus(modeIdentifier: "") == .unknown)
}

@Test func eachModeGivesBackTheIdentifierItIsMatchedOn() {
    let identified = MacFocus.allCases.filter { $0.modeIdentifier != nil }

    #expect(identified == [.work, .personal, .doNotDisturb, .sleep])
    for focus in identified {
        #expect(MacFocus(modeIdentifier: focus.modeIdentifier!) == focus)
    }
}

@Test func eachStateHasTheNameTheSettingsShow() {
    #expect(MacFocus.allCases.map(\.displayName) == [
        "No Focus", "Work", "Personal", "Do Not Disturb", "Sleep", "Other Focus",
    ])
}

// Tests/PixelClockKitTests/TilePolicyTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// MARK: - The Focus rule

@Test func aTileIsQuietOnlyInTheFocusesItWasToldToBe() {
    let rule = FocusRule(silencedIn: [.doNotDisturb, .sleep])

    #expect(rule.silences(.doNotDisturb))
    #expect(rule.silences(.sleep))
    #expect(rule.silences(.noFocus) == false)
    #expect(rule.silences(.work) == false)
    #expect(rule.silences(.personal) == false)
}

@Test func aFocusThatCannotBeNamedFollowsWhenUnknown() {
    #expect(FocusRule(whenUnknown: .hold).silences(.unknown))
    #expect(FocusRule(whenUnknown: .run).silences(.unknown) == false)
}

// One home for the answer. The editor shows five boxes and a menu; a sixth,
// invisible box that overruled the menu would be state nobody can see or undo.
@Test func unknownInTheSetDoesNotOverruleWhenUnknown() {
    let rule = FocusRule(silencedIn: [.unknown], whenUnknown: .run)

    #expect(rule.silences(.unknown) == false)
}

@Test func whenUnknownSaysNothingAboutTheNamedStates() {
    let rule = FocusRule(silencedIn: [], whenUnknown: .hold)

    for focus in MacFocus.allCases where focus != .unknown {
        #expect(rule.silences(focus) == false, "\(focus)")
    }
}

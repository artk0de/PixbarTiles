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

// MARK: - The hours

@Test func aTileKeptAlwaysIsNeverSilencedByTheHour() {
    #expect((0..<24).allSatisfy { TileWindow.always.silences(atHour: $0) == false })
}

@Test func quietHoursSilenceInsideTheWindow() {
    let night = TileWindow.quiet(HourWindow(startHour: 23, endHour: 8))

    #expect(night.silences(atHour: 23))
    #expect(night.silences(atHour: 3))
    #expect(night.silences(atHour: 8) == false)
    #expect(night.silences(atHour: 12) == false)
}

@Test func workingHoursSilenceOutsideTheWindow() {
    let office = TileWindow.active(HourWindow(startHour: 10, endHour: 19))

    #expect(office.silences(atHour: 9))
    #expect(office.silences(atHour: 10) == false)
    #expect(office.silences(atHour: 18) == false)
    #expect(office.silences(atHour: 19))
}

// The same hours as quiet hours and as working hours are complements, for
// every window that covers anything and every hour of the day.
@Test func quietAndActiveOverTheSameHoursAreOpposites() {
    for start in 0..<24 {
        for end in 0..<24 where start != end {
            let window = HourWindow(startHour: start, endHour: end)
            for hour in 0..<24 {
                #expect(
                    TileWindow.quiet(window).silences(atHour: hour)
                        != TileWindow.active(window).silences(atHour: hour),
                    "\(window.label) at \(hour):00"
                )
            }
        }
    }
}

@Test func anEmptyWindowSilencesNothingEitherWay() {
    let nothing = HourWindow(startHour: 6, endHour: 6)

    #expect((0..<24).allSatisfy { TileWindow.quiet(nothing).silences(atHour: $0) == false })
    #expect((0..<24).allSatisfy { TileWindow.active(nothing).silences(atHour: $0) == false })
}

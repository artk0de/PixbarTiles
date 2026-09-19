// Tests/PixelClockTilesAppTests/MacFocusResolutionTests.swift
import Foundation
import PixelClockKit
import Testing
@testable import PixelClockTilesApp

// How the Focus the Mac is in is read off macOS, keeping `FocusGate`'s rules:
// the grant first, then the database, and the boolean only when the database
// cannot be read.

private let everyMode: [ActiveFocusMode] = [
    .noFocus,
    .cannotTell,
    .mode("com.apple.focus.work"),
    .mode("com.apple.focus.personal"),
    .mode("com.apple.donotdisturb.mode.default"),
    .mode("com.apple.sleep.sleep-mode"),
    .mode("com.apple.focus.fitness"),
]

// Unauthorized, `isFocused` is false whatever is on — the answer an idle Mac
// gives — and a mode read without the grant is not evidence either. So nothing
// the centre says moves it off `.noFocus`, and every tile's hours decide alone.
@Test(arguments: [FocusAccess.notDetermined, .denied, .restricted])
func anUnauthorizedCentreIsNoFocusWhateverElseItSays(access: FocusAccess) {
    for mode in everyMode {
        for focused in [false, true] {
            #expect(
                MacFocus.resolved(access: access, activeMode: mode, isFocused: focused) == .noFocus,
                "\(mode), isFocused \(focused)"
            )
        }
    }
}

@Test func aModeReadFromTheDatabaseIsTheStateItNames() {
    let expected: [(String, MacFocus)] = [
        ("com.apple.focus.work", .work),
        ("com.apple.focus.personal", .personal),
        ("com.apple.donotdisturb.mode.default", .doNotDisturb),
        ("com.apple.sleep.sleep-mode", .sleep),
        ("com.apple.focus.fitness", .unknown),
    ]
    for (identifier, focus) in expected {
        for focused in [false, true] {
            #expect(
                MacFocus.resolved(
                    access: .authorized, activeMode: .mode(identifier), isFocused: focused
                ) == focus,
                "\(identifier), isFocused \(focused)"
            )
        }
    }
}

// The database is where the boolean's own answer comes from, so the two
// disagreeing is two reads a moment apart, not two opinions.
@Test func aDatabaseSayingNothingIsOnIsNoFocusWhateverTheBooleanSays() {
    #expect(MacFocus.resolved(access: .authorized, activeMode: .noFocus, isFocused: true) == .noFocus)
}

@Test func anUnreadableDatabaseLeavesTheBooleanToDecide() {
    #expect(
        MacFocus.resolved(access: .authorized, activeMode: .cannotTell, isFocused: false) == .noFocus
    )
    #expect(
        MacFocus.resolved(access: .authorized, activeMode: .cannotTell, isFocused: true) == .unknown
    )
}

@Test func theCentreIsReadThroughTheSameRule() {
    let status = StubFocusStatus(access: .authorized, isFocused: true, activeMode: .cannotTell)

    #expect(MacFocus(reading: status) == .unknown)

    status.nowIn(.mode("com.apple.sleep.sleep-mode"))
    #expect(MacFocus(reading: status) == .sleep)
}

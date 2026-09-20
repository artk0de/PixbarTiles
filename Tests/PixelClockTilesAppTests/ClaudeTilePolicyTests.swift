import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// Which Focus the Claude tile survives, read off what macOS actually says and
// through the tile's own policy row.
//
// Shown by default, hidden by exception. The first version of this had it the
// other way round — a list of the two Focuses the app was FOR, hiding it
// everywhere else — and that put the app off the clock during the state a Mac
// is in most of the day: no Focus at all. What was asked for is that work and
// personal time do not stop it, which is a statement about exceptions.

private func claudeRuns(_ status: StubFocusStatus) -> Bool {
    TileDefaults.claude.runs(in: MacFocus(reading: status), atHour: 12)
}

@Test func theAppKeepsWorkingThroughTheFocusesItWasAskedToSurvive() {
    for identifier in [
        "com.apple.focus.work",
        "com.apple.focus.personal-time",
        // And every other ordinary Focus, for the same reason: none of these
        // silences the room either.
        "com.apple.focus.fitness",
        "com.apple.focus.mindfulness",
        "com.apple.focus.reading",
    ] {
        let status = StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode(identifier)
        )
        #expect(claudeRuns(status), "hidden during \(identifier)")
    }
}

// The exception list, and it is the anecdotes' list rather than a second copy.
@Test func theAppIsHiddenOnlyByTheFocusesThatSilenceTheRoom() {
    for identifier in DoNotDisturbDatabase.silencing {
        let status = StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode(identifier)
        )
        #expect(!claudeRuns(status), "shown during \(identifier)")
    }

    // Stated as membership too, so that a Focus quietly added to the silencing
    // list starts hiding this app without anybody having to remember to.
    #expect(DoNotDisturbDatabase.silencing.contains("com.apple.donotdisturb.mode.default"))
    #expect(DoNotDisturbDatabase.silencing.contains("com.apple.sleep.sleep-mode"))
}

// No Focus at all is the ordinary state of a Mac, and it is the case the first
// version got wrong: it hid the app almost always, and the report that came
// back was "the app stopped appearing", not "the gate is inverted".
@Test func theAppIsShownWhenNoFocusIsOnAtAll() {
    let status = StubFocusStatus(access: .authorized, isFocused: false, activeMode: .noFocus)

    #expect(claudeRuns(status))
}

// And both ways of not knowing show it.
//
// Reading the active mode needs Full Disk Access, and an unauthorized centre
// cannot be believed about the mode either — its `isFocused` is the same false
// a machine with no Focus gives. Hiding on either would produce an app that
// never appears on a machine where everything else works, with nothing anywhere
// saying why.
@Test func theAppIsShownWheneverTheFocusCannotBeRead() {
    let noFullDiskAccess = StubFocusStatus(
        access: .authorized, isFocused: true, activeMode: .cannotTell
    )
    #expect(claudeRuns(noFullDiskAccess))

    for access: FocusAccess in [.notDetermined, .denied, .restricted] {
        let unauthorized = StubFocusStatus(
            access: access, isFocused: false, activeMode: .noFocus
        )
        #expect(claudeRuns(unauthorized), "hidden while access is \(access)")
    }
}

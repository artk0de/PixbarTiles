import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// Which Focus the Claude app belongs to, read off what macOS actually says.
//
// The list of identifiers lives in `AwtrixKit`; what is tested here is the
// translation — every answer the status can give, mapped to shown or not. The
// interesting branches are the two that are not a named mode.

@Test func theAppIsShownDuringTheTwoFocusesItBelongsTo() {
    for identifier in ["com.apple.focus.work", "com.apple.focus.personal-time"] {
        let status = StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode(identifier)
        )
        #expect(ClaudeFocusAudience.shows(status), "hidden during \(identifier)")
    }
}

@Test func theAppIsHiddenDuringEveryOtherNamedFocus() {
    for identifier in [
        "com.apple.donotdisturb.mode.default",
        "com.apple.sleep.sleep-mode",
        "com.apple.focus.fitness",
        "com.apple.focus.mindfulness",
    ] {
        let status = StubFocusStatus(
            access: .authorized, isFocused: true, activeMode: .mode(identifier)
        )
        #expect(!ClaudeFocusAudience.shows(status), "shown during \(identifier)")
    }
}

// No Focus at all is not one of the two, and it is the ordinary state of a Mac.
// Asserted on its own because it is the case that decides whether this app is
// on the clock most of the time.
@Test func theAppIsHiddenWhenNoFocusIsOnAtAll() {
    let status = StubFocusStatus(access: .authorized, isFocused: false, activeMode: .noFocus)

    #expect(!ClaudeFocusAudience.shows(status))
}

// And the two ways of not knowing both show it.
//
// Reading the active mode needs Full Disk Access, and an unauthorized centre
// cannot be believed about the mode either — its `isFocused` is the same false
// a machine with no Focus gives. Hiding on either would produce an app that
// never appears on a machine where everything else works, with nothing anywhere
// saying why. Showing costs a Claude app on the matrix during Do Not Disturb:
// visible, harmless, and it explains itself the moment somebody looks.
@Test func theAppIsShownWheneverTheFocusCannotBeRead() {
    let noFullDiskAccess = StubFocusStatus(
        access: .authorized, isFocused: true, activeMode: .cannotTell
    )
    #expect(ClaudeFocusAudience.shows(noFullDiskAccess))

    for access: FocusAccess in [.notDetermined, .denied, .restricted] {
        // The mode says "no Focus" and is not to be believed, because the
        // permission to read it was never granted. This is the branch that
        // would otherwise hide the app on every machine that has not been
        // through the permission prompt.
        let unauthorized = StubFocusStatus(
            access: access, isFocused: false, activeMode: .noFocus
        )
        #expect(ClaudeFocusAudience.shows(unauthorized), "hidden while access is \(access)")
    }
}

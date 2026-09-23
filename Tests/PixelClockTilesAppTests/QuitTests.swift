import AppKit
import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// Quit is instant, by the user's call (2026-09-21). The teardown wait it
// replaced spent up to the transport's own fifteen seconds seeing a held
// banner's dismiss through — against a clock that cannot answer, fifteen
// seconds of a panel reading as broken. What an instant exit costs is left
// to what already carries it: a banner outlives the process on the clock
// that was showing it, and a borrowed device state waits for the next
// launch to give it back — the durable borrow record and the launch-time
// restore are exactly that machinery. `AppModel.teardown` stays what the
// tests use to stop the loops; a quit no longer waits on it.

@Test @MainActor func quittingAnswersMacOSWithTerminateNow() {
    let delegate = AppDelegate(model: testModel(), discovery: inertDiscovery())

    #expect(delegate.applicationShouldTerminate(.shared) == .terminateNow)
}

import PixelClockKit
import Foundation
import Testing
@testable import PixelClockTilesApp

// What a threshold crossing does once the trajectory has found one.
//
// Two halves that must not depend on each other. Measured against a locally
// built bundle: `UNUserNotificationCenter.current()` resolves and reports
// `notDetermined`, and `requestAuthorization` then comes back REFUSED with
// `UNErrorDomain` code 1 rather than raising a prompt — unsigned, the system
// will not register the app for notifications at all. So the denied case is not
// the unlucky path, it is the shipping one, and a dialog conditional on
// authorization would be a warning nobody ever sees.

private let lowBattery = BatteryWarning(threshold: 20, percent: 19)

@Test @MainActor func theDialogStillAppearsWhenNotificationsAreDenied() async {
    let dialog = RecordingDialog()
    let notifications = StubNotifications(granted: false)
    let subject = BatteryAlert(dialog: dialog, notifications: notifications)

    await subject.warn(lowBattery)

    #expect(dialog.shown.count == 1)
    // And nothing was posted, which is the other half: a denied app that posts
    // anyway is not a thing that can happen, so an implementation ignoring the
    // answer would be silently wrong rather than loudly.
    #expect(notifications.posted.isEmpty)
}

@Test @MainActor func anAuthorizedWarningReachesNotificationCentreAsWellAsTheDialog() async {
    let dialog = RecordingDialog()
    let notifications = StubNotifications(granted: true)
    let subject = BatteryAlert(dialog: dialog, notifications: notifications)

    await subject.warn(lowBattery)

    #expect(dialog.shown.count == 1)
    #expect(notifications.posted.count == 1)
    // The same words in both places. Two wordings for one crossing is two
    // pieces of news as far as the reader is concerned.
    #expect(notifications.posted.first?.title == dialog.shown.first?.title)
    #expect(notifications.posted.first?.body == dialog.shown.first?.body)
}

@Test @MainActor func authorizationIsNotAskedForUntilTheFirstWarning() async {
    let notifications = StubNotifications(granted: true)
    let subject = BatteryAlert(dialog: RecordingDialog(), notifications: notifications)

    // Built, wired into the poll, and never used: a menu bar toy that demands
    // notification permission on first run gets refused before the user knows
    // what it wants, and the refusal is permanent until System Settings.
    #expect(notifications.authorizationRequests == 0)

    await subject.warn(lowBattery)

    #expect(notifications.authorizationRequests == 1)
}

@Test @MainActor func authorizationIsAskedForOnceHoweverManyWarningsFollow() async {
    let notifications = StubNotifications(granted: true)
    let subject = BatteryAlert(dialog: RecordingDialog(), notifications: notifications)

    await subject.warn(lowBattery)
    await subject.warn(BatteryWarning(threshold: 10, percent: 9))
    await subject.warn(BatteryWarning(threshold: 5, percent: 4))

    #expect(notifications.authorizationRequests == 1)
    #expect(notifications.posted.count == 3)
}

@Test @MainActor func aRefusalIsRememberedRatherThanReasked() async {
    let notifications = StubNotifications(granted: false)
    let dialog = RecordingDialog()
    let subject = BatteryAlert(dialog: dialog, notifications: notifications)

    await subject.warn(lowBattery)
    await subject.warn(BatteryWarning(threshold: 10, percent: 9))

    // The refusal is the answer, not the absence of one. Asking again on every
    // crossing is a permission prompt the user already said no to.
    #expect(notifications.authorizationRequests == 1)
    // And the dialog keeps arriving, which is the whole point of the split.
    #expect(dialog.shown.count == 2)
}

@Test func eachThresholdSaysSomethingOfItsOwn() {
    // The SAME percentage in all four, so the only thing that can tell them
    // apart is the wording. Written with a percentage per threshold this passed
    // with two of the four lines identical — the numbers accounted for the whole
    // difference, and the test claimed the wording.
    let bodies = [20, 10, 5, 1].map { threshold in
        BatteryAlertWords.body(for: BatteryWarning(threshold: threshold, percent: 4))
    }

    // Four lines that read the same are four dialogs whose only information is
    // that one appeared.
    #expect(Set(bodies).count == 4, "\(bodies)")
}

@Test func theWordsNameWhereTheBatteryIsRatherThanWhereTheLineWas() {
    // A poll every twenty seconds can find the battery at 19% having last seen
    // it at 25%. "20%" would be the one number on screen that is not a reading.
    for threshold in [20, 10, 5, 1] {
        let body = BatteryAlertWords.body(
            for: BatteryWarning(threshold: threshold, percent: threshold - 1)
        )
        #expect(body.contains("\(threshold - 1)%"), "\(body) does not name the reading")
    }
}

@Test func theTitleEscalatesRatherThanRepeating() {
    let low = BatteryAlertWords.title(for: BatteryWarning(threshold: 20, percent: 19))
    let critical = BatteryAlertWords.title(for: BatteryWarning(threshold: 5, percent: 4))

    #expect(low != critical)
}

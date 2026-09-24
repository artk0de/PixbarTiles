import AppKit
import PixbarKit
import Foundation
import UserNotifications

/// Told when the battery has fallen through a threshold.
///
/// Declared here rather than in the kit for the reason `ConnectorRunning` is:
/// the kit works out THAT a threshold was crossed, and what to do about it —
/// steal focus, ask the system for permission to post — is the app's.
protocol BatteryWarningPresenting: Sendable {
    @MainActor func warn(_ warning: BatteryWarning, on clock: String) async
}

/// The in-app half: a dialog the user cannot miss.
@MainActor
protocol BatteryDialogPresenting {
    func show(title: String, body: String)
}

/// The system half: Notification Centre.
///
/// Two calls rather than one, because they fail differently and only one of
/// them is allowed to be asked lazily. Behind a protocol because
/// `UNUserNotificationCenter.current()` does not merely fail outside a bundle —
/// it raises `NSInternalInconsistencyException` and takes the process with it,
/// which under `swift test` is the whole suite.
protocol BatteryNotificationPosting: Sendable {
    func requestAuthorization() async -> Bool
    func post(title: String, body: String) async
}

/// What a crossing says, in the user's words.
///
/// Its own type rather than two strings built where the dialog is raised, for
/// the reason `NextRunLine` is one: what the user reads is behaviour, and it
/// has to say the same thing in the dialog and in Notification Centre or one
/// crossing arrives as two pieces of news.
enum BatteryAlertWords {
    /// Escalates once, at the point where the clock is about to stop being a
    /// clock. Four distinct titles would be four things to read rather than one
    /// thing to notice.
    static func title(for warning: BatteryWarning) -> String {
        warning.threshold <= 5 ? "AWTRIX clock is about to switch off" : "AWTRIX clock is low"
    }

    /// Names where the battery IS, not where the line was. A poll every twenty
    /// seconds can find it at 19% having last seen it at 25%, and "20%" would
    /// be the one number on screen that is not a reading. The clock's own name
    /// leads, because with more than one on the desk the first word is what
    /// says whose battery it is.
    static func body(for warning: BatteryWarning, on clock: String) -> String {
        switch warning.threshold {
        case 1: "\(clock): \(warning.percent)% left. The next thing it does is switch off."
        case 5: "\(clock): \(warning.percent)% left. Plug it in now."
        case 10: "\(clock): \(warning.percent)% left. Plug it in soon."
        default: "\(clock): \(warning.percent)% left, and falling."
        }
    }
}

/// Raises a threshold crossing, both ways it can be raised.
///
/// The two halves are deliberately not chained. The dialog goes up first and
/// unconditionally; the system notification is attempted afterwards and only if
/// the system allows it. Which way round they go is the whole design: measured
/// against a locally built bundle, `requestAuthorization` comes back refused
/// with `UNErrorDomain` code 1 rather than prompting, so the notification half
/// reaches nobody today — and a dialog gated on it would be a battery warning
/// that never appears.
@MainActor
final class BatteryAlert: BatteryWarningPresenting {
    private let dialog: any BatteryDialogPresenting
    private let notifications: any BatteryNotificationPosting
    /// What the system said, or nil while it has not been asked.
    ///
    /// Three states rather than a bool, because "not asked" is not "refused":
    /// the ask happens at the first crossing rather than at launch — a menu bar
    /// toy that demands notification permission on first run gets refused
    /// before the user knows what it wants, and that refusal stands until
    /// somebody goes into System Settings. A refusal, once given, is an answer
    /// and is not asked again.
    private var authorized: Bool?

    init(dialog: any BatteryDialogPresenting, notifications: any BatteryNotificationPosting) {
        self.dialog = dialog
        self.notifications = notifications
    }

    func warn(_ warning: BatteryWarning, on clock: String) async {
        let title = BatteryAlertWords.title(for: warning)
        let body = BatteryAlertWords.body(for: warning, on: clock)
        // First, and before anything is awaited. An authorization request that
        // never comes back — the system prompt is up and the user is elsewhere
        // — would otherwise hold the warning that matters behind the one that
        // does not.
        dialog.show(title: title, body: body)
        if authorized == nil { authorized = await notifications.requestAuthorization() }
        guard authorized == true else { return }
        await notifications.post(title: title, body: body)
    }
}

/// The shipped dialog: an `NSAlert`, raised from the menu bar.
///
/// Scheduled onto the main queue rather than run where it is called.
/// `runModal()` spins a nested run loop and does not return until the user
/// dismisses it, and the caller is the reachability poll's own task — run
/// inline, a dialog nobody is looking at would stop the app asking the clock
/// anything. The nested loop drains the main queue, so the main actor keeps
/// being serviced behind the sheet.
///
/// Activated first, deliberately. This app has `LSUIElement` set: it owns no
/// window and is not the front app, and an alert raised without activating
/// arrives behind whatever the user is actually looking at.
struct ModalBatteryDialog: BatteryDialogPresenting {
    func show(title: String, body: String) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                NSApplication.shared.activate(ignoringOtherApps: true)
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = body
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
        }
    }
}

/// The shipped system half.
///
/// Both calls are gated on there being a bundle at all, and that guard is not
/// defensive tidiness: `UNUserNotificationCenter.current()` raises
/// `NSInternalInconsistencyException` — "bundleProxyForCurrentProcess is nil" —
/// and aborts the process when there is none. That is every `swift run` of this
/// package, and it would be every `swift test` too if anything constructed this
/// type there.
///
/// Measured against a locally built bundle: the centre resolves, the status
/// reads `notDetermined`, and `requestAuthorization` comes back refused with
/// `UNErrorDomain` code 1 rather than prompting — unsigned and un-notarized, the
/// system will not register the app for notifications at all. Which is why the
/// dialog is not conditional on any of this: today it is the only half that
/// reaches the user, and the day the app is signed this half starts working
/// without anything here changing.
struct SystemBatteryNotifier: BatteryNotificationPosting {
    func requestAuthorization() async -> Bool {
        guard isBundled else { return false }
        // Refusals arrive as a thrown `UNError`, not as `granted == false`, so
        // both endings mean the same thing here: nothing may be posted.
        return (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func post(title: String, body: String) async {
        guard isBundled else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        // No trigger: delivered as soon as the centre takes it. A crossing is
        // news about now, and a scheduled one would arrive after the battery
        // had moved on.
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }

    private var isBundled: Bool { Bundle.main.bundleIdentifier != nil }
}

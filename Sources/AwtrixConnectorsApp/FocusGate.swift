import Foundation
import Intents

/// What macOS has been asked about Focus, and what it answered.
///
/// This app's own four states rather than `INFocusStatusAuthorizationStatus`,
/// for the reason `BatteryNotificationPosting` exists: the type that answers
/// this in the shipped app cannot be constructed under `swift test` without
/// aborting the process, so the question has to be askable of something else.
/// The four cases are the system's own, one for one, so nothing is folded away
/// here that the gate might want back.
enum FocusAccess: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

/// What macOS says about Focus.
///
/// Two questions rather than one, and keeping them apart is the whole point.
/// An unauthorized centre answers `isFocused == false` — the same answer as a
/// genuinely idle Mac — so a gate that read only the second would believe no
/// Focus is ever on and speak at three in the morning for ever, silently and by
/// construction.
protocol FocusStatusReading: Sendable {
    /// Whether this app may believe the answer below.
    var access: FocusAccess { get }
    /// Whether a Focus is on, as the system reports it. Evidence only while
    /// `access` is `.authorized`.
    var isFocused: Bool { get }
    /// Asks macOS for access. See `SystemFocusStatus` for what that costs.
    func requestAccess()
}

/// The hours the schedule stays quiet when macOS will not say whether a Focus
/// is on.
///
/// Hours rather than minutes: this is a guess standing in for the system's own
/// answer, and a guess with a five-minute resolution implies a precision it
/// does not have. Two pickers is also the whole editor, which matters for
/// something the user sets once.
struct QuietWindow: Equatable, Sendable {
    /// The first hour of the quiet stretch, inclusive.
    var startHour: Int
    /// The hour it ends at, exclusive — so 23 to 8 is quiet at 23:59 and
    /// speaking again at 08:00.
    var endHour: Int

    /// Eleven at night until eight in the morning: the case that prompted the
    /// whole gate. Shipped as the default rather than left empty, because an
    /// empty window is the behaviour this task exists to remove and a user who
    /// never opens the settings would keep it.
    static let `default` = QuietWindow(startHour: 23, endHour: 8)

    /// What the pickers offer. Every hour of the day, and both ends draw from
    /// the same list — a window is a pair of hours, not a start with a length.
    static let selectableHours = Array(0...23)

    static let startKey = "quietStartHour"
    static let endKey = "quietEndHour"

    /// Whether this moment falls inside the window.
    ///
    /// Read to the hour, in the machine's own calendar: the user set hours, and
    /// the question is which hour it is where they are sitting.
    func contains(_ moment: Date, in calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: moment)
        // Zero length is zero quiet. The other reading of two pickers landing
        // on the same hour — a window that swallows the whole day — is an app
        // that has gone permanently mute because somebody scrolled one wheel
        // too far, with nothing on the panel to say why.
        guard startHour != endHour else { return false }
        // The default wraps midnight, so this is the case rather than the edge
        // case: 23 to 8 is two stretches with the day boundary between them.
        guard startHour < endHour else { return hour >= startHour || hour < endHour }
        return hour >= startHour && hour < endHour
    }

    /// The window as the settings say it, `23:00–08:00`.
    var label: String {
        "\(Self.clockFace(startHour))–\(Self.clockFace(endHour))"
    }

    /// An hour as a clock reads it.
    ///
    /// Written out rather than handed to `DateFormatter`, for the reason
    /// `BatteryLine.duration` is: a locale-dependent formatter would have the
    /// suite say one thing on this machine and another on anybody else's.
    static func clockFace(_ hour: Int) -> String {
        String(format: "%02d:00", hour)
    }

    /// What the last launch left behind, or the default when nothing was ever
    /// set.
    ///
    /// Read through `object(forKey:)` rather than `integer(forKey:)`, because
    /// the latter answers 0 for a key that was never written and midnight is a
    /// perfectly good hour — a user who set a window starting at 00:00 must not
    /// be indistinguishable from one who set nothing.
    static func stored(in defaults: UserDefaults) -> QuietWindow {
        guard
            let start = defaults.object(forKey: startKey) as? Int,
            let end = defaults.object(forKey: endKey) as? Int
        else { return .default }
        return QuietWindow(startHour: start, endHour: end)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(startHour, forKey: Self.startKey)
        defaults.set(endHour, forKey: Self.endKey)
    }
}

/// Which of the two rules decides whether the schedule may speak.
///
/// Never both, and the user is told which. Somebody who refused the prompt
/// should be able to see that the app is running on its own window rather than
/// on the system's state, or the difference between "no Focus is on" and "I am
/// not allowed to know" is invisible on the one surface that could show it.
enum QuietRule: Equatable, Sendable {
    /// macOS answered, and this app is allowed to ask.
    case focus
    /// The system's answer is not evidence, so the user's own hours decide.
    case quietHours(QuietWindow)
}

/// Whether the schedule may speak, and what to call it when it may not.
///
/// A value rather than an object: it holds the centre it asks and the clock it
/// reads, and every answer is a function of those two. The window is a
/// parameter rather than a field because `AppModel` owns it — the pickers bind
/// to it and the defaults keep it — and a second copy here would be a second
/// thing to keep in step.
struct FocusGate: Sendable {
    /// What the panel says while a Focus silences the schedule.
    ///
    /// `INFocusStatusCenter` reports *whether* a Focus is active, never *which*
    /// — telling Sleep from Work needs the TCC-protected Do Not Disturb
    /// database and Full Disk Access with it — so the words name the state
    /// rather than the Focus.
    static let duringFocus = "Focus is on"
    /// And while the user's own hours do, because macOS would not say.
    static let duringQuietHours = "quiet hours"

    let status: any FocusStatusReading
    /// Injected so a test can ask what the gate does at three in the morning
    /// without waiting until then.
    let now: @Sendable () -> Date

    init(status: any FocusStatusReading, now: @escaping @Sendable () -> Date = Date.init) {
        self.status = status
        self.now = now
    }

    /// Which rule is in force.
    ///
    /// `.authorized` and nothing else. The other three answers all mean the
    /// same thing here — this app may not read the Focus state — and a check
    /// written as "not denied" would put a `notDetermined` centre's
    /// `isFocused == false` back in charge, which is the whole defect.
    func rule(quietHours: QuietWindow) -> QuietRule {
        status.access == .authorized ? .focus : .quietHours(quietHours)
    }

    /// What is silencing the schedule, or nil when nothing is.
    ///
    /// `isFocused` is read on ONE of the two branches. Read on both — or read
    /// before the rule is decided — an unauthorized centre's false would be an
    /// app that believes no Focus is ever on and speaks at three in the
    /// morning, silently and by construction.
    func silence(quietHours: QuietWindow) -> String? {
        switch rule(quietHours: quietHours) {
        case .focus:
            return status.isFocused ? Self.duringFocus : nil
        case let .quietHours(window):
            return window.contains(now()) ? Self.duringQuietHours : nil
        }
    }

    /// Asks macOS for access.
    func requestAccess() {
        status.requestAccess()
    }
}

/// What the settings say about which rule is in force.
///
/// Its own type rather than a string built in the view, for the reason
/// `NextRunLine` is one: what the user reads is behaviour, and a `Text` in a
/// SwiftUI body is not somewhere behaviour can be read back from.
enum FocusRuleLine {
    static func text(for rule: QuietRule) -> String {
        switch rule {
        case .focus:
            "Quiet while macOS reports a Focus"
        case let .quietHours(window):
            "macOS will not say whether a Focus is on — quiet \(window.label) instead"
        }
    }
}

/// The shipped centre.
///
/// Behind a protocol for a harder reason than tidiness, and the measurement is
/// worth spelling out because it decides the whole design.
///
/// Measured on this machine, macOS 26.6, no code-signing identity installed:
///
/// - `INFocusStatusCenter.default` resolves, `authorizationStatus` reads
///   `notDetermined`, and `focusStatus.isFocused` answers `Optional(false)`.
///   All three work from a bare `swift run` binary. None of them prompts.
/// - `requestAuthorization` **aborts the process** from a bare binary —
///   `EXC_CRASH (SIGABRT)`, TCC namespace, `__TCC_CRASHING_DUE_TO_PRIVACY_
///   VIOLATION__`, "the app's Info.plist must contain an
///   NSFocusStatusUsageDescription key". Under `swift test` that is the whole
///   suite, which is exactly the hazard `BatteryNotificationPosting` exists for.
/// - It aborts the same way from an ad-hoc-signed .app whose Info.plist DOES
///   carry the key, when the binary is executed directly rather than launched.
///   TCC attributes the plist through LaunchServices, and a path it did not
///   launch is a process with no usage description as far as it is concerned.
/// - Launched properly — `open -a`, key present, ad-hoc signed — it does not
///   abort and does not prompt: the completion handler is **never called**, and
///   `authorizationStatus` is still `notDetermined` afterwards. Unsigned and
///   un-notarized, the system will not put the app in front of the user at all.
///
/// So the unauthorized fallback is not a corner case, it is the shipping path,
/// and two rules follow. Nothing here may be awaited — a continuation waiting
/// on that handler would never resume — so `requestAccess` returns immediately
/// and the answer is read back off `access` on the next tick. And the call is
/// gated twice: on there being a bundle at all, and on that bundle carrying the
/// key TCC names. Neither guard makes a directly-executed bundle safe; what
/// makes the suite safe is that this type is never constructed in it.
struct SystemFocusStatus: FocusStatusReading {
    var access: FocusAccess {
        switch INFocusStatusCenter.default.authorizationStatus {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    /// Nil folds to false, and it costs nothing to do so: an answer the system
    /// declined to give is not a Focus, and while this app is unauthorized the
    /// value is not read at all.
    var isFocused: Bool {
        INFocusStatusCenter.default.focusStatus.isFocused ?? false
    }

    func requestAccess() {
        guard canAsk else { return }
        // The handler is deliberately empty. Measured above, it is never called
        // on this machine; what reads the answer is `access`, on the next turn
        // of whichever loop asked.
        INFocusStatusCenter.default.requestAuthorization { _ in }
    }

    /// Whether asking would be answered rather than fatal.
    ///
    /// Necessary and not sufficient — see the type's own note — and both halves
    /// are needed: `swift run` has no bundle at all, and a bundle assembled
    /// without the usage description is a guaranteed abort rather than a
    /// refusal.
    private var canAsk: Bool {
        Bundle.main.bundleIdentifier != nil
            && Bundle.main.object(forInfoDictionaryKey: "NSFocusStatusUsageDescription") != nil
    }
}

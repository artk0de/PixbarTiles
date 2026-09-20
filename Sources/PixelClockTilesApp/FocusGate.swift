import Foundation
import Intents
import PixelClockKit

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

/// Which Focus is on, as the Do Not Disturb database has it.
///
/// Three answers rather than an optional identifier, because the third is not a
/// missing value. "Nothing is on" and "I could not read the file" are opposite
/// instructions — the first speaks, the second hands the decision back to
/// `INFocusStatusCenter`'s boolean — and a `String?` spells them the same way.
enum ActiveFocusMode: Equatable, Sendable {
    /// Nothing is asserted. Spelled out rather than left as `nil` for the
    /// reason above, and not called `none`, which would read as `Optional`'s
    /// own at every use site that wraps this.
    case noFocus
    /// This mode identifier is asserted right now.
    case mode(String)
    /// The database could not be read, or was not the shape this app knows.
    /// Not an error state: without Full Disk Access it is what every launch
    /// gets, and on most machines it is the only answer this app will see.
    case cannotTell
}

/// What macOS says about Focus.
///
/// Three questions rather than one, and keeping them apart is the whole point.
/// An unauthorized centre answers `isFocused == false` — the same answer as a
/// genuinely idle Mac — so a gate that read only the second would believe no
/// Focus is ever on and speak at three in the morning for ever, silently and by
/// construction.
///
/// The third is not the framework's answer at all. Apple exposes no API for
/// which Focus is on, so it comes off disk from behind a permission this app
/// usually does not hold — which is why it carries a "cannot tell" of its own
/// instead of leaning on `access`: the two refusals are granted separately and
/// an app can easily have one and not the other.
protocol FocusStatusReading: Sendable {
    /// Whether this app may believe the answer below.
    var access: FocusAccess { get }
    /// Whether a Focus is on, as the system reports it. Evidence only while
    /// `access` is `.authorized`.
    var isFocused: Bool { get }
    /// WHICH Focus is on, which the two answers above cannot express and
    /// `INFocusStatusCenter` will not say. See `DoNotDisturbDatabase` for where
    /// it comes from and why it is usually `.cannotTell`.
    var activeMode: ActiveFocusMode { get }
    /// Asks macOS for access. See `SystemFocusStatus` for what that costs.
    func requestAccess()
}

extension FocusStatusReading {
    /// The conservative answer, so a centre that says nothing about the mode
    /// behaves exactly as this app did before it could read one: the boolean
    /// decides, and every Focus silences. A default of `.noFocus` would have
    /// been a silent opt-in to speaking through Sleep.
    var activeMode: ActiveFocusMode { .cannotTell }
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
        hours.contains(hour: calendar.component(.hour, from: moment))
    }

    /// The window as the settings say it, `23:00–08:00`.
    var label: String { hours.label }

    /// An hour as a clock reads it.
    static func clockFace(_ hour: Int) -> String {
        HourWindow.clockFace(hour)
    }

    /// The same two hours as the kit's window, which owns the arithmetic —
    /// the wrap past midnight and the zero-length rule — for this window and
    /// for every tile's.
    private var hours: HourWindow {
        HourWindow(startHour: startHour, endHour: endHour)
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

/// What the system's answer about Focus is worth, which is the one thing about
/// this gate the user cannot see from outside.
///
/// No longer a choice BETWEEN two rules: `FocusGate.silence(quietHours:)`
/// applies the user's window whichever of these holds, and this says only what
/// the Focus half beside it is doing. Kept as cases of its own rather than
/// folded into a boolean, because somebody who refused the prompt should be
/// able to see that the app is running on their window alone — "no Focus is on"
/// and "I am not allowed to know" look identical from the surface, and only in
/// the second is the window carrying the whole gate.
///
/// Three cases and not two, because the app has behaved three ways since it
/// started reading the mode and the caption could only say two of them — which
/// is how it came to announce a rule that had stopped being true. The split is
/// not the permission: it is whether a mode was READ, which is one observation
/// rather than an inference about why a read failed.
enum QuietRule: Equatable, Sendable {
    /// The mode was read, so only the Focuses this app knows to be silencing
    /// silence it. Every other one — Work, Fitness, whatever the user invented
    /// — speaks.
    case namedFocuses
    /// A Focus can be seen but not named, so every Focus silences. The
    /// conservative branch, and the one most machines are on.
    case anyFocus
    /// The system's answer is not evidence, so the user's own hours are all
    /// there is.
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
    /// The state rather than the mode, even now that the mode is sometimes
    /// known. A second string naming Do Not Disturb would put the permission on
    /// the panel, which is opened to answer "is the clock alive" and is not
    /// somewhere the user can act on Full Disk Access; the explanation belongs
    /// behind the gear, which is where `FocusRuleLine` keeps it.
    static let duringFocus = "Focus is on"
    /// And while the user's own hours do — whatever macOS says, not only when
    /// it will not say anything. Distinct strings because `AppModel` tells the
    /// two apart to decide whether a held beat may still SPEND.
    static let duringQuietHours = "quiet hours"

    let status: any FocusStatusReading
    /// Injected so a test can ask what the gate does at three in the morning
    /// without waiting until then.
    let now: @Sendable () -> Date

    init(status: any FocusStatusReading, now: @escaping @Sendable () -> Date = Date.init) {
        self.status = status
        self.now = now
    }

    /// Whether the centre's answer may be believed, and the window it stands
    /// beside when it may not.
    ///
    /// `.authorized` and nothing else. The other three answers all mean the
    /// same thing here — this app may not read the Focus state — and a check
    /// written as "not denied" would put a `notDetermined` centre's
    /// `isFocused == false` back in charge, which is the whole defect.
    ///
    /// Still a `QuietRule` rather than the `Bool` this once computed, because
    /// the settings sheet reads it through `FocusRuleLine`: a bare boolean
    /// would have to be turned back into the same sentences one layer up,
    /// somewhere a test cannot read them back off the model.
    ///
    /// Three answers and not two, because the app behaves three ways and the
    /// caption could only say two of them. The permission decides first — an
    /// unauthorized centre is the window alone whatever the file says — and
    /// then whether a mode was actually read decides which Focus rule is in
    /// force: named, so only Do Not Disturb and Sleep silence, or unnamed, so
    /// every Focus does. That second question is asked of the same
    /// `activeMode` `activeFocusSilence` branches on, so the sentence and the
    /// behaviour cannot disagree.
    func rule(quietHours: QuietWindow) -> QuietRule {
        guard status.access == .authorized else { return .quietHours(quietHours) }
        return status.activeMode == .cannotTell ? .anyFocus : .namedFocuses
    }

    /// What is silencing the schedule, or nil when nothing is.
    ///
    /// Both gates, and whichever wants silence gets it. The exclusive choice
    /// this replaces — the window OR the system, never both — was written while
    /// `INFocusStatusCenter` had never once answered `.authorized` here, so the
    /// branch that dropped the window was unreachable and looked free. Signing
    /// the app revived the centre and the user's own 23:00–08:00 stopped
    /// applying on the build they run. The window is their instruction about
    /// their own night, and a system Focus becoming legible is not a reason to
    /// stop obeying it.
    ///
    /// The window is asked FIRST, and that ordering is load-bearing rather than
    /// a tie-break: the answer is a REASON as well as a verdict, and
    /// `AppModel.duringTheQuietWindow` compares this string to decide whether
    /// the nightly refresh may spend. A 3 a.m. Sleep answered as `duringFocus`
    /// would let it load its model and spin the fans inside the hours somebody
    /// set aside for not being disturbed.
    ///
    /// What does NOT change is which branch may read the centre. Its two
    /// answers stay behind `rule`, because an unauthorized centre's false is
    /// the same false an idle Mac gives — read here it would be an app that
    /// believes no Focus is ever on, silently and by construction. The mode is
    /// behind the same guard for the same reason: a database this app may not
    /// act on is not evidence either.
    ///
    /// The two Focus cases fall through together, and that is not a case left
    /// unhandled: they differ in what the settings SAY, not in what may be
    /// read, and the branch between them is `activeFocusSilence`'s own — made
    /// from the same `activeMode` `rule` asked, so the caption cannot describe
    /// one rule while the gate runs another.
    func silence(quietHours: QuietWindow) -> String? {
        if quietHours.contains(now()) { return Self.duringQuietHours }
        if case .quietHours = rule(quietHours: quietHours) { return nil }
        return activeFocusSilence
    }

    /// Which Focus is on when the database will say, and the boolean when it
    /// will not.
    ///
    /// The asymmetry in the last branch is deliberate, and a future reader will
    /// otherwise file it as a bug and remove it: told nothing about the mode,
    /// this goes back to treating EVERY Focus as silencing. Staying quiet when
    /// it could have spoken costs the user a joke they never hear; speaking
    /// when it should have stayed quiet is what wakes somebody at three in the
    /// morning. Only one of those is recoverable.
    ///
    /// `.noFocus` speaks without consulting the boolean, because the file is
    /// where the boolean's own answer comes from — Control Center writes an
    /// assertion and `INFocusStatusCenter` reports that there is one — so a
    /// disagreement between them is the two being read a moment apart rather
    /// than two opinions worth arbitrating.
    private var activeFocusSilence: String? {
        switch status.activeMode {
        case let .mode(identifier):
            DoNotDisturbDatabase.silencing.contains(identifier) ? Self.duringFocus : nil
        case .noFocus:
            nil
        case .cannotTell:
            status.isFocused ? Self.duringFocus : nil
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
    /// What the permission buys, said where the user can act on it.
    ///
    /// A standing sentence rather than a line that changes with the grant, and
    /// the reason is that the app cannot tell the two apart: a refused
    /// permission, a moved file and a shape macOS has changed all read as
    /// `.cannotTell`, so a line announcing "no access" would be a guess
    /// presented as a fact. What the two states DO is certain, so that is what
    /// this says.
    ///
    /// That argument still holds, and `text(for:)` does not break it. This
    /// sentence is about the PERMISSION — why the app might not be able to name
    /// a Focus — and the cause of a failed read is the part that cannot be
    /// known. The line above it reports something else entirely: whether a mode
    /// was in fact read a moment ago. That is an observation with an answer,
    /// taken from the same read the gate acts on, and it says which rule is
    /// running without claiming to know why. Neither line announces "no
    /// access"; only this one talks about access at all.
    ///
    /// No button beside it. `x-apple.systempreferences:` URLs for this pane
    /// were not verified to land on it, and a button that opens the wrong pane
    /// is worse than a sentence naming the right one.
    static let whichFocusesSilenceDependsOnFullDiskAccess =
        "macOS tells apps only that some Focus is on, never which one. Without "
            + "Full Disk Access every Focus reads as Other Focus to your tiles; "
            + "grant it in System Settings › Privacy & Security › Full Disk "
            + "Access and Work, Personal, Do Not Disturb and Sleep are told apart."

    /// Which rule is in force, said under the pickers that set the window.
    ///
    /// Both Focus sentences name BOTH gates, and they have to: the line sits
    /// directly under the hour pickers, and a caption saying the system decides
    /// would tell somebody who had just set 23:00 that their pickers do
    /// nothing.
    ///
    /// The two of them differ in WHICH Focuses silence, which is the thing that
    /// changed under the user and was reported as a defect: Full Disk Access
    /// was granted, the app started reading the mode and silencing for Do Not
    /// Disturb and Sleep alone, and this caption went on announcing that any
    /// Focus would. The modes are named rather than counted, because "some
    /// Focuses" is not something a person can act on and these two are the
    /// whole list.
    ///
    /// Said without naming the hours, unlike the third branch. They are on the
    /// two pickers immediately above, and a caption repeating them is a second
    /// place for them to disagree.
    static func text(for rule: QuietRule) -> String {
        switch rule {
        case .namedFocuses:
            "Quiet during Do Not Disturb and Sleep, and inside your quiet hours either way"
        case .anyFocus:
            "Quiet while macOS reports a Focus, and inside your quiet hours either way"
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

    /// Read off the disk on every ask — a read this app is refused until
    /// somebody grants Full Disk Access by hand. See `DoNotDisturbDatabase`.
    var activeMode: ActiveFocusMode { DoNotDisturbDatabase.activeMode() }

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

/// `~/Library/DoNotDisturb/DB/Assertions.json`, read for the one fact
/// `INFocusStatusCenter` will not give up: WHICH Focus is on.
///
/// Undocumented, unsupported, and taken deliberately. There is no API for this
/// — the centre answers `isFocused` and nothing else — so the choice was
/// between reading the file and silencing every Focus alike, which is what the
/// app did and what this exists to stop. The cost is stated rather than hidden:
/// Apple may change the format in any release, and the app that reads it is
/// asking for a key to the whole disk.
///
/// The read costs Full Disk Access and nothing less. Measured on this machine:
/// the directory is the user's own, `drwxr-xr-x`, with no restricted flag, and
/// a read still fails `EPERM` rather than `EACCES` — TCC's signature, not the
/// file system's. A self-signed identity and a LaunchServices launch were both
/// tried, which is what revived CoreLocation and the Focus centre here, and
/// neither moves this one.
enum DoNotDisturbDatabase {
    /// The two modes this app stays quiet for.
    ///
    /// Matched on the IDENTIFIER, never on the `mode.name` that sits beside it
    /// in `ModeConfigurations.json`: that name is localised — it reads "Сон"
    /// and "Работа" on this machine — and the user can rename any Focus from
    /// System Settings. These identifiers ship with macOS and are not editable.
    ///
    /// `ModeConfigurations.json` is not read at all. It could only corroborate
    /// what these two identifiers already say, and every other mode in it is
    /// one to speak through — including the ones a user invents, which no list
    /// here could enumerate.
    static let silencing: Set<String> = Set(
        [MacFocus.doNotDisturb, .sleep].compactMap(\.modeIdentifier)
    )

    /// Where macOS keeps it.
    ///
    /// The real home directory, which this app has because it is not sandboxed.
    /// A sandboxed one would be handed its own container here and would read a
    /// path that does not exist — silently, as a missing file, which this app
    /// reads as `.cannotTell` and would look exactly like a refused permission.
    static let assertions = URL.homeDirectory
        .appending(path: "Library/DoNotDisturb/DB/Assertions.json")

    /// What the file on disk says right now.
    ///
    /// Read on every ask rather than cached, and the price is one 4-5 KB file
    /// and a decode: 32 µs measured, against a gate consulted a few times every
    /// five seconds by the label refresh. A cache would have to be invalidated
    /// on a change nothing tells this app about, and a stale one is a Focus the
    /// user switched off half an hour ago still holding the app quiet.
    static func activeMode(at url: URL = assertions) -> ActiveFocusMode {
        guard let data = try? Data(contentsOf: url) else { return .cannotTell }
        return activeMode(inAssertions: data)
    }

    /// The same question asked of bytes, so the shape can be tested without the
    /// permission — which the suite does not have and must never need.
    static func activeMode(inAssertions data: Data) -> ActiveFocusMode {
        guard
            let file = try? JSONDecoder().decode(AssertionsFile.self, from: data),
            let store = file.data.first
        else { return .cannotTell }
        // Absent is what an idle Mac was MEASURED to write: with every Focus
        // off, the key is not in the file at all. Empty was never observed and
        // is defended against rather than seen. Both have to mean "nothing is
        // on" — read as an unrecognised shape, the commonest state there is
        // would fall back to the boolean and put the old behaviour back.
        guard let records = store.storeAssertionRecords, records.isEmpty == false else {
            return .noFocus
        }
        let identifiers = records.compactMap { $0.assertionDetails?.assertionDetailsModeIdentifier }
        // Something is asserted and this app cannot name it. Not `.noFocus`,
        // which would speak through what might be Sleep.
        guard identifiers.count == records.count else { return .cannotTell }
        // Whichever one silences, if either is there. Modes do not stack today
        // — one record, one Focus, in every capture — but the file is a list,
        // and the quiet answer is the recoverable one if that stops being true.
        return .mode(identifiers.first { silencing.contains($0) } ?? identifiers[0])
    }

    /// The file, with the history left out BY CONSTRUCTION.
    ///
    /// This is the whole defence against the trap, and it is a type rather than
    /// a rule somebody has to keep in mind. Beside `storeAssertionRecords` the
    /// file carries `storeInvalidationRecords` and
    /// `storeInvalidationRequestRecords` — assertions that have ENDED, in the
    /// same shape, wrapping the same `assertionDetailsModeIdentifier`. Captured
    /// on an idle machine they held five records naming Do Not Disturb, Sleep
    /// and Work while nothing at all was on. `Decodable` ignores keys a type
    /// does not declare, so a parser written this way cannot read the history
    /// even by accident.
    private struct AssertionsFile: Decodable {
        let data: [Store]

        struct Store: Decodable {
            let storeAssertionRecords: [Record]?
        }

        struct Record: Decodable {
            let assertionDetails: Details?
        }

        struct Details: Decodable {
            let assertionDetailsModeIdentifier: String?
        }
    }
}

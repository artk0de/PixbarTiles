import Foundation
import Intents
import PixbarKit

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

/// The one sentence the settings still say about Focus, and the type that
/// holds it.

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
    /// A button beside it opens the pane (`FullDiskAccess.openSettings`).
    static let whichFocusesSilenceDependsOnFullDiskAccess =
        "macOS tells apps only that some Focus is on, never which one. Without "
            + "Full Disk Access every Focus reads as Other Focus to your tiles; "
            + "grant it in System Settings › Privacy & Security › Full Disk "
            + "Access and Work, Personal, Do Not Disturb and Sleep are told apart."
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

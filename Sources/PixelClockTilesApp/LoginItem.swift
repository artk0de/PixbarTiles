import Foundation
import ServiceManagement

/// What macOS says about opening this app at login.
///
/// This app's own four states rather than `SMAppService.Status`, for the reason
/// `FocusAccess` exists: the type that answers this in the shipped app talks to
/// the real login-item database, so the question has to be askable of something
/// else or every test of this surface registers the machine it runs on. The
/// four cases are the system's own, one for one, so nothing is folded away here
/// that the checkbox might want back.
///
/// `notFound` and `notRegistered` both draw an empty box and are still kept
/// apart, because they are different facts: measured on this machine, a bundle
/// the login-item database has never seen answers `notFound`, and one that has
/// been registered and then unregistered answers `notRegistered`. Folding them
/// would throw away the only signal that says whether this app has ever asked.
enum LoginItemState: Equatable, Sendable {
    /// The database has a record and it is off.
    case notRegistered
    /// Registered, and macOS will start it.
    case enabled
    /// Registered, and macOS is holding it until somebody says so in System
    /// Settings. Not an off, and not something this app can resolve from here.
    case requiresApproval
    /// No record at all — a bundle the database has never been told about.
    case notFound
}

/// Why the shipped registrar would not even ask.
///
/// Its own error rather than a bare `NSError`, because it reaches the user as
/// the sentence under the checkbox: `localizedDescription` on an anonymous
/// error is a domain and a number, which explains nothing to somebody who just
/// clicked a box.
enum LoginItemRefusal: Error, LocalizedError, Equatable {
    case noBundleToRegister

    var errorDescription: String? {
        "There is no app bundle to open at login — this build is a bare binary."
    }
}

/// What the login-item database says, and the two ways to change its mind.
///
/// `state` is a question asked of the system every time rather than a value
/// this app keeps. That is the whole design: the user can take the login item
/// away in System Settings without this app being running, and a remembered
/// answer would be a lie the checkbox goes on telling.
protocol LoginItemRegistering: Sendable {
    var state: LoginItemState { get }
    func register() throws
    func unregister() throws
}

/// The checkbox behind the gear, and what it is allowed to believe.
///
/// An object rather than a computed property on the view, for two reasons. The
/// failure has to survive the redraw that follows the click that caused it —
/// a `Text` built inside a `Toggle`'s action closure is not somewhere anything
/// can be read back from — and the system read is not free: measured on this
/// machine, the first `SMAppService.mainApp.status` of a process costs 16.9 ms
/// and later ones 1.45 ms, so it is asked when the surface opens and after each
/// call rather than on every draw.
///
/// Its own object rather than fields on `AppModel` for the reason
/// `PlaceSearchModel` is one: none of this is a setting. The system owns the
/// answer, this app stores nothing, and there is consequently nothing here for
/// the model that outlives the sheet to hold.
@MainActor
final class LoginItemModel: ObservableObject {
    /// Said when macOS has the registration and is sitting on it.
    ///
    /// Names the surface to go to, because that is the only useful thing left:
    /// approval cannot be granted from inside the app, and a user given an
    /// empty box and no explanation clicks it again for ever.
    /// `nonisolated` because it is a fact about words rather than about this
    /// object's state, and a test asking what the sentence says has no reason
    /// to hop to the main actor to find out.
    nonisolated static let approvalIsHeldInSystemSettings =
        "macOS is holding this one. Turn PixelClockTiles on in System Settings › "
            + "General › Login Items."

    /// What the system last answered. Published so the tick follows a change
    /// this app did not make.
    @Published private(set) var state: LoginItemState
    /// Why the box is not what was asked for, or nil when there is nothing to
    /// explain.
    @Published private(set) var note: String?

    private let service: any LoginItemRegistering

    init(service: any LoginItemRegistering = SystemLoginItem()) {
        self.service = service
        self.state = service.state
        self.note = Self.note(for: service.state)
    }

    /// Whether the box is ticked.
    ///
    /// `.enabled` and nothing else. Written as "not notRegistered" it would
    /// tick for `requiresApproval` — an app macOS is actively refusing to
    /// start — which is the one state where a ticked box is worse than a clear
    /// one.
    var opensAtLogin: Bool { state == .enabled }

    /// Asks the system to change, then reads back what it actually did.
    ///
    /// The read-back is unconditional, and that is the point of the whole type.
    /// A registration can be declined without throwing — probed, and a
    /// refusal-shaped failure is exactly what a stored boolean cannot see — so
    /// what the box shows afterwards is the system's own answer, never the
    /// answer that was asked for.
    func setOpensAtLogin(_ wanted: Bool) {
        var refusal: String?
        do {
            if wanted {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // The error's own words, for the reason `PlaceSearchModel` shows
            // them: they are what separate a refusal from an outage from a
            // build that cannot ask at all, and the user acts differently on
            // each.
            refusal = "Could not \(wanted ? "switch this on" : "switch this off"): "
                + error.localizedDescription
        }
        state = service.state
        // The refusal wins over the standing note. Both cannot be true of the
        // same click, and the one naming what just failed is the one the user
        // is looking for.
        note = refusal ?? Self.note(for: state)
    }

    /// What a state needs said about it, or nothing when it speaks for itself.
    ///
    /// Only one of the four does. A ticked box, a clear box and a box for an
    /// app the database has never heard of all mean what they look like; an
    /// approval held elsewhere does not.
    private static func note(for state: LoginItemState) -> String? {
        state == .requiresApproval ? approvalIsHeldInSystemSettings : nil
    }
}

/// The shipped registrar.
///
/// Probed on this machine, macOS 26.6.1, with no valid code-signing identity —
/// and the result is the opposite of the other three Apple authorization APIs
/// this app meets:
///
/// - `register()` **succeeds** from an ad-hoc-signed bundle. Status goes
///   `notFound` → `enabled`, `unregister()` takes it back to `notRegistered`,
///   and `sfltool dumpbtm` shows a real login-item record appear and go.
/// - It succeeds identically whether the bundle is signed by the linker's
///   ad-hoc signature or by the untrusted local certificate, and whether it is
///   executed directly or launched through LaunchServices. The signature is not
///   what this API is gated on.
/// - `requiresApproval` was never reached here: the record arrived enabled and
///   allowed without a prompt.
///
/// So unlike notifications, Focus and CoreLocation, this one is live today and
/// the checkbox is not a promise about a future signed build.
///
/// The guard is the part that is not optional. `SMAppService.mainApp` outside a
/// bundle does not refuse — it registers whatever `Bundle.main.bundlePath`
/// happens to be, which under `swift test` is a directory inside the Xcode
/// toolchain. Probed with a bare binary, which duly appeared in the login-item
/// database and had to be taken back out.
struct SystemLoginItem: LoginItemRegistering {
    /// Whether there is a bundle for the system to point a login item at.
    ///
    /// Internal rather than private, unlike `SystemFocusStatus.canAsk`, and the
    /// difference is what it costs to be wrong. There, an unguarded ask aborts
    /// a process; here it silently adds a login item to the machine of whoever
    /// ran the code. A guard nothing asserts is one somebody deletes as noise.
    static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asked of the system on every read. See `LoginItemRegistering` for why
    /// nothing is cached, and `LoginItemModel` for what that read costs.
    ///
    /// Unbundled this answers `notFound`, which is true — there is no bundle to
    /// have a record — and costs nothing, so it needs no guard of its own.
    var state: LoginItemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        // A state this app has not met folds to the empty box rather than the
        // ticked one: the box is a claim that macOS will start this app, and an
        // answer nobody has read is not evidence for it.
        @unknown default: .notRegistered
        }
    }

    func register() throws {
        guard Self.isBundled else { throw LoginItemRefusal.noBundleToRegister }
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        guard Self.isBundled else { throw LoginItemRefusal.noBundleToRegister }
        try SMAppService.mainApp.unregister()
    }
}

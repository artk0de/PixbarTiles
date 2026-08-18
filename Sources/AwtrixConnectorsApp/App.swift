import AppKit
import AwtrixKit
import SwiftUI

@main
struct AwtrixConnectorsApp: App {
    /// Adopted for one reason: a `MenuBarExtra` scene has no termination hook,
    /// and quit is where the held banner gets taken off the clock. `AppDelegate`
    /// is the only place that can ask macOS for the time to do it.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(
                model: delegate.model,
                monitor: delegate.model.monitor,
                discovery: delegate.discovery
            )
        } label: {
            MenuBarGlyph(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The menu bar mark.
///
/// A view of its own rather than an `Image` written inline, because a Scene does
/// not observe anything: the glyph would be drawn once at launch and never
/// change. A view does observe, so this is where the online state is read.
private struct MenuBarGlyph: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Image(nsImage: AppGlyph.menuBar(lit: model.isDeviceOnline))
            // Belt and braces over `NSImage.isTemplate`. The flag is what
            // AppKit reads and it is set and tested; this is the SwiftUI-side
            // gate on the same question, and the failure it guards against —
            // black art painted on a dark menu bar — is invisible rather than
            // wrong-looking.
            .renderingMode(.template)
    }
}

enum AppGlyph {
    /// 30x18, not square: the menu bar caps an item's HEIGHT at the bar's, but
    /// not its width, and the glyph is a wide device. `Scripts/MakeIcon.swift`
    /// emits it at exactly this aspect — its device style widens the canvas to
    /// 30/18 of the height — so a size set here that disagrees is macOS
    /// stretching the art.
    static let menuBarSize = NSSize(width: 30, height: 18)

    /// The menu bar mark, as a template image so macOS recolours it for light,
    /// dark and the highlighted state. Offline is the same panel with nothing
    /// lit on it — two drawings rather than one plus a badge, because a badge
    /// does not survive being 18pt tall.
    ///
    /// `NSImage(named:)` reads `Contents/Resources`, which only exists once
    /// `Scripts/bundle.sh` has assembled the .app — under a bare `swift run`
    /// there is no bundle and this returns nil. The SF Symbol fallback is what
    /// keeps the unbundled binary usable rather than showing an empty slot, and
    /// it is what the tests exercise: they run outside a bundle too.
    static func menuBar(lit: Bool) -> NSImage {
        // Force-unwrapped deliberately. Both names ship with macOS 14, so a nil
        // here is a typo rather than a runtime condition — and the alternative
        // to failing loudly is a menu bar item with nothing in it, which looks
        // exactly like an app that did not launch.
        prepare(
            NSImage(named: lit ? "MenuBarIcon" : "MenuBarIconOffline")
                ?? NSImage(
                    systemSymbolName: lit ? "square.grid.3x2.fill" : "square.grid.3x2",
                    accessibilityDescription: "AWTRIX"
                )!
        )
    }

    /// Whatever was found, turned into what the menu bar expects.
    ///
    /// Its own function because the two sources arrive differently: a loose PNG
    /// out of `Contents/Resources` is not a template until it is said to be,
    /// while an SF Symbol already is. Written inline, the assignment would be
    /// invisible to anything running outside a bundle — which is every test, and
    /// which is exactly the case where forgetting it ships a black glyph onto a
    /// dark menu bar.
    static func prepare(_ image: NSImage) -> NSImage {
        image.isTemplate = true
        image.size = menuBarSize
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    /// Which AWTRIX clocks are advertising themselves on the network.
    ///
    /// Owned here rather than by `AppModel`, and that is a boundary rather than
    /// a filing decision. `AppModel` is the schedule, the device and what the
    /// user chose; a browse touches none of the three. Keeping it out means the
    /// thing the quit budget waits on — `AppModel.teardown` — has no browse in
    /// it to wait for, and the schedule cannot be disturbed by a device
    /// appearing on the network because there is nothing between them.
    let discovery: DeviceBrowser
    private let budget: QuitBudget

    override init() {
        self.model = .live()
        self.discovery = DeviceBrowser()
        self.budget = QuitBudget()
        super.init()
    }

    /// No default for `discovery`, deliberately. A default here is the real
    /// factory, and one line — a test calling `applicationDidFinishLaunching`
    /// on a delegate that took it — would put a live `NWBrowser` on the user's
    /// LAN from inside `swift test`. Naming it is one argument; noticing it
    /// afterwards is not.
    init(model: AppModel, budget: QuitBudget, discovery: DeviceBrowser) {
        self.model = model
        self.discovery = discovery
        self.budget = budget
        super.init()
    }

    /// Where the schedules start. Not in `AppModel.init`, so that building the
    /// model reaches neither the network nor the clock.
    func applicationDidFinishLaunching(_ notification: Notification) {
        model.start()
        discovery.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        beginTermination { sender.reply(toApplicationShouldTerminate: $0) }
    }

    /// Asks macOS to wait, tears down, and answers when it has settled.
    ///
    /// Split from `applicationShouldTerminate` so the waiting is testable
    /// without an `NSApplication` to reply to; what is left above is the one
    /// line that names the real replier.
    ///
    /// The answer is always yes, including when the budget expired. A no would
    /// cancel the quit and leave an app running with its schedules already
    /// cancelled and its monitor stopped — a worse state than the one the user
    /// asked for.
    func beginTermination(
        reply: @escaping @MainActor (Bool) -> Void
    ) -> NSApplication.TerminateReply {
        // Stopped before the budget is taken, never inside it. Cancelling a
        // browse is synchronous, puts nothing on the network and has nothing in
        // flight; the budget exists for one collaborator — the dismiss that
        // takes a held banner off the clock — and a settle window landing
        // inside it would be three more seconds of a quit with nothing left to
        // do.
        discovery.stop()
        Task {
            _ = await budget.settle { await self.model.teardown() }
            reply(true)
        }
        return .terminateLater
    }
}

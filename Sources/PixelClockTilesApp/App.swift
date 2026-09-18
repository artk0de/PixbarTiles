import AppKit
import PixelClockKit
// `AnyCancellable` is declared in Combine, which is also where the `@Published`
// this delegate subscribes to comes from.
import Combine
import SwiftUI

@main
struct PixelClockTilesApp: App {
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
            // Behind the panel rather than inside `MenuPanel`, because it is
            // not the panel's business which window it is on — it is the
            // delegate's, and this scene is where the two already meet.
            //
            // Taken out of hit testing, because an `NSView` is in it by
            // default: this one is laid out across the whole panel and answers
            // no click, so anywhere the panel does not draw a control it would
            // be what the click reached.
            .background(
                PanelWindowReader { delegate.panelMoved(to: $0) }
                    .allowsHitTesting(false)
            )
        } label: {
            MenuBarGlyph(model: delegate.model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Reports the window the panel was put on.
///
/// A view, because a view is the only thing that can answer: `MenuBarExtra` in
/// `.window` style builds the panel's window itself, on the first open, and
/// returns it to nobody — there is nothing for the delegate to hold at launch,
/// which is where its observer is set up. `NSView.viewDidMoveToWindow` fires
/// when the panel is put on screen, and `window` is then the panel's own.
///
/// Internal rather than private so a test can put one in a window of its own:
/// the mechanism is what the whole filter rests on, and a menu bar extra cannot
/// be opened from a test.
struct PanelWindowReader: NSViewRepresentable {
    /// Called with the window on every move, `nil` included. What a nil means is
    /// the reader's caller's business, not the reader's.
    let report: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView { WindowReportingView(report: report) }

    /// Nothing to update: the view draws nothing and reads nothing from SwiftUI.
    /// What it reports comes from AppKit moving it, not from the state changing.
    func updateNSView(_ view: NSView, context: Context) {}
}

/// The AppKit half of `PanelWindowReader`.
private final class WindowReportingView: NSView {
    private let report: (NSWindow?) -> Void

    init(report: @escaping (NSWindow?) -> Void) {
        self.report = report
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("never unarchived: this view exists only where SwiftUI builds it")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        report(window)
    }
}

/// The menu bar mark.
///
/// A view of its own rather than an `Image` written inline, because a Scene does
/// not observe anything: the glyph would be drawn once at launch and never
/// change. A view does observe, so this is where the online state is read.
/// Internal rather than private so a test can draw it, and what is worth
/// drawing is the pair `AppGlyph`'s own tests cannot say: that the view picks
/// its image FROM the device state rather than from a constant, and that it
/// picks the right way round. The second half is not free — a render can only
/// report that two pictures differ, which `lit: !model.isDeviceOnline`
/// satisfies — so the test compares each render against the render of the
/// drawing that state is supposed to select, not against the other state.
struct MenuBarGlyph: View {
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

    /// One drawing of the mark: where the bundle keeps it, and what to draw
    /// when there is no bundle.
    ///
    /// A value holding both names rather than two ternaries inside
    /// `menuBar(lit:)`, and the reason is the defect this type shipped with.
    /// With the names picked separately, the mapping from state to drawing had
    /// no single site and nothing could read it back: swapping either pair
    /// inverted the menu bar and left all 653 tests green, because every
    /// assertion in the suite said only that the two drawings DIFFER, which an
    /// inverted mapping satisfies exactly as well as a correct one. One value
    /// per state gives the direction somewhere to be asserted.
    struct Drawing: Equatable, Sendable {
        /// The PNG in `Contents/Resources`, once `Scripts/bundle.sh` has
        /// assembled the .app.
        let resource: String
        /// What an unbundled binary draws instead — which is every test, and a
        /// bare `swift run`.
        let symbol: String
    }

    /// The panel with its pixels lit: the clock is answering.
    static let litDrawing = Drawing(resource: "MenuBarIcon", symbol: "square.grid.3x2.fill")

    /// The same panel with nothing on it: the clock is not answering. Two
    /// drawings rather than one plus a badge, because a badge does not survive
    /// being 18pt tall — and an empty panel is also what an unreachable clock
    /// actually looks like across the room.
    static let unlitDrawing = Drawing(resource: "MenuBarIconOffline", symbol: "square.grid.3x2")

    /// Which drawing a reachability answer selects.
    ///
    /// A function of its own, and the ONLY place the two are told apart.
    /// Inverting this line is the one edit that inverts the menu bar, so it is
    /// the one thing a test has to be able to read — which is what it could not
    /// do while the choice lived inside two ternaries in the middle of an image
    /// lookup.
    static func drawing(lit: Bool) -> Drawing { lit ? litDrawing : unlitDrawing }

    /// The menu bar mark, as a template image so macOS recolours it for light,
    /// dark and the highlighted state.
    ///
    /// `NSImage(named:)` reads `Contents/Resources`, which only exists once
    /// `Scripts/bundle.sh` has assembled the .app — under a bare `swift run`
    /// there is no bundle and this returns nil. The SF Symbol fallback is what
    /// keeps the unbundled binary usable rather than showing an empty slot, and
    /// it is what the tests exercise: they run outside a bundle too.
    static func menuBar(lit: Bool) -> NSImage {
        let chosen = drawing(lit: lit)
        // Force-unwrapped deliberately. Both symbols ship with macOS 14, so a
        // nil here is a typo rather than a runtime condition — and the
        // alternative to failing loudly is a menu bar item with nothing in it,
        // which looks exactly like an app that did not launch.
        return prepare(
            NSImage(named: chosen.resource)
                ?? NSImage(
                    systemSymbolName: chosen.symbol, accessibilityDescription: "PixelClockTiles"
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
    /// Where the window's comings and goings are heard.
    ///
    /// Injected for the reason every other collaborator here is: a test that
    /// posts one into `.default` would be heard by every other model alive in
    /// the suite, and closing one window would shut another test's surface.
    private let notifications: NotificationCenter
    /// The subscriptions that hear the panel's window come and go.
    private var windowWatchers: [any NSObjectProtocol] = []
    /// The subscription that hears whether the clock is answering.
    private var reachability: AnyCancellable?
    /// Whether the panel is on screen.
    ///
    /// Kept here rather than asked of AppKit, because the question is "has this
    /// delegate been told the panel opened and not yet told it closed" — which
    /// is what the browse is allowed to depend on. `NSWindow.isKeyWindow` would
    /// answer about a window that may not exist yet.
    private var panelIsOpen = false
    /// Whether a browse has been asked for.
    ///
    /// What this delegate INTENDED, not what the browser is doing — the browser
    /// owns that, and it already makes a late report from a cancelled browse
    /// harmless. Kept so that the same answer arriving twice, which is what a
    /// poll every minute produces, costs nothing at all.
    private var isBrowsing = false
    /// The window the panel is on, once it is on one.
    ///
    /// Weak, because the window is SwiftUI's rather than this type's: holding it
    /// would keep an ordered-out panel alive past the point its owner is done
    /// with it. What that costs is one event — a window released between the
    /// resign and the block that hears it takes its own close with it — and the
    /// alternative costs a window nobody can see, kept by a reference nobody
    /// reads.
    private weak var panelWindow: NSWindow?

    override init() {
        // First, before `.live()`: everything it builds reads the defaults, and
        // on the first launch after the rename those are still in the old domain.
        DefaultsCarryOver.run(
            from: DefaultsCarryOver.previousDomain,
            into: Bundle.main.bundleIdentifier,
            through: .standard
        )
        self.model = .live()
        self.discovery = DeviceBrowser()
        self.budget = QuitBudget()
        self.notifications = .default
        super.init()
    }

    /// No default for `discovery`, deliberately. A default here is the real
    /// factory, and one line — a test calling `applicationDidFinishLaunching`
    /// on a delegate that took it — would put a live `NWBrowser` on the user's
    /// LAN from inside `swift test`. Naming it is one argument; noticing it
    /// afterwards is not.
    init(
        model: AppModel,
        budget: QuitBudget,
        discovery: DeviceBrowser,
        notifications: NotificationCenter = .default
    ) {
        self.model = model
        self.discovery = discovery
        self.budget = budget
        self.notifications = notifications
        super.init()
    }

    /// Where the schedules start. Not in `AppModel.init`, so that building the
    /// model reaches neither the network nor the clock.
    ///
    /// No browse is started here, and its absence is the point. This used to
    /// call `discovery.start()` and nothing ever called `stop()`, so a Bonjour
    /// browse ran for the whole life of the process — including every minute
    /// the configured address was answering perfectly well. Multicast is the
    /// one kind of traffic that costs a Wi-Fi network rather than a link: every
    /// frame goes to every client on every band at the lowest basic rate, and
    /// wakes every power-saving device on it. The clock is one of those, and
    /// the app already knows the address it talks to. What decides a browse now
    /// is `reconsiderBrowsing`.
    ///
    /// The clock's answers are subscribed to BEFORE the schedules start,
    /// because `model.start()` fires the first poll and that answer is what a
    /// panel opened seconds later has to be right about.
    func applicationDidFinishLaunching(_ notification: Notification) {
        watchWhetherTheClockAnswers()
        model.start()
        watchThePanelsWindow()
    }

    /// Starts or stops the browse, from the two things that decide it.
    ///
    /// One place rather than a decision at each edge. The edges arrive in any
    /// order — a panel opened onto a clock that is already down, a clock that
    /// comes back while the panel is open — and three call sites each making up
    /// their own mind is three chances for them to disagree about whether a
    /// browse is running.
    ///
    /// **What stops a browse:** the panel closing, or the clock answering.
    /// **What starts one again:** the panel opening while the clock is not
    /// answering. There is no state in which a browse outlives both, which is
    /// what keeps an `NWBrowser` off the network for the whole of a working
    /// installation's life. Nothing else is a bound worth having: an
    /// unreachable-for-N-polls timer was the alternative and it is a browse
    /// that runs for as long as the outage does, which for a clock left
    /// unplugged over a holiday is the defect again with an extra counter.
    ///
    /// Two conditions and no third. "Is an address configured" is deliberately
    /// not asked: `AppModel.live()` falls back to `defaultDeviceHost` when the
    /// defaults key is unset, so an unconfigured app is pointed at a guess —
    /// and a guess nothing answers at is already a clock that is not answering.
    /// A separate check would be a second way to say the same thing, with its
    /// own way of being wrong.
    private func reconsiderBrowsing(clockIsAnswering: Bool) {
        // A panel that is not on screen has nowhere to show what a browse
        // found: the discovery row is drawn there and nowhere else.
        let wanted = panelIsOpen && clockIsAnswering == false
        guard wanted != isBrowsing else { return }
        isBrowsing = wanted
        if wanted { discovery.start() } else { discovery.stop() }
    }

    /// Hears every reachability answer, because one of them is a reason to stop
    /// looking.
    ///
    /// The value is passed down rather than read back off the model: `@Published`
    /// publishes in `willSet`, so at this point `model.isDeviceOnline` is still
    /// the previous answer and the one that matters is the argument.
    ///
    /// `assumeIsolated` for the reason the window observer below uses it — the
    /// mutation that publishes this happens on the main actor, so delivery does
    /// too, and the compiler cannot see that through Combine.
    private func watchWhetherTheClockAnswers() {
        reachability = model.$isDeviceOnline.sink { [weak self] answering in
            MainActor.assumeIsolated {
                self?.reconsiderBrowsing(clockIsAnswering: answering)
            }
        }
    }

    /// The panel is on screen: browse if there is anything to look for.
    private func panelDidOpen() {
        panelIsOpen = true
        reconsiderBrowsing(clockIsAnswering: model.isDeviceOnline)
    }

    /// The panel has gone: whatever the browse was for, nobody can read it now.
    private func panelDidClose() {
        panelIsOpen = false
        reconsiderBrowsing(clockIsAnswering: model.isDeviceOnline)
    }

    /// Told which window the panel was put on, by the panel itself.
    ///
    /// Learned rather than held from the start, because there is nothing to hold
    /// at launch: `MenuBarExtra` in `.window` style builds the window on the
    /// first open and hands it to nobody. A view inside the panel is the one
    /// thing that can see it, which is what `PanelWindowReader` is for.
    ///
    /// A nil is not recorded, deliberately. Being taken off its window is part
    /// of how the panel goes away, and the resign that says so is already in
    /// flight by then — forgetting the window here would drop the very close it
    /// describes.
    ///
    /// Learning the window IS the first open, and that is why the browse is
    /// reconsidered here rather than only on `didBecomeKey` below. The window
    /// is built when the panel is first shown and then reused, so the key
    /// notification covers every open after this one and cannot cover this one:
    /// it has to know which window is the panel's, and this is where that is
    /// learned. Whichever of the two arrives first, the other costs nothing —
    /// `reconsiderBrowsing` compares against what it has already asked for.
    func panelMoved(to window: NSWindow?) {
        guard let window else { return }
        panelWindow = window
        panelDidOpen()
    }

    /// Hears the panel's window come and go: the menu goes back on the panel
    /// when it goes, and the browse lives between the two.
    ///
    /// Losing key IS how a menu bar extra closes. Its window is dismissed by
    /// the click that lands somewhere else, and it is ordered out rather than
    /// closed — so `NSWindow.willClose` never arrives, and SwiftUI's own
    /// `onDisappear` is worse than silent: measured here, it fires when a
    /// hosting view is torn down, which every throwaway render does, and not
    /// when a window is ordered out at all.
    ///
    /// Becoming key is the same fact read the other way, and it is why the open
    /// side is heard here rather than from a SwiftUI `.onAppear`: a window that
    /// resigns key on every close became key on every open to have anything to
    /// resign. The close half is already shipped and works, so the open half
    /// cannot be missing. `.onAppear` would have been the alternative — it is
    /// what `AppModel.refreshOnPanelOpen` rides — but it fires per appearance
    /// rather than per open, it lives in a view that cannot reach this
    /// delegate, and it would leave the two ends of one browse in two frameworks.
    ///
    /// Here rather than in `AppModel`, for the reason `applicationDidFinish
    /// Launching` is: translating what AppKit says into what the model does is
    /// this type's whole job, and the model has no window to watch.
    ///
    /// Filtered to the panel's own window, because this app has more than one.
    /// `BatteryAlert` raises an `NSAlert` and an authorization prompt is a
    /// window too; each of them takes key when it appears and resigns it when it
    /// is dismissed, and heard unfiltered, either one silently shut whichever
    /// surface the user had open. A window that is not the panel's going quiet
    /// says nothing about the panel.
    ///
    /// `NSApplication.didResignActiveNotification` was the alternative, and it
    /// is rejected for answering a different question: the app can stay active
    /// while the panel goes away — clicking the menu bar item a second time
    /// dismisses it with no other app taking over — and putting the menu back on
    /// the panel is precisely what would then stop happening.
    ///
    /// Subscriptions that compare, rather than ones re-registered on
    /// `object: panelWindow` whenever the panel gets a window. The window does
    /// not exist here, at launch; a re-registering observer would have to be
    /// right about tearing the old one down as well as putting the new one up,
    /// and these only have to be right about which window they are looking at.
    private func watchThePanelsWindow() {
        guard windowWatchers.isEmpty else { return }
        windowWatchers = [
            whenThePanelsWindow(NSWindow.didBecomeKeyNotification) { $0.panelDidOpen() },
            whenThePanelsWindow(NSWindow.didResignKeyNotification) { delegate in
                delegate.model.windowDidClose()
                delegate.panelDidClose()
            },
        ]
    }

    /// One observer of `name`, deaf to every window that is not the panel's.
    ///
    /// The filter written once rather than once per notification: it is the
    /// half that was got wrong before, and two copies of it is two places for
    /// the next one to be got wrong in.
    private func whenThePanelsWindow(
        _ name: Notification.Name, then act: @escaping @MainActor (AppDelegate) -> Void
    ) -> any NSObjectProtocol {
        notifications.addObserver(forName: name, object: nil, queue: .main) {
            [weak self] notification in
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                // Both halves named, rather than `window === self?.panelWindow`:
                // two nils are identical, so an unrecognisable notification
                // arriving before the panel has ever been opened would read as
                // the panel's own.
                guard let self, let window, window === self.panelWindow else { return }
                act(self)
            }
        }
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
        //
        // Unconditional, rather than routed through `reconsiderBrowsing`: quit
        // is the one moment that does not care what this delegate believes it
        // asked for.
        discovery.stop()
        panelIsOpen = false
        isBrowsing = false
        // Both wires cut, for the same reason: what is left of this app is a
        // teardown, and neither a window taking key nor a last reading landing
        // is a reason to put a browse back on the network during it.
        for watcher in windowWatchers { notifications.removeObserver(watcher) }
        windowWatchers = []
        reachability = nil
        Task {
            _ = await budget.settle { await self.model.teardown() }
            reply(true)
        }
        return .terminateLater
    }
}

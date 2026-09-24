import AppKit
import PixbarKit
// `AnyCancellable` is declared in Combine, which is also where the `@Published`
// this delegate subscribes to comes from.
import Combine
import SwiftUI

@main
struct PixbarTilesApp: App {
    /// Adopted for one reason: a `MenuBarExtra` scene has no termination hook,
    /// and quit is where the held banner gets taken off the clock. `AppDelegate`
    /// is the only place that can ask macOS for the time to do it.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarContent(
                model: delegate.model,
                panel: delegate.panelModel,
                settings: delegate.settingsModel,
                pin: delegate.panelPin,
                windowMoved: { delegate.panelMoved(to: $0) }
            )
        } label: {
            MenuBarGlyph(model: delegate.model)
        }
        .menuBarExtraStyle(.window)

        // The panel pinned to a window of its own. Floating while the app is
        // in the background, because a pinned panel that a text editor can
        // cover is a pin that did not take; normal while it is active, so the
        // app's own Settings can come in front of it
        // (`AppDelegate.levelThePinnedWindow`).
        Window("PixbarTiles", id: PinnedPanelWindow.id) {
            PinnedPanelWindow(
                model: delegate.model,
                panel: delegate.panelModel,
                settings: delegate.settingsModel,
                pin: delegate.panelPin
            )
        }
        .windowResizability(.contentSize)
        // Present at launch only when the pin was left in. Suppressed by
        // default an app would otherwise open a panel window nobody asked for;
        // suppressed ALWAYS, an app quit while pinned would come back saying
        // "pinned to its own window" with no window anywhere — a state the
        // user has to click their way out of.
        .defaultLaunchBehavior(delegate.panelPin.isPinned ? .presented : .suppressed)

        // The real Settings window — ⌘, opens it, the window is restorable,
        // and the panel's gear and every clock's gear aim it before opening.
        Settings {
            SettingsRoot(
                model: delegate.model,
                settings: delegate.settingsModel,
                discovery: delegate.discovery
            )
        }

        // The tile settings window: ONE window whose content swaps — the
        // second row asking re-targets the first's window, because ten open
        // tile windows is not a state worth supporting.
        Window("Tile Settings", id: "tile-settings") {
            TileSettingsWindow(
                model: delegate.model,
                settings: delegate.tileSettingsModel
            )
        }
        .windowResizability(.contentSize)
        // Opened at a size the content is comfortable at rather than at its
        // floor. Without one, macOS starts every `Window` scene at the
        // smallest size its content admits to, which for a two-column window
        // is both columns at their minimum and nothing to spare.
        .defaultSize(width: 720, height: 420)

        // The tile store: one window, re-aimed by whichever clock's gear
        // opened it. Choosing a tile is reading — categories and cards, not
        // a menu row.
        Window("Tile Store", id: "tile-store") {
            TileStoreWindow(store: delegate.storeModel)
        }
        .windowResizability(.contentSize)
        // Wide enough for three cards on the adaptive grid: at the floor it
        // is two, and a store whose shelf shows two things reads as a store
        // with two things on it.
        .defaultSize(width: 720, height: 480)

        // One clock's own settings: its tiles as cards, and the clock
        // itself. The facade carries the aim; a second gear's click
        // re-targets this one window.
        Window("Clock Settings", id: "clock-settings") {
            ClockSettingsWindow(
                settings: delegate.settingsModel,
                model: delegate.model,
                store: delegate.storeModel
            )
        }
        // The same resize rule as its two siblings. It was the one window
        // without it, so the three windows the app opens from a gear each
        // behaved differently when dragged.
        .windowResizability(.contentSize)
        .defaultSize(width: 560, height: 460)
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
        // No rendering mode on purpose. A template would let macOS tint the
        // ink for the bar, but it would tint the offline state's red square
        // with it — so the glyph is drawn per appearance instead.
        Image(nsImage: AppGlyph.menuBar(for: AppGlyph.state(
            hasNoClocks: model.hasNoClocks,
            isDeviceOnline: model.isDeviceOnline
        )))
    }
}

enum AppGlyph {
    /// 28x18, not square: the glyph's canvas in points, which is what
    /// `Scripts/MakeIcon.swift` emits at every scale — the menu bar caps an
    /// item's HEIGHT at the bar's, not its width. Read off `PixbarGlyph` so a
    /// size set here cannot disagree with the art and have macOS stretch it.
    static let menuBarSize = NSSize(width: PixbarGlyph.width, height: PixbarGlyph.height)

    /// Which of the two inks the bar is asking for.
    enum BarAppearance {
        case dark
        case light

        /// Read from the appearance AppKit is drawing WITH, not the app's or
        /// the system's: a status item follows the menu bar, which on recent
        /// macOS can follow the wallpaper and differ from both. `bestMatch`
        /// against the two concrete names IS the resolution — a light bar
        /// answers aqua, a dark one darkAqua — and inside a drawing handler
        /// `currentDrawing()` is the drawing view's own effective appearance.
        static func of(_ appearance: NSAppearance) -> BarAppearance {
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
        }
    }

    /// One drawing of the mark: where the bundle keeps each appearance's
    /// variant, and what to draw when there is no bundle.
    ///
    /// A value holding all three names rather than conditionals inside
    /// `menuBar(lit:)`, and the reason is the defect this type shipped with.
    /// With the names picked separately, the mapping from state to drawing had
    /// no single site and nothing could read it back: swapping either pair
    /// inverted the menu bar and left the whole suite green, because every
    /// assertion in the suite said only that the two drawings DIFFER, which an
    /// inverted mapping satisfies exactly as well as a correct one. One value
    /// per state gives the direction somewhere to be asserted.
    struct Drawing: Equatable, Sendable {
        /// The PNG for a dark menu bar, in `Contents/Resources`, once
        /// `Scripts/bundle.sh` has assembled the .app.
        let darkResource: String
        /// The PNG for a light menu bar.
        let lightResource: String
        /// What an unbundled binary draws instead — which is every test, and a
        /// bare `swift run`. Symbols have no appearance variants; the shape is
        /// what the fallback is for.
        let symbol: String

        /// The variant drawn FOR the bar being drawn — the one place
        /// appearance and state meet.
        func resource(for appearance: BarAppearance) -> String {
            appearance == .dark ? darkResource : lightResource
        }
    }

    /// The screen lit: the case filled, the P and a hairline bezel knocked
    /// out of it. A clock is answering.
    static let litDrawing = Drawing(
        darkResource: "pixbar-glyph-dark-online",
        lightResource: "pixbar-glyph-light-online",
        symbol: "square.grid.3x2.fill"
    )

    /// The screen out: the case an outline, the P a half-point contour, a
    /// red square on the corner. No clock is answering. The outline is what
    /// still reads at 18pt; the red square is what says "fault" when it does.
    static let unlitDrawing = Drawing(
        darkResource: "pixbar-glyph-dark-offline",
        lightResource: "pixbar-glyph-light-offline",
        symbol: "square.grid.3x2"
    )

    /// The case with a blank screen: no clock has ever been configured, so
    /// there is nothing on it to show — no P, no badge, the case and feet
    /// whole.
    static let emptyDrawing = Drawing(
        darkResource: "pixbar-glyph-dark-empty",
        lightResource: "pixbar-glyph-light-empty",
        symbol: "rectangle"
    )

    /// Which of the three drawings the bar is showing.
    enum State: Equatable {
        case online, offline, empty
    }

    /// The state a glyph draws, from the two facts the model holds, decided
    /// once rather than at each caller. With no clocks configured the
    /// reachability question has nothing to be about — there is no clock to
    /// be answering or not — so the empty screen wins over both answers.
    static func state(hasNoClocks: Bool, isDeviceOnline: Bool) -> State {
        if hasNoClocks { return .empty }
        return isDeviceOnline ? .online : .offline
    }

    /// Which drawing a state selects.
    ///
    /// A function of its own, and the ONLY place the three are told apart.
    /// Inverting this table is the one edit that inverts the menu bar, so it
    /// is the one thing a test has to be able to read — which is what it could
    /// not do while the choice lived inside conditionals in the middle of an
    /// image lookup.
    static func drawing(for state: State) -> Drawing {
        switch state {
        case .online: litDrawing
        case .offline: unlitDrawing
        case .empty: emptyDrawing
        }
    }

    /// The menu bar mark: an image whose drawing handler picks the variant for
    /// whichever bar is drawing it, so the dark menu bar gets white ink and
    /// the light one black.
    ///
    /// A drawing handler rather than a resolved `NSImage`, and that is about
    /// time, not size: the bar's appearance is only known when AppKit draws,
    /// and it can change while the app runs. `cacheMode = .never` is what
    /// keeps nothing standing between AppKit's redraw and the handler, so a
    /// theme or wallpaper flip re-asks and the status item keeps up without
    /// any hook of ours.
    ///
    /// `NSImage(named:)` reads `Contents/Resources`, which only exists once
    /// `Scripts/bundle.sh` has assembled the .app — under a bare `swift run`
    /// there is no bundle and this returns nil. The SF Symbol fallback is what
    /// keeps the unbundled binary usable rather than showing an empty slot, and
    /// it is what the tests exercise: they run outside a bundle too.
    static func menuBar(for state: State) -> NSImage {
        let chosen = drawing(for: state)
        let image = NSImage(size: menuBarSize, flipped: false) { rect in
            let appearance = BarAppearance.of(NSAppearance.currentDrawing())
            // Force-unwrapped deliberately. The symbol ships with macOS 14, so
            // a nil here is a typo rather than a runtime condition — and the
            // alternative to failing loudly is a menu bar item with nothing in
            // it, which looks exactly like an app that did not launch.
            (NSImage(named: chosen.resource(for: appearance))
                ?? NSImage(
                    systemSymbolName: chosen.symbol, accessibilityDescription: "PixbarTiles"
                )!)
                .draw(in: rect)
            return true
        }
        // The default for a built image, said out loud because the old glyph's
        // whole preparation was the opposite: a template would discard the
        // offline red this glyph exists to carry.
        image.isTemplate = false
        image.cacheMode = .never
        return image
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model: AppModel
    /// The panel's facade, built once here at the root where the model is
    /// built, so its subscription lives as long as the model does — the
    /// panel's scene is transient, and a facade owned there would resubscribe
    /// on every open.
    let panelModel: PanelModel
    /// The Settings window's facade, for the same reason: the window's scene
    /// is rebuilt freely, and the tab the user left it on belongs to state
    /// that outlives a rebuild.
    let settingsModel: SettingsModel
    /// The tile settings window's facade — the draft and the debounced
    /// preview — which likewise outlives a scene rebuild, and whose
    /// subscription is what follows the tile the panel aimed it at.
    let tileSettingsModel: TileSettingsModel
    /// The store's facade, aimed by the clock gears. One store, one aim at
    /// a time: the cards answer about the clock that asked.
    let storeModel: StoreModel
    /// Whether the panel is pinned to a window of its own. Owned here because
    /// BOTH scenes read it — the menu bar item to decide what it shows, and
    /// the window to know it should be there at all.
    let panelPin = PanelPin()
    /// Which clocks are advertising themselves on the network — both models:
    /// the AWTRIX browse merged with the TC002 broadcasts.
    ///
    /// Owned here rather than by `AppModel`, and that is a boundary rather than
    /// a filing decision. `AppModel` is the schedule, the device and what the
    /// user chose; a browse touches none of the three. Keeping it out means the
    /// thing the quit budget waits on — `AppModel.teardown` — has no browse in
    /// it to wait for, and the schedule cannot be disturbed by a device
    /// appearing on the network because there is nothing between them.
    let discovery: ClockDiscovery
    /// Where the window's comings and goings are heard.
    ///
    /// Injected for the reason every other collaborator here is: a test that
    /// posts one into `.default` would be heard by every other model alive in
    /// the suite, and closing one window would shut another test's surface.
    private let notifications: NotificationCenter
    /// The subscriptions that hear the panel's window come and go.
    private var windowWatchers: [any NSObjectProtocol] = []
    /// The popover's drag, followed until it is let go (`PanelDrag`).
    private var panelDrag = PanelDrag()
    /// Asks whether the drag is over; runs only while one is under way.
    private var panelDragRelease: Timer?
    /// The subscription that hears whether the clock is answering.
    private var reachability: AnyCancellable?
    /// The subscription that hears the Clocks tab come and go.
    private var clocksSectionWatch: AnyCancellable?
    /// Whether the panel is on screen.
    ///
    /// Kept here rather than asked of AppKit, because the question is "has this
    /// delegate been told the panel opened and not yet told it closed" — which
    /// is what the browse is allowed to depend on. `NSWindow.isKeyWindow` would
    /// answer about a window that may not exist yet.
    private var panelIsOpen = false
    /// The two halves of the browsing rule, as the last event left them.
    ///
    /// Mirrors rather than reads: `@Published` delivers in `willSet`, so a
    /// subscriber that read back off the model would see the previous answer.
    /// Each subscription hands its own value down and stores it here; a read
    /// at `panelDidOpen` time is current, because that call is not inside a
    /// publisher's delivery.
    private var clockIsAnswering = false
    /// Whether the Settings window's Clocks tab is on screen — the fact the
    /// model now publishes, mirrored here the same way the answer is.
    private var clocksSectionVisible = false
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
        // on the first launch after a rename those are still in an old domain.
        DefaultsCarryOver.run(into: Bundle.main.bundleIdentifier, through: .standard)
        // Also before `.live()`: it opens the secret store, and on the first
        // launch as PixbarTiles `secrets.enc` is still in the PixelClockTiles
        // folder. A failed move leaves that folder where it was; the next
        // launch tries again.
        _ = try? SupportFolder.carryOver()
        self.model = .live()
        self.panelModel = PanelModel(model: model)
        self.settingsModel = SettingsModel(model: model)
        self.tileSettingsModel = TileSettingsModel(model: model, naming: CoreLocationPlaceNaming())
        self.storeModel = StoreModel(model: model)
        self.discovery = ClockDiscovery(browse: DeviceBrowser())
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
        discovery: ClockDiscovery,
        notifications: NotificationCenter = .default
    ) {
        self.model = model
        self.panelModel = PanelModel(model: model)
        self.settingsModel = SettingsModel(model: model)
        self.tileSettingsModel = TileSettingsModel(model: model, naming: CoreLocationPlaceNaming())
        self.storeModel = StoreModel(model: model)
        self.discovery = discovery
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
        // An update may ship a different hook. The one Claude Code runs is
        // brought in line with it here, and only while connected. A failure is
        // left for the next launch: the old hook still stores documents.
        try? ClaudeCodePaths.shippedLink?.refreshHookIfConnected()
    }

    /// Starts or stops the browse, from the two things that decide it.
    ///
    /// One place rather than a decision at each edge. The edges arrive in any
    /// order — a panel opened onto a clock that is already down, a clock that
    /// comes back while the panel is open, the Add clock sheet opening onto a
    /// clock that answers — and any more call sites each making up their own
    /// mind is more chances for them to disagree about whether a browse is
    /// running.
    ///
    /// **What starts a browse:** the panel opening while the clock is not
    /// answering, or the Clocks tab coming on screen — the tab is where a
    /// clock seen advertising itself becomes a configured one, and a tab
    /// open on an installation whose clock answers perfectly well still
    /// needs the list fed. **What stops one:** the panel closing, the clock
    /// answering, or the tab going away. There is no state in which a browse
    /// outlives every reason for it, which is what keeps an `NWBrowser` off
    /// the network for the whole of a working installation's life. Nothing
    /// else is a bound worth having: an unreachable-for-N-polls timer was the
    /// alternative and it is a browse that runs for as long as the outage
    /// does, which for a clock left unplugged over a holiday is the defect
    /// again with an extra counter.
    ///
    /// Two conditions and no third. "Is an address configured" is deliberately
    /// not asked: `AppModel.live()` falls back to `defaultDeviceHost` when the
    /// defaults key is unset, so an unconfigured app is pointed at a guess —
    /// and a guess nothing answers at is already a clock that is not answering.
    /// A separate check would be a second way to say the same thing, with its
    /// own way of being wrong.
    private func reconsiderBrowsing() {
        // A Clocks tab on screen is a reason of its own — the window holds
        // the list, whatever the panel is doing. The panel arm is the outage
        // arm: open, and the clock not answering, is when the user is
        // looking at a panel that wants the list.
        let wanted = clocksSectionVisible || (panelIsOpen && clockIsAnswering == false)
        guard wanted != isBrowsing else { return }
        isBrowsing = wanted
        if wanted { discovery.start() } else { discovery.stop() }
    }

    /// Hears every reachability answer, because one of them is a reason to stop
    /// looking — and hears the sheet, because it is a reason to start.
    ///
    /// The values are passed down rather than read back off the model:
    /// `@Published` publishes in `willSet`, so at this point the model's own
    /// stored answers are still the previous ones and the ones that matter are
    /// the arguments.
    ///
    /// `assumeIsolated` for the reason the window observer below uses it — the
    /// mutation that publishes this happens on the main actor, so delivery does
    /// too, and the compiler cannot see that through Combine.
    private func watchWhetherTheClockAnswers() {
        reachability = model.$isDeviceOnline.sink { [weak self] answering in
            MainActor.assumeIsolated {
                self?.clockIsAnswering = answering
                self?.reconsiderBrowsing()
            }
        }
        clocksSectionWatch = model.$clocksSectionVisible.sink { [weak self] visible in
            MainActor.assumeIsolated {
                self?.clocksSectionVisible = visible
                self?.reconsiderBrowsing()
            }
        }
    }

    /// The panel is on screen: browse if there is anything to look for.
    private func panelDidOpen() {
        // Pinned, the menu bar item is only the way back to the window: the
        // click focuses it, and the popover — nothing to see in it — goes as
        // the focus leaves.
        if panelPin.isPinned, let pinned = WindowFocus.pinnedWindow(among: NSApp.windows) {
            // The popover off the screen first: left on a full-screen app's
            // Space, it holds the app there and the Space never changes.
            panelWindow?.orderOut(nil)
            WindowFocus.bringOnly(pinned)
            return
        }
        panelIsOpen = true
        // One full repaint per open, because the window is shared by three
        // surfaces of three different heights: the settings (615) leaves the
        // panel (198) with most of the window it does not use, and AppKit's
        // dirty-rect redraw only repaints what CHANGED — the band the last
        // surface left is exactly what did not change. Flagging the whole
        // content view is the cheap way to start every open from clean glass.
        panelWindow?.contentView?.needsDisplay = true
        reconsiderBrowsing()
    }

    /// The panel has gone: whatever the browse was for, nobody can read it now.
    private func panelDidClose() {
        panelIsOpen = false
        reconsiderBrowsing()
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
        // Deliberately no touch of the window's LAYER here. A runtime
        // `wantsLayer` on the panel's contentView took the whole window's
        // buttons dead — Quit, the gear, every row control — because the
        // SwiftUI host owns its layer and event routing through it, and an
        // AppKit-forced layer under a `MenuBarExtra` window desynchronizes
        // the two. The ghost defenses live in `panelDidOpen` instead: a full
        // repaint per open, which changes no view structure at all.
        //
        // The window's BACKGROUND is another matter, and it is what makes
        // Liquid Glass glass: the `glassEffect` on the panel's content
        // refracts whatever is behind the window, and behind an opaque
        // window background there is nothing — the material rendered as a
        // dark slab. Clear background, once; it is the window's own and the
        // host does not fight AppKit over it.
        window.clearBackgroundForGlass()
        AppLog.panel.info(
            """
            panel window \(String(describing: type(of: window)), privacy: .public) \
            movable=\(window.isMovable, privacy: .public) \
            byBackground=\(window.isMovableByWindowBackground, privacy: .public) \
            style=\(window.styleMask.rawValue, privacy: .public) \
            level=\(window.level.rawValue, privacy: .public)
            """
        )
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
            whenThePanelsWindow(NSWindow.didMoveNotification) { $0.panelWasDragged() },
            notifications.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.levelThePinnedWindow() } },
            notifications.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.levelThePinnedWindow() } },
        ]
    }

    /// The pinned window floats over other apps and not over this one's own
    /// windows (`WindowFocus.pinnedLevel`), re-levelled whenever the app
    /// comes to the front or leaves it.
    func levelThePinnedWindow() {
        WindowFocus.pinnedWindow(among: NSApp.windows)?.level =
            WindowFocus.pinnedLevel(appIsActive: NSApp.isActive)
    }

    /// The panel's window moved. If a mouse button is DOWN it was the user
    /// dragging it, and a panel dragged off the menu bar is a panel pinned —
    /// the way SoundSource's own pin flips — where the drag is let go.
    ///
    /// The held button is the whole discriminator, and it is not a heuristic:
    /// macOS places this window under the menu bar item on every open, and
    /// that placement posts the same notification with no button down. Without
    /// the guard the panel would pin itself the first time it was ever shown.
    private func panelWasDragged() {
        AppLog.panel.info(
            """
            panel moved: pinned=\(self.panelPin.isPinned, privacy: .public) \
            buttons=\(NSEvent.pressedMouseButtons, privacy: .public) \
            frame=\(String(describing: self.panelWindow?.frame), privacy: .public)
            """
        )
        guard let frame = panelWindow?.frame else { return }
        let following = panelDrag.moved(
            topLeft: CGPoint(x: frame.minX, y: frame.maxY),
            buttonDown: NSEvent.pressedMouseButtons != 0,
            pinned: panelPin.isPinned
        )
        guard following, panelDragRelease == nil else { return }
        panelDragRelease = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelDragMayHaveEnded() }
        }
    }

    /// The drag is over when no button is down: pin where it was let go.
    private func panelDragMayHaveEnded() {
        guard let origin = panelDrag.released(buttonDown: NSEvent.pressedMouseButtons != 0) else { return }
        panelDragRelease?.invalidate()
        panelDragRelease = nil
        AppLog.panel.info("panel dragged off the menu bar — pinning")
        panelPin.detach(at: origin)
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
        // Instant, by the user's call (2026-09-21). The teardown wait it
        // replaced spent up to the transport's own fifteen seconds seeing a
        // held banner's dismiss through — against a clock that cannot answer,
        // fifteen seconds of a panel reading as broken. What an instant exit
        // costs is left to what already carries it: a banner outlives the
        // process on the clock that was showing it, and a borrowed device
        // state waits for the next launch to give it back — the durable
        // borrow record and launch-time restore are exactly that machinery.
        // `AppModel.teardown` stays what the tests use to stop the loops; a
        // quit no longer waits on it.
        .terminateNow
    }
}

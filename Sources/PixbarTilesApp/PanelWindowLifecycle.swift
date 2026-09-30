import AppKit
import PixbarKit

/// The panel's window as AppKit reports it: when it opens and closes, where it
/// is dragged (a drag off the menu bar pins it), and the level of the pinned
/// window as the app comes and goes.
///
/// Translating what AppKit says into what the app does is this type's whole
/// job; the model has no window to watch, and the browse rule only needs to
/// hear "open" and "closed".
@MainActor
final class PanelWindowLifecycle {
    private let model: AppModel
    private let pin: PanelPin
    private let browsingPolicy: ClockBrowsingPolicy
    /// Where the window's comings and goings are heard.
    ///
    /// Injected: a test that posts one into `.default` would be heard by every
    /// other model alive in the suite, and closing one window would shut
    /// another test's surface.
    private let notifications: NotificationCenter
    /// The subscriptions that hear the panel's window come and go.
    private var windowWatchers: [any NSObjectProtocol] = []
    /// The popover's drag, followed until it is let go (`PanelDrag`).
    private var panelDrag = PanelDrag()
    /// Asks whether the drag is over; runs only while one is under way.
    private var panelDragRelease: Timer?
    /// The window the panel is on, once it is on one.
    ///
    /// Weak, because the window is SwiftUI's rather than this type's: holding it
    /// would keep an ordered-out panel alive past the point its owner is done
    /// with it. What that costs is one event — a window released between the
    /// resign and the block that hears it takes its own close with it — and the
    /// alternative costs a window nobody can see, kept by a reference nobody
    /// reads.
    private weak var panelWindow: NSWindow?

    init(model: AppModel, pin: PanelPin, browsingPolicy: ClockBrowsingPolicy, notifications: NotificationCenter) {
        self.model = model
        self.pin = pin
        self.browsingPolicy = browsingPolicy
        self.notifications = notifications
    }

    /// The panel is on screen: browse if there is anything to look for.
    private func panelDidOpen() {
        // Pinned, the menu bar item is only the way back to the window: the
        // click focuses it, and the popover — nothing to see in it — goes as
        // the focus leaves.
        if pin.isPinned, let pinned = WindowFocus.pinnedWindow(among: NSApp.windows) {
            // The popover off the screen first: left on a full-screen app's
            // Space, it holds the app there and the Space never changes.
            panelWindow?.orderOut(nil)
            WindowFocus.bringOnly(pinned)
            return
        }
        // One full repaint per open, because the window is shared by three
        // surfaces of three different heights: the settings (615) leaves the
        // panel (198) with most of the window it does not use, and AppKit's
        // dirty-rect redraw only repaints what CHANGED — the band the last
        // surface left is exactly what did not change. Flagging the whole
        // content view is the cheap way to start every open from clean glass.
        panelWindow?.contentView?.needsDisplay = true
        browsingPolicy.panelOpened()
    }

    /// The panel has gone: whatever the browse was for, nobody can read it now.
    private func panelDidClose() {
        browsingPolicy.panelClosed()
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
    /// `ClockBrowsingPolicy` compares against what it has already asked for.
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
    /// rather than per open, it lives in a view that cannot reach this type,
    /// and it would leave the two ends of one browse in two frameworks.
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
    func watch() {
        guard windowWatchers.isEmpty else { return }
        windowWatchers = [
            whenThePanelsWindow(NSWindow.didBecomeKeyNotification) { $0.panelDidOpen() },
            whenThePanelsWindow(NSWindow.didResignKeyNotification) { lifecycle in
                lifecycle.model.windowDidClose()
                lifecycle.panelDidClose()
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
            panel moved: pinned=\(self.pin.isPinned, privacy: .public) \
            buttons=\(NSEvent.pressedMouseButtons, privacy: .public) \
            frame=\(String(describing: self.panelWindow?.frame), privacy: .public)
            """
        )
        guard let frame = panelWindow?.frame else { return }
        let following = panelDrag.moved(
            topLeft: CGPoint(x: frame.minX, y: frame.maxY),
            buttonDown: NSEvent.pressedMouseButtons != 0,
            pinned: pin.isPinned
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
        pin.detach(at: origin)
    }

    /// One observer of `name`, deaf to every window that is not the panel's.
    ///
    /// The filter written once rather than once per notification: it is the
    /// half that was got wrong before, and two copies of it is two places for
    /// the next one to be got wrong in.
    private func whenThePanelsWindow(
        _ name: Notification.Name, then act: @escaping @MainActor (PanelWindowLifecycle) -> Void
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
}

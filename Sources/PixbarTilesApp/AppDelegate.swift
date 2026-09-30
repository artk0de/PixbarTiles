import AppKit
import PixbarKit
import SwiftUI

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
    /// The browse rule: when the app looks for clocks on the network.
    let browsingPolicy: ClockBrowsingPolicy
    /// The panel's window as AppKit reports it: open, closed, dragged, pinned.
    let panelWindowLifecycle: PanelWindowLifecycle

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
        self.browsingPolicy = ClockBrowsingPolicy(discovery: discovery)
        self.panelWindowLifecycle = PanelWindowLifecycle(
            model: model, pin: panelPin, browsingPolicy: browsingPolicy, notifications: .default
        )
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
        self.browsingPolicy = ClockBrowsingPolicy(discovery: discovery)
        self.panelWindowLifecycle = PanelWindowLifecycle(
            model: model, pin: panelPin, browsingPolicy: browsingPolicy, notifications: notifications
        )
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
    /// is `ClockBrowsingPolicy`.
    ///
    /// The clock's answers are subscribed to BEFORE the schedules start,
    /// because `model.start()` fires the first poll and that answer is what a
    /// panel opened seconds later has to be right about.
    func applicationDidFinishLaunching(_ notification: Notification) {
        browsingPolicy.watch(model)
        model.start()
        panelWindowLifecycle.watch()
        // An update may ship a different hook. The one Claude Code runs is
        // brought in line with it here, and only while connected. A failure is
        // left for the next launch: the old hook still stores documents.
        try? ClaudeCodePaths.shippedLink?.refreshHookIfConnected()
    }

    /// Told which window the panel was put on, by the panel itself
    /// (`PanelWindowReader`) — see `PanelWindowLifecycle.panelMoved(to:)`.
    func panelMoved(to window: NSWindow?) {
        panelWindowLifecycle.panelMoved(to: window)
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

import AppKit
import AwtrixKit
import Foundation
import Testing
@testable import AwtrixConnectorsApp

// MARK: - The menu bar glyph

// 30x18, not square. The bar caps an item's height and not its width, the
// device is wide, and `Scripts/MakeIcon.swift` emits the glyph at exactly this
// aspect — a size set here that disagrees is macOS stretching the art.
@Test @MainActor func theMenuBarGlyphIsATemplateAtTheAspectTheGeneratorEmits() {
    let glyph = AppGlyph.menuBar(lit: true)

    #expect(glyph.size == NSSize(width: 30, height: 18))
    // Template: macOS discards the colour and recolours the shape for light,
    // dark and the highlighted state. Without this the glyph stays black on a
    // dark menu bar.
    #expect(glyph.isTemplate)
}

@Test @MainActor func theOfflineGlyphIsDrawnToTheSameSize() {
    #expect(AppGlyph.menuBar(lit: false).size == NSSize(width: 30, height: 18))
    #expect(AppGlyph.menuBar(lit: false).isTemplate)
}

// Online and offline are two drawings, not one drawing plus a badge — a badge
// does not survive being 18pt tall. This runs outside a bundle, so what it
// actually pins is the fallback pair: `NSImage(named:)` finds nothing here.
//
// What it does NOT pin is which of the two means which, and that is not a
// nuance: `lit != unlit` is satisfied by an inverted mapping exactly as well as
// by a correct one. The two tests below are the direction.
@Test @MainActor func onlineAndOfflineAreTwoDifferentGlyphs() {
    let lit = AppGlyph.menuBar(lit: true).tiffRepresentation
    let unlit = AppGlyph.menuBar(lit: false).tiffRepresentation

    #expect(lit != nil)
    #expect(lit != unlit)
}

// A reachable clock is the panel with its pixels lit; an unreachable one is the
// hollow panel. Named here rather than inferred from a comparison, because the
// comparison above stays green with the two swapped — measured, on the shipped
// tree, with all 653 tests passing while the menu bar showed a lit AWTRIX panel
// for a dead clock.
@Test @MainActor func aReachableClockSelectsTheLitPanelAndAnUnreachableOneTheHollowOne() {
    #expect(
        AppGlyph.drawing(lit: true)
            == AppGlyph.Drawing(resource: "MenuBarIcon", symbol: "square.grid.3x2.fill")
    )
    #expect(
        AppGlyph.drawing(lit: false)
            == AppGlyph.Drawing(resource: "MenuBarIconOffline", symbol: "square.grid.3x2")
    )
}

// And the image handed back is drawn from the drawing that table names, or the
// table is a decoration nothing reads. Outside a bundle the fallback symbol is
// what gets drawn, so the reference is built from the symbol name THIS test
// states and compared pixel for pixel — the same technique the panel tests use,
// aimed at identity rather than at difference.
@Test @MainActor func theGlyphIsDrawnFromTheDrawingItsStateNames() {
    #expect(AppGlyph.menuBar(lit: true).tiffRepresentation == glyphDrawnFrom("square.grid.3x2.fill"))
    #expect(AppGlyph.menuBar(lit: false).tiffRepresentation == glyphDrawnFrom("square.grid.3x2"))
    // Or two nils would satisfy both lines above without anything being drawn.
    #expect(glyphDrawnFrom("square.grid.3x2.fill") != nil)
}

/// An SF Symbol put through the same preparation `menuBar(lit:)` applies, as
/// bytes. Two separately built images of one symbol render identically — a
/// determinism control this depends on, and the reason it is safe to compare
/// against a reference rather than against the other state.
@MainActor
private func glyphDrawnFrom(_ symbol: String) -> Data? {
    AppGlyph.prepare(NSImage(systemSymbolName: symbol, accessibilityDescription: "AWTRIX")!)
        .tiffRepresentation
}

// The bundled case, which nothing running outside a bundle can otherwise reach.
// A loose PNG in `Contents/Resources` arrives with `isTemplate` false; the SF
// Symbol the other tests fall back to arrives with it true, so only an image
// that starts out plain can tell whether the glyph is made a template at all.
@Test @MainActor func anImageLoadedFromTheBundleIsMadeATemplateAtTheGlyphsSize() {
    let loaded = NSImage(size: NSSize(width: 90, height: 54))
    #expect(loaded.isTemplate == false)

    let glyph = AppGlyph.prepare(loaded)

    #expect(glyph.isTemplate)
    #expect(glyph.size == AppGlyph.menuBarSize)
}

// MARK: - Where this app writes

// The reaper removes whole directory trees and is contained by this root, so a
// root of `/tmp` would put every other process's scratch directory inside the
// boundary.
@Test func theClipRootIsADirectoryOfThisAppsOwn() {
    #expect(AppPaths.clipRoot != FileManager.default.temporaryDirectory)
    #expect(
        AppPaths.clipRoot.deletingLastPathComponent().standardizedFileURL
            == FileManager.default.temporaryDirectory.standardizedFileURL
    )
}

// The played set is what "an anecdote is never repeated" rests on. In the
// temporary directory a reboot would make every anecdote the user has heard
// unheard again.
@Test func theAnecdoteStoreOutlivesAReboot() {
    #expect(AppPaths.anecdoteStore.path.contains("Application Support"))
    #expect(
        AppPaths.anecdoteStore.path
            .hasPrefix(FileManager.default.temporaryDirectory.path) == false
    )
}

/// A store URL of this test's own.
///
/// `AnecdoteQueue.init` reads whatever file it is handed, and `AppPaths`
/// resolves to the user's real `~/Library/Application Support`. A test has no
/// business opening that, whatever it is asserting.
private func scratchStore() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("live-\(UUID().uuidString).json")
}

// MARK: - The composition root

@Test @MainActor func theAppIsWiredWithTheAnecdoteConnector() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // A store of its own, like the defaults suite: `AnecdoteQueue.init` reads
    // whatever file it is given, and a test has no business opening the user's.
    let subject = AppModel.live(
        defaults: defaults,
        transport: StubTransport(),
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).json")
    )

    let connector = try #require(subject.registry.all.first)
    #expect(connector.id == "anecdotes")
    // First, and the order is the order the panel offers them in: the
    // anecdotes are what this app is for, and the ambient pair is what it also
    // does while nobody is asking it anything.
    #expect(subject.registry.all.map(\.id) == ["anecdotes", "weather", "claude"])
    // Deliberately not asserting the interval here. `AnecdoteConnector`'s own
    // default IS thirty minutes, so every such assertion holds equally through
    // the store's fallback and proves nothing about debt 2. The
    // `StubConnector(5 * 60)` tests are what carry that rule.
}

// And of the three it registers, only the anecdotes are offered a row. The rule
// is `PanelRows`, applied here to the connectors the app ACTUALLY ships rather
// than to a pair made up for the test: `thePanelDrawsNoRowForAConnectorThat
// IsAmbient` proves the rule reaches the screen, and this proves both shipped
// ambient connectors are on the wrong side of it while the shipped anecdotes
// stay on the right one.
//
// Both halves are asserted, because "no rows at all" satisfies the first on its
// own — which is the whole panel gone and the test still green.
@Test @MainActor func onlyTheAnecdotesAreOfferedARowOnThePanel() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(subject.registry.all.map(\.id) == ["anecdotes", "weather", "claude"])
    #expect(PanelRows.drawn(from: subject.registry.all).map(\.id) == ["anecdotes"])
}

/// Whether an output would put sound in the room.
///
/// Both channels, because they are two different noises made by two different
/// machines: `localAudio` is this Mac speaking through its own speakers, and
/// `jingle` is the clock's buzzer playing RTTTL. A guard watching one of them
/// would wave the other straight through.
private func putsSoundInTheRoom(_ output: ConnectorOutput) -> Bool {
    output.jingle != nil || output.localAudio.isEmpty == false
}

// Nothing but the anecdotes is ever spoken, and that is a rule rather than an
// observation. It happens to hold today because `AnecdoteConnector` is the only
// place in `Sources/` that sets either audio field — an accident nothing was
// holding in place, and the next connector to want a jingle would have found
// nothing in its way.
//
// Read off the SHIPPED registry rather than off a list written here, and that
// is the point of putting it in this file: a hand-written roster is the same
// accident with a test around it, green on the day it is written and silent
// about the connector somebody registers next year. Every connector `live()`
// composes is walked, and the anecdotes are excluded BY TYPE — a string id here
// could stop matching after a rename and quietly excuse everything.
//
// What this does NOT cover, so nobody over-trusts it:
//   - A connector registered somewhere other than `AppModel.live()`. Nothing
//     enumerates conformers of a protocol in Swift, so the composition root is
//     the widest net available.
//   - `produce()` on the anecdote connector itself, which is the one allowed to
//     speak. `theAnecdoteConnectorIsAudibleAndSpeaks` in the kit's own suite is
//     what pins that it still does.
//   - A connector whose `produce()` cannot run under this transport: it is
//     covered by its DECLARATION only, which is a promise rather than a
//     measurement. The count below is what says at least one real output was
//     inspected.
//   - Anything a connector hands to the device that is not carried on its
//     output — this reads the value `produce()` returns, and `ConnectorHost` is
//     what turns it into sound.
@Test @MainActor func nothingButTheAnecdotesEverPutsSoundInTheRoom() async throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults, transport: SkyAndClockTransport(), anecdoteStore: scratchStore()
    )
    let others = subject.registry.all.filter { ($0 is AnecdoteConnector) == false }

    // Or every expectation in the loop is unreached and the test is a
    // decoration on an empty collection.
    #expect(others.isEmpty == false)

    var inspected = 0
    for connector in others {
        // The declaration first: it is the answer the schedule reads BEFORE
        // `produce()` is called, and the only answer available for a connector
        // that cannot be produced here.
        #expect(connector.isAudible == false, "\(connector.id) declares itself audible")
        guard let output = try? await connector.produce() else { continue }
        inspected += 1
        #expect(putsSoundInTheRoom(output) == false, "\(connector.id) produced audio")
    }

    // At least one connector was really produced, or the loop asserted nothing
    // about any actual output — a transport answering nothing would leave every
    // one of them unproducible and the test green.
    #expect(inspected > 0)
    // And the question being asked is one that can answer yes, or the loop
    // passes for a connector singing through either channel.
    #expect(putsSoundInTheRoom(ConnectorOutput(text: "x", jingle: AnecdoteConnector.nokiaJingle)))
    #expect(
        putsSoundInTheRoom(
            ConnectorOutput(
                text: "x", localAudio: [SpokenClip(url: URL(fileURLWithPath: "/tmp/x.wav"))]
            )
        )
    )
}

// The two ends of the reaper's safety argument, which is the file's own words:
// containment means nothing if the synthesizer writes somewhere the queue is not
// allowed to delete. Neither end could be read back before, so pointing them at
// different roots — or rooting the queue at the whole temporary directory —
// changed nothing any test could see.
@Test @MainActor func theSynthesizerWritesWhereTheReaperIsAllowedToDelete() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("wiring-\(UUID().uuidString)")
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("wiring-\(UUID().uuidString).json")

    let wiring = AppModel.anecdoteWiring(
        transport: StubTransport(), clipRoot: root, storeURL: store
    )

    #expect(wiring.speech.outputDirectory == root)
    #expect(wiring.queue.clipRoot == root)
}

// The last line of debt 2 that was still a promise rather than a check: that
// `live()` hands `anecdoteWiring` the app's own root, rather than an explicit
// one of its own. Passing the whole temporary directory there left 304 tests
// green.
//
// Read by reflection because `AnecdoteConnector.queue` is `private` and there is
// no seam that returns it — `Mirror` reads stored properties regardless of
// access control. Reflection to reach BEHAVIOUR would be wrong; this reads one
// stored URL to check a wiring invariant, and the alternative was widening the
// kit's API for a test. Not circular: `AppPaths.clipRoot` on the right is
// separately pinned by `theClipRootIsADirectoryOfThisAppsOwn`, so moving the
// constant fails there and overriding it at the call site fails here.
@Test @MainActor func theAppHandsItsOwnClipRootToTheQueueItBuilds() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults,
        transport: StubTransport(),
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).json")
    )

    let connector = try #require(subject.registry.all.first)
    let queue = try #require(
        Mirror(reflecting: connector).children.compactMap { $0.value as? AnecdoteQueue }.first
    )
    #expect(queue.clipRoot == AppPaths.clipRoot)
}

// And that the root the app actually ships with is the one both ends get.
@Test @MainActor func theAppsOwnClipRootReachesBothEnds() async {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("wiring-\(UUID().uuidString).json")

    let wiring = AppModel.anecdoteWiring(transport: StubTransport(), storeURL: store)

    #expect(wiring.speech.outputDirectory == AppPaths.clipRoot)
    #expect(wiring.queue.clipRoot == AppPaths.clipRoot)
}

// The window the shipped app keeps played audio for, and the queue it reaches.
// Nothing in the kit invents this number, so nothing in the kit would notice it
// being zero — and zero deletes the audio behind every entry History offers to
// replay, at the first reap after it was heard.
@Test @MainActor func theAppKeepsPlayedClipsForTenDays() async {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("wiring-\(UUID().uuidString).json")

    let wiring = AppModel.anecdoteWiring(transport: StubTransport(), storeURL: store)

    #expect(AppPaths.clipRetention == 10 * 24 * 60 * 60)
    #expect(wiring.queue.retention == AppPaths.clipRetention)
}

// The record of what this app put on the flash has to outlive the process that
// put it there — that is the single property the whole store exists for, and
// swapping `live()` to an in-memory one changed nothing any test could see.
@Test @MainActor func whatAnEarlierLaunchUploadedIsStillRemovableInThisOne() async throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Written by a previous launch, through the store `live()` is meant to use.
    UserDefaultsUploadedIconStore(defaults: defaults).record("9039")
    let transport = StubTransport()

    let subject = AppModel.live(
        defaults: defaults,
        transport: transport,
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).json")
    )
    subject.removeInstalledIcons()
    #expect(await waitUntil { subject.iconStatus == "removed 9039" })

    let deletions = transport.requests.filter { $0.httpMethod == "DELETE" }
    let body = String(decoding: deletions.first?.httpBody ?? Data(), as: UTF8.self)
    #expect(deletions.count == 1)
    #expect(body.contains("/ICONS/9039.gif"))
}

// The same argument one field over, and the one the final review found still
// open: the record of the overlay this app borrowed has to outlive the process
// that borrowed it. `live()` handing `ConnectorHost` the in-memory default
// meant a force quit — or any teardown that outran the quit budget — left the
// user's own overlay unrecoverable, and nothing in the suite could see it.
@Test @MainActor func whatAnEarlierLaunchBorrowedIsStillGivenBackInThisOne() async throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Written by a previous launch that never got to give it back, through the
    // store `live()` is meant to use.
    UserDefaultsBorrowedOverlayStore(defaults: defaults).record(
        BorrowedOverlay(before: "aurora", applied: "rain", borrower: "weather")
    )
    let transport = StubTransport(body: onlineStats)

    let subject = AppModel.live(
        defaults: defaults,
        transport: transport,
        anecdoteStore: FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).json")
    )
    await subject.teardown()

    let written = transport.requests
        .filter { $0.url?.path == "/api/settings" && $0.httpMethod == "POST" }
        .compactMap {
            (try? JSONSerialization.jsonObject(with: $0.httpBody ?? Data()))
                .flatMap { $0 as? [String: Any] }?["OVERLAY"] as? String
        }
    // What the earlier launch displaced, not `clear` and not the `rain` it left
    // on the device.
    #expect(written == ["aurora"])
    // And the loan is discharged, so the launch after this one does not write
    // it a second time over whatever the user has set since.
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults).borrowedOverlay() == nil)
}

@Test @MainActor func theDeviceHostIsTakenFromDefaultsWhenOneIsSaved() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)

    #expect(AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.9")
}

@Test @MainActor func theDeviceHostFallsBackToTheOneOnTheDesk() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(
        AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost
            == "192.168.1.72"
    )
}

// MARK: - What the panel says about a device nobody has asked yet

// `isOnline` is false for `.unknown` exactly as it is for `.offline`, so the
// panel announced a disconnection during the twenty seconds before the first
// poll answers. Same conflation `DeviceState` exists to prevent, and the same
// one this task fixed in a test and left in the view.
@Test func aDeviceNobodyHasAskedYetIsNotReportedAsDisconnected() {
    #expect(DeviceStatusLine.title(for: .unknown) == "Checking…")
    #expect(DeviceStatusLine.title(for: .offline("boom")) == "Disconnected")
    #expect(DeviceStatusLine.colour(for: .unknown) != DeviceStatusLine.colour(for: .offline("boom")))
}

@Test func aReachableDeviceIsReportedAsConnected() throws {
    let stats = try JSONDecoder().decode(DeviceStats.self, from: onlineStats)

    #expect(DeviceStatusLine.title(for: .online(stats)) == "Connected")
    #expect(DeviceStatusLine.colour(for: .online(stats)) == .green)
}

// MARK: - What the panel says about devices nobody has pointed the app at yet

// The defect this whole state exists to prevent: every one of these renders as
// zero devices, and three of the four are fixed by doing different things.
@Test func aRefusedPermissionIsNotReportedAsAnEmptyNetwork() {
    let refused = DiscoveryStatusLine.text(for: .denied)
    let empty = DiscoveryStatusLine.text(for: .listed([]))
    let searching = DiscoveryStatusLine.text(for: .searching)

    #expect(refused != empty)
    #expect(searching != empty)
    #expect(refused != searching)
    // Somebody who declined the prompt has to be told where to change their
    // mind, not told the network is empty.
    #expect(refused?.contains("Local Network") == true)
}

@Test func aBrowseNobodyHasFinishedIsNotReportedAsAnEmptyNetworkEither() {
    #expect(DiscoveryStatusLine.text(for: .searching)?.contains("Looking") == true)
    #expect(DiscoveryStatusLine.text(for: .searching)?.contains("No AWTRIX") == false)
}

// Discovery that was never started says nothing at all, rather than reporting
// on a browse that has not happened.
@Test func aDiscoveryNobodyStartedSaysNothing() {
    #expect(DiscoveryStatusLine.text(for: .idle) == nil)
}

@Test func aFailedBrowseSaysWhatFailed() {
    #expect(DiscoveryStatusLine.text(for: .failed("interface went away"))?
        .contains("interface went away") == true)
}

// Two clocks on one network, and neither is more the device than the other.
// A line that counted them — "2 devices found" — leaves the user with no way to
// tell which name is which, and the name is the only thing discovery knows.
@Test func everyDiscoveredInstanceIsNamedRatherThanCounted() {
    let line = DiscoveryStatusLine.text(for: .listed([
        DiscoveredDevice(instanceName: "awtrix_a07f9c"),
        DiscoveredDevice(instanceName: "awtrix_ff0102"),
    ]))

    #expect(line?.contains("awtrix_a07f9c") == true)
    #expect(line?.contains("awtrix_ff0102") == true)
    // And says how to choose between them, because the app talks to an address
    // and neither name is one.
    #expect(line?.contains("the address below") == true)
}

// One device needs no such instruction: there is nothing to choose between.
@Test func oneDeviceIsNamedWithoutAskingTheUserToChooseBetweenThings() {
    let line = DiscoveryStatusLine.text(for: .listed([
        DiscoveredDevice(instanceName: "awtrix_a07f9c"),
    ]))

    #expect(line?.contains("awtrix_a07f9c") == true)
    #expect(line?.contains("the address below") == false)
}

// A clock can advertise itself over Bonjour and still not answer `/api/stats` —
// a different subnet, firmware still booting, the web interface switched off.
// So the line reports the advertisement in the advertisement's own words, and
// the question of whether the app can talk to the address it was pointed at
// stays with the monitor, one line up.
@Test func theDiscoveryLineReportsAnAdvertisementRatherThanAConnection() {
    let seen = DiscoveryStatusLine.text(for: .listed([
        DiscoveredDevice(instanceName: "awtrix_a07f9c"),
    ]))

    #expect(seen?.hasPrefix("Seen on the network:") == true)
    #expect(seen?.contains("awtrix_a07f9c") == true)
}

// MARK: - Looking for the device on the network

// Building the delegate reaches neither the clock nor the network, and a browse
// is network: the same rule `AppModel` already keeps about its own loops.
@Test @MainActor func buildingTheDelegateDoesNotStartBrowsing() {
    let browsing = FakeBonjourBrowser()

    _ = AppDelegate(
        model: testModel(),
        budget: QuitBudget(),
        discovery: DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    )

    #expect(browsing.liveBrowses == 0)
}

/// A delegate that has launched, with a clock a test can take down and a browse
/// it can count.
///
/// Everything with a beat of its own is parked: the schedule and the poll sleep
/// on metronomes, so nothing here moves until a test moves it. The poll's is
/// handed in rather than made here, because the tests that take the clock down
/// and put it back have to be able to tick it.
@MainActor
private func launchedForBrowsing(
    _ browsing: FakeBonjourBrowser,
    clock: any Transport = StubTransport(body: onlineStats),
    deviceHost: String = "10.0.0.5",
    poll: Metronome = Metronome(),
    settle: @escaping DeviceBrowser.Sleeping = { _ in },
    notifications: NotificationCenter = NotificationCenter(),
    budget: QuitBudget = QuitBudget()
) -> AppDelegate {
    let delegate = AppDelegate(
        model: testModel(
            transport: clock,
            sleep: Metronome().sleep,
            pollSleep: poll.sleep,
            deviceHost: deviceHost
        ),
        budget: budget,
        discovery: DeviceBrowser(browsing: { browsing }, sleep: settle),
        notifications: notifications
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    return delegate
}

// The defect. `applicationDidFinishLaunching` used to call `discovery.start()`
// and nothing ever called `stop()`, so the browse ran for the life of the
// process — including every minute the configured address was answering
// perfectly well. Multicast is the one kind of traffic that costs a Wi-Fi
// network: every frame goes to every client on every band at the lowest basic
// rate and wakes every power-saving device, the clock among them.
@Test @MainActor func launchingTheAppDoesNotBrowse() {
    let browsing = FakeBonjourBrowser()

    let delegate = launchedForBrowsing(browsing)

    #expect(browsing.liveBrowses == 0)
    withExtendedLifetime(delegate) {}
}

// The steady state of a working installation, and the whole point of the task:
// the app knows the address, the address answers, so there is nothing to look
// for. Opening the panel does not change that.
@Test @MainActor func aPanelOpenedOnAClockThatAnswersLooksForNothing() async {
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(browsing)
    #expect(await waitUntil { delegate.model.isDeviceOnline })

    delegate.panelMoved(to: aWindow())

    #expect(browsing.liveBrowses == 0)
    await delegate.model.teardown()
}

// The case discovery exists for: the clock has moved, or has never been found,
// and the panel is where the user is looking for it.
@Test @MainActor func aPanelOpenedOnAClockThatIsNotAnsweringLooksForIt() async {
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(browsing, clock: SwitchableTransport(answering: false))
    #expect(await waitUntil { isOffline(delegate.model) })

    delegate.panelMoved(to: aWindow())

    #expect(browsing.liveBrowses == 1)
    await delegate.model.teardown()
}

// A launch nobody has given an address is not a state of its own, and that is
// worth pinning rather than assuming: `AppModel.live()` falls back to
// `defaultDeviceHost` when the defaults key is unset, so an unconfigured app is
// pointed at a guess. A guess nothing answers at is a clock that is not
// answering, which is the case above — one rule covers both, and there is no
// "is it configured" question anywhere in the delegate to get wrong.
@Test @MainActor func aLaunchWithNoAddressOfItsOwnLooksForAClock() async {
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(
        browsing,
        clock: SwitchableTransport(answering: false),
        deviceHost: AppModel.defaultDeviceHost
    )
    #expect(await waitUntil { isOffline(delegate.model) })

    delegate.panelMoved(to: aWindow())

    #expect(delegate.model.deviceHost == AppModel.defaultDeviceHost)
    #expect(browsing.liveBrowses == 1)
    await delegate.model.teardown()
}

// The answer the browse was waiting for can arrive from the other direction:
// the clock is plugged back in and the poll finds it. The app now has what it
// was looking for, so it stops looking — without this, a panel left open on an
// outage browses for as long as the outage lasts.
@Test @MainActor func theBrowseStopsAsSoonAsTheClockAnswers() async {
    let browsing = FakeBonjourBrowser()
    let clock = SwitchableTransport(answering: false)
    let poll = Metronome()
    let delegate = launchedForBrowsing(browsing, clock: clock, poll: poll)
    #expect(await waitUntil { isOffline(delegate.model) })
    delegate.panelMoved(to: aWindow())
    #expect(browsing.liveBrowses == 1)

    clock.nowAnswers()
    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()

    #expect(await waitUntil { delegate.model.isDeviceOnline })
    #expect(browsing.liveBrowses == 0)
    await delegate.model.teardown()
}

// A poll lands every minute and says the same thing every time, and each of
// those answers reaches the rule that decides the browse. Acted on rather than
// compared against what was already asked for, that is a browse torn down and
// rebuilt once a minute — a fresh burst of multicast queries every time, which
// is most of the traffic this task exists to stop.
//
// Read off `starts` rather than `liveBrowses`: a restart cancels and begins
// again, so the count of LIVE browses is one either way and only the count of
// beginnings can tell them apart.
@Test @MainActor func theSameAnswerTwiceDoesNotRestartTheBrowse() async {
    let browsing = FakeBonjourBrowser()
    let poll = Metronome()
    let delegate = launchedForBrowsing(
        browsing, clock: SwitchableTransport(answering: false), poll: poll
    )
    #expect(await waitUntil { isOffline(delegate.model) })
    delegate.panelMoved(to: aWindow())
    #expect(browsing.starts == 1)

    #expect(await waitUntil { poll.parked == 1 })
    poll.tick()

    // Parked again is the second poll over, answer published and all.
    #expect(await waitUntil { poll.parked == 1 })
    #expect(browsing.starts == 1)
    #expect(browsing.liveBrowses == 1)
    await delegate.model.teardown()
}

// What bounds the browse, and it is the strongest bound available: the
// discovery row is drawn on the panel and nowhere else, so a closed panel is a
// browse nobody can read. Losing key IS how a menu bar extra closes, and
// becoming key is how it opens — the same event read from both ends.
@Test @MainActor func closingThePanelStopsTheBrowseAndOpeningItAgainStartsOne() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(
        browsing, clock: SwitchableTransport(answering: false), notifications: notifications
    )
    #expect(await waitUntil { isOffline(delegate.model) })
    delegate.panelMoved(to: panel)
    #expect(browsing.liveBrowses == 1)

    loseFocus(panel, through: notifications)
    #expect(await waitUntil { browsing.liveBrowses == 0 })

    takeFocus(panel, through: notifications)

    #expect(await waitUntil { browsing.liveBrowses == 1 })
    // Held to the end deliberately: the observers hold the delegate weakly, so a
    // released one hears the window and does nothing about it.
    withExtendedLifetime(delegate) {}
    await delegate.model.teardown()
}

// The other half of the filter the close side already keeps. This process has
// more windows than the panel — `BatteryAlert` raises an `NSAlert`, and an
// authorization prompt is a window too — and every one of them takes key when
// it appears. Heard unfiltered, an alert would put a browse on the network with
// no panel to show what it found.
@Test @MainActor func aWindowThatIsNotThePanelDoesNotStartABrowse() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(
        browsing, clock: SwitchableTransport(answering: false), notifications: notifications
    )
    #expect(await waitUntil { isOffline(delegate.model) })
    delegate.panelMoved(to: panel)
    loseFocus(panel, through: notifications)
    #expect(await waitUntil { browsing.liveBrowses == 0 })

    takeFocus(aWindow(), through: notifications)

    await afterTheQueuedObserversHaveRun()
    #expect(browsing.liveBrowses == 0)
    withExtendedLifetime(delegate) {}
    await delegate.model.teardown()
}

@Test @MainActor func quittingStopsTheBrowse() async {
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(
        browsing, clock: SwitchableTransport(answering: false), budget: QuitBudget(seconds: 0.01)
    )
    #expect(await waitUntil { isOffline(delegate.model) })
    delegate.panelMoved(to: aWindow())
    #expect(browsing.liveBrowses == 1)

    _ = delegate.beginTermination { _ in }

    // A browse left running holds an `NWBrowser` on an app whose every other
    // loop is already cancelled.
    #expect(browsing.liveBrowses == 0)
}

// The budget is fifteen seconds for one thing: the dismiss that takes a held
// banner off the clock. The browse is stopped before the budget is taken, so
// its settle window is abandoned rather than waited out — three more seconds of
// a quit that has nothing left to do.
@Test @MainActor func quitAbandonsTheDiscoveryWindowRatherThanWaitingItOut() async {
    let window = Metronome()
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(
        browsing,
        clock: SwitchableTransport(answering: false),
        settle: window.sleep,
        budget: QuitBudget(seconds: 0.01)
    )
    #expect(await waitUntil { isOffline(delegate.model) })
    delegate.panelMoved(to: aWindow())
    // The browse comes up, which is what opens the window in the first place.
    browsing.emit(.ready)
    #expect(await waitUntil { window.parked == 1 })

    _ = delegate.beginTermination { _ in }

    #expect(await waitUntil { window.parked == 0 })
}

// Discovery has a clock of its own and it is the schedule's beat it must not
// steal: a device appearing on the network is not a reason to deliver anything.
//
// The browse is started here rather than through the panel, and the clock is
// left answering, because what is under test is what a REPORT does to a running
// schedule — and a schedule paused by an outage would prove the same thing for
// the wrong reason. How a browse comes to be running has its own tests above.
@Test @MainActor func aDiscoveryReportDoesNotDisturbTheSchedule() async {
    let browsing = FakeBonjourBrowser()
    let schedule = Metronome()
    let host = SpyHost()
    let delegate = AppDelegate(
        model: testModel(host: host, sleep: schedule.sleep, pollSleep: Metronome().sleep),
        budget: QuitBudget(),
        discovery: DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    #expect(await waitUntil { schedule.parked == 1 })
    delegate.discovery.start()

    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(delegate.discovery.found.map(\.instanceName) == ["awtrix_a07f9c"])
    // No delivery, rather than nothing at all: the launch's own restock is on
    // the list and is not something a discovery report caused.
    #expect(host.calls.contains { $0.hasPrefix("run:") } == false)
    #expect(schedule.parked == 1)
}

// The instance name is not a hostname: `awtrix.local` does not resolve, and
// neither does `awtrix_a07f9c.local`. A discovery that quietly repointed the
// app would repoint it at nothing at all.
@Test @MainActor func aDiscoveredInstanceIsNeverWrittenAsTheAddressTheAppTalksTo() throws {
    let suite = "discovery-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let browsing = FakeBonjourBrowser()
    let delegate = AppDelegate(
        model: testModel(sleep: Metronome().sleep, pollSleep: Metronome().sleep),
        budget: QuitBudget(),
        discovery: DeviceBrowser(browsing: { browsing }, sleep: { _ in })
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    // Started directly for the reason the test above starts one: what a report
    // must not do is written down here, not where a browse comes from.
    delegate.discovery.start()

    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(delegate.discovery.found.map(\.instanceName) == ["awtrix_a07f9c"])
    // The address is the user's to set, through the field, and finding a clock
    // is not the user saying anything. `awtrix_a07f9c` is not a hostname —
    // written here it would point the next launch at nothing that resolves.
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == nil)
    #expect(delegate.model.deviceHost == "10.0.0.5")
}

// MARK: - The address the next launch will use

// The write half of the brief's step 5. The panel's discovery line names a
// clock; this is how the user acts on that name without opening a terminal, and
// it goes through the same defaults key `AppModel.live()` reads at launch.
@Test @MainActor func theAddressTypedIntoThePanelIsWhatTheNextLaunchUses() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    DeviceHostField.save("10.0.0.9", to: defaults)

    // Read back the way the app reads it, not the way it was written: a field
    // writing some other key would save happily and change nothing.
    #expect(AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.9")
}

// Nothing else in the app writes this key, so a blank entry saved would come up
// at the next launch pointed at an empty host — and the panel that could fix it
// sits behind a device that no longer answers.
@Test @MainActor func aBlankAddressIsRefusedRatherThanSaved() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)

    #expect(DeviceHostField.save("   \n ", to: defaults) == nil)

    // And the address that was there is still there.
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
}

// A pasted address arrives with whatever was around it. `AwtrixDevice` builds
// `http://<host>/api/...` by interpolation, so a stray space is a URL that
// never resolves and a panel that says Disconnected for ever.
@Test @MainActor func theAddressIsTrimmedBeforeItIsSaved() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    DeviceHostField.save("  192.168.1.72\n", to: defaults)

    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "192.168.1.72")
}

// Pasting `http://10.0.0.5` out of the clock's own web interface is the single
// most likely thing anybody does with this field, and it was saved verbatim.
// Every request is then built as `http://http://10.0.0.5/api/stats`, whose host
// is a machine literally named `http`: a permanently unreachable clock, with a
// DNS error in the offline reason and nothing suggesting the address is
// malformed.
//
// Read back the way the app reads it, so a field that normalised for display
// and stored the paste would still be caught.
@Test @MainActor func aPastedAddressIsStoredWithoutItsScheme() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let note = DeviceHostField.save("http://10.0.0.5/", to: defaults)

    #expect(note == DeviceHostField.takesEffectNextLaunch)
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.5")
    #expect(
        AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.5"
    )
}

// And an entry nothing can be made of is complained about on the field rather
// than accepted and left to fail as a poll a quarter of an hour later, on a
// different surface, with nothing connecting the two.
@Test @MainActor func anAddressThatCannotBeAHostIsRefusedOnTheField() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)

    #expect(DeviceHostField.save("a b", to: defaults) == DeviceHostField.unusable)
    #expect(DeviceHostField.save("http://", to: defaults) == DeviceHostField.unusable)

    // And the address that was there is still there.
    #expect(defaults.string(forKey: AppModel.deviceHostKey) == "10.0.0.9")
}

// What the panel says after a save. The address is read once at launch and
// handed to the device, the monitor and the host; a confirmation that implied
// the app had already moved would be wrong until the next launch.
@Test @MainActor func savingSaysItTakesEffectAtTheNextLaunchRatherThanNow() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let note = DeviceHostField.save("10.0.0.9", to: defaults)

    #expect(note == DeviceHostField.takesEffectNextLaunch)
    #expect(note?.lowercased().contains("next launch") == true)
}

// MARK: - A network the app cannot browse

// The fourth answer folded into the third. With Wi-Fi off, no route, or a
// VPN-only link, the browse is up and cannot run — and the panel used to wait
// three seconds and then announce that nothing was advertising itself on a
// network that was not there.
@Test func aNetworkTheAppCannotBrowseIsNotReportedAsAnEmptyNetwork() {
    let unavailable = DiscoveryStatusLine.text(for: .unavailable("Network is down"))

    #expect(unavailable != DiscoveryStatusLine.text(for: .listed([])))
    #expect(unavailable != DiscoveryStatusLine.text(for: .searching))
    #expect(unavailable != DiscoveryStatusLine.text(for: .denied))
    // And says which network problem, because "no network" has causes the user
    // can tell apart.
    #expect(unavailable?.contains("Network is down") == true)
}

// MARK: - Where the clock is

// Typed, not asked for. Probed on this machine before the decision was made:
// an unsigned binary calling `requestWhenInUseAuthorization` is left at
// `.notDetermined` and `requestLocation` fails with kCLErrorDenied — the same
// answer `UNUserNotificationCenter` and `INFocusStatusCenter` already give
// here. So CoreLocation is not wired at all, and this is the path that works.

@Test @MainActor func theLocationTypedIntoTheSettingsIsWhatTheNextPollUses() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    LocationField.save("52.52, 13.405", to: defaults)

    // Read back the way the connector reads it, not the way it was written: a
    // field writing some other key would save happily and change nothing.
    #expect(Coordinates.stored(in: defaults) == Coordinates(latitude: 52.52, longitude: 13.405))
}

@Test @MainActor func aLocationNobodyHasTypedFallsBackToSomewhereRatherThanNowhere() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    // A connector with no coordinates has nothing to ask about and would report
    // a failure on every poll until somebody opened the settings.
    #expect(Coordinates.stored(in: defaults) == Coordinates.default)
}

// Open-Meteo answers a 400 for coordinates off the globe, so the panel says so
// rather than the connector reporting a failure a quarter of an hour later.
@Test @MainActor func coordinatesOffTheGlobeAreRefusedRatherThanSaved() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    LocationField.save("52.52, 13.405", to: defaults)

    for refused in ["91, 0", "-91, 0", "0, 181", "0, -181", "north, east", "52.52", "", "  "] {
        #expect(LocationField.save(refused, to: defaults) == LocationField.unreadable, "\(refused)")
    }

    // And what was there is still there.
    #expect(Coordinates.stored(in: defaults) == Coordinates(latitude: 52.52, longitude: 13.405))
}

@Test @MainActor func aLocationIsTypedTheWayItIsShown() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let shown = LocationField.text(for: Coordinates(latitude: 52.52, longitude: 13.405))
    #expect(LocationField.save(shown, to: defaults) == LocationField.takesEffectAtTheNextPoll)

    #expect(Coordinates.stored(in: defaults) == Coordinates(latitude: 52.52, longitude: 13.405))
}

@Test @MainActor func theAppIsWiredWithTheWeatherConnector() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    let weather = try #require(subject.registry.connector(id: "weather"))
    // Its own cadence rather than the store's thirty-minute fallback, and the
    // ten minutes it names rather than the fifteen the service updates at: the
    // number here is how often the CLOCK is refreshed, and the app carries a
    // one-hour `lifetime` that a slower cadence would let expire on a couple of
    // failed polls. The service's own fifteen stays inside `OpenMeteoSource` as
    // the cache window, which is what a free public API is owed.
    #expect(weather.defaultInterval == 600)
    #expect(subject.settings(for: weather).interval == 600)
}

// The location the shipped connector reads is the one the settings write, and
// it is read on every poll rather than captured at launch — otherwise typing a
// new one would do nothing until the app was restarted.
@Test @MainActor func theShippedWeatherConnectorReadsTheLocationTheSettingsWrite() async throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let transport = SkyAndClockTransport()
    let subject = AppModel.live(
        defaults: defaults, transport: transport, anecdoteStore: scratchStore()
    )
    let weather = try #require(subject.registry.connector(id: "weather"))

    subject.typedLocation = "52.52, 13.405"
    _ = try await weather.produce()

    let asked = try #require(
        transport.requests.compactMap { $0.url }.first { $0.host == "api.open-meteo.com" }
    )
    #expect(asked.absoluteString.contains("latitude=52.52"))
    #expect(asked.absoluteString.contains("longitude=13.405"))
}

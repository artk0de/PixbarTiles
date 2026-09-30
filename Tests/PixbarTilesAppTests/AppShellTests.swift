import AppKit
import PixbarKit
import Foundation
import Testing
@testable import PixbarTilesApp

// MARK: - The menu bar glyph

// 28x18: the canvas `Scripts/MakeIcon.swift` emits at every scale, the
// glyph's points times the scale. A size set here that disagrees is macOS
// stretching the art. And not a template — a template is macOS DISCARDING the
// colour, and the offline state's red square is part of the glyph.
@Test @MainActor func theMenuBarGlyphIsAtItsPointsPerArtPixelSizeAndKeepsItsColours() {
    let glyph = AppGlyph.menuBar(for: .online)

    #expect(glyph.size == NSSize(width: 28, height: 18))
    #expect(glyph.isTemplate == false)
}

@Test @MainActor func theOfflineGlyphIsDrawnToTheSameSize() {
    let glyph = AppGlyph.menuBar(for: .offline)

    #expect(glyph.size == AppGlyph.menuBarSize)
    #expect(glyph.isTemplate == false)
}

@Test @MainActor func theEmptyGlyphIsDrawnToTheSameSize() {
    let glyph = AppGlyph.menuBar(for: .empty)

    #expect(glyph.size == AppGlyph.menuBarSize)
    #expect(glyph.isTemplate == false)
}

// Online and offline are two drawings, not one drawing plus a badge — a badge
// does not survive being 18pt tall. This runs outside a bundle, so what it
// actually pins is the fallback pair: `NSImage(named:)` finds nothing here.
//
// What it does NOT pin is which of the two means which, and that is not a
// nuance: `lit != unlit` is satisfied by an inverted mapping exactly as well as
// by a correct one. The mapping test below is the direction.
@Test @MainActor func onlineAndOfflineAreTwoDifferentGlyphs() {
    let lit = AppGlyph.menuBar(for: .online).tiffRepresentation
    let unlit = AppGlyph.menuBar(for: .offline).tiffRepresentation

    #expect(lit != nil)
    #expect(lit != unlit)
}

// The empty screen is its own drawing, distinct from both powered states:
// offline has grey sliders where empty has none, and the pixels show it.
@Test @MainActor func theEmptyGlyphIsItsOwnDrawingNotTheOfflineOne() {
    let empty = AppGlyph.menuBar(for: .empty).tiffRepresentation
    let offline = AppGlyph.menuBar(for: .offline).tiffRepresentation
    let online = AppGlyph.menuBar(for: .online).tiffRepresentation

    #expect(empty != nil)
    #expect(empty != offline)
    #expect(empty != online)
}

// A reachable clock selects the online drawing, an unreachable one the offline
// drawing, and an installation with no clocks at all the empty one — a clock
// with a blank screen, because there is nothing to show on it. Each drawing
// carries BOTH appearances, because the shipped PNGs come in dark and light.
// Inverting any one cell of this table puts, say, the dark bar's offline art
// on an online light bar, which no comparison of two whole images would
// catch. The names are written here and nowhere else in the app, which is
// what makes the table assertable at all.
@Test func aReachableClockSelectsTheOnlineDrawingAndAnUnreachableOneTheOfflineOne() {
    #expect(
        AppGlyph.drawing(for: .online)
            == AppGlyph.Drawing(
                darkResource: "pixbar-glyph-dark-online",
                lightResource: "pixbar-glyph-light-online",
                symbol: "square.grid.3x2.fill"
            )
    )
    #expect(
        AppGlyph.drawing(for: .offline)
            == AppGlyph.Drawing(
                darkResource: "pixbar-glyph-dark-offline",
                lightResource: "pixbar-glyph-light-offline",
                symbol: "square.grid.3x2"
            )
    )
    #expect(
        AppGlyph.drawing(for: .empty)
            == AppGlyph.Drawing(
                darkResource: "pixbar-glyph-dark-empty",
                lightResource: "pixbar-glyph-light-empty",
                symbol: "rectangle"
            )
    )
}

// The state a glyph draws is decided once, from the two facts the model
// holds: with no clocks configured there is nothing the online/offline
// question could be about, so the empty screen wins over both.
@Test func theGlyphsStateIsDecidedOnceFromTheModelsTwoFacts() {
    #expect(AppGlyph.state(hasNoClocks: true, isDeviceOnline: true) == .empty)
    #expect(AppGlyph.state(hasNoClocks: true, isDeviceOnline: false) == .empty)
    #expect(AppGlyph.state(hasNoClocks: false, isDeviceOnline: true) == .online)
    #expect(AppGlyph.state(hasNoClocks: false, isDeviceOnline: false) == .offline)
}

// And a drawing hands the handler the variant drawn FOR the bar being drawn —
// the split `resource(for:)` makes is the one place appearance and state meet.
@Test func aDrawingNamesTheVariantForTheBarItIsDrawnOn() {
    let drawing = AppGlyph.Drawing(darkResource: "d", lightResource: "l", symbol: "s")

    #expect(drawing.resource(for: .dark) == "d")
    #expect(drawing.resource(for: .light) == "l")
}

// The variant is chosen from the appearance AppKit is drawing WITH, not the
// app's or the system's: a status item follows the menu bar, which on recent
// macOS can follow the wallpaper and differ from both. `bestMatch` against the
// two concrete names IS the resolution — a light bar answers aqua, a dark one
// darkAqua.
@Test @MainActor func theVariantFollowsTheAppearanceItIsDrawnUnder() {
    #expect(AppGlyph.BarAppearance.of(NSAppearance(named: .aqua)!) == .light)
    #expect(AppGlyph.BarAppearance.of(NSAppearance(named: .darkAqua)!) == .dark)
}

// The image carries no cached rendering. A status item whose bar flips
// appearance — theme or wallpaper — is only redrawn from the handler if
// nothing stands between the redraw and it; a cached bitmap would keep the
// previous bar's variant on screen until relaunch.
@Test @MainActor func theGlyphIsNeverCachedSoALiveAppearanceChangeRedrawsIt() {
    #expect(AppGlyph.menuBar(for: .online).cacheMode == .never)
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
    // anecdotes are what this app is for, and the ambient set is what it also
    // does while nobody is asking it anything.
    #expect(subject.registry.all.map(\.id) == ["anecdotes", "weather", "claude", "zai", "nightlight", "github"])
    // Deliberately not asserting the interval here. `AnecdoteConnector`'s own
    // default IS thirty minutes, so every such assertion holds equally through
    // the store's fallback and proves nothing about debt 2. The
    // `StubConnector(5 * 60)` tests are what carry that rule.
}

// A kind held back from the store is still registered — a tile already
// stored keeps running — but the Add tile menu does not offer it.
@Test @MainActor func theStoreDoesNotOfferAKindHeldBack() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(subject.registry.connector(id: AnecdotesKind.id) != nil)
    #expect(subject.tileCandidates().map(\.connectorId).contains(AnecdotesKind.id) == false)
    #expect(subject.tileCandidates().map(\.connectorId).contains(WeatherKind.id))
}

// And of the set it registers, the order is registration order: the
// anecdotes are what this app is for, and the ambient set is what it also
// does while nobody is asking it anything. Which of them get a row is no
// longer the registry's question at all — the panel draws one row per tile
// stored, and which tiles exist is the user's doing through the Add tile
// menu.
@Test @MainActor func theConnectorsAreRegisteredInOfferOrder() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(
        defaults: defaults, transport: StubTransport(), anecdoteStore: scratchStore()
    )

    #expect(subject.registry.all.map(\.id) == ["anecdotes", "weather", "claude", "zai", "nightlight", "github"])
}

/// Whether an output would put sound in the room.
///
/// Both channels, because they are two different noises made by two different
/// machines: `localAudio` is this Mac speaking through its own speakers, and
/// `jingle` is the clock's buzzer playing RTTTL. A guard watching one of them
/// would wave the other straight through.
private func putsSoundInTheRoom(_ output: AwtrixDelivery) -> Bool {
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
//     output — this reads the value `produce()` returns, and `AwtrixClockSession` is
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
    #expect(putsSoundInTheRoom(AwtrixDelivery(text: "x", jingle: AnecdoteConnector.nokiaJingle)))
    #expect(
        putsSoundInTheRoom(
            AwtrixDelivery(
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
// that borrowed it. `live()` handing `AwtrixClockSession` the in-memory default
// meant a quit — which no longer waits for any teardown at all — leaving the
// user's own overlay unrecoverable, and nothing in the suite could see it.
@Test @MainActor func whatAnEarlierLaunchBorrowedIsStillGivenBackInThisOne() async throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    // Written by a previous launch that never got to give it back, through the
    // store `live()` is meant to use — under the id of the clock `live()` will
    // drive. The clock is stored first and the clock migration told not to run,
    // or the migration would replace it, and the id with it.
    defaults.set(true, forKey: ClockMigration.markerKey)
    let clock = try storeAClock(in: defaults)
    UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).record(
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
    #expect(UserDefaultsBorrowedOverlayStore(defaults: defaults, clockId: clock.id).borrowedOverlay() == nil)
}

@Test @MainActor func theDeviceHostIsTakenFromDefaultsWhenOneIsSaved() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)

    #expect(AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.9")
}

// A fresh install invents no clock (D6): no clock, and no host to point at —
// the panel's "No clocks yet" is the answer, not an address nobody chose.
@Test @MainActor func aFreshInstallHasNoClockAndNoHost() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    let subject = AppModel.live(defaults: defaults, anecdoteStore: scratchStore())

    #expect(subject.hasNoClocks)
    #expect(subject.deviceHost == "")
}

// MARK: - What the panel says about a device nobody has asked yet

// `isOnline` is false for `.unknown` exactly as it is for `.offline`, so the
// panel announced a disconnection during the twenty seconds before the first
// poll answers. Same conflation `DeviceState` exists to prevent, and the same
// one this task fixed in a test and left in the view.
@Test func aDeviceNobodyHasAskedYetIsNotReportedAsDisconnected() {
    // The words said from the model's own three-valued reachability — the
    // vocabulary the status dot renders, so a dot and its line cannot
    // disagree about what the clock has answered.
    #expect(DeviceStatusLine.title(for: AppModel.ClockReachability.unknown) == "Checking…")
    #expect(DeviceStatusLine.title(for: .unreachable) == "Disconnected")
    #expect(DeviceStatusLine.title(for: .reachable) == "Connected")
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

// Discovery no longer looks for one model: the browse sees AWTRIX and the
// broadcasts see TC002s, so no line may claim only AWTRIX — "no AWTRIX is
// advertising" read as a lie to everybody whose clock is a TC002.
@Test func noLineNamesAModelAnyMore() {
    #expect(DiscoveryStatusLine.text(for: .searching)?.contains("AWTRIX") == false)
    let empty = DiscoveryStatusLine.text(for: .listed([]))
    #expect(empty?.contains("No clock is advertising itself") == true)
    #expect(empty?.contains("AWTRIX") == false)
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
        discovery: ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
            // A stream that yields nothing and ends: every browse a test arms
            // must be able to start without a real UDP listener binding the
            // port underneath it.
            sightings: { AsyncStream { $0.finish() } }
        )
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
) -> AppDelegate {
    let delegate = AppDelegate(
        model: testModel(
            transport: clock,
            sleep: Metronome().sleep,
            pollSleep: poll.sleep,
            deviceHost: deviceHost
        ),
        discovery: ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: settle),
            sightings: { AsyncStream { $0.finish() } }
        ),
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

// The Clocks tab is the other thing that makes looking worth doing: it is
// where a clock seen advertising itself becomes a configured one, so a tab
// open on an installation whose clock answers perfectly well still needs the
// list fed. The outage arm is the tests above. The tab is the Settings
// window's own now, so the arm is told straight to the model, the way the
// tab's appearances tell it.
@Test @MainActor func openingTheClocksTabLooksEvenWhenTheClockAnswers() async {
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(browsing)
    #expect(await waitUntil { delegate.model.isDeviceOnline })
    delegate.panelMoved(to: aWindow())
    #expect(browsing.liveBrowses == 0)

    delegate.model.clocksSectionVisibilityChanged(true)
    #expect(await waitUntil { browsing.liveBrowses == 1 })

    // And the tab going away takes the browse back down: the clock answers,
    // so the tab was the only reason left to look.
    delegate.model.clocksSectionVisibilityChanged(false)
    #expect(await waitUntil { browsing.liveBrowses == 0 })
    await delegate.model.teardown()
}

// The zero-clocks arm, pinned because a fresh install lands here first and
// the browse rule does not ask it as a separate question: nothing configured
// means nothing answering, so the outage arm holds — a panel open, and with
// it the Clocks section, is a browse. The panel is opened the way the app
// opens it (the window takes key), and the tab adds nothing the zero-clock
// state has not already started.
@Test @MainActor func atZeroClocksAPanelOpenStartsTheBrowseAndTheTabKeepsIt() async {
    let browsing = FakeBonjourBrowser()
    let notifications = NotificationCenter()
    let panel = aWindow()
    let delegate = AppDelegate(
        model: testModel(clocks: [], tiles: []),
        discovery: ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
            sightings: { AsyncStream { $0.finish() } }
        ),
        notifications: notifications
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    #expect(browsing.liveBrowses == 0)

    delegate.panelMoved(to: panel)
    takeFocus(panel, through: notifications)
    #expect(await waitUntil { browsing.liveBrowses == 1 })

    delegate.model.clocksSectionVisibilityChanged(true)
    await afterTheQueuedObserversHaveRun()
    // One browse still, not a second: the tab arm is OR'd onto the
    // zero-clock arm, and an OR restarts nothing that already runs.
    #expect(browsing.starts == 1)
    await delegate.model.teardown()
}

// The tab arm does NOT die with the panel — that was the sheet's rule, when
// the Clocks section was drawn in the panel's window. The tab lives in the
// Settings window now, which has somewhere of its own to show what a browse
// found, so the panel going away leaves the tab's browse standing. It ends
// when the tab does.
@Test @MainActor func theClocksTabKeepsItsBrowseWhenThePanelCloses() async {
    let notifications = NotificationCenter()
    let panel = aWindow()
    let browsing = FakeBonjourBrowser()
    let delegate = launchedForBrowsing(browsing, notifications: notifications)
    #expect(await waitUntil { delegate.model.isDeviceOnline })

    delegate.model.clocksSectionVisibilityChanged(true)
    delegate.panelMoved(to: panel)
    #expect(await waitUntil { browsing.liveBrowses == 1 })

    loseFocus(panel, through: notifications)
    await afterTheQueuedObserversHaveRun()
    #expect(browsing.liveBrowses == 1)

    delegate.model.clocksSectionVisibilityChanged(false)
    #expect(await waitUntil { browsing.liveBrowses == 0 })
    await delegate.model.teardown()
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
        discovery: ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
            sightings: { AsyncStream { $0.finish() } }
        )
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    #expect(await waitUntil { schedule.parked == 1 })
    delegate.discovery.start()

    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(delegate.discovery.found.map(\.name) == ["awtrix_a07f9c"])
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
        model: testModel(defaults: defaults, sleep: Metronome().sleep, pollSleep: Metronome().sleep),
        discovery: ClockDiscovery(
            browse: DeviceBrowser(browsing: { browsing }, sleep: { _ in }),
            sightings: { AsyncStream { $0.finish() } }
        )
    )
    delegate.applicationDidFinishLaunching(Notification(name: .init("launched")))
    // Started directly for the reason the test above starts one: what a report
    // must not do is written down here, not where a browse comes from.
    delegate.discovery.start()

    browsing.emit(.results(["awtrix_a07f9c"]))

    #expect(delegate.discovery.found.map(\.name) == ["awtrix_a07f9c"])
    // The address is the user's to set, through the field, and finding a clock
    // is not the user saying anything. `awtrix_a07f9c` is not a hostname —
    // written here it would point the next launch at nothing that resolves.
    #expect(ClockStore(defaults: defaults).all().contains { $0.address == "awtrix_a07f9c" } == false)
    #expect(delegate.model.deviceHost == "10.0.0.5")
}

// MARK: - The address the next launch will use

// The write half of the brief's step 5, driven the only way it is reachable
// now that no field draws it: through the model property the relocation also
// writes. The rule is unchanged — normalise, refuse a blank, store on the
// record for the next launch.
@Test @MainActor func theAddressTypedIntoThePanelIsWhatTheNextLaunchUses() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try ClockStore(defaults: defaults).replaceAll([
        ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    ])
    defaults.set(true, forKey: ClockMigration.markerKey)
    let subject = AppModel.live(defaults: defaults, anecdoteStore: scratchStore())

    subject.typedHost = "10.0.0.9"

    // Read back the way the app reads it, not the way it was written: a write
    // landing on some other key would change nothing the launch reads.
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
    #expect(AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.9")
}

// Nothing else in the app writes the record's address, so a blank saved would
// come up at the next launch pointed at an empty host.
@Test @MainActor func aBlankAddressIsRefusedRatherThanSaved() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "10.0.0.9", tiles: [])

    subject.typedHost = "   \n "

    // And the address that was there is still there.
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
}

// A pasted address arrives with whatever was around it. `AwtrixDevice` builds
// `http://<host>/api/...` by interpolation, so a stray space is a URL that
// never resolves and a panel that says Disconnected for ever.
@Test @MainActor func theAddressIsTrimmedBeforeItIsSaved() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "10.0.0.5", tiles: [])

    subject.typedHost = "  192.168.1.72\n"

    #expect(ClockStore(defaults: defaults).all().first?.address == "192.168.1.72")
}

// Pasting `http://10.0.0.5` out of the clock's own web interface is the single
// most likely thing anybody does with this field, and it was saved verbatim.
// Every request is then built as `http://http://10.0.0.5/api/stats`, whose host
// is a machine literally named `http`: a permanently unreachable clock, with a
// DNS error in the offline reason and nothing suggesting the address is
// malformed.
//
// Read back the way the app reads it, so a write that normalised for display
// and stored the paste would still be caught.
@Test @MainActor func aPastedAddressIsStoredWithoutItsScheme() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "10.0.0.5", tiles: [])

    subject.typedHost = "http://10.0.0.5/"

    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.5")
    #expect(
        AppModel.live(defaults: defaults, anecdoteStore: scratchStore()).deviceHost == "10.0.0.5"
    )
}

// And an entry nothing can be made of is refused rather than accepted and left
// to fail as a poll a quarter of an hour later, on a different surface, with
// nothing connecting the two.
@Test @MainActor func anAddressThatCannotBeAHostIsRefusedOnTheField() throws {
    let suite = "host-field-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let subject = testModel(defaults: defaults, deviceHost: "10.0.0.9", tiles: [])

    subject.typedHost = "a b"
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
    subject.typedHost = "http://"
    #expect(ClockStore(defaults: defaults).all().first?.address == "10.0.0.9")
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
    let clock = try storeAClock(in: defaults)
    try storeTheMigratedTiles(on: clock, in: defaults)
    let place = StoredLocation(defaults: defaults, clockId: clock.id)

    LocationField.save("52.52, 13.405", to: place)

    // Read back the way the connector reads it, not the way it was written: a
    // field writing some other key would save happily and change nothing.
    #expect(place.current == Coordinates(latitude: 52.52, longitude: 13.405))
}

@Test @MainActor func aLocationNobodyHasTypedFallsBackToSomewhereRatherThanNowhere() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = try storeAClock(in: defaults)
    try storeTheMigratedTiles(on: clock, in: defaults)

    // A connector with no coordinates has nothing to ask about and would report
    // a failure on every poll until somebody opened the settings.
    #expect(StoredLocation(defaults: defaults, clockId: clock.id).current == Coordinates.default)
}

// Open-Meteo answers a 400 for coordinates off the globe, so the panel says so
// rather than the connector reporting a failure a quarter of an hour later.
@Test @MainActor func coordinatesOffTheGlobeAreRefusedRatherThanSaved() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = try storeAClock(in: defaults)
    try storeTheMigratedTiles(on: clock, in: defaults)
    let place = StoredLocation(defaults: defaults, clockId: clock.id)
    place.save(Coordinates(latitude: 52.52, longitude: 13.405))

    for refused in ["91, 0", "-91, 0", "0, 181", "0, -181", "north, east", "52.52", "", "  "] {
        #expect(LocationField.save(refused, to: place) == LocationField.unreadable, "\(refused)")
    }

    // And what was there is still there.
    #expect(place.current == Coordinates(latitude: 52.52, longitude: 13.405))
}

@Test @MainActor func aLocationIsTypedTheWayItIsShown() throws {
    let suite = "location-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let clock = try storeAClock(in: defaults)
    try storeTheMigratedTiles(on: clock, in: defaults)
    let place = StoredLocation(defaults: defaults, clockId: clock.id)

    let shown = LocationField.text(for: Coordinates(latitude: 52.52, longitude: 13.405))
    #expect(LocationField.save(shown, to: place) == LocationField.takesEffectAtTheNextPoll)

    #expect(place.current == Coordinates(latitude: 52.52, longitude: 13.405))
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
    let clock = ClockRecord(name: "Clock", model: .awtrix3, address: "10.0.0.5")
    try ClockStore(defaults: defaults).replaceAll([clock])
    defaults.set(true, forKey: ClockMigration.markerKey)
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

// The panel's second statistic, said by the model the panel reads: a clock
// that has answered reports its charge; a clock that is not answering
// reports nothing, and a TC002 never does.
@Test @MainActor func theBatteryLineSaysWhatTheClockReportsAndNothingWhenItCannot() async {
    let model = testModel(deviceHost: "10.0.0.5")
    let desk = model.clocks[0]

    #expect(model.batteryLine(of: desk) == nil)
    model.start()
    #expect(await waitUntil { model.isDeviceOnline })
    #expect(model.batteryLine(of: desk)?.contains("77%") == true)
    await model.teardown()
}

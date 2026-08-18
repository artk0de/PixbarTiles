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
@Test @MainActor func onlineAndOfflineAreTwoDifferentGlyphs() {
    let lit = AppGlyph.menuBar(lit: true).tiffRepresentation
    let unlit = AppGlyph.menuBar(lit: false).tiffRepresentation

    #expect(lit != nil)
    #expect(lit != unlit)
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
    #expect(subject.registry.all.count == 1)
    // Deliberately not asserting the interval here. `AnecdoteConnector`'s own
    // default IS thirty minutes, so every such assertion holds equally through
    // the store's fallback and proves nothing about debt 2. The
    // `StubConnector(5 * 60)` tests are what carry that rule.
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

// And that the root the app actually ships with is the one both ends get.
@Test @MainActor func theAppsOwnClipRootReachesBothEnds() async {
    let store = FileManager.default.temporaryDirectory
        .appendingPathComponent("wiring-\(UUID().uuidString).json")

    let wiring = AppModel.anecdoteWiring(transport: StubTransport(), storeURL: store)

    #expect(wiring.speech.outputDirectory == AppPaths.clipRoot)
    #expect(wiring.queue.clipRoot == AppPaths.clipRoot)
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

@Test @MainActor func theDeviceHostIsTakenFromDefaultsWhenOneIsSaved() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("10.0.0.9", forKey: AppModel.deviceHostKey)

    #expect(AppModel.live(defaults: defaults).deviceHost == "10.0.0.9")
}

@Test @MainActor func theDeviceHostFallsBackToTheOneOnTheDesk() throws {
    let suite = "app-model-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }

    #expect(AppModel.live(defaults: defaults).deviceHost == "192.168.1.72")
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

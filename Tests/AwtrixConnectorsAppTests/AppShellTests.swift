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

    let subject = AppModel.live(defaults: defaults)

    let connector = try #require(subject.registry.all.first)
    #expect(connector.id == "anecdotes")
    #expect(subject.settings(for: connector).interval == connector.defaultInterval)
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

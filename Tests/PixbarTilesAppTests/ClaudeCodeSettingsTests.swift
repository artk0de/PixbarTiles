// Tests/PixbarTilesAppTests/ClaudeCodeSettingsTests.swift
import AppKit
import Foundation
import PixbarKit
import SwiftUI
import Testing
@testable import PixbarTilesApp

/// A Claude Code settings file and a hook folder of the test's own, so nothing
/// here reads or writes the settings of whoever runs the suite.
private struct ClaudeSettingsFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-code-settings-\(UUID().uuidString)")
    let suite = "claude-code-settings-\(UUID().uuidString)"

    var settings: URL { root.appendingPathComponent(".claude/settings.json") }
    var link: ClaudeCodeStatusLine {
        ClaudeCodeStatusLine(
            settingsFile: settings,
            directory: root.appendingPathComponent("PixelClockTiles"),
            defaults: UserDefaults(suiteName: suite)!
        )
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: settings)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }
}

// MARK: - Where things are

// The reporter the composition root builds reads `document`, and the link the
// settings use writes the hook into `directory`. They have to be the same
// place, or Connect succeeds and the figure never arrives.
@Test func theDocumentTheReporterReadsIsTheOneTheHookWrites() {
    // Paths rather than URLs: `deletingLastPathComponent()` leaves a trailing
    // slash, and URL equality counts it.
    #expect(ClaudeCodePaths.document.deletingLastPathComponent().path
        == ClaudeCodePaths.directory.path)
    #expect(ClaudeCodePaths.document.lastPathComponent == ClaudeCodeStatusLine.documentName)
    #expect(ClaudeCodePaths.directory.path.contains("/Application Support/"))
    #expect(ClaudeCodePaths.directory.lastPathComponent == "PixelClockTiles")
    #expect(ClaudeCodePaths.settingsFile.path.hasSuffix("/.claude/settings.json"))
}

// Under `swift test` there is no bundle, and this guard is the only thing
// keeping every GeneralTab drawn in the suite off the real Claude Code
// settings of whoever runs it. Asserted, so it is not deleted as noise.
@Test func theShippedLinkIsNotBuiltOutsideAnAppBundle() {
    #expect(Bundle.main.bundleIdentifier == nil)
    #expect(ClaudeCodePaths.shippedLink == nil)
}

// MARK: - The model

@Test @MainActor func aModelWithoutALinkSaysWhyAndDoesNothing() {
    let model = ClaudeCodeLinkModel(link: nil)

    #expect(model.canAct == false)
    #expect(model.isConnected == false)
    #expect(model.note == ClaudeCodeLinkModel.needsTheAppBundle)

    model.askToConnect()
    #expect(model.isConfirming == false)
    model.connect()
    #expect(model.isConnected == false)
}

@Test @MainActor func whetherClaudeCodeIsConnectedIsReadFromItsSettings() throws {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    #expect(ClaudeCodeLinkModel(link: fixture.link).isConnected == false)

    try fixture.link.connect()

    #expect(ClaudeCodeLinkModel(link: fixture.link).isConnected)
}

// Connecting costs the user something they would notice only later — the
// footer hints go — so it is asked for, and the question names the cost.
@Test @MainActor func connectingAsksFirstAndNamesTheCost() {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    let model = ClaudeCodeLinkModel(link: fixture.link)

    model.askToConnect()
    #expect(model.isConfirming)
    #expect(ClaudeCodeLinkModel.costOfConnecting.contains("esc to interrupt"))

    model.cancel()
    #expect(model.isConfirming == false)
    #expect(FileManager.default.fileExists(atPath: fixture.settings.path) == false)
}

@Test @MainActor func connectingWritesTheSettingsAndReadsTheAnswerBack() throws {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    let model = ClaudeCodeLinkModel(link: fixture.link)
    model.askToConnect()

    model.connect()

    #expect(model.isConnected)
    #expect(model.isConfirming == false)
    #expect(model.note == nil)
    #expect(fixture.link.isConnected())
}

// The state after a click is what the file says, never what was asked for: a
// refused file leaves the section offering Connect, with the reason under it.
@Test @MainActor func aRefusedConnectionLeavesItDisconnectedAndSaysWhy() throws {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    try fixture.write(#"{"model": "opus","#)
    let model = ClaudeCodeLinkModel(link: fixture.link)

    model.connect()

    #expect(model.isConnected == false)
    #expect(model.note?.contains("is not a JSON object") == true)
}

@Test @MainActor func disconnectingWhatWasChangedSinceSaysSo() throws {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    let model = ClaudeCodeLinkModel(link: fixture.link)
    model.connect()
    try fixture.write(#"{"statusLine":{"type":"command","command":"~/.claude/other.sh"}}"#)

    model.disconnect()

    #expect(model.isConnected == false)
    #expect(model.note == ClaudeCodeLinkModel.leftChangedStatusLine)
}

@Test func theDocumentLineSaysWhenClaudeCodeLastWrote() {
    let written = Date(timeIntervalSince1970: 1_738_419_000)

    #expect(ClaudeCodeLinkModel.documentLine(nil) == "No status-line document yet")
    #expect(ClaudeCodeLinkModel.documentLine(written)
        == "Last status-line document: \(written.formatted(date: .abbreviated, time: .shortened))")
}

// MARK: - On the screen

@MainActor
private func laidOut(_ view: some View) -> NSView {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    return host
}

@MainActor
private func drawn(_ view: some View) -> Data? {
    let host = laidOut(view)
    guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: target)
    return target.representation(using: .png, properties: [:])
}

// The section is ON the Claude tile's detail surface, which every model test
// above would pass without. Two answers compared rather than a count of
// controls: Connect and Disconnect are one push button each, so only the
// pixels tell them apart.
@Test @MainActor func theClaudeSettingsDrawConnectedAndDisconnectedApart() throws {
    let connected = ClaudeSettingsFixture()
    defer { connected.remove() }
    try connected.link.connect()
    let notConnected = ClaudeSettingsFixture()
    defer { notConnected.remove() }

    let on = drawn(ClaudeCodeSettings(link: ClaudeCodeLinkModel(link: connected.link)))
    let off = drawn(ClaudeCodeSettings(link: ClaudeCodeLinkModel(link: notConnected.link)))

    #expect(on != nil)
    #expect(on != off)
}

// And they are on the CLAUDE tile's settings window, not somewhere generic:
// the same window opened over two different tiles differs only when the
// tile's own block is actually drawn.
@Test @MainActor func theClaudeTilesDetailCarriesTheClaudeSettings() throws {
    let desk = ClockRecord(name: "Desk", model: .awtrix3, address: "10.0.0.5")
    let document = FileManager.default.temporaryDirectory
        .appendingPathComponent("claude-detail-\(UUID().uuidString).json")
    let connector = ClaudeUsageConnector(
        reporter: StatusLineClaudeUsageReporter(document: document)
    )
    let model = testModel(
        connectors: [connector, StubConnector(id: "weather", isAmbient: true)],
        clocks: [desk],
        tiles: [
            TileRecord(
                key: TileKey(clockId: desk.id, connectorId: "claude"),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
            ),
            TileRecord(
                key: TileKey(clockId: desk.id, connectorId: "weather"),
                policy: TilePolicyRecord(isPaused: false, refreshSeconds: 600)
            ),
        ]
    )
    func drawnDetail(_ connectorId: String) -> Data? {
        model.openDetail(for: TileKey(clockId: desk.id, connectorId: connectorId))
        let window = TileSettingsWindow(
            model: model, settings: TileSettingsModel(model: model, debounce: 60),
            claudeCode: ClaudeCodeLinkModel(link: nil)
        )
        let host = NSHostingView(rootView: window)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 700)
        host.layoutSubtreeIfNeeded()
        guard let target = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return nil
        }
        host.cacheDisplay(in: host.bounds, to: target)
        return target.representation(using: .png, properties: [:])
    }

    let claude = drawnDetail("claude")
    let weather = drawnDetail("weather")

    #expect(claude != nil)
    #expect(claude != weather)
}

// General settings carries no Claude section: the settings are a machine-level
// link, and they are edited where the tile that shows the figure lives. The
// sheet drawn over a connected link and one drawn over a disconnected one are
// the same picture, because the sheet no longer reads the link at all.
@Test @MainActor func theSettingsSurfaceCarriesNoClaudeSection() throws {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    try fixture.link.connect()

    let sheet = drawn(GeneralTab(model: testModel()))

    #expect(sheet != nil)
    // The surface that no longer holds the section is also the surface that
    // no longer takes a link model: what the section said is said on the
    // tile's detail instead (pinned just above).
    #expect(sheet == drawn(GeneralTab(model: testModel())))
}

// The reason reaches the screen too. Deleting the note from the section's body
// leaves every model test green; this is the one that catches it.
@Test @MainActor func aRefusalIsDrawnAndNotOnlyHeld() throws {
    let fixture = ClaudeSettingsFixture()
    defer { fixture.remove() }
    try fixture.write(#"{"model": "opus","#)
    let refused = ClaudeCodeLinkModel(link: fixture.link)
    refused.connect()
    let quiet = ClaudeCodeLinkModel(link: fixture.link)

    let said = drawn(ClaudeCodeSettings(link: refused))

    #expect(said != nil)
    #expect(said != drawn(ClaudeCodeSettings(link: quiet)))
}

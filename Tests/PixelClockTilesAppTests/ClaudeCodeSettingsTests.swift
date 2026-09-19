// Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift
import AppKit
import Foundation
import PixelClockKit
import SwiftUI
import Testing
@testable import PixelClockTilesApp

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
// keeping every `SettingsSheet(model:)` in the suite off the real Claude Code
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

// Tests/PixbarKitTests/ClaudeCodeStatusLineTests.swift
import Foundation
import Testing
@testable import PixbarKit

// Connecting edits one key of somebody else's settings file, so every test
// here works on a copy: a settings file under a temporary home, a hook folder
// with a space in its name, and a defaults suite of its own. None of them
// reads or writes the settings of whoever runs the suite.

private struct ClaudeLinkScratch {
    let root: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "claude-link-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }

    var settings: URL { root.appendingPathComponent(".claude/settings.json") }
    var directory: URL { root.appendingPathComponent("Application Support/PixelClockTiles") }
    var link: ClaudeCodeStatusLine {
        ClaudeCodeStatusLine(settingsFile: settings, directory: directory, defaults: defaults)
    }

    func writeSettings(_ text: String) throws {
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: settings)
    }

    func settingsBytes() throws -> Data {
        try Data(contentsOf: settings)
    }

    func settingsObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: settingsBytes()) as? [String: Any])
    }

    func mode(of url: URL) throws -> Int? {
        try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

/// A settings file with the kinds of keys a real one carries.
private let claudeSettings = #"""
{
  "model": "opus",
  "permissions": { "allow": ["Bash(ls:*)"], "deny": [] },
  "env": { "DISABLE_TELEMETRY": "1" },
  "includeCoAuthoredBy": false,
  "cleanupPeriodDays": 30
}
"""#

/// A settings file with a status line of its own, carrying the optional fields
/// Claude Code documents.
private let settingsWithAStatusLine = #"""
{
  "model": "opus",
  "statusLine": {
    "type": "command",
    "command": "~/.claude/statusline.sh",
    "padding": 2,
    "refreshInterval": 5
  }
}
"""#

// MARK: - Connect

@Test func connectingWithNoSettingsFileCreatesOneHoldingOnlyTheStatusLine() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }

    try scratch.link.connect()

    let root = try scratch.settingsObject()
    #expect(root.keys.sorted() == ["statusLine"])
    let line = try #require(root["statusLine"] as? [String: Any])
    #expect(line["type"] as? String == "command")
    #expect(line["command"] as? String
        == ClaudeCodeStatusLine.command(hook: scratch.link.hook, chaining: nil))
    // Nothing was replaced, so there is nothing to put back.
    #expect(scratch.defaults.object(forKey: ClaudeCodeStatusLine.previousKey) == nil)
}

@Test func theHookIsInstalledAsTheShippedScriptForItsOwnerAlone() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }

    try scratch.link.connect()

    #expect(try Data(contentsOf: scratch.link.hook) == Data(ClaudeCodeStatusLine.script.utf8))
    #expect(try scratch.mode(of: scratch.link.hook) == 0o700)
}

@Test func connectingKeepsEveryOtherKeyAsItWas() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(claudeSettings)
    let before = try scratch.settingsObject()

    try scratch.link.connect()

    var after = try scratch.settingsObject()
    #expect(after.removeValue(forKey: "statusLine") != nil)
    #expect(NSDictionary(dictionary: after).isEqual(to: before))
}

// The previous line keeps showing, through the hook, and keeps its padding and
// its timer: everything but `command` is the user's and stays theirs.
@Test func connectingOverAStatusLineChainsItsCommandAndKeepsItsOtherFields() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(settingsWithAStatusLine)

    try scratch.link.connect()

    let line = try #require(try scratch.settingsObject()["statusLine"] as? [String: Any])
    #expect(line["command"] as? String == ClaudeCodeStatusLine.command(
        hook: scratch.link.hook, chaining: "~/.claude/statusline.sh"
    ))
    #expect(line["type"] as? String == "command")
    #expect(line["padding"] as? Int == 2)
    #expect(line["refreshInterval"] as? Int == 5)
    #expect(scratch.defaults.data(forKey: ClaudeCodeStatusLine.previousKey) != nil)
}

// A half-finished edit, JSON with a comment in it, an array: writing over any
// of them would lose what the user had, so the file is left exactly as it was
// and nothing else happens either.
@Test func aSettingsFileThatIsNotAJSONObjectIsLeftAloneAndSaysWhy() throws {
    for text in [#"{"model": "opus","#, "[1, 2]", "", #"{ // mine"# + "\n}"] {
        let scratch = try ClaudeLinkScratch()
        defer { scratch.remove() }
        try scratch.writeSettings(text)

        #expect(throws: ClaudeCodeSettingsRefusal.notAJSONObject(path: scratch.settings.path)) {
            try scratch.link.connect()
        }
        #expect(try scratch.settingsBytes() == Data(text.utf8), "\(text)")
        #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path) == false)
        #expect(scratch.defaults.object(forKey: ClaudeCodeStatusLine.previousKey) == nil)
    }
}

@Test func anUnreadableSettingsFileIsLeftAloneAndSaysWhy() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(claudeSettings)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o000], ofItemAtPath: scratch.settings.path
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: scratch.settings.path
        )
    }

    #expect(throws: ClaudeCodeSettingsRefusal.unreadable(path: scratch.settings.path)) {
        try scratch.link.connect()
    }
}

// A settings file can hold secrets under `env`, and a rename-based write would
// otherwise hand the new file the default mode. 0o640 is unusual on purpose:
// it tells "kept" apart from "reset to 0644" and from "forced to 0600".
@Test func aWriteKeepsTheSettingsFilesPermissions() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(claudeSettings)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o640], ofItemAtPath: scratch.settings.path
    )

    try scratch.link.connect()

    #expect(try scratch.mode(of: scratch.settings) == 0o640)
}

// Dotfiles repositories keep `settings.json` as a symlink. The write goes to
// the file the link points at, and the link stays a link.
@Test func aSymlinkedSettingsFileStaysALinkAndItsTargetIsWritten() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    let dotfiles = scratch.root.appendingPathComponent("dotfiles/claude-settings.json")
    try FileManager.default.createDirectory(
        at: dotfiles.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data(claudeSettings.utf8).write(to: dotfiles)
    try FileManager.default.createDirectory(
        at: scratch.settings.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(at: scratch.settings, withDestinationURL: dotfiles)

    try scratch.link.connect()

    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: scratch.settings.path)
        == dotfiles.path)
    let target = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: dotfiles)) as? [String: Any]
    )
    #expect(target["statusLine"] != nil)
}

@Test func noStagingFileIsLeftBehind() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(claudeSettings)

    try scratch.link.connect()

    #expect(try FileManager.default.contentsOfDirectory(
        atPath: scratch.settings.deletingLastPathComponent().path
    ) == ["settings.json"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: scratch.directory.path)
        == [ClaudeCodeStatusLine.hookName])
}

// Claude Code is never pointed at a hook that is not there. With a plain file
// where the hook's folder should be, the hook cannot be written, and the
// settings must come out exactly as they went in.
@Test func theHookIsInPlaceBeforeClaudeCodeIsPointedAtIt() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(claudeSettings)
    try FileManager.default.createDirectory(
        at: scratch.directory.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data().write(to: scratch.directory)

    #expect(throws: (any Error).self) {
        try scratch.link.connect()
    }
    #expect(try scratch.settingsBytes() == Data(claudeSettings.utf8))
}

// MARK: - Disconnect

@Test func disconnectingPutsThePreviousStatusLineBackExactly() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(settingsWithAStatusLine)
    let before = try scratch.settingsObject()
    try scratch.link.connect()

    #expect(try scratch.link.disconnect() == .restored)

    #expect(NSDictionary(dictionary: try scratch.settingsObject()).isEqual(to: before))
    #expect(scratch.defaults.object(forKey: ClaudeCodeStatusLine.previousKey) == nil)
}

// Absent, not `null`: there was no key before, so there is no key after.
@Test func disconnectingWhenThereWasNoStatusLineRemovesTheKey() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(claudeSettings)
    let before = try scratch.settingsObject()
    try scratch.link.connect()

    try scratch.link.disconnect()

    let after = try scratch.settingsObject()
    #expect(after["statusLine"] == nil)
    #expect(NSDictionary(dictionary: after).isEqual(to: before))
}

// The figure leaves the clock with the document: the reporter reads nothing
// once it is gone, and the tile lapses at the end of its lifetime.
@Test func disconnectingTakesTheHookAndTheDocumentAway() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.link.connect()
    try Data("{}".utf8).write(to: scratch.link.document)

    try scratch.link.disconnect()

    #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path) == false)
    #expect(FileManager.default.fileExists(atPath: scratch.link.document.path) == false)
}

// Somebody — the user, or Claude Code's own `/statusline` — replaced this
// app's status line after it connected. Putting the old one back would destroy
// theirs, so the file is left alone and this app forgets what it held.
@Test func aStatusLineChangedSinceConnectingIsLeftAsItIs() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(settingsWithAStatusLine)
    try scratch.link.connect()
    let theirs = #"{"statusLine":{"type":"command","command":"~/.claude/other.sh"}}"#
    try scratch.writeSettings(theirs)

    #expect(try scratch.link.disconnect() == .leftAlone)

    #expect(try scratch.settingsBytes() == Data(theirs.utf8))
    #expect(scratch.defaults.object(forKey: ClaudeCodeStatusLine.previousKey) == nil)
    #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path) == false)
}

// A second Connect must not record this app's own status line as "previous":
// Disconnect would then put the hook back instead of the user's line.
@Test func connectingTwiceKeepsTheFirstPrevious() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(settingsWithAStatusLine)
    let before = try scratch.settingsObject()
    try scratch.link.connect()
    let once = try scratch.settingsBytes()

    try scratch.link.connect()
    #expect(try scratch.settingsBytes() == once)

    try scratch.link.disconnect()
    #expect(NSDictionary(dictionary: try scratch.settingsObject()).isEqual(to: before))
}

// Connected is read from the file every time. A command that merely STARTS
// like this app's — the hook's path with something glued to it — is not this
// app's.
@Test func connectedMeansTheSettingsPointAtThisHookAndAtNothingThatMerelyStartsLikeIt() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    #expect(scratch.link.isConnected() == false)

    try scratch.link.connect()
    #expect(scratch.link.isConnected())

    let base = ClaudeCodeStatusLine.command(hook: scratch.link.hook, chaining: nil)
    let lookalike = try JSONSerialization.data(
        withJSONObject: ["statusLine": ["type": "command", "command": base + "x"]]
    )
    try lookalike.write(to: scratch.settings)
    #expect(scratch.link.isConnected() == false)

    try scratch.writeSettings(settingsWithAStatusLine)
    #expect(scratch.link.isConnected() == false)
}

// A settings file that cannot be read is not evidence of anything. Disconnect
// refuses before it touches the hook or the stored previous value, since the
// settings may still point at both.
@Test func disconnectingOverAnUnparseableSettingsFileTouchesNothing() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.writeSettings(settingsWithAStatusLine)
    try scratch.link.connect()
    try scratch.writeSettings(#"{"statusLine": "#)

    #expect(throws: ClaudeCodeSettingsRefusal.notAJSONObject(path: scratch.settings.path)) {
        try scratch.link.disconnect()
    }
    #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path))
    #expect(scratch.defaults.data(forKey: ClaudeCodeStatusLine.previousKey) != nil)
}

// MARK: - The hook after an update, and the last document

// An app update may ship a different script. Claude Code would go on running
// the old one, and nothing would say so.
@Test func aHookThatDriftedIsRewrittenWhileConnected() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.link.connect()
    try Data("#!/bin/sh\n# an older hook\n".utf8).write(to: scratch.link.hook)

    try scratch.link.refreshHookIfConnected()

    #expect(try Data(contentsOf: scratch.link.hook) == Data(ClaudeCodeStatusLine.script.utf8))
    #expect(try scratch.mode(of: scratch.link.hook) == 0o700)
}

// While Claude Code points at a hook that is not there, its status row is
// broken; putting the hook back mends it.
@Test func aMissingHookIsPutBackWhileConnected() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.link.connect()
    try FileManager.default.removeItem(at: scratch.link.hook)

    try scratch.link.refreshHookIfConnected()

    #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path))
}

@Test func nothingIsInstalledWhileNotConnected() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }

    try scratch.link.refreshHookIfConnected()
    #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path) == false)

    try scratch.writeSettings(settingsWithAStatusLine)
    try scratch.link.refreshHookIfConnected()
    #expect(FileManager.default.fileExists(atPath: scratch.link.hook.path) == false)
}

// A hook that already matches is not rewritten. Its modification time is the
// witness.
@Test func aHookThatMatchesIsLeftUntouched() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    try scratch.link.connect()
    let old = Date(timeIntervalSince1970: 1_000_000_000)
    try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: scratch.link.hook.path
    )

    try scratch.link.refreshHookIfConnected()

    #expect(try FileManager.default.attributesOfItem(atPath: scratch.link.hook.path)[
        .modificationDate
    ] as? Date == old)
}

@Test func theLastDocumentTimeIsWhenTheHookLastWroteOne() throws {
    let scratch = try ClaudeLinkScratch()
    defer { scratch.remove() }
    #expect(scratch.link.lastDocumentAt() == nil)

    try FileManager.default.createDirectory(
        at: scratch.directory, withIntermediateDirectories: true
    )
    try Data("{}".utf8).write(to: scratch.link.document)
    // In the future, on purpose: APFS moves a fresh file's creation date along
    // when its modification date is set into the past, which would let a
    // `.creationDate` reading pass for the real one. A future time leaves the
    // creation date where it is, so the two are tellable apart.
    let written = Date(timeIntervalSince1970: 1_938_419_000)
    try FileManager.default.setAttributes(
        [.modificationDate: written], ofItemAtPath: scratch.link.document.path
    )

    #expect(scratch.link.lastDocumentAt() == written)
}

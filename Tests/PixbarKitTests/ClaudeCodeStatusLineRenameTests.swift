import Foundation
import Testing
@testable import PixbarKit

// Connecting wrote a command into Claude Code's settings that runs the hook in
// the app's own folder, and the folder was renamed with the app: a user who
// connected as PixelClockTiles has `/bin/sh '…/PixelClockTiles/claude-statusline.sh'`
// in their settings. That command is still this app's — it must read as
// connected, and the launch's refresh must point it at the new folder while
// keeping the status line it chains to. Every test works on a scratch home,
// as the other status-line tests do.

private struct RenameScratch {
    let root: URL
    let suite: String
    let defaults: UserDefaults

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-rename-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "claude-rename-\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    var settings: URL { root.appendingPathComponent(".claude/settings.json") }
    var directory: URL { root.appendingPathComponent("Application Support/PixbarTiles") }
    var oldDirectory: URL { root.appendingPathComponent("Application Support/PixelClockTiles") }
    var oldHook: URL { oldDirectory.appendingPathComponent(ClaudeCodeStatusLine.hookName) }

    var link: ClaudeCodeStatusLine {
        ClaudeCodeStatusLine(
            settingsFile: settings, directory: directory, defaults: defaults,
            legacyDirectories: [oldDirectory]
        )
    }

    /// Settings holding the command the old build wrote, with the fields a
    /// status line carries beside it.
    func writeOldCommand(chaining previous: String?) throws {
        let line: [String: Any] = [
            "type": "command",
            "command": ClaudeCodeStatusLine.command(hook: oldHook, chaining: previous),
            "padding": 2,
        ]
        let root: [String: Any] = ["model": "opus", "statusLine": line]
        try FileManager.default.createDirectory(
            at: settings.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try JSONSerialization.data(withJSONObject: root).write(to: settings)
    }

    func statusLine() throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: settings))
        let root = try #require(object as? [String: Any])
        return try #require(root["statusLine"] as? [String: Any])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suite)
    }
}

@Test func aCommandUnderTheOldFolderIsStillThisAppsConnection() throws {
    let scratch = try RenameScratch()
    defer { scratch.remove() }
    try scratch.writeOldCommand(chaining: "~/.claude/statusline.sh")

    #expect(scratch.link.isConnected())
}

// The launch's refresh moves the command to the new hook. What it chains to is
// the user's own status line and arrives verbatim — quotes and all — and every
// other field stays theirs. The hook is written before the settings name it.
@Test func theRefreshPointsAnOldCommandAtTheNewHookKeepingWhatItChains() throws {
    let scratch = try RenameScratch()
    defer { scratch.remove() }
    let previous = #"printf '%s' "it's mine""#
    try scratch.writeOldCommand(chaining: previous)

    try scratch.link.refreshHookIfConnected()

    let line = try scratch.statusLine()
    #expect(line["command"] as? String
        == ClaudeCodeStatusLine.command(hook: scratch.link.hook, chaining: previous))
    #expect(line["padding"] as? Int == 2)
    #expect(line["type"] as? String == "command")
    #expect(try Data(contentsOf: scratch.link.hook) == Data(ClaudeCodeStatusLine.script.utf8))
}

@Test func theRefreshPointsAnOldCommandWithNothingChainedAtTheNewHook() throws {
    let scratch = try RenameScratch()
    defer { scratch.remove() }
    try scratch.writeOldCommand(chaining: nil)

    try scratch.link.refreshHookIfConnected()

    #expect(try scratch.statusLine()["command"] as? String
        == ClaudeCodeStatusLine.command(hook: scratch.link.hook, chaining: nil))
}

// Connect over the old command is the same move, never a chain of this app's
// own hook to itself.
@Test func connectingOverTheOldCommandMovesItRatherThanChainingIt() throws {
    let scratch = try RenameScratch()
    defer { scratch.remove() }
    try scratch.writeOldCommand(chaining: "~/.claude/statusline.sh")

    try scratch.link.connect()

    #expect(try scratch.statusLine()["command"] as? String == ClaudeCodeStatusLine.command(
        hook: scratch.link.hook, chaining: "~/.claude/statusline.sh"
    ))
}

// Disconnecting under the old command still puts back what the old build
// replaced — the value it remembered travelled with the defaults.
@Test func disconnectingUnderTheOldCommandPutsThePreviousStatusLineBack() throws {
    let scratch = try RenameScratch()
    defer { scratch.remove() }
    try scratch.writeOldCommand(chaining: "~/.claude/statusline.sh")
    let remembered = ["statusLine": ["type": "command", "command": "~/.claude/statusline.sh"]]
    scratch.defaults.set(
        try JSONSerialization.data(withJSONObject: remembered), forKey: ClaudeCodeStatusLine.previousKey
    )

    #expect(try scratch.link.disconnect() == .restored)
    #expect(try scratch.statusLine()["command"] as? String == "~/.claude/statusline.sh")
}

// Only the named folders count: a link that knows no old folder does not claim
// the old command, and a command that merely starts like the old hook is not
// this app's.
@Test func anOldCommandIsOursOnlyThroughTheFoldersTheLinkNames() throws {
    let scratch = try RenameScratch()
    defer { scratch.remove() }
    try scratch.writeOldCommand(chaining: nil)
    let unaware = ClaudeCodeStatusLine(
        settingsFile: scratch.settings, directory: scratch.directory, defaults: scratch.defaults
    )
    #expect(unaware.isConnected() == false)

    let lookalike: [String: Any] = ["statusLine": [
        "type": "command",
        "command": ClaudeCodeStatusLine.command(hook: scratch.oldHook, chaining: nil) + "x",
    ]]
    try JSONSerialization.data(withJSONObject: lookalike).write(to: scratch.settings)
    #expect(scratch.link.isConnected() == false)
}

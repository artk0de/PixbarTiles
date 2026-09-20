import Foundation
import Testing
@testable import PixelClockKit

// The hook, run the way Claude Code runs a status line: `sh -c` over the
// command this app writes into Claude Code's settings, with a document on
// stdin. Nothing here parses the script. It is executed, because that is the
// only way to know what a shell makes of it.

/// A folder shaped like the one the app writes to: a space in its name, as
/// "Application Support" has, and an apostrophe, which is what breaks naive
/// quoting.
private struct HookFolder {
    let url: URL
    var hook: URL { url.appendingPathComponent(ClaudeCodeStatusLine.hookName) }
    var document: URL { url.appendingPathComponent(ClaudeCodeStatusLine.documentName) }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Application Support 'lane C' \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(ClaudeCodeStatusLine.script.utf8).write(to: hook)
    }

    var storedDocument: String? {
        (try? Data(contentsOf: document)).map { String(decoding: $0, as: UTF8.self) }
    }

    func command(chaining previous: String? = nil) -> String {
        ClaudeCodeStatusLine.command(hook: hook, chaining: previous)
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

private struct StatusLineRun {
    let status: Int32
    let output: String
}

/// Runs a status-line command as Claude Code does, and waits for it.
///
/// SIGPIPE is ignored and the throwing write is used, so a hook broken by a
/// mutation that exits before reading its input fails the test instead of
/// killing the test process.
private func runStatusLine(_ command: String, input: String) throws -> StatusLineRun {
    signal(SIGPIPE, SIG_IGN)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    try? stdin.fileHandleForWriting.write(contentsOf: Data(input.utf8))
    try? stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return StatusLineRun(
        status: process.terminationStatus, output: String(decoding: output, as: UTF8.self)
    )
}

/// What a session sends before its first reply: no `rate_limits` yet.
private let beforeTheFirstReply = #"{"model":{"display_name":"Opus"},"session_id":"abc"}"#

@Test func aDocumentCarryingRateLimitsIsStoredWholeAndNothingIsPrinted() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    let run = try runStatusLine(folder.command(), input: statusLineDocument)

    #expect(run.status == 0)
    // With nothing chained the hook prints nothing. What Claude Code draws for
    // an empty status line is HANDOFF item C3.
    #expect(run.output == "")
    #expect(folder.storedDocument == statusLineDocument + "\n")
}

// A session that has not had its first reply yet must not blank the figure
// another session wrote.
@Test func aDocumentWithoutRateLimitsLeavesTheStoredOneAlone() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    _ = try runStatusLine(folder.command(), input: beforeTheFirstReply)
    #expect(folder.storedDocument == nil)

    _ = try runStatusLine(folder.command(), input: statusLineDocument)
    _ = try runStatusLine(folder.command(), input: beforeTheFirstReply)
    #expect(folder.storedDocument == statusLineDocument + "\n")
}

@Test func thePreviousStatusLineGetsTheSameInputAndItsOutputIsShown() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    let run = try runStatusLine(folder.command(chaining: "cat"), input: statusLineDocument)

    #expect(run.status == 0)
    #expect(run.output == statusLineDocument + "\n")
    #expect(folder.storedDocument == statusLineDocument + "\n")
}

// The document is stored BEFORE the previous line runs, so a previous line
// that fails, hangs until Claude Code cancels it, or is not there any more
// costs the figure nothing. Its exit status is passed on, so Claude Code sees
// the previous line exactly as it would without this hook in front of it.
@Test func aPreviousStatusLineThatFailsStillLeavesTheDocumentBehind() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    let run = try runStatusLine(
        folder.command(chaining: "echo partial; exit 3"), input: statusLineDocument
    )

    #expect(run.status == 3)
    #expect(run.output == "partial\n")
    #expect(folder.storedDocument == statusLineDocument + "\n")
}

@Test func aPreviousCommandWithQuotesInItSurvivesTheChain() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    let run = try runStatusLine(
        folder.command(chaining: #"printf '%s\n' "it's""#), input: beforeTheFirstReply
    )

    #expect(run.output == "it's\n")
}

// The document carries the session's working directory and transcript path.
@Test func theStoredDocumentIsReadableByItsOwnerAlone() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    _ = try runStatusLine(folder.command(), input: statusLineDocument)

    let mode = try FileManager.default
        .attributesOfItem(atPath: folder.document.path)[.posixPermissions] as? Int
    #expect(mode == 0o600)
}

// The staging file is renamed over the document, never copied, so nothing
// piles up beside the hook.
@Test func nothingButTheHookAndTheDocumentIsLeftInTheFolder() throws {
    let folder = try HookFolder()
    defer { folder.remove() }

    _ = try runStatusLine(folder.command(), input: statusLineDocument)
    _ = try runStatusLine(folder.command(), input: beforeTheFirstReply)
    _ = try runStatusLine(folder.command(chaining: "exit 3"), input: statusLineDocument)

    let names = try FileManager.default.contentsOfDirectory(atPath: folder.url.path).sorted()
    #expect(names == [ClaudeCodeStatusLine.documentName, ClaudeCodeStatusLine.hookName].sorted())
}

@Test func aQuotedArgumentIsOneWordToTheShell() {
    #expect(ClaudeCodeStatusLine.quoted("it's here") == #"'it'\''s here'"#)
    let hook = URL(fileURLWithPath: "/a b/claude-statusline.sh")
    #expect(ClaudeCodeStatusLine.command(hook: hook, chaining: nil)
        == "/bin/sh '/a b/claude-statusline.sh'")
    #expect(ClaudeCodeStatusLine.command(hook: hook, chaining: "x y")
        == "/bin/sh '/a b/claude-statusline.sh' 'x y'")
}

import Foundation

/// Why Claude Code's settings file was left as it was.
///
/// Its own error rather than whatever Foundation threw, because it reaches the
/// user as the sentence under the Connect button.
public enum ClaudeCodeSettingsRefusal: Error, Equatable, LocalizedError {
    /// The file is there and is not one JSON object: a half-finished edit, a
    /// comment, an array. Writing over it would throw away whatever the user
    /// was in the middle of.
    case notAJSONObject(path: String)
    /// The file is there and this app may not read it.
    case unreadable(path: String)

    public var errorDescription: String? {
        switch self {
        case let .notAJSONObject(path):
            "\(path) is not a JSON object, so it was left as it is."
        case let .unreadable(path):
            "\(path) could not be read, so it was left as it is."
        }
    }
}

/// Claude Code's `statusLine` setting, pointed at this app's hook and back.
///
/// One key of one file, and only when the user asks. Every other key keeps its
/// value; formatting and key order do not survive a rewrite, values do. The
/// value this replaces is kept in the app's defaults under `previousKey`, and
/// its command is chained by the hook, so a status line the user already had
/// goes on showing.
public struct ClaudeCodeStatusLine {
    public static let previousKey = "claudeStatusLine.previous"
    public static let hookName = "claude-statusline.sh"
    public static let documentName = "claude-status.json"

    /// Claude Code's user settings, `~/.claude/settings.json` in the app.
    public let settingsFile: URL
    /// This app's own folder. The hook, and the document it writes, live here.
    public let directory: URL
    private let defaults: UserDefaults

    public init(settingsFile: URL, directory: URL, defaults: UserDefaults) {
        self.settingsFile = settingsFile
        self.directory = directory
        self.defaults = defaults
    }

    public var hook: URL { directory.appendingPathComponent(Self.hookName) }
    public var document: URL { directory.appendingPathComponent(Self.documentName) }

    /// Points Claude Code's status line at the hook.
    ///
    /// The order is the safety argument. The settings are read, and refused,
    /// before anything is written. The replaced value is remembered before it
    /// is replaced. The hook is on disk before Claude Code is told to run it.
    public func connect() throws {
        var root = try readSettings()
        let previous = root["statusLine"]
        try remember(previous)
        try installHook()
        root["statusLine"] = replacement(for: previous)
        try writeSettings(root)
    }

    // MARK: - Settings

    /// The settings as one object. An absent file reads as an empty one, which
    /// is how Connect creates it.
    private func readSettings() throws -> [String: Any] {
        let file = settingsFile.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
        guard let data = try? Data(contentsOf: file) else {
            throw ClaudeCodeSettingsRefusal.unreadable(path: settingsFile.path)
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ClaudeCodeSettingsRefusal.notAJSONObject(path: settingsFile.path)
        }
        return root
    }

    /// Writes through a staged file and a rename, onto the file a symlink
    /// points at, keeping the mode the file had. A file created here is the
    /// owner's alone.
    private func writeSettings(_ root: [String: Any]) throws {
        let file = settingsFile.resolvingSymlinksInPath()
        let data = try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        let mode = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.posixPermissions]
            as? Int
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Self.replace(file, with: data, permissions: mode ?? 0o600)
    }

    /// The previous status line with `command` pointed at the hook. Every other
    /// field — `padding`, `refreshInterval`, anything newer — stays the user's.
    private func replacement(for previous: Any?) -> [String: Any] {
        var line = previous as? [String: Any] ?? [:]
        let chained = (line["command"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        line["type"] = "command"
        line["command"] = Self.command(hook: hook, chaining: chained)
        return line
    }

    /// Keeps the value Connect replaces, or forgets there was one. Wrapped in
    /// an object so any JSON value survives the trip, `null` included.
    private func remember(_ previous: Any?) throws {
        guard let previous else {
            defaults.removeObject(forKey: Self.previousKey)
            return
        }
        let wrapped = try JSONSerialization.data(withJSONObject: ["statusLine": previous])
        defaults.set(wrapped, forKey: Self.previousKey)
    }

    // MARK: - Hook

    private func installHook() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.replace(hook, with: Data(Self.script.utf8), permissions: 0o700)
    }

    /// Writes `data` beside `file` and renames it over, so a crash leaves the
    /// old file or the new one and never half of either.
    static func replace(_ file: URL, with data: Data, permissions: Int) throws {
        let staged = file.deletingLastPathComponent()
            .appendingPathComponent(".\(file.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(
            atPath: staged.path, contents: data, attributes: [.posixPermissions: permissions]
        ) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: staged.path])
        }
        guard rename(staged.path, file.path) == 0 else {
            let failure = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: staged)
            throw failure
        }
    }

    /// What Claude Code runs after each reply once connected.
    ///
    /// It reads stdin once. A document carrying `rate_limits` is stored whole
    /// beside the script, through a staging file and `mv`, which is atomic on
    /// one volume. Then the status line configured before this one, passed as
    /// the first argument, gets the same input and its output and exit status
    /// are passed through. It uses no `jq` and no interpreter: the script
    /// stores, and the app parses.
    ///
    /// Storing comes first so that a previous line that fails, or is cancelled
    /// mid-run, costs the figure nothing. `umask 077` makes the document the
    /// owner's alone; it carries the session's working directory.
    static let script = #"""
    #!/bin/sh
    # PixelClockTiles keeps Claude Code's rate limits here for the clock, then
    # hands the status line to the command that was configured before it, if any.
    # The app rewrites this file whenever it differs from the copy it ships.
    umask 077
    here=${0%/*}
    input=$(cat)
    case $input in
    *'"rate_limits"'*)
        staged="$here/claude-status.json.$$"
        printf '%s\n' "$input" > "$staged" && mv -f "$staged" "$here/claude-status.json" || rm -f "$staged"
        ;;
    esac
    if [ -n "$1" ]; then
        printf '%s\n' "$input" | /bin/sh -c "$1"
        exit
    fi
    """#

    /// The `command` written into Claude Code's settings.
    ///
    /// Run through `/bin/sh` rather than directly, so the hook needs no exec bit
    /// and no shebang lookup, and quoted, because the app's folder sits under
    /// "Application Support". The previous command rides as an argument rather
    /// than in a file beside the hook, which bounds the chain by the text
    /// itself: nothing the hook reads can point it back at itself.
    static func command(hook: URL, chaining previous: String?) -> String {
        let base = "/bin/sh \(quoted(hook.path))"
        guard let previous else { return base }
        return "\(base) \(quoted(previous))"
    }

    /// One shell word, whatever the text holds: single quotes, with each `'`
    /// written as `'\''`.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}

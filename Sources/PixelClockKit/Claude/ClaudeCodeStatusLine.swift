import Foundation

/// Claude Code's `statusLine` setting, pointed at this app's hook and back.
public struct ClaudeCodeStatusLine {
    public static let hookName = "claude-statusline.sh"
    public static let documentName = "claude-status.json"

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

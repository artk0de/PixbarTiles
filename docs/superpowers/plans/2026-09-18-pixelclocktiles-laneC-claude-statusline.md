# PixelClockTiles lane C — Claude usage from Claude Code's status line

> **For agentic workers:** REQUIRED SUB-SKILL: Use `dinopowers:executing-plans` (it wraps `superpowers:executing-plans`) or `superpowers:subagent-driven-development` to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Claude tile stops handling a credential. A POSIX `sh` hook that the app writes into its own folder stores every Claude Code status-line document that carries `rate_limits`, and `StatusLineClaudeUsageReporter` reads the stored document on each refresh. Connect and Disconnect edit only the `statusLine` key of `~/.claude/settings.json`. The keychain reader, the credential file reader, the HTTP reporter and `ClaudeUsageReading.init?(json:)` are deleted along with their tests.

**Architecture:** The reading and the settings edit are kit logic, in `PixelClockKit/Claude/`: `StatusLineClaudeUsageReporter` (an actor that conforms to the existing `ClaudeUsageReporting` seam) and `ClaudeCodeStatusLine` (the hook text, the command, and the connect, disconnect and refresh operations over injected URLs and defaults). The app target contributes three small pieces. `ClaudeCodePaths` holds the real locations and returns no link at all outside an app bundle. `ClaudeCodeLinkModel` and `ClaudeCodeSettings` are one section on the current settings surface, built the way `LoginItemModel` and `LoginItemSettings` are. The composition root changes by one line.

**Tech Stack:** Swift 6.3.3, SwiftPM tools 6.0, macOS 14 floor, swift-testing, Swift 6 strict concurrency, Foundation and SwiftUI only, `/bin/sh` for the hook.

**Spec:** `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md`, sections § "Claude usage — read from Claude Code's status line", decision 11, the lane C row of § Phases, and the related bullets in § General settings, § Persistence and migration, § Error handling, § Testing and § Out of scope.

**External contract:** <https://code.claude.com/docs/en/statusline>, fetched 2026-09-18. `rate_limits.five_hour` and `rate_limits.seven_day` each carry `used_percentage` (0–100) and `resets_at` (Unix epoch seconds). They are present only for Pro and Max, only after the first API response of a session, and each window can be absent on its own. Claude Code drops a window once its `resets_at` passes. The script runs after each assistant message, debounced at 300 ms, and an in-flight run is cancelled when a new update arrives. It also runs when a window reaches its `resets_at`. A script that prints nothing or exits non-zero blanks the status row. A custom status line hides most footer hints, `esc to interrupt` among them. The hooks page says command strings run under `sh -c` on macOS.

**Where to work:** the lane C worktree off `feat/pixelclocktiles`, after phase 0 (the rename) has landed. Every path below uses the new names.

## Global Constraints

The "Global Constraints" of `docs/superpowers/plans/2026-08-17-awtrix-connectors.md` still bind. The ones this lane leans on:

- Swift tools version `6.0`, platform floor `.macOS(.v14)`, Swift 6 strict concurrency. A type that crosses an actor boundary is `Sendable`.
- **No third-party dependencies.** The hook uses no `jq` and no interpreter. `sh`, `cat`, `printf`, `mv` and `rm` are all it needs: the script stores, and the app parses.
- Every identifier, comment, commit message and document is in English.
- Zero build warnings on both targets.

Lane rules:

- **No test reads or writes the real `~/.claude/settings.json`, and none writes the real Application Support folder.** Tests build `ClaudeCodeStatusLine` over temporary directories and a scratch `UserDefaults` suite. The shipped link (`ClaudeCodePaths.shippedLink`) is `nil` whenever `Bundle.main.bundleIdentifier` is `nil`, which is always true under `swift test`. `SystemLoginItem.isBundled` uses the same guard, for the same reason.
- No network calls to `192.168.1.72`. Nothing in this lane talks to a clock.
- Mutation discipline, as `docs/HANDOFF.md` lays it down: mutate one site at a time. After adding a guard, re-run the mutations of the guards it sits in front of. Each task below lists its mutations. Revert each mutation before starting the next.
- Git is used by the executor only: one commit per task, with the message given in the task.

## Re-verify before executing

Phase 0 is running as this plan is written, and phases 1 and 2 run beside it. Check these first, and fix the plan in place if one fails.

1. **Phase 0 landed.** Run `ls Sources/PixelClockKit/Claude Sources/PixelClockTilesApp Tests/PixelClockKitTests Tests/PixelClockTilesAppTests`. Expected: all four exist, and `Sources/PixelClockKit/Claude` holds `ClaudeCredentials.swift`, `ClaudeUsage.swift`, `ClaudeUsageBand.swift`, `ClaudeUsageReading.swift` and `ClaudeUsageReporter.swift`. Test files import `@testable import PixelClockKit` and `@testable import PixelClockTilesApp`.
2. **The Application Support folder name.** Run `grep -n 'appendingPathComponent("' Sources/PixelClockTilesApp/AppModel.swift` and read `AppPaths.anecdoteStore`. The spec names the folder `PixelClockTiles`, and `ClaudeCodePaths.directory` (Task 8) writes that literal. If phase 0 kept `AwtrixConnectors`, or added a shared support-directory constant, use the folder phase 0 settled on, so the hook sits beside the rest of the app's data, and change Task 8's `theDocumentTheReporterReadsIsTheOneTheHookWrites` to match.
3. **The seam phase 2 keeps.** Run `grep -n "protocol ClaudeUsageReporting" -A4 Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift`. Expected: `func read() async throws -> ClaudeUsageReading?`. Phase 2 may already have split the connector into `read()` and `awtrixFace`. That changes nothing here as long as this requirement and `init(reporter:showsNow:)` are intact.
4. **The reporter line in `live()`.** Run `grep -n "ClaudeUsageReporter(transport: transport)" Sources/PixelClockTilesApp/AppModel.swift`. Expected: one hit, L586 at `39d7072`. Locate it by text if it has moved.
5. **The block Task 11 deletes.** Run `grep -n "MARK: - Reading the service's answer\|MARK: - What reaches the device" Tests/PixelClockKitTests/ClaudeUsageTests.swift`. Expected: L51 and L123 at `39d7072`.
6. **The status-line contract.** Re-fetch <https://code.claude.com/docs/en/statusline> and confirm that the `rate_limits` field names, the epoch-seconds `resets_at` and "runs in a shell" are unchanged. If the page now names a shell other than `sh`, change the hook's `/bin/sh -c "$1"` to match.
7. **Baselines.** Run `swift test --filter ClaudeUsageTests`. Expected: 14 tests pass. Then run `swift test` and note the total, so that Task 11's deletion can be checked against it.

## Decisions settled in this plan

| # | Question | Decision | Why |
| --- | --- | --- | --- |
| L1 | How the hook learns the previous command | The command is an argument in the `command` written into settings: `/bin/sh '<hook>' '<previous command>'`. There is no sidecar file. | A sidecar that got the app's own command written into it by a second Connect would have the hook chain into itself for ever. An argument bounds the chain by the text itself, and the settings file shows the user what runs. The previous value is still kept in `claudeStatusLine.previous` for Disconnect, as the spec says. |
| L2 | Paths with spaces and quotes | Every path and the chained command are single-quoted, with `'` written as `'\''`. The hook is run as `/bin/sh '<path>'`, so it needs no exec bit and no shebang lookup. | "Application Support" has a space. `'\''` is valid in `sh`, `bash`, `zsh` and `fish`. Measured on this machine: a folder named `… Application Support 'lane C'` survives `sh -c`. |
| L3 | The previous `statusLine`'s other fields | Kept. The replacement object is the previous one with `type` set to `"command"` and `command` replaced, so `padding`, `refreshInterval`, `hideVimModeIndicator` and any unknown key stay. | The chained output is the previous line's, so its padding still applies. |
| L4 | What Disconnect restores | If the settings still point at this hook: the previous value exactly as it was stored (object, `null` or string), or the key removed when there was none. Otherwise the settings are left alone and the model says so. Either way the stored previous value, the hook and the document are removed. | Restoring over a status line the user set up after connecting would destroy it. Deleting the document lets the figure leave the clock at the end of its lifetime instead of standing until the weekly reset. |
| L5 | Connect while already connected | A no-op. | Otherwise the app's own command would become the stored "previous" one, and Disconnect would put the hook back. |
| L6 | File modes | Hook `0700`. Document `0600`, from `umask 077` inside the hook. The settings file keeps whatever mode it had, and a newly created one is `0600`. | Owner-only. The document holds session data such as `cwd` and `transcript_path`. A rename-based write would otherwise reset a `0600` settings file, which may hold `env` secrets, to `0644`. |
| L7 | Rewriting the hook when it drifts | Yes. At launch, from `AppDelegate.applicationDidFinishLaunching`, and only while the settings point at the hook. The comparison is byte for byte against `ClaudeCodeStatusLine.script`. A matching hook is not rewritten. A missing one is put back. | An app update that changes the script would otherwise leave the old one running with nothing to say so. |
| L8 | Atomic writes | Settings and hook are written to a staged file beside the target, then `rename(2)`. The target's symlinks are resolved first. In the hook, the document goes through `claude-status.json.$$` and then `mv -f`. | A crash leaves the old file or the new one. A dotfiles symlink stays a symlink. `$$` keeps two sessions writing at once from sharing a staging file. |
| L9 | Order inside Connect | Read and validate settings, remember the previous value, install the hook, and only then write the settings. | Claude Code is never pointed at a hook that is not on disk, and a refused file costs nothing. |
| L10 | Which documents the reporter trusts | A missing document means no reading. Otherwise each window is taken from the document if both its fields are numbers, and from this process's memory if not. A document that is not JSON, or has no `rate_limits` object, counts as "both windows missing". The answer is `nil` once the weekly `resets_at` is at or before now. An expired five-hour window becomes `fiveHour == nil` rather than a stale figure. | Deleting the document is how Disconnect takes the figure away. One rule for every other shape of document is simpler than a guard per shape, and the hook's text match can let through a document whose only `"rate_limits"` is inside a session name. |
| L11 | `observedAt` | The document's modification time, set on every reading. No view reads it in this lane. The settings line reads the same modification time through `ClaudeCodeStatusLine.lastDocumentAt()`, because that line has to show a time even when there is no reading (a reset week, for example). | See "Spec findings" below. |
| L12 | Where the settings line comes from | `ClaudeCodeLinkModel`, which is a `@StateObject` of its own section, like `LoginItemSettings`. `AppModel` gains nothing for it. | This keeps the `AppModel` edit to the reporter line. The state belongs to the file, not to the schedule. |
| L13 | Unbundled builds | `ClaudeCodePaths.shippedLink` is `nil` without a bundle id, so the section says Connect needs the app bundle. | This is the only guard that keeps every existing `SettingsSheet(model:)` test off the real settings file without editing those tests. |
| L14 | The hook's output when nothing is chained | It prints nothing and exits 0. When a command is chained, the hook exits with that command's status. | The spec leaves the output to the chained line. The documentation says an empty output blanks the row. C3 in HANDOFF checks what that looks like. |

## tea-rags impact enrichment

`semantic_search` with `rerank: "blastRadius"` over the ten existing files returned zero results, with the codegraph drift warning the parent reported (`master: 286018a → 8751a97`). Nothing was reindexed, as instructed. The signals below come from `git log` on `feat/pixelclocktiles`. The "Fix" column counts commits whose subject starts with `fix`.

| File (old path on disk) | Commits | Fix | Last | Role here |
| --- | --- | --- | --- | --- |
| `Sources/AwtrixKit/Claude/ClaudeCredentials.swift` | 2 | 1 | 2026-08-26 | deleted |
| `Sources/AwtrixKit/Claude/ClaudeUsageReporter.swift` | 2 | 1 | 2026-08-26 | deleted |
| `Sources/AwtrixKit/Claude/ClaudeUsageReading.swift` | 2 | 0 | 2026-08-20 | modified |
| `Sources/AwtrixKit/Connectors/ClaudeUsageConnector.swift` | 2 | 0 | 2026-08-20 | doc comment only |
| `Sources/AwtrixConnectorsApp/AppModel.swift` | 31 | 13 | 2026-09-10 | one line and its comment |
| `Sources/AwtrixConnectorsApp/SettingsSheet.swift` | 11 | 0 | 2026-09-10 | one parameter, one line |
| `Sources/AwtrixConnectorsApp/App.swift` | 9 | 6 | 2026-08-20 | one line |
| `Tests/AwtrixKitTests/ClaudeUsageReporterTests.swift` | 2 | 1 | 2026-08-26 | deleted |
| `Tests/AwtrixKitTests/ClaudeUsageTests.swift` | 4 | 1 | 2026-08-20 | one block deleted |
| `docs/HANDOFF.md` | 13 | 1 | 2026-08-20 | append-only |

The two hot files are `AppModel.swift` (42% of its commits are fixes) and `App.swift` (67%). Each gets a single isolated line, in its own task (Task 10), so a regression in either can be bisected to one commit. Everything else is new code in new files.

## File map

| Action | Path | Task |
| --- | --- | --- |
| Modify | `Sources/PixelClockKit/Claude/ClaudeUsageReading.swift` | 1, 11 |
| Create | `Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift` | 1–3 |
| Create | `Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift` | 1–3 |
| Create | `Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift` | 4–7 |
| Create | `Tests/PixelClockKitTests/ClaudeStatusLineHookTests.swift` | 4 |
| Create | `Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift` | 5–7 |
| Create | `Sources/PixelClockTilesApp/ClaudeCodeSettings.swift` | 8, 9 |
| Create | `Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift` | 8, 9 |
| Modify | `Sources/PixelClockTilesApp/SettingsSheet.swift` | 9 |
| Modify | `Sources/PixelClockTilesApp/AppModel.swift` (`live()`, reporter line and its comment) | 10 |
| Modify | `Sources/PixelClockTilesApp/App.swift` (`applicationDidFinishLaunching`) | 10 |
| Modify | `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` (doc comment of `ClaudeUsageReporting`, L3–13) | 10 |
| Delete | `Sources/PixelClockKit/Claude/ClaudeCredentials.swift` | 11 |
| Delete | `Sources/PixelClockKit/Claude/ClaudeUsageReporter.swift` | 11 |
| Delete | `Tests/PixelClockKitTests/ClaudeUsageReporterTests.swift` | 11 |
| Modify | `Tests/PixelClockKitTests/ClaudeUsageTests.swift` (delete L51–121) | 11 |
| Modify | `docs/HANDOFF.md` (append) | 12 |

### Existing symbols this plan references, verified at `39d7072`

| Symbol | Where (old path) | Real signature |
| --- | --- | --- |
| `ClaudeUsageReporting` | `Connectors/ClaudeUsageConnector.swift:10–14` | `public protocol ClaudeUsageReporting: Sendable { func read() async throws -> ClaudeUsageReading? }` |
| `ClaudeUsageConnector.init` | `Connectors/ClaudeUsageConnector.swift:49–55` | `public init(reporter: any ClaudeUsageReporting, showsNow: @escaping @Sendable () -> Bool = { true })` |
| `ClaudeUsageReading` | `Claude/ClaudeUsageReading.swift:9–62` | `public struct ClaudeUsageReading: Sendable, Equatable` with `public let utilization: Int`, `public let resetsAt: Date?`, `public init(utilization: Int, resetsAt: Date?)`, `public init?(json: Data)`, `static let weeklyBar = "seven_day"`, `private static func moment(from text: String) -> Date?` |
| `ClaudeUsageReporter` | `Claude/ClaudeUsageReporter.swift:9,43–49` | `public struct ClaudeUsageReporter: ClaudeUsageReporting`, `public init(transport: any Transport = URLSessionTransport(), credentials: any ClaudeCredentialReading = AnyClaudeCredentials())` |
| `ClaudeCredentialReading` and its three readers | `Claude/ClaudeCredentials.swift:18,33,81,98,120` | `public protocol ClaudeCredentialReading: Sendable { func accessToken() -> String? }`, `public struct KeychainClaudeCredentials`, `public struct FileClaudeCredentials`, `public struct AnyClaudeCredentials`, `enum ClaudeCredentialSearch` |
| `AppModel.live` | `AwtrixConnectorsApp/AppModel.swift:535–539` | `static func live(defaults: UserDefaults = .standard, transport: any Transport = URLSessionTransport(), anecdoteStore: URL = AppPaths.anecdoteStore) -> AppModel` |
| `AppPaths.anecdoteStore` | `AwtrixConnectorsApp/AppModel.swift:107–115` | `static let anecdoteStore: URL`, today under `Application Support/AwtrixConnectors` |
| `AppDelegate.applicationDidFinishLaunching` | `AwtrixConnectorsApp/App.swift:282–286` | `func applicationDidFinishLaunching(_ notification: Notification)` |
| `SettingsSheet.init` | `AwtrixConnectorsApp/SettingsSheet.swift:28–36` | `init(model: AppModel, loginItem: @autoclosure @escaping () -> LoginItemModel = LoginItemModel(), defaults: UserDefaults = .standard)` |
| `LoginItemSettings.init` (template) | `AwtrixConnectorsApp/SettingsSheet.swift:235–237` | `init(item: @autoclosure @escaping () -> LoginItemModel = LoginItemModel())` |
| `SystemLoginItem.isBundled` (template) | `AwtrixConnectorsApp/LoginItem.swift:178` | `static var isBundled: Bool { Bundle.main.bundleIdentifier != nil }` |
| `testModel(...)` | `AwtrixConnectorsAppTests/Doubles.swift:451` | `func testModel(connectors: [any Connector] = [StubConnector()], …) -> AppModel`, every parameter defaulted |
| `usageBody` | `AwtrixKitTests/ClaudeUsageTests.swift:61` | `let usageBody = """…"""`, used only by `ClaudeUsageTests.swift` and `ClaudeUsageReporterTests.swift` |

### New symbols and their production callers

| New symbol | Production caller in this plan |
| --- | --- |
| `ClaudeUsageWindow` | built by `StatusLineClaudeUsageReporter.window(_:)`; the type of `ClaudeUsageReading.fiveHour` |
| `ClaudeUsageReading.fiveHour`, `.observedAt`, the four-argument `init` | `StatusLineClaudeUsageReporter.read()` (Task 3) |
| `StatusLineClaudeUsageReporter` | `AppModel.live()` (Task 10) |
| `ClaudeCodeStatusLine`, `connect()`, `disconnect()`, `isConnected()`, `lastDocumentAt()` | `ClaudeCodeLinkModel` (Task 8) |
| `ClaudeCodeStatusLine.refreshHookIfConnected()` | `AppDelegate.applicationDidFinishLaunching` (Task 10) |
| `ClaudeCodeStatusLine.script`, `command(hook:chaining:)`, `quoted(_:)`, `replace(_:with:permissions:)` | `connect()`, `installHook()`, `isOurs(_:)` (Tasks 5–7) |
| `ClaudeCodeStatusLine.Disconnection` | returned to `ClaudeCodeLinkModel.disconnect()` |
| `ClaudeCodeSettingsRefusal` | thrown by `readSettings()`, shown by `ClaudeCodeLinkModel` |
| `ClaudeCodePaths.directory`, `.settingsFile`, `.document`, `.shippedLink` | `AppModel.live()`, `ClaudeCodeLinkModel.init`, `AppDelegate` |
| `ClaudeCodeLinkModel` | `ClaudeCodeSettings` (Task 9) |
| `ClaudeCodeSettings` | `SettingsSheet.body` (Task 9) |

## Contact points with parallel lanes

Line numbers are as of `39d7072`. Locate by symbol if they have moved.

| File / symbol | Lane C does | Other lane | Merge rule |
| --- | --- | --- | --- |
| `AppModel.live()`: the comment at L578–582 and `reporter: ClaudeUsageReporter(transport: transport),` at L586 | replaces both (Task 10) | **Phase 1** rewrites how `deviceHost` and `store` are obtained. **Phase 2** makes three edits in `live()` and has written down that it never edits the reporter line. | disjoint lines. Keep lane C's lines and re-apply the others on top. |
| `ClaudeUsageReading(utilization:resetsAt:)` | kept. The two new parameters default to `nil` (Task 1). | **Phase 2**'s `ConnectorFaceTests` constructs it | compatible by construction |
| `ClaudeUsageConnector.init(reporter:showsNow:)`, `output(for:)`, `Failure` | not changed | **Phase 2** splits `produce()` into `read()` and `awtrixFace` | no overlap |
| `ClaudeUsageConnector.swift` L3–13, the doc comment on `ClaudeUsageReporting` | rewords the comment, leaves the signature alone (Task 10) | **Phase 2** edits L24 onwards (type rename, L57–62, L76–80) | disjoint hunks |
| `ClaudeUsageReading.swift`, `ClaudeCredentials.swift`, `ClaudeUsageReporter.swift`, `ClaudeUsageReporterTests.swift` | modifies or deletes | Phase 2 has written down that it does not touch them | no overlap |
| `Tests/PixelClockKitTests/ClaudeUsageTests.swift` | deletes L51–121, the `init?(json:)` block and `usageBody` (Task 11) | Phase 2 (D11) keeps its drawing tests in this file without editing it | no overlap. If phase 2 did edit it after all, the hunks are disjoint (phase 2's are at L123 onwards). |
| `SettingsSheet.init` and `body` | adds the `claudeCode:` parameter and one line in `body` (Task 9) | **Phase 1** may touch `deviceHostSection`. **Phase 5** later splits the surface into `ClocksSettings` and friends. | disjoint lines. Phase 5 moves `ClaudeCodeSettings(link:)` as it is. |
| `App.swift`, `applicationDidFinishLaunching` | appends one line (Task 10) | **Phase 0** renamed the `App` struct at L9 | disjoint |
| The Application Support folder name | reads `ClaudeCodePaths.directory` | **Phase 0** owns the folder policy | re-verify item 2 |
| `AppShellTests.nothingButTheAnecdotesEverPutsSoundInTheRoom` | not edited. It now produces the Claude connector over the app's own `claude-status.json` instead of the keychain and the network. | **Phase 2** renames `produce()` in it | nothing to merge |
| `ClaudeUsageReading.fiveHour`, `.observedAt` | provided | **Phase 3b** (TC002 Claude face) needs only `utilization`. **Phase 5** (`TileRowLine`) is the natural reader of `observedAt`. | additive |
| `docs/HANDOFF.md` | appends one section (Task 12) | every lane | append-only, merged by concatenation. Items carry a `C` prefix so they do not collide with other lanes' numbers. |

---

### Task 1: The weekly figure out of a status-line document

**Files:**
- Modify: `Sources/PixelClockKit/Claude/ClaudeUsageReading.swift`
- Create: `Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift`
- Test: `Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift`

**Interfaces:**
- Consumes: `ClaudeUsageReporting` (`func read() async throws -> ClaudeUsageReading?`), `ClaudeUsageReading.init(utilization:resetsAt:)`.
- Produces:
  - `public struct ClaudeUsageWindow: Sendable, Equatable { public let utilization: Int; public let resetsAt: Date; public init(utilization: Int, resetsAt: Date) }`
  - `ClaudeUsageReading` gains `public let fiveHour: ClaudeUsageWindow?` and `public let observedAt: Date?`, and its memberwise `init` becomes `init(utilization: Int, resetsAt: Date?, fiveHour: ClaudeUsageWindow? = nil, observedAt: Date? = nil)`.
  - `public actor StatusLineClaudeUsageReporter: ClaudeUsageReporting` with `public init(document: URL, now: @escaping @Sendable () -> Date = { Date() })`.

**Templates** (read by hand, since tea-rags returned nothing): `ClaudeUsageReading.init?(json:)` for tolerant `JSONSerialization` reading, where an explicit `null` reads as absent and rounding is to the nearest whole percent. `ClaudeUsageTests.swift` for the fixture-as-string style.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift
import Foundation
import Testing
@testable import PixelClockKit

// The weekly figure, read from what Claude Code's status line leaves behind.
//
// Claude Code hands its status-line command a JSON document on stdin after
// each reply, and this app's hook stores the ones that carry `rate_limits`.
// The shape is a documented contract — https://code.claude.com/docs/en/statusline
// — where `/api/oauth/usage`, which this replaces, never was.

/// The document as Claude Code's documentation gives it, trimmed to the fields
/// around `rate_limits` but not reshaped. `spend_limit` is left in: it rides in
/// the same object behind a gateway, and nothing here may mistake it for a
/// window this app reads.
let statusLineDocument = #"""
{
  "cwd": "/current/working/directory",
  "session_id": "abc123...",
  "model": { "id": "claude-opus-5", "display_name": "Opus" },
  "workspace": {
    "current_dir": "/current/working/directory",
    "project_dir": "/original/project/directory"
  },
  "version": "2.1.90",
  "cost": { "total_cost_usd": 0.01234, "total_duration_ms": 45000 },
  "context_window": { "used_percentage": 8, "remaining_percentage": 92 },
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day": { "used_percentage": 41.2, "resets_at": 1738857600 },
    "spend_limit": { "used_percentage": 62.8, "resets_at": 1740787200 }
  }
}
"""#

/// Before either window in `statusLineDocument` resets.
private let beforeEitherReset = Date(timeIntervalSince1970: 1_738_420_000)

/// When the documents below were written, unless a test says otherwise.
private let writtenAt = Date(timeIntervalSince1970: 1_738_419_000)

/// A folder of its own holding the document, with a modification time the test
/// chooses — `observedAt` is that time, so it has to be known.
private struct StatusDocumentFolder {
    let url: URL
    var document: URL { url.appendingPathComponent("claude-status.json") }

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("status-document-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ json: String, modified: Date = writtenAt) throws {
        try Data(json.utf8).write(to: document)
        try FileManager.default.setAttributes(
            [.modificationDate: modified], ofItemAtPath: document.path
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
    }
}

@Test func theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    try folder.write(statusLineDocument)
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    let reading = try #require(await reporter.read())

    #expect(reading.utilization == 41)
    #expect(reading.resetsAt == Date(timeIntervalSince1970: 1_738_857_600))
    #expect(reading.fiveHour == ClaudeUsageWindow(
        utilization: 24, resetsAt: Date(timeIntervalSince1970: 1_738_425_600)
    ))
    // The file's own time, not the moment it was read: the settings line and
    // any later "updated 3 min ago" are about when Claude Code last spoke.
    #expect(reading.observedAt == writtenAt)
}

// Nearest, because a bar drawn at 78 with the number 79 beside it is the kind
// of disagreement nobody can explain. Claude Code sends fractions.
@Test func aFractionalPercentageIsRoundedToTheNearestWholeOne() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    try folder.write(#"{"rate_limits":{"seven_day":{"used_percentage":78.4,"resets_at":1738857600}}}"#)
    let low = try #require(await reporter.read())
    try folder.write(#"{"rate_limits":{"seven_day":{"used_percentage":78.6,"resets_at":1738857600}}}"#)
    let high = try #require(await reporter.read())

    #expect(low.utilization == 78)
    #expect(high.utilization == 79)
}

// Nil, never zero: zero is a real figure meaning "nothing spent this week".
@Test func noDocumentIsNoReading() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    #expect(try await reporter.read() == nil)
}

// A window is read only when both of its figures are there. Without
// `resets_at` there is no telling when the figure stops being true, and a
// window that can never expire would stand on the clock for ever.
@Test func aWindowNeedsBothItsFiguresAndANullIsAbsence() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    for document in [
        #"{"rate_limits":{"seven_day":null}}"#,
        #"{"rate_limits":{"seven_day":{"used_percentage":41.2}}}"#,
        #"{"rate_limits":{"seven_day":{"resets_at":1738857600}}}"#,
        #"{"rate_limits":{"seven_day":{"used_percentage":"41","resets_at":1738857600}}}"#,
    ] {
        try folder.write(document)
        #expect(try await reporter.read() == nil, "\(document)")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StatusLineClaudeUsageReporterTests`
Expected: FAIL to compile, with `cannot find 'StatusLineClaudeUsageReporter' in scope` and `cannot find 'ClaudeUsageWindow' in scope`.

- [ ] **Step 3: Write minimal implementation**

`ClaudeUsageReading.swift` in full. `init?(json:)` stays until Task 11, because `ClaudeUsageReporter` still calls it until Task 10. It now sets the two new fields to `nil`.

```swift
// Sources/PixelClockKit/Claude/ClaudeUsageReading.swift
import Foundation

/// One reading of the weekly allowance.
///
/// `utilization` is a percentage Claude reported, not something derived here,
/// and it is allowed past a hundred: an overage channel keeps serving after the
/// bar is full, and a reading of a hundred and forty is a true thing to say
/// about a week.
public struct ClaudeUsageReading: Sendable, Equatable {
    public let utilization: Int
    /// When this week's bar starts again, when the source says so.
    public let resetsAt: Date?
    /// The rolling five-hour window, when the source reported one. Carried, and
    /// drawn by no face yet.
    public let fiveHour: ClaudeUsageWindow?
    /// When the document this came from was written: its modification time.
    /// Nil for a reading that did not come from a document.
    public let observedAt: Date?

    /// The two newer fields default to nil, so a reading built from a figure
    /// alone — every drawing test, every face — reads as it always did.
    public init(
        utilization: Int,
        resetsAt: Date?,
        fiveHour: ClaudeUsageWindow? = nil,
        observedAt: Date? = nil
    ) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.fiveHour = fiveHour
        self.observedAt = observedAt
    }

    /// The weekly bar out of an answer from `/api/oauth/usage`.
    ///
    /// The bars are TOP-LEVEL KEYS, not a list — `five_hour`, `seven_day`, and
    /// a set of per-model weekly ones. This was captured from a live answer
    /// rather than assumed, after a first version invented a `rate_limits`
    /// array and passed its own tests against its own invention.
    ///
    /// Three details that all have to be right at once, and each of which fails
    /// silently on its own: the per-model bars come back as explicit `null` on
    /// an account with no split, so a null has to read as absence rather than
    /// as a zero bar; `utilization` is FRACTIONAL, so reading it as an integer
    /// throws every value away; and `resets_at` carries sub-second precision
    /// and an offset, which the default ISO-8601 reader declines without a word.
    ///
    /// Nil for anything that is not a weekly reading, and that is the whole
    /// point of the initialiser being failable: zero is a real reading meaning
    /// "nothing spent yet", so answering zero for an unparseable body would put
    /// a confident, calm, wrong number on the clock.
    public init?(json: Data) {
        guard
            let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
            let weekly = root[Self.weeklyBar] as? [String: Any],
            let utilization = weekly["utilization"] as? Double
        else { return nil }

        // Nearest whole percent. The bar and the number beside it are drawn from
        // this one value, so rounding here is what keeps them from disagreeing.
        self.utilization = Int(utilization.rounded())
        self.resetsAt = (weekly["resets_at"] as? String).flatMap(Self.moment(from:))
        self.fiveHour = nil
        self.observedAt = nil
    }

    /// The name the service gives the weekly bar. Written down once, here,
    /// because it is a wire value and not a word this app chose.
    static let weeklyBar = "seven_day"

    /// The service's timestamps carry fractional seconds; some fields elsewhere
    /// do not. Both are tried rather than assumed, because the failure mode of
    /// guessing is a reset time that is silently nil.
    private static func moment(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// One of Claude Code's rate-limit windows: how much of it is gone, and when it
/// starts again.
public struct ClaudeUsageWindow: Sendable, Equatable {
    public let utilization: Int
    public let resetsAt: Date

    public init(utilization: Int, resetsAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}
```

```swift
// Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift
import Foundation

/// The weekly figure, out of the document Claude Code's status line leaves in
/// this app's folder.
///
/// Claude Code runs its status-line command after each reply and hands it a
/// JSON document on stdin. This app's hook stores the ones that carry
/// `rate_limits`, whole, and this reads the stored one. It is a local read, so
/// it happens on every refresh and nothing watches the file.
public actor StatusLineClaudeUsageReporter: ClaudeUsageReporting {
    private let document: URL
    /// Read from Task 3 on, when a window that has reset stops being a reading.
    private let now: @Sendable () -> Date

    public init(document: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.document = document
        self.now = now
    }

    public func read() async throws -> ClaudeUsageReading? {
        guard let data = try? Data(contentsOf: document) else { return nil }
        let limits = Self.rateLimits(in: data)
        guard let weekly = Self.window(limits["seven_day"]) else { return nil }
        return ClaudeUsageReading(
            utilization: weekly.utilization,
            resetsAt: weekly.resetsAt,
            fiveHour: Self.window(limits["five_hour"]),
            observedAt: modificationDate()
        )
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: document.path))?[.modificationDate]
            as? Date
    }

    /// The `rate_limits` object, or an empty one for a document that has none
    /// or is not JSON at all.
    private static func rateLimits(in data: Data) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return root?["rate_limits"] as? [String: Any] ?? [:]
    }

    /// One window, or nil unless both of its figures are numbers.
    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard
            let window = value as? [String: Any],
            let used = window["used_percentage"] as? Double,
            let resets = window["resets_at"] as? Double
        else { return nil }
        // Nearest whole percent. The bar and the number beside it are drawn from
        // this one value, so rounding here is what keeps them from disagreeing.
        return ClaudeUsageWindow(
            utilization: Int(used.rounded()),
            resetsAt: Date(timeIntervalSince1970: resets)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StatusLineClaudeUsageReporterTests`
Expected: PASS, 4 tests.

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS, 14 tests. The two-argument initializer still compiles everywhere.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| R1 | `Int(used.rounded())` → `Int(used)` | `swift test --filter StatusLineClaudeUsageReporterTests` | FAIL `aFractionalPercentageIsRoundedToTheNearestWholeOne`, `theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong` |
| R2 | take `let resets = window["resets_at"] as? Double` out of the `guard` and write `let resets = (window["resets_at"] as? Double) ?? .greatestFiniteMagnitude` below it | same | FAIL `aWindowNeedsBothItsFiguresAndANullIsAbsence` |
| R3 | `limits["seven_day"]` → `limits["spend_limit"]` in `read()` | same | FAIL `theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong` (63, not 41) |
| R4 | `observedAt: modificationDate()` → `observedAt: Date()` | same | FAIL `theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong` |
| R5 | the missing-file guard: `guard let data = try? Data(contentsOf: document) else { return nil }` → `let data = (try? Data(contentsOf: document)) ?? Data()` | same | **survives here, and that is expected**: with no memory yet, an empty document is already no reading. Task 2 makes it killable and re-runs it. |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/ClaudeUsageReading.swift \
        Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift \
        Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift
git commit -m "feat: read the Claude figure from the status-line document"
```

---

### Task 2: A window the next document leaves out keeps its last value

**Files:**
- Modify: `Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift`
- Test: `Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift`

**Interfaces:**
- Consumes: Task 1's reporter.
- Produces: no new API. `read()` now remembers the last `seven_day` and `five_hour` windows this process saw.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift`:

```swift
// MARK: - A document missing a window

// Each window can be absent on its own, and the spec's rule is to keep the last
// value this process saw for it. Blanking the weekly figure because one reply
// carried only the five-hour window would take a true number off the clock.
@Test func aWindowMissingFromTheNextDocumentKeepsTheLastValueSeen() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )
    try folder.write(statusLineDocument)
    _ = try await reporter.read()

    let later = Date(timeIntervalSince1970: 1_738_419_500)
    try folder.write(
        #"{"rate_limits":{"five_hour":{"used_percentage":30,"resets_at":1738425600}}}"#,
        modified: later
    )
    let weeklyKept = try #require(await reporter.read())

    #expect(weeklyKept.utilization == 41)
    #expect(weeklyKept.resetsAt == Date(timeIntervalSince1970: 1_738_857_600))
    #expect(weeklyKept.fiveHour?.utilization == 30)
    // The document read is the new one, even though its week came from memory.
    #expect(weeklyKept.observedAt == later)

    // And the other way round.
    try folder.write(#"{"rate_limits":{"seven_day":{"used_percentage":44,"resets_at":1738857600}}}"#)
    let fiveHourKept = try #require(await reporter.read())

    #expect(fiveHourKept.utilization == 44)
    #expect(fiveHourKept.fiveHour?.utilization == 30)
}

// Every other shape of document counts as "both windows missing". The hook
// stores anything whose TEXT contains "rate_limits" — a session renamed
// "rate_limits" is enough — and a document with no windows is no reason to
// take a figure off the clock that nothing has contradicted.
@Test func aDocumentWithNoWindowsKeepsTheLastValuesSeen() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )
    try folder.write(statusLineDocument)
    _ = try await reporter.read()

    try folder.write(#"{"session_name":"rate_limits","model":{"display_name":"Opus"}}"#)
    #expect(try await reporter.read()?.utilization == 41)

    try folder.write("not json at all")
    #expect(try await reporter.read()?.utilization == 41)
}

// Until one has been seen, there is nothing to keep.
@Test func aDocumentWithoutAWeeklyWindowIsNoReadingUntilOneHasBeenSeen() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )

    try folder.write(#"{"rate_limits":{"five_hour":{"used_percentage":12,"resets_at":1738425600}}}"#)

    #expect(try await reporter.read() == nil)
}

// The document gone is not "a window missing". Disconnect deletes it so that
// the figure leaves the clock, and a memory that outlived the file would keep
// the figure there until the weekly reset.
@Test func aDeletedDocumentTakesTheFigureAwayEvenAfterOneWasSeen() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { beforeEitherReset }
    )
    try folder.write(statusLineDocument)
    #expect(try await reporter.read() != nil)

    try FileManager.default.removeItem(at: folder.document)

    #expect(try await reporter.read() == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StatusLineClaudeUsageReporterTests`
Expected: FAIL in `aWindowMissingFromTheNextDocumentKeepsTheLastValueSeen` and `aDocumentWithNoWindowsKeepsTheLastValuesSeen` (both read `nil`). The other six pass.

- [ ] **Step 3: Write minimal implementation**

In `StatusLineClaudeUsageReporter`, add the two stored windows below `now`, and replace `read()`:

```swift
    /// The last value of each window this process saw.
    ///
    /// A window can be missing from any one document, and when it is, the last
    /// value seen stands in for it. Per process and in memory: a relaunch that
    /// finds a document without a week reads nothing until one arrives, which is
    /// the honest answer for a figure nobody has confirmed since.
    private var weekly: ClaudeUsageWindow?
    private var fiveHour: ClaudeUsageWindow?
```

```swift
    public func read() async throws -> ClaudeUsageReading? {
        // In front of the memory, on purpose: a deleted document is how
        // Disconnect takes the figure away.
        guard let data = try? Data(contentsOf: document) else { return nil }
        let limits = Self.rateLimits(in: data)
        if let seen = Self.window(limits["seven_day"]) { weekly = seen }
        if let seen = Self.window(limits["five_hour"]) { fiveHour = seen }

        guard let current = weekly else { return nil }
        return ClaudeUsageReading(
            utilization: current.utilization,
            resetsAt: current.resetsAt,
            fiveHour: fiveHour,
            observedAt: modificationDate()
        )
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StatusLineClaudeUsageReporterTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| R6 | delete `if let seen = Self.window(limits["seven_day"]) { weekly = seen }` and read the week from the document only (`guard let current = Self.window(limits["seven_day"])`) | `swift test --filter StatusLineClaudeUsageReporterTests` | FAIL `aWindowMissingFromTheNextDocumentKeepsTheLastValueSeen`, `aDocumentWithNoWindowsKeepsTheLastValuesSeen` |
| R7 | `fiveHour: fiveHour` → `fiveHour: Self.window(limits["five_hour"])` | same | FAIL `aWindowMissingFromTheNextDocumentKeepsTheLastValueSeen` (second half) |
| R5 again | Task 1's missing-file mutation. The memory now sits behind that guard, so re-run it. | same | FAIL `aDeletedDocumentTakesTheFigureAwayEvenAfterOneWasSeen`. If it survives, the guard's purpose has been lost; stop and find out why. |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift \
        Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift
git commit -m "feat: keep a window the next status-line document leaves out"
```

---

### Task 3: Nothing once the week has reset

**Files:**
- Modify: `Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift`
- Test: `Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift`

**Interfaces:**
- Consumes: Task 2's reporter and its `now`.
- Produces: `read()` answers `nil` once the weekly `resetsAt` is at or before `now()`, and leaves out a five-hour window whose `resetsAt` has passed.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift`:

```swift
// MARK: - A window that has reset

/// A time a test can move. `@unchecked` because every access goes through
/// `lock`; `Mutex` would say the same thing and is macOS 15+.
private final class MovableNow: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) { current = start }

    var value: Date {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

// Once the week's reset has passed, the figure describes a window that is over,
// and spending since then is unknown. Zero would be a calm, confident lie, so
// the answer is nothing, and the tile leaves the clock at the end of its
// lifetime. The boundary is the reset itself: at that instant the week is over.
@Test func aWeekThatHasResetIsNoReading() async throws {
    let reset = Date(timeIntervalSince1970: 1_738_857_600)
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }

    for (resetsAt, answers) in [(1_738_857_599, false), (1_738_857_600, false), (1_738_857_601, true)] {
        try folder.write(
            #"{"rate_limits":{"seven_day":{"used_percentage":41,"resets_at":\#(resetsAt)}}}"#
        )
        // A reporter per case, so no memory from the case before stands in.
        let reporter = StatusLineClaudeUsageReporter(document: folder.document, now: { reset })
        #expect((try await reporter.read() != nil) == answers, "resets_at \(resetsAt)")
    }
}

// The same rule applies to a week held in memory. Claude Code drops a window
// once it resets, so the document after a reset has no week in it, and the
// remembered one must not stand in for it.
@Test func aRememberedWeekThatHasSinceResetIsNoReading() async throws {
    let now = MovableNow(beforeEitherReset)
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    let reporter = StatusLineClaudeUsageReporter(document: folder.document, now: { now.value })
    try folder.write(statusLineDocument)
    #expect(try await reporter.read() != nil)

    try folder.write(#"{"rate_limits":{"five_hour":{"used_percentage":3,"resets_at":1738900000}}}"#)
    now.value = Date(timeIntervalSince1970: 1_738_857_600)

    #expect(try await reporter.read() == nil)
}

// A five-hour window that has reset is dropped, and the week still reads. Only
// the week decides whether there is a reading at all.
@Test func anExpiredFiveHourWindowIsDroppedAndTheWeekStillReads() async throws {
    let folder = try StatusDocumentFolder()
    defer { folder.remove() }
    try folder.write(statusLineDocument)
    let betweenTheResets = Date(timeIntervalSince1970: 1_738_430_000)
    let reporter = StatusLineClaudeUsageReporter(
        document: folder.document, now: { betweenTheResets }
    )

    let reading = try #require(await reporter.read())

    #expect(reading.utilization == 41)
    #expect(reading.fiveHour == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter StatusLineClaudeUsageReporterTests`
Expected: FAIL in `aWeekThatHasResetIsNoReading`, `aRememberedWeekThatHasSinceResetIsNoReading` and `anExpiredFiveHourWindowIsDroppedAndTheWeekStillReads`.

- [ ] **Step 3: Write minimal implementation**

`StatusLineClaudeUsageReporter.swift` in full:

```swift
// Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift
import Foundation

/// The weekly figure, out of the document Claude Code's status line leaves in
/// this app's folder.
///
/// Claude Code runs its status-line command after each reply and hands it a
/// JSON document on stdin. This app's hook stores the ones that carry
/// `rate_limits`, whole, and this reads the stored one. It is a local read, so
/// it happens on every refresh and nothing watches the file.
///
/// An actor because it remembers; see `weekly`.
public actor StatusLineClaudeUsageReporter: ClaudeUsageReporting {
    private let document: URL
    private let now: @Sendable () -> Date
    /// The last value of each window this process saw.
    ///
    /// A window can be missing from any one document, and when it is, the last
    /// value seen stands in for it. Per process and in memory: a relaunch that
    /// finds a document without a week reads nothing until one arrives, which is
    /// the honest answer for a figure nobody has confirmed since.
    private var weekly: ClaudeUsageWindow?
    private var fiveHour: ClaudeUsageWindow?

    public init(document: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.document = document
        self.now = now
    }

    /// The week as Claude Code last reported it, or nil when there is none to
    /// be had: no document, no week seen yet, or a week that has reset.
    ///
    /// Nil rather than zero after a reset. The window the figure described is
    /// over and spending since then is unknown; the connector turns nil into no
    /// delivery, and the clock drops the app when its lifetime runs out.
    public func read() async throws -> ClaudeUsageReading? {
        // In front of the memory, on purpose: a deleted document is how
        // Disconnect takes the figure away.
        guard let data = try? Data(contentsOf: document) else { return nil }
        let limits = Self.rateLimits(in: data)
        if let seen = Self.window(limits["seven_day"]) { weekly = seen }
        if let seen = Self.window(limits["five_hour"]) { fiveHour = seen }

        let moment = now()
        guard let current = weekly, current.resetsAt > moment else { return nil }
        return ClaudeUsageReading(
            utilization: current.utilization,
            resetsAt: current.resetsAt,
            fiveHour: fiveHour.flatMap { $0.resetsAt > moment ? $0 : nil },
            observedAt: modificationDate()
        )
    }

    private func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: document.path))?[.modificationDate]
            as? Date
    }

    /// The `rate_limits` object, or an empty one for a document that has none
    /// or is not JSON at all. Both read as "every window missing".
    private static func rateLimits(in data: Data) -> [String: Any] {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return root?["rate_limits"] as? [String: Any] ?? [:]
    }

    /// One window, or nil unless both of its figures are numbers. Without
    /// `resets_at` nothing can say when the figure stops being true.
    private static func window(_ value: Any?) -> ClaudeUsageWindow? {
        guard
            let window = value as? [String: Any],
            let used = window["used_percentage"] as? Double,
            let resets = window["resets_at"] as? Double
        else { return nil }
        // Nearest whole percent. The bar and the number beside it are drawn from
        // this one value, so rounding here is what keeps them from disagreeing.
        return ClaudeUsageWindow(
            utilization: Int(used.rounded()),
            resetsAt: Date(timeIntervalSince1970: resets)
        )
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter StatusLineClaudeUsageReporterTests`
Expected: PASS, 11 tests.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| R8 | `current.resetsAt > moment` → `current.resetsAt >= moment` | `swift test --filter StatusLineClaudeUsageReporterTests` | FAIL `aWeekThatHasResetIsNoReading` (the exact-reset case) |
| R9 | drop `, current.resetsAt > moment` | same | FAIL `aWeekThatHasResetIsNoReading`, `aRememberedWeekThatHasSinceResetIsNoReading` |
| R10 | `fiveHour.flatMap { … }` → `fiveHour` | same | FAIL `anExpiredFiveHourWindowIsDroppedAndTheWeekStillReads` |

The expiry check sits after the memory and after the missing-file guard, not in front of them, so R5–R7 need no re-run.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/StatusLineClaudeUsageReporter.swift \
        Tests/PixelClockKitTests/StatusLineClaudeUsageReporterTests.swift
git commit -m "feat: answer nothing once the week the figure described has reset"
```

---

### Task 4: The hook, run the way Claude Code runs it

**Files:**
- Create: `Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift`
- Test: `Tests/PixelClockKitTests/ClaudeStatusLineHookTests.swift`

**Interfaces:**
- Consumes: `statusLineDocument` from Task 1's test file (module-internal).
- Produces, on `public struct ClaudeCodeStatusLine`:
  - `public static let hookName = "claude-statusline.sh"`
  - `public static let documentName = "claude-status.json"`
  - `static let script: String` (the hook)
  - `static func command(hook: URL, chaining previous: String?) -> String`
  - `static func quoted(_ text: String) -> String`

The hook was prototyped with `/bin/sh` on this machine, in a folder named `… Application Support 'lane C'`. Measured: a document with `rate_limits` is stored with mode `0600` and nothing is printed (exit 0). A document without it leaves the stored one alone. A chained `cat` prints the input. A chained `echo partial; exit 3` prints `partial`, exits 3, and the document is still written. A chained command containing `it's` survives. With the folder read-only, the chain still runs and the hook exits 0.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/ClaudeStatusLineHookTests.swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeStatusLineHookTests`
Expected: FAIL to compile, with `cannot find 'ClaudeCodeStatusLine' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeStatusLineHookTests`
Expected: PASS, 8 tests.

- [ ] **Step 5: Mutation checks, one at a time**

Edit the `script` literal for H1–H5.

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| H1 | delete the `case … esac` wrapper, so every document is stored | `swift test --filter ClaudeStatusLineHookTests` | FAIL `aDocumentWithoutRateLimitsLeavesTheStoredOneAlone` |
| H2 | move the `if [ -n "$1" ] … fi` block above `case` | same | FAIL `aPreviousStatusLineThatFailsStillLeavesTheDocumentBehind`, `thePreviousStatusLineGetsTheSameInputAndItsOutputIsShown` (the chain's `exit` returns before storing) |
| H3 | `exit` → `exit 0` | same | FAIL `aPreviousStatusLineThatFailsStillLeavesTheDocumentBehind` |
| H4 | delete `umask 077` | same | FAIL `theStoredDocumentIsReadableByItsOwnerAlone` (0644) |
| H5 | `mv -f` → `cp` | same | FAIL `nothingButTheHookAndTheDocumentIsLeftInTheFolder` |
| H6 | in `quoted`, drop the `replacingOccurrences` | same | FAIL every test that runs the hook (the folder name has an apostrophe) and `aQuotedArgumentIsOneWordToTheShell` |
| H7 | delete `if [ -n "$1" ]; then` and its `fi`, so the chain always runs | same | **survives, and that is expected**: `sh -c ''` prints nothing and exits 0. It is an equivalent mutant. The guard is kept because it saves a fork per status update and says what it means. |
| H8 | write the document directly (`printf … > "$here/claude-status.json"`) instead of staging it | same | **survives**: atomicity is not observable without a concurrent reader, and a test built on one would be timing-dependent. It is covered by review, and recorded here so that nobody reads the survival as a gap. |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift \
        Tests/PixelClockKitTests/ClaudeStatusLineHookTests.swift
git commit -m "feat: a status-line hook that keeps rate limits and chains the previous line"
```

---

### Task 5: Connect edits one key of Claude Code's settings

**Files:**
- Modify: `Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift`
- Test: `Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift`

**Interfaces:**
- Consumes: Task 4's `script`, `command(hook:chaining:)`, `quoted(_:)`.
- Produces:
  - `public enum ClaudeCodeSettingsRefusal: Error, Equatable, LocalizedError { case notAJSONObject(path: String); case unreadable(path: String) }`
  - on `ClaudeCodeStatusLine`: `public static let previousKey = "claudeStatusLine.previous"`, `public init(settingsFile: URL, directory: URL, defaults: UserDefaults)`, `public let settingsFile: URL`, `public let directory: URL`, `public var hook: URL`, `public var document: URL`, `public func connect() throws`, `static func replace(_ file: URL, with data: Data, permissions: Int) throws`.

**Templates:** `UserDefaultsBorrowedOverlayStore` for a defaults-backed record held in one key. `AnecdoteQueue`'s store write (`data.write(to:options: .atomic)`) is the atomic-write precedent. It is not reused here because `.atomic` replaces a symlink with a plain file and resets the file's mode.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift
import Foundation
import Testing
@testable import PixelClockKit

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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeCodeStatusLineTests`
Expected: FAIL to compile, with `cannot find 'ClaudeCodeSettingsRefusal' in scope` and `'ClaudeCodeStatusLine' cannot be constructed because it has no accessible initializers` (or the equivalent message for a missing `init(settingsFile:directory:defaults:)`).

- [ ] **Step 3: Write minimal implementation**

`ClaudeCodeStatusLine.swift` in full:

```swift
// Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'ClaudeCodeStatusLineTests|ClaudeStatusLineHookTests'`
Expected: PASS, 10 + 8 = 18 tests.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| S1 | in `readSettings`, `throw …notAJSONObject` → `return [:]` | `swift test --filter ClaudeCodeStatusLineTests` | FAIL `aSettingsFileThatIsNotAJSONObjectIsLeftAloneAndSaysWhy` |
| S1b | in `readSettings`, `throw …unreadable` → `return [:]` | same | FAIL `anUnreadableSettingsFileIsLeftAloneAndSaysWhy` |
| S3 | in `replacement`, `var line = previous as? [String: Any] ?? [:]` → `var line: [String: Any] = [:]` | same | FAIL `connectingOverAStatusLineChainsItsCommandAndKeepsItsOtherFields` |
| S3b | `chaining: chained` → `chaining: nil` | same | FAIL `connectingOverAStatusLineChainsItsCommandAndKeepsItsOtherFields` |
| S8 | `mode ?? 0o600` → `0o600` | same | FAIL `aWriteKeepsTheSettingsFilesPermissions` |
| S9 | drop `.resolvingSymlinksInPath()` in `writeSettings` | same | FAIL `aSymlinkedSettingsFileStaysALinkAndItsTargetIsWritten` |
| S10 | move `try installHook()` below `try writeSettings(root)` | same | FAIL `theHookIsInPlaceBeforeClaudeCodeIsPointedAtIt` |
| S11 | in `replace`, `rename` → `FileManager.default.copyItem` of the staged file without removing it | same | FAIL `noStagingFileIsLeftBehind` |
| S12 | the hook's `0o700` → `0o644` | same | FAIL `theHookIsInstalledAsTheShippedScriptForItsOwnerAlone` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift \
        Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift
git commit -m "feat: connect Claude Code's status line to the hook"
```

---

### Task 6: Disconnect puts the status line back

**Files:**
- Modify: `Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift`
- Test: `Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift`

**Interfaces:**
- Consumes: Task 5's `readSettings()`, `writeSettings(_:)`, `previousKey`.
- Produces: `public enum Disconnection: Equatable, Sendable { case restored, leftAlone }`, `public func isConnected() -> Bool`, `@discardableResult public func disconnect() throws -> Disconnection`. Connect becomes a no-op while connected.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeCodeStatusLineTests`
Expected: FAIL to compile, with `value of type 'ClaudeCodeStatusLine' has no member 'disconnect'` and `… no member 'isConnected'`.

- [ ] **Step 3: Write minimal implementation**

In `ClaudeCodeStatusLine`, add below `document`:

```swift
    /// What `disconnect()` did.
    public enum Disconnection: Equatable, Sendable {
        /// The value this app replaced is back, or the key is gone when there
        /// was none.
        case restored
        /// Something else had replaced this app's status line since; it was kept.
        case leftAlone
    }

    /// Whether Claude Code's settings point at this hook right now.
    ///
    /// Read from the file every time. The user, or Claude Code's `/statusline`,
    /// can change it while this app is not looking, and a remembered answer
    /// would be a Disconnect button for something that is no longer there.
    public func isConnected() -> Bool {
        guard let root = try? readSettings() else { return false }
        return isOurs(root["statusLine"])
    }
```

In `connect()`, insert the guard after `let previous = root["statusLine"]`:

```swift
        var root = try readSettings()
        let previous = root["statusLine"]
        // Already connected. Remembering this app's own status line as the
        // previous one would have Disconnect put the hook back.
        guard isOurs(previous) == false else { return }
        try remember(previous)
```

Add below `connect()`:

```swift
    /// Puts back what Connect replaced, and takes the hook and its document
    /// away.
    ///
    /// Only while the settings still point at this hook. A status line set up
    /// since is somebody's newer choice, and restoring over it would destroy
    /// it. Either way the stored previous value, the hook and the document go:
    /// the reporter reads nothing once the document is gone, and the figure
    /// leaves the clock at the end of its lifetime.
    @discardableResult
    public func disconnect() throws -> Disconnection {
        var root = try readSettings()
        var outcome = Disconnection.leftAlone
        if isOurs(root["statusLine"]) {
            // Nil removes the key, which is what "there was none" restores to.
            root["statusLine"] = remembered()
            try writeSettings(root)
            outcome = .restored
        }
        defaults.removeObject(forKey: Self.previousKey)
        try? FileManager.default.removeItem(at: hook)
        try? FileManager.default.removeItem(at: document)
        return outcome
    }
```

Add below `remember(_:)`:

```swift
    private func remembered() -> Any? {
        guard
            let data = defaults.data(forKey: Self.previousKey),
            let wrapped = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return wrapped["statusLine"]
    }

    /// Whether a `statusLine` value is this app's: its command is exactly the
    /// hook's, or the hook's followed by a chained argument.
    private func isOurs(_ statusLine: Any?) -> Bool {
        guard let command = (statusLine as? [String: Any])?["command"] as? String else {
            return false
        }
        let base = Self.command(hook: hook, chaining: nil)
        return command == base || command.hasPrefix(base + " ")
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeCodeStatusLineTests`
Expected: PASS, 17 tests.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| S2 | delete `guard isOurs(previous) == false else { return }` | `swift test --filter ClaudeCodeStatusLineTests` | FAIL `connectingTwiceKeepsTheFirstPrevious` |
| S4 | in `connect()`, delete `try remember(previous)` | same | FAIL `disconnectingPutsThePreviousStatusLineBackExactly` |
| S5 | `root["statusLine"] = remembered()` → `root["statusLine"] = remembered() ?? NSNull()` | same | FAIL `disconnectingWhenThereWasNoStatusLineRemovesTheKey` |
| S6 | `if isOurs(root["statusLine"])` → `if true` | same | FAIL `aStatusLineChangedSinceConnectingIsLeftAsItIs` |
| S7 | `command == base \|\| command.hasPrefix(base + " ")` → `command.hasPrefix(base)` | same | FAIL `connectedMeansTheSettingsPointAtThisHookAndAtNothingThatMerelyStartsLikeIt` |
| S13 | move the three cleanup lines above `var root = try readSettings()` | same | FAIL `disconnectingOverAnUnparseableSettingsFileTouchesNothing` |
| S14 | delete `try? FileManager.default.removeItem(at: document)` | same | FAIL `disconnectingTakesTheHookAndTheDocumentAway` |

The already-connected guard now sits in front of `remember` and `replacement`, so re-run Task 5's **S3**, **S3b** and this task's **S4**. Each must still fail its test. If one survives, the new guard has swallowed its purpose.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift \
        Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift
git commit -m "feat: disconnect Claude Code and put its status line back"
```

---

### Task 7: Keep the installed hook in line with the shipped one

**Files:**
- Modify: `Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift`
- Test: `Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift`

**Interfaces:**
- Consumes: Task 6's `isConnected()`, Task 5's `installHook()`.
- Produces: `public func refreshHookIfConnected() throws`, `public func lastDocumentAt() -> Date?`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift`:

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeCodeStatusLineTests`
Expected: FAIL to compile, with `value of type 'ClaudeCodeStatusLine' has no member 'refreshHookIfConnected'` and `… no member 'lastDocumentAt'`.

- [ ] **Step 3: Write minimal implementation**

Add to `ClaudeCodeStatusLine`, below `disconnect()`:

```swift
    /// Brings the hook Claude Code runs in line with the one this build ships,
    /// or puts it back when it has gone.
    ///
    /// Only while connected: a launch never creates anything for a user who has
    /// not asked. A hook that already matches is not rewritten.
    public func refreshHookIfConnected() throws {
        guard isConnected() else { return }
        guard (try? Data(contentsOf: hook)) != Data(Self.script.utf8) else { return }
        try installHook()
    }

    /// When the hook last stored a document, or nil when there is none.
    public func lastDocumentAt() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: document.path))?[.modificationDate]
            as? Date
    }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'ClaudeCodeStatusLineTests|ClaudeStatusLineHookTests'`
Expected: PASS, 22 + 8 = 30 tests.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| S15 | delete `guard isConnected() else { return }` | `swift test --filter ClaudeCodeStatusLineTests` | FAIL `nothingIsInstalledWhileNotConnected` |
| S16 | delete the drift comparison `guard … != Data(Self.script.utf8) …` | same | FAIL `aHookThatMatchesIsLeftUntouched` |
| S17 | `lastDocumentAt()` reads `.creationDate` | same | FAIL `theLastDocumentTimeIsWhenTheHookLastWroteOne`. With the past-dated fixture this plan first wrote, the mutant SURVIVES: APFS moves a fresh file's creation date along when its modification date is set into the past, so the two read the same. The fixture above uses a future time, which leaves the creation date where it is, and kills it. |

The connected check sits in front of the drift check, so re-run **S16** once S15 is reverted. It must still fail `aHookThatMatchesIsLeftUntouched`.

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockKit/Claude/ClaudeCodeStatusLine.swift \
        Tests/PixelClockKitTests/ClaudeCodeStatusLineTests.swift
git commit -m "feat: bring the installed hook in line with the shipped one"
```

---

### Task 8: The model behind Connect Claude Code

**Files:**
- Create: `Sources/PixelClockTilesApp/ClaudeCodeSettings.swift`
- Test: `Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift`

**Interfaces:**
- Consumes: `ClaudeCodeStatusLine` (Tasks 5–7), `ClaudeCodeSettingsRefusal`.
- Produces:
  - `enum ClaudeCodePaths { static let directory: URL; static let settingsFile: URL; static let document: URL; static var shippedLink: ClaudeCodeStatusLine? }`
  - `@MainActor final class ClaudeCodeLinkModel: ObservableObject` with `init(link: ClaudeCodeStatusLine? = ClaudeCodePaths.shippedLink)`, `@Published private(set) var isConnected: Bool`, `isConfirming: Bool`, `lastDocumentAt: Date?`, `note: String?`, `var canAct: Bool`, `func askToConnect()`, `func cancel()`, `func connect()`, `func disconnect()`, and `nonisolated static let costOfConnecting`, `needsTheAppBundle`, `leftChangedStatusLine: String` plus `nonisolated static func documentLine(_ at: Date?) -> String`.

**Templates:** `LoginItemModel` (`Sources/PixelClockTilesApp/LoginItem.swift`, 1 commit, no fixes) for the read-back after every action and a note that survives the redraw. `SystemLoginItem.isBundled` for the guard that keeps `swift test` off the machine's real state.

- [ ] **Step 1: Write the failing test**

```swift
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeCodeSettingsTests`
Expected: FAIL to compile, with `cannot find 'ClaudeCodePaths' in scope` and `cannot find 'ClaudeCodeLinkModel' in scope`.

- [ ] **Step 3: Write minimal implementation**

```swift
// Sources/PixelClockTilesApp/ClaudeCodeSettings.swift
import Foundation
import PixelClockKit

/// Where the Claude figure comes from, on this Mac.
enum ClaudeCodePaths {
    /// This app's own folder. The hook and the document it writes live here,
    /// beside the app's other data.
    static let directory: URL = {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("PixelClockTiles")
    }()

    /// Claude Code's user settings, the file its `/statusline` and `/config`
    /// edit.
    static let settingsFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/settings.json")

    /// What the composition root's reporter reads, and what the hook writes.
    static let document = directory.appendingPathComponent(ClaudeCodeStatusLine.documentName)

    /// The link over the real files, or nil without an app bundle.
    ///
    /// The guard is the point. Under `swift test` there is no bundle, and every
    /// test that lays out the settings surface would otherwise read, and could
    /// rewrite, the Claude Code settings of whoever runs the suite. A bare
    /// `swift run` build pays for that by not being able to connect.
    static var shippedLink: ClaudeCodeStatusLine? {
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return ClaudeCodeStatusLine(
            settingsFile: settingsFile, directory: directory, defaults: .standard
        )
    }
}

/// Connect / Disconnect Claude Code, and what the section says about it.
///
/// Its own object rather than fields on `AppModel`, for the reason
/// `LoginItemModel` is one: none of this is a setting of the app's. Whether
/// Claude Code is connected is a fact about its settings file, read after every
/// action rather than remembered, because the user or Claude Code's own
/// `/statusline` can change that file while this app is not looking.
@MainActor
final class ClaudeCodeLinkModel: ObservableObject {
    /// Said before connecting, because the cost is invisible until later.
    nonisolated static let costOfConnecting =
        "Claude Code will run this app's script after every reply, and the clock "
            + "gets the usage figure from it. With any custom status line, Claude "
            + "Code stops showing most of its footer hints, esc to interrupt among them."
    nonisolated static let needsTheAppBundle =
        "Connecting Claude Code needs the app bundle — this build is a bare binary."
    nonisolated static let leftChangedStatusLine =
        "Claude Code's status line had been changed since connecting, so it was left as it is."

    @Published private(set) var isConnected: Bool
    /// Between Connect and its confirmation.
    @Published private(set) var isConfirming = false
    @Published private(set) var lastDocumentAt: Date?
    /// Why the last action did not do what was asked, or nil.
    @Published private(set) var note: String?

    private let link: ClaudeCodeStatusLine?

    init(link: ClaudeCodeStatusLine? = ClaudeCodePaths.shippedLink) {
        self.link = link
        self.isConnected = link?.isConnected() ?? false
        self.lastDocumentAt = link?.lastDocumentAt()
        self.note = link == nil ? Self.needsTheAppBundle : nil
    }

    var canAct: Bool { link != nil }

    func askToConnect() {
        isConfirming = canAct
    }

    func cancel() {
        isConfirming = false
    }

    func connect() {
        guard let link else { return }
        isConfirming = false
        do {
            try link.connect()
            note = nil
        } catch {
            note = "Could not connect: " + error.localizedDescription
        }
        readBack(link)
    }

    func disconnect() {
        guard let link else { return }
        do {
            note = try link.disconnect() == .leftAlone ? Self.leftChangedStatusLine : nil
        } catch {
            note = "Could not disconnect: " + error.localizedDescription
        }
        readBack(link)
    }

    /// What the file says now, whatever was asked for.
    private func readBack(_ link: ClaudeCodeStatusLine) {
        isConnected = link.isConnected()
        lastDocumentAt = link.lastDocumentAt()
    }

    nonisolated static func documentLine(_ at: Date?) -> String {
        guard let at else { return "No status-line document yet" }
        return "Last status-line document: \(at.formatted(date: .abbreviated, time: .shortened))"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter ClaudeCodeSettingsTests`
Expected: PASS, 9 tests.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| M1 | in `connect()`, `readBack(link)` → `isConnected = true` | `swift test --filter ClaudeCodeSettingsTests` | FAIL `aRefusedConnectionLeavesItDisconnectedAndSaysWhy` |
| M2 | in `connect()`, delete `isConfirming = false` | same | FAIL `connectingWritesTheSettingsAndReadsTheAnswerBack` |
| M3 | delete `guard Bundle.main.bundleIdentifier != nil else { return nil }` | same | FAIL `theShippedLinkIsNotBuiltOutsideAnAppBundle` (building the link reads nothing, so this mutation is safe to run) |
| M4 | `isConfirming = canAct` → `isConfirming = true` | same | FAIL `aModelWithoutALinkSaysWhyAndDoesNothing` |
| M5 | `== .leftAlone ? Self.leftChangedStatusLine : nil` → `nil` | same | FAIL `disconnectingWhatWasChangedSinceSaysSo` |
| M6 | `directory` built on `.cachesDirectory` | same | FAIL `theDocumentTheReporterReadsIsTheOneTheHookWrites` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockTilesApp/ClaudeCodeSettings.swift \
        Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift
git commit -m "feat: the Connect Claude Code model behind the settings"
```

---

### Task 9: Connect / Disconnect Claude Code on the settings surface

**Files:**
- Modify: `Sources/PixelClockTilesApp/ClaudeCodeSettings.swift`
- Modify: `Sources/PixelClockTilesApp/SettingsSheet.swift` (`init` at L28–36, `body` at L38–57)
- Test: `Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift`

**Interfaces:**
- Consumes: Task 8's `ClaudeCodeLinkModel`. `SettingsSheet.init(model:loginItem:defaults:)`.
- Produces: `struct ClaudeCodeSettings: View` with `init(link: @autoclosure @escaping () -> ClaudeCodeLinkModel = ClaudeCodeLinkModel())`. `SettingsSheet.init` gains `claudeCode: @autoclosure @escaping () -> ClaudeCodeLinkModel = ClaudeCodeLinkModel()`, placed between `loginItem:` and `defaults:`.

**Templates:** `LoginItemSettings` and its tests (`LoginItemTests.swift`: `laidOut`, `drawn`, and the proof that the section is on the settings surface).

- [ ] **Step 1: Write the failing test**

Append to `Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift`:

```swift
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

// The section is ON the settings surface, which every model test above would
// pass without. Two answers compared rather than a count of controls: Connect
// and Disconnect are one push button each, so only the pixels tell them apart.
@Test @MainActor func theSectionIsOnTheSettingsSurface() throws {
    let connected = ClaudeSettingsFixture()
    defer { connected.remove() }
    try connected.link.connect()
    let notConnected = ClaudeSettingsFixture()
    defer { notConnected.remove() }

    let on = drawn(SettingsSheet(
        model: testModel(), claudeCode: ClaudeCodeLinkModel(link: connected.link)
    ))
    let off = drawn(SettingsSheet(
        model: testModel(), claudeCode: ClaudeCodeLinkModel(link: notConnected.link)
    ))

    #expect(on != nil)
    #expect(on != off)
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter ClaudeCodeSettingsTests`
Expected: FAIL to compile, with `extra argument 'claudeCode' in call` and `cannot find 'ClaudeCodeSettings' in scope`.

- [ ] **Step 3: Write minimal implementation**

Append to `Sources/PixelClockTilesApp/ClaudeCodeSettings.swift`. It also needs `import SwiftUI` at the top of that file:

```swift
/// Connect / Disconnect Claude Code, with the time of the last status-line
/// document.
///
/// A view of its own, for the reason `LoginItemSettings` is one: the whole
/// settings surface costs 57 ms to lay out, and a test about this section has
/// no business spending it. It lives on the current settings surface until
/// phase 5 moves it; the view moves as it is.
///
/// Confirmation is inline rather than an alert. The menu bar window dismisses
/// when it loses focus, and takes any sheet or alert over it with it.
struct ClaudeCodeSettings: View {
    /// `@StateObject` for the reason `LoginItemSettings` uses one: the note
    /// has to survive the redraws every keystroke elsewhere on the surface
    /// causes.
    @StateObject private var link: ClaudeCodeLinkModel

    init(link: @autoclosure @escaping () -> ClaudeCodeLinkModel = ClaudeCodeLinkModel()) {
        _link = StateObject(wrappedValue: link())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Claude usage").font(.caption).foregroundStyle(.secondary)
            if link.isConnected {
                Button("Disconnect Claude Code") { link.disconnect() }
                    .controlSize(.small)
            } else if link.isConfirming {
                Text(ClaudeCodeLinkModel.costOfConnecting)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Connect") { link.connect() }
                    Button("Cancel") { link.cancel() }
                }
                .controlSize(.small)
            } else {
                Button("Connect Claude Code…") { link.askToConnect() }
                    .controlSize(.small)
                    .disabled(link.canAct == false)
            }
            Text(ClaudeCodeLinkModel.documentLine(link.lastDocumentAt))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let note = link.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
```

In `Sources/PixelClockTilesApp/SettingsSheet.swift`, add a stored property below `loginItem`:

```swift
    /// Handed down for the reason `loginItem` is: a test can put a link over a
    /// fixture file in, and the shipped default reads Claude Code's real
    /// settings only inside an app bundle.
    private let claudeCode: () -> ClaudeCodeLinkModel
```

Replace `init`:

```swift
    init(
        model: AppModel,
        loginItem: @autoclosure @escaping () -> LoginItemModel = LoginItemModel(),
        claudeCode: @autoclosure @escaping () -> ClaudeCodeLinkModel = ClaudeCodeLinkModel(),
        defaults: UserDefaults = .standard
    ) {
        _model = ObservedObject(wrappedValue: model)
        self.loginItem = loginItem
        self.claudeCode = claudeCode
        self.defaults = defaults
    }
```

In `body`, between `microphonesSection` and `iconSection`:

```swift
            microphonesSection
            Divider()
            ClaudeCodeSettings(link: claudeCode())
            Divider()
            iconSection
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter 'ClaudeCodeSettingsTests|LoginItemTests|PanelRenderingTests|PanelWidthTests'`
Expected: PASS. `ClaudeCodeSettingsTests` has 11 tests. The other three files keep their counts: they lay out `SettingsSheet(model:)` with the default link, which is `nil` under `swift test`, and both renders in each of their comparisons draw the same section.

- [ ] **Step 5: Mutation checks, one at a time**

| # | Mutate | Run | Expected |
| --- | --- | --- | --- |
| V1 | delete `ClaudeCodeSettings(link: claudeCode())` and its `Divider()` from `SettingsSheet.body` | `swift test --filter ClaudeCodeSettingsTests` | FAIL `theSectionIsOnTheSettingsSurface` |
| V2 | delete the `if let note` block from `ClaudeCodeSettings.body` | same | FAIL `aRefusalIsDrawnAndNotOnlyHeld` |
| V3 | swap the `isConnected` branch for the Connect button (`if false`) | same | FAIL `theSectionIsOnTheSettingsSurface` |

- [ ] **Step 6: Commit**

```bash
git add Sources/PixelClockTilesApp/ClaudeCodeSettings.swift \
        Sources/PixelClockTilesApp/SettingsSheet.swift \
        Tests/PixelClockTilesAppTests/ClaudeCodeSettingsTests.swift
git commit -m "feat: Connect / Disconnect Claude Code in the settings"
```

---

### Task 10: The running app takes the figure from the status line

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`live()`, the comment at L578–582 and the reporter at L586)
- Modify: `Sources/PixelClockTilesApp/App.swift` (`applicationDidFinishLaunching`, L282–286)
- Modify: `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` (doc comment of `ClaudeUsageReporting`, L3–13)

**Interfaces:**
- Consumes: `StatusLineClaudeUsageReporter(document:now:)`, `ClaudeCodePaths.document`, `ClaudeCodePaths.shippedLink`, `ClaudeCodeStatusLine.refreshHookIfConnected()`.
- Produces: nothing new. This task is wiring.

This task has no failing test of its own. `live()` hands the reporter to a connector that does not expose it, and the launch line does nothing under `swift test` because the shipped link is `nil` there, which is exactly what that guard is for. Task 8's `theDocumentTheReporterReadsIsTheOneTheHookWrites` pins the path the reporter reads, the existing composition-root tests in `AppShellTests.swift` pin the registry, and HANDOFF items C2 and C5 cover the rest on the real app.

- [ ] **Step 1: Replace the reporter in the composition root**

In `AppModel.live()`, replace:

```swift
        // The credential is Claude Code's, not this app's, and the reporter
        // only ever reads it — see `ClaudeCredentialReading` for why refreshing
        // it here would drop that program out of its own session. A launch on a
        // machine with no Claude Code signed in reports nothing and the app
        // simply never appears in the loop.
        let focusStatus = SystemFocusStatus()
        registry.register(
            ClaudeUsageConnector(
                reporter: ClaudeUsageReporter(transport: transport),
                showsNow: { ClaudeFocusAudience.shows(focusStatus) }
            )
        )
```

with:

```swift
        // The figure is whatever Claude Code's status line last left in this
        // app's folder. Until Claude Code is connected in the settings and has
        // replied once there is no document, and the app never enters the loop.
        let focusStatus = SystemFocusStatus()
        registry.register(
            ClaudeUsageConnector(
                reporter: StatusLineClaudeUsageReporter(document: ClaudeCodePaths.document),
                showsNow: { ClaudeFocusAudience.shows(focusStatus) }
            )
        )
```

- [ ] **Step 2: Bring the hook in line at launch**

In `AppDelegate.applicationDidFinishLaunching(_:)`, append after `watchThePanelsWindow()`:

```swift
        // An update may ship a different hook. The one Claude Code runs is
        // brought in line with it here, and only while connected. A failure is
        // left for the next launch: the old hook still stores documents.
        try? ClaudeCodePaths.shippedLink?.refreshHookIfConnected()
```

- [ ] **Step 3: Reword the seam's doc comment**

In `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift`, replace L3–13, the doc comment and the protocol, with the following. The signature does not change.

```swift
/// Where a source of weekly-allowance readings comes from.
///
/// A protocol rather than the file read itself, so the drawing can be tested
/// against a figure, and where the figure comes from is answered once, in the
/// type that implements it — `StatusLineClaudeUsageReporter` in this kit.
public protocol ClaudeUsageReporting: Sendable {
    /// The current weekly reading, or nil when there is none to be had: no
    /// status-line document yet, or a week that has reset since the last one.
    func read() async throws -> ClaudeUsageReading?
}
```

- [ ] **Step 4: Build and run what covers it**

Run: `swift build`
Expected: builds with zero warnings.

Run: `swift test --filter 'AppShellTests|ClaudeUsageTests|ClaudeCodeSettingsTests|StatusLineClaudeUsageReporterTests'`
Expected: PASS. `AppShellTests` count unchanged, `ClaudeUsageTests` 14, `ClaudeCodeSettingsTests` 11, `StatusLineClaudeUsageReporterTests` 11.

Run: `grep -rnw "ClaudeUsageReporter" Sources/PixelClockTilesApp`
Expected: no output. `-w` does not match `StatusLineClaudeUsageReporter`.

- [ ] **Step 5: Commit**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Sources/PixelClockTilesApp/App.swift \
        Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift
git commit -m "feat: take the Claude figure from the status line in the running app"
```

---

### Task 11: Remove the keychain reader and `/api/oauth/usage`

**Files:**
- Delete: `Sources/PixelClockKit/Claude/ClaudeCredentials.swift`
- Delete: `Sources/PixelClockKit/Claude/ClaudeUsageReporter.swift`
- Delete: `Tests/PixelClockKitTests/ClaudeUsageReporterTests.swift`
- Modify: `Sources/PixelClockKit/Claude/ClaudeUsageReading.swift` (drop `init?(json:)`, `weeklyBar`, `moment(from:)`)
- Modify: `Tests/PixelClockKitTests/ClaudeUsageTests.swift` (delete L51–121)

**Interfaces:**
- Consumes: Task 10, after which nothing calls any of these.
- Produces: nothing. The app no longer reads another program's credential, so there is no keychain prompt, before or after the bundle id changes.

The deleted tests cover behaviour that no longer exists. They are not rewritten. The band tests, the drawing tests, the gate tests and the lifetime test in `ClaudeUsageTests.swift` cover behaviour that survives, and they are kept byte for byte.

- [ ] **Step 1: Delete the files**

```bash
git rm Sources/PixelClockKit/Claude/ClaudeCredentials.swift \
       Sources/PixelClockKit/Claude/ClaudeUsageReporter.swift \
       Tests/PixelClockKitTests/ClaudeUsageReporterTests.swift
```

- [ ] **Step 2: Drop the `/api/oauth/usage` parser**

`Sources/PixelClockKit/Claude/ClaudeUsageReading.swift` in full:

```swift
// Sources/PixelClockKit/Claude/ClaudeUsageReading.swift
import Foundation

/// One reading of the weekly allowance.
///
/// `utilization` is a percentage Claude Code reported, not something derived
/// here, and it is allowed past a hundred: an overage channel keeps serving
/// after the bar is full, and a reading of a hundred and forty is a true thing
/// to say about a week. `StatusLineClaudeUsageReporter` is where it is read.
public struct ClaudeUsageReading: Sendable, Equatable {
    public let utilization: Int
    /// When this week's bar starts again, when the source says so.
    public let resetsAt: Date?
    /// The rolling five-hour window, when the source reported one. Carried, and
    /// drawn by no face yet.
    public let fiveHour: ClaudeUsageWindow?
    /// When the document this came from was written: its modification time.
    /// Nil for a reading that did not come from a document.
    public let observedAt: Date?

    /// The two newer fields default to nil, so a reading built from a figure
    /// alone — every drawing test, every face — reads as it always did.
    public init(
        utilization: Int,
        resetsAt: Date?,
        fiveHour: ClaudeUsageWindow? = nil,
        observedAt: Date? = nil
    ) {
        self.utilization = utilization
        self.resetsAt = resetsAt
        self.fiveHour = fiveHour
        self.observedAt = observedAt
    }
}

/// One of Claude Code's rate-limit windows: how much of it is gone, and when it
/// starts again.
public struct ClaudeUsageWindow: Sendable, Equatable {
    public let utilization: Int
    public let resetsAt: Date

    public init(utilization: Int, resetsAt: Date) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }
}
```

- [ ] **Step 3: Drop the parser's tests**

In `Tests/PixelClockKitTests/ClaudeUsageTests.swift`, delete from `// MARK: - Reading the service's answer` (L51) through the closing brace of `aWeeklyBarWithNoResetTimeIsStillAReading` (L121), together with the blank line after it. That removes `usageBody`, `theWeeklyBarIsTheOneRead`, `aFractionalUtilizationIsRoundedToTheNearestWholePercent`, `anAnswerWithoutTheWeeklyBarIsNoReadingAtAll` and `aWeeklyBarWithNoResetTimeIsStillAReading`. The rounding rule they carried now lives in `aFractionalPercentageIsRoundedToTheNearestWholeOne`. `// MARK: - What reaches the device` becomes the line after `everyBandDrawsADistinctColour`'s closing brace and one blank line.

- [ ] **Step 4: Verify nothing names the removed code**

Run: `grep -rnw -e ClaudeCredentialReading -e KeychainClaudeCredentials -e FileClaudeCredentials -e AnyClaudeCredentials -e ClaudeCredentialSearch -e ClaudeUsageReporter -e usageBody -e weeklyBar Sources Tests`
Expected: no output.

Run: `grep -rn "oauth/usage\|init?(json\|import Security" Sources Tests`
Expected: no output.

Run: `swift build`
Expected: builds with zero warnings.

Run: `swift test --filter ClaudeUsageTests`
Expected: PASS, 10 tests (14 before, minus 4).

Run: `swift test`
Expected: PASS. The total equals re-verify item 7's baseline, minus 9 (`ClaudeUsageReporterTests`), minus 4 (`ClaudeUsageTests`), plus 11 + 8 + 22 + 11 = 52 from this lane. Parallel lanes will have moved the baseline too, so compare against the baseline taken in this worktree.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/PixelClockKit/Claude Tests/PixelClockKitTests
git commit -m "refactor: remove the keychain reader and /api/oauth/usage"
```

---

### Task 12: What lane C leaves for the hardware

**Files:**
- Modify: `docs/HANDOFF.md` (append one section at the end)

**Interfaces:**
- Consumes: Tasks 1–11.
- Produces: the lane's entry in HANDOFF, append-only.

- [ ] **Step 1: Append the section**

Append to the end of `docs/HANDOFF.md`:

```markdown
## Claude usage from Claude Code's status line — lane C

The Claude figure no longer comes from `/api/oauth/usage` with a token taken
from the keychain. Connect Claude Code (in the settings) sets Claude Code's
`statusLine` to `/bin/sh '<Application Support>/PixelClockTiles/claude-statusline.sh'`,
followed by the previous command as a quoted argument when there was one. After
each reply the hook stores the document, if it carries `rate_limits`, as
`claude-status.json` beside itself, then runs the previous command. The
replaced value is kept in the defaults key `claudeStatusLine.previous`, and
Disconnect puts it back, removes the hook and removes the document.
`StatusLineClaudeUsageReporter` reads the document on every Claude refresh.

Known limits, which are not defects:

- A project's own `.claude/settings.json` with a `statusLine` overrides the
  user's in that project, so sessions there never run the hook.
- `CLAUDE_CONFIG_DIR` moves Claude Code's settings. The app edits
  `~/.claude/settings.json` only.
- Two sessions signed in to different accounts: the last one to reply wins.
- A `refreshInterval` carried over from a previous status line runs the hook on
  that timer too, and Claude Code re-runs it when a window resets. The
  document's time can move without a reply.
- Rewriting `settings.json` keeps every value, but not its formatting or key
  order.
- A bare `swift run` build cannot connect. Without a bundle id there is no
  link, and that guard is what keeps `swift test` off the real settings.

### What only a person at the hardware can settle — added by lane C

C1. **Connect.** Copy `~/.claude/settings.json` aside, open the settings, press
    Connect Claude Code…, read the confirmation, press Connect. Diff the file
    against the copy: `statusLine` is the only key that changed.
C2. **The figure arrives.** Run an interactive `claude` session and send one
    message. `claude-status.json` appears beside the hook, the settings line
    shows its time when the settings are reopened, and within one Claude
    refresh (five minutes at most) the clock shows the same weekly percentage
    that `/usage` reports.
C3. **An empty status row.** With nothing chained, the hook prints nothing. The
    documentation says an empty output blanks the row. Look at what Claude Code
    actually draws there, and confirm that `esc to interrupt` is gone, as the
    confirmation says.
C4. **Disconnect.** `statusLine` is back to what the copy from C1 holds, or
    absent if it was absent. The hook and the document are gone. The figure
    leaves the clock within its lifetime (fifteen minutes).
C5. **Launch refresh.** While connected, overwrite the hook with any text and
    relaunch the app. The hook is back to the shipped script, with mode 0700.
C6. **No keychain prompt.** From this build on, no dialog ever asks for the
    "Claude Code-credentials" keychain item.
```

- [ ] **Step 2: Commit**

```bash
git add docs/HANDOFF.md
git commit -m "docs: what lane C leaves for the hardware"
```

---

## Mutation ledger

The executor fills in the last column with killed, survived (expected), or survived, investigate.

| # | Task | Site | Killing test | Result |
| --- | --- | --- | --- | --- |
| R1 | 1 | rounding | `aFractionalPercentageIsRoundedToTheNearestWholeOne` | |
| R2 | 1 | window needs `resets_at` | `aWindowNeedsBothItsFiguresAndANullIsAbsence` | |
| R3 | 1 | `seven_day` key | `theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong` | |
| R4 | 1 | `observedAt` source | `theWeeklyWindowIsTheFigureAndTheFiveHourOneRidesAlong` | |
| R5 | 1, re-run in 2 | missing-file guard | `aDeletedDocumentTakesTheFigureAwayEvenAfterOneWasSeen` (from Task 2) | |
| R6 | 2 | weekly memory | `aWindowMissingFromTheNextDocumentKeepsTheLastValueSeen` | |
| R7 | 2 | five-hour memory | `aWindowMissingFromTheNextDocumentKeepsTheLastValueSeen` | |
| R8 | 3 | `>` vs `>=` at the reset | `aWeekThatHasResetIsNoReading` | |
| R9 | 3 | weekly expiry | `aWeekThatHasResetIsNoReading` | |
| R10 | 3 | five-hour expiry | `anExpiredFiveHourWindowIsDroppedAndTheWeekStillReads` | |
| H1 | 4 | `rate_limits` filter | `aDocumentWithoutRateLimitsLeavesTheStoredOneAlone` | |
| H2 | 4 | store before chain | `aPreviousStatusLineThatFailsStillLeavesTheDocumentBehind` | |
| H3 | 4 | exit status passed on | `aPreviousStatusLineThatFailsStillLeavesTheDocumentBehind` | |
| H4 | 4 | `umask 077` | `theStoredDocumentIsReadableByItsOwnerAlone` | |
| H5 | 4 | `mv` not `cp` | `nothingButTheHookAndTheDocumentIsLeftInTheFolder` | |
| H6 | 4 | quote escaping | every hook test | |
| H7 | 4 | `[ -n "$1" ]` | none: an equivalent mutant | survived (expected) |
| H8 | 4 | staged write | none: atomicity is not observable here | survived (expected) |
| S1, S1b | 5 | refusals | `aSettingsFileThatIsNotAJSONObjectIsLeftAloneAndSaysWhy`, `anUnreadableSettingsFileIsLeftAloneAndSaysWhy` | |
| S3, S3b | 5, re-run in 6 | other fields and chained command | `connectingOverAStatusLineChainsItsCommandAndKeepsItsOtherFields` | |
| S8 | 5 | file mode kept | `aWriteKeepsTheSettingsFilesPermissions` | |
| S9 | 5 | symlink resolved | `aSymlinkedSettingsFileStaysALinkAndItsTargetIsWritten` | |
| S10 | 5 | hook before settings | `theHookIsInPlaceBeforeClaudeCodeIsPointedAtIt` | |
| S11 | 5 | rename, no leftovers | `noStagingFileIsLeftBehind` | |
| S12 | 5 | hook mode | `theHookIsInstalledAsTheShippedScriptForItsOwnerAlone` | |
| S2 | 6 | already connected | `connectingTwiceKeepsTheFirstPrevious` | |
| S4 | 6 | previous remembered | `disconnectingPutsThePreviousStatusLineBackExactly` | |
| S5 | 6 | key removed, not `null` | `disconnectingWhenThereWasNoStatusLineRemovesTheKey` | |
| S6 | 6 | restore only our own | `aStatusLineChangedSinceConnectingIsLeftAsItIs` | |
| S7 | 6 | exact command match | `connectedMeansTheSettingsPointAtThisHookAndAtNothingThatMerelyStartsLikeIt` | |
| S13 | 6 | refuse before cleanup | `disconnectingOverAnUnparseableSettingsFileTouchesNothing` | |
| S14 | 6 | document removed | `disconnectingTakesTheHookAndTheDocumentAway` | |
| S15 | 7 | refresh only while connected | `nothingIsInstalledWhileNotConnected` | |
| S16 | 7, re-run after S15 | drift comparison | `aHookThatMatchesIsLeftUntouched` | |
| S17 | 7 | modification date | `theLastDocumentTimeIsWhenTheHookLastWroteOne` | killed, after the fixture moved to a future time — see Task 7 Step 5 |
| M1–M6 | 8 | model and paths | as listed in Task 8 | |
| V1–V3 | 9 | the section on screen | as listed in Task 9 | |

## Spec findings

Proposed corrections, for the parent to fold into the spec:

1. **`observedAt` has no reader.** The spec adds it to `ClaudeUsageReading`, but no face or view reads it, and the settings line has to show a time even when there is no reading (a reset week), so it stats the file itself. Proposed: name phase 5's `TileRowLine` as its reader ("updated 3 min ago"), or defer the field to that phase under the spec's own rule that a type lands in the phase that first reads it. This plan carries it, because the lane brief lists it.
2. **Disconnect after the status line was changed.** The spec says Disconnect "puts it back, or removes the key when there was none", and says nothing about a `statusLine` somebody replaced after connecting. Proposed sentence: "When the settings no longer point at the hook, Disconnect leaves them as they are and says so."
3. **Disconnect removes the hook and the document.** Without that, the figure stands until the weekly reset. Proposed addition to § Claude usage.
4. **"Every other key keeps its value"** holds for values only. `JSONSerialization` normalises formatting and key order. Proposed wording: "every other key keeps its value; the file's formatting is not preserved."
5. **What an empty status line shows.** The status-line documentation already says an empty output or a non-zero exit blanks the row. HANDOFF C3 still checks it by eye.
6. **`spend_limit`.** `rate_limits` can also carry `spend_limit`, behind a gateway. The reporter ignores it. Worth one clause in the spec, so a later reader does not take it for the weekly window.
7. **Unbundled builds cannot connect** (decision L13). It follows from keeping the suite off the real settings file without editing existing tests, and the spec does not mention it.
8. **The Application Support folder** is `AwtrixConnectors` today (`AppPaths.anecdoteStore`), and the spec names `PixelClockTiles`. Phase 0 owns the decision; re-verify item 2 adapts this plan to it.

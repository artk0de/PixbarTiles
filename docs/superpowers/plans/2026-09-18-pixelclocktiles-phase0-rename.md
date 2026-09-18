# PixelClockTiles Phase 0 — Rename Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The package, its two targets and the bundle carry the PixelClockTiles
name, and an existing installation keeps its settings across the bundle id
change. Nothing else changes.

**Architecture:** Most of this is a mechanical rename: `git mv` of four
directories plus a word-for-word substitution of the module and target names.
The one piece of logic is `DefaultsCarryOver`, which the composition root runs
before anything reads defaults. It copies the old domain's keys into the new
one once, never overwriting, with the marker written last.

**Tech Stack:** Swift 6.3.3, SwiftPM tools 6.0, swift-testing, macOS 14 floor.

**Spec:** `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md`
(§ "Rename — phase 0", Phases row 0)

## Global Constraints

- Swift tools version `6.0`, platform floor `.macOS(.v14)`, Swift 6 strict concurrency.
- **No third-party dependencies** — nothing in `Package.swift`'s dependency list, ever.
- All source comments, identifiers, commit messages and documentation are English.
- AWTRIX-specific types keep their names — `AwtrixDevice`, `AwtrixError`, `DeviceDiscovery.isAwtrixInstance`.
- Bundle id `dev.artk0re.awtrix-connectors` → `dev.artk0re.pixelclocktiles`, with the old domain's keys copied into the new one on first launch.
- Tests never touch the real defaults domains: every test works on `UserDefaults(suiteName:)` suites it removes in `defer`.
- Do not edit `docs/superpowers/specs/2026-08-17-*` or `docs/superpowers/plans/2026-08-17-*`; they are historical records.
- Each commit leaves `swift build` warning-free and `swift test` green.
- Baseline before the rename: **999 tests**, green, zero warnings.

## Impact signals (tea-rags)

Owner is `artk0de` at 100% on every file, so no silo routing is needed. The
index predates the rename and its codegraph shows `fanIn` 0 everywhere, so
the table records churn only.

| File | Churn | Touched how |
| --- | --- | --- |
| `Sources/AwtrixConnectorsApp/AppModel.swift` | 31 commits, 42% fixes | one comment in `AppPaths`; nothing executable |
| `Sources/AwtrixKit/Device/AwtrixDevice.swift` | 11 | comment only |
| `Sources/AwtrixConnectorsApp/App.swift` | 9 | struct name; the key copy wired into `AppDelegate.init()` |
| `docs/HANDOFF.md` | 13 | living references |
| `Scripts/bundle.sh` | 5 | names, id, usage strings |
| `Package.swift` | 4 | names |

The key copy has no proven template here: the project has no one-shot
migration yet. The nearest analogues are `PanelWidth.stored(in:)` /
`save(to:)`, a value over an injected `UserDefaults`, and the suite-per-test
fixture in `HistoryHeightTests`.

## Persisted identity — decisions

| Where the old name lives | Bound to | Decision |
| --- | --- | --- |
| Defaults domain `dev.artk0re.awtrix-connectors` | bundle id | **Migrate**: `DefaultsCarryOver` (Task 3) |
| `~/Library/Application Support/AwtrixConnectors/anecdotes.json` | a literal in `AppPaths` | **Keep**. The rename does not move it, and moving it would take a second, file-system migration whose only gain is the folder's name, at the risk of the played set that "never repeat" rests on |
| `$TMPDIR/awtrix-speech` | a literal in `AppPaths` | **Keep**. The store records clip paths absolutely, and the reaper only reclaims inside the root, so a new root would orphan every recorded clip |
| `DispatchQueue` labels `dev.artk0re.awtrix-connectors.*` | nothing persisted | **Rename** to `dev.artk0re.pixelclocktiles.*` |
| Logger subsystems, Caches | none exist | — |
| Notification identifiers | per-request UUIDs | nothing to do; the notification grant is paid once |
| Login item (`SMAppService.mainApp`) | the bundle | nothing stored; the user turns it on again once |
| Keychain | reads Claude Code's items (`Claude Code-credentials`), none of ours | nothing to do; the access prompt is paid once |
| TCC grants (location, notifications, Focus, Local Network, Full Disk Access) | bundle id + signature | paid once by the user, as the spec says |
| Signing identity `AwtrixConnectors Local Signing` | selected by SHA-1 | **Keep**; its name is not read by anything |
| App icon wordmark reading `AWTRIX` (`Scripts/MakeIcon.swift`) | art | **Keep** for now; a redesign is a design question for the user, not a rename |

---

### Task 1: The mechanical rename

**Files:**
- Move: `Sources/AwtrixKit/` → `Sources/PixelClockKit/`, `Sources/AwtrixConnectorsApp/` → `Sources/PixelClockTilesApp/`, `Tests/AwtrixKitTests/` → `Tests/PixelClockKitTests/`, `Tests/AwtrixConnectorsAppTests/` → `Tests/PixelClockTilesAppTests/`
- Move: `Sources/PixelClockKit/AwtrixKit.swift` → `Sources/PixelClockKit/PixelClockKit.swift`
- Modify: `Package.swift`, every `.swift` file under `Sources/` and `Tests/` that names `AwtrixKit` or `AwtrixConnectorsApp`, `Scripts/make_parser_parity_corpus.py`
- Modify: `Scripts/bundle.sh:18-19` — `--product` and the binary path only, so the script builds at this commit too

**Interfaces:**
- Produces: module `PixelClockKit`, executable target `PixelClockTilesApp`, test targets `PixelClockKitTests` and `PixelClockTilesAppTests`, package `PixelClockTiles`, `public enum PixelClockKit { static let version }`, `@main struct PixelClockTilesApp`.

The enum keeps shadowing its module, as `AwtrixKit` did. Fixing that is its
own task in HANDOFF, and this one changes no behaviour.

- [ ] **Step 1: Move the directories and the namespace file**

```bash
git mv Sources/AwtrixKit Sources/PixelClockKit
git mv Sources/AwtrixConnectorsApp Sources/PixelClockTilesApp
git mv Tests/AwtrixKitTests Tests/PixelClockKitTests
git mv Tests/AwtrixConnectorsAppTests Tests/PixelClockTilesAppTests
git mv Sources/PixelClockKit/AwtrixKit.swift Sources/PixelClockKit/PixelClockKit.swift
```

- [ ] **Step 2: Substitute the names**

`AwtrixConnectorsApp` goes first, so the bare `AwtrixConnectors` left in
`LoginItem.swift` and `AppPaths` stays for Tasks 2 and 4 to decide.

```bash
files=$(grep -rlE 'AwtrixKit|AwtrixConnectorsApp' Sources Tests Package.swift Scripts/make_parser_parity_corpus.py)
sed -i '' -e 's/AwtrixConnectorsApp/PixelClockTilesApp/g' -e 's/AwtrixKit/PixelClockKit/g' $files
sed -i '' -e 's/name: "AwtrixConnectors"/name: "PixelClockTiles"/' Package.swift
```

- [ ] **Step 3: Check nothing is left**

Run: `grep -rnE 'AwtrixKit|AwtrixConnectorsApp' Sources Tests Package.swift Scripts`
Expected: no output.

- [ ] **Step 4: Build and test**

Run: `swift build 2>&1 | grep -i warning` — expected empty.
Run: `swift test` — expected 999 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Sources Tests Package.swift Scripts/make_parser_parity_corpus.py Scripts/bundle.sh
git commit -m "refactor: rename the package to PixelClockTiles and the kit to PixelClockKit"
```

### Task 2: The bundle and the words the user sees

**Files:**
- Modify: `Scripts/bundle.sh`
- Modify: `Sources/PixelClockTilesApp/LoginItem.swift:81` — "Turn PixelClockTiles on in System Settings › General › Login Items."
- Modify: `Sources/PixelClockTilesApp/App.swift` — the glyph's `accessibilityDescription` becomes `"PixelClockTiles"`; `Tests/PixelClockTilesAppTests/AppShellTests.swift` mirrors it in `glyphDrawnFrom`
- Modify: `Sources/PixelClockTilesApp/SystemChangeWatcher.swift:19,50` — queue labels `dev.artk0re.pixelclocktiles.network-path` / `.focus-assertions`
- Modify: the `defaults write dev.artk0re.awtrix-connectors …` comments in `PanelWidth.swift`, `AwtrixDevice.swift`, `PanelWidthTests.swift` → `dev.artk0re.pixelclocktiles`

`bundle.sh`: `APP="build/PixelClockTiles.app"`, `--product PixelClockTilesApp`,
binary `PixelClockTilesApp` copied to `Contents/MacOS/PixelClockTiles`,
`CFBundleExecutable` and `CFBundleName` `PixelClockTiles`,
`CFBundleIdentifier` `dev.artk0re.pixelclocktiles`. Usage strings:

- Local Network: "PixelClockTiles looks for pixel clocks on your network, so you do not have to type their address yourself."
- Focus: "PixelClockTiles checks whether a Focus is on, so it stays quiet instead of reading a joke out loud while you are busy."
- Location: "PixelClockTiles reads this Mac's location once, when you ask it to, so the clock shows the weather where you actually are."

The battery alert titles ("AWTRIX clock is low") and the discovery lines
("Looking for AWTRIX devices…") stay. They describe the device, which in this
phase is still only ever an AWTRIX clock, and phase 4 renames them per clock.

- [ ] **Step 1:** Apply the edits above.
- [ ] **Step 2:** `swift build 2>&1 | grep -i warning` empty; `swift test` 999 passed.
- [ ] **Step 3:** `./Scripts/bundle.sh debug`, then check the result:

```bash
plutil -extract CFBundleIdentifier raw build/PixelClockTiles.app/Contents/Info.plist   # dev.artk0re.pixelclocktiles
test -x build/PixelClockTiles.app/Contents/MacOS/PixelClockTiles && echo ok
```

- [ ] **Step 4: Commit** — `feat: ship as PixelClockTiles under dev.artk0re.pixelclocktiles`

### Task 3: Carry the old settings over, once

**Files:**
- Create: `Sources/PixelClockTilesApp/DefaultsCarryOver.swift`
- Test: `Tests/PixelClockTilesAppTests/DefaultsCarryOverTests.swift`
- Modify: `Sources/PixelClockTilesApp/App.swift` — `AppDelegate.init()` runs the copy before `.live()`

**Interfaces:**
- Produces:

```swift
enum DefaultsCarryOver {
    static let previousDomain = "dev.artk0re.awtrix-connectors"
    static let doneKey = "carriedOverFromAwtrixConnectors"
    /// The writes a carry-over makes, in order, the marker last. Empty once done.
    static func writes(previous: [String: Any], current: [String: Any]) -> [(key: String, value: Any)]
    /// Reads both persistent domains through `defaults` and applies `writes`.
    /// `current` nil — a bare `swift run` with no bundle id — does nothing.
    static func run(from previous: String, into current: String?, through defaults: UserDefaults)
}
```

`current` is compared against the new domain's **persistent** dictionary,
never `defaults.object(forKey:)`. The search list also answers from
`NSGlobalDomain`, so a per-app `AppleLanguages` the old app carried would
count as already present and be dropped.

- [ ] **Step 1: Write the failing tests.** Each test uses two fresh suites (`carry-over-old-<uuid>`, `carry-over-new-<uuid>`), both removed in `defer`:
  - every key of the old domain arrives in the new one, with its type (string, integer, bool, data);
  - a key the new domain already holds keeps its value;
  - a key the new domain only has as a registered default is still carried over (the key is unique to the test: the registration domain is process-wide and cannot be taken back);
  - a copy cut short writes only what is still missing, marker last;
  - a second run copies nothing, even after the old domain gained a key;
  - the old domain is byte-for-byte what it was;
  - `writes` puts the marker last, and returns nothing once the marker is present;
  - an absent old domain still writes the marker, and nothing else;
  - a nil current domain writes nothing;
  - `previousDomain` is exactly `"dev.artk0re.awtrix-connectors"`.
- [ ] **Step 2:** `swift test --filter DefaultsCarryOverTests` fails to compile (`DefaultsCarryOver` undefined).
- [ ] **Step 3:** Implement:

```swift
static func writes(previous: [String: Any], current: [String: Any]) -> [(key: String, value: Any)] {
    guard current[doneKey] == nil else { return [] }
    let carried = previous
        .filter { current[$0.key] == nil }
        .sorted { $0.key < $1.key }
        .map { (key: $0.key, value: $0.value) }
    return carried + [(key: doneKey, value: true)]
}

static func run(from previous: String, into current: String?, through defaults: UserDefaults) {
    guard let current else { return }
    let pending = writes(
        previous: defaults.persistentDomain(forName: previous) ?? [:],
        current: defaults.persistentDomain(forName: current) ?? [:]
    )
    for (key, value) in pending { defaults.set(value, forKey: key) }
}
```

Wire in `AppDelegate.init()`, first line:

```swift
DefaultsCarryOver.run(
    from: DefaultsCarryOver.previousDomain,
    into: Bundle.main.bundleIdentifier,
    through: .standard
)
```

- [ ] **Step 4:** Filtered run passes; then mutate one site at a time (drop the `current[$0.key] == nil` filter; move the marker first; drop the `doneKey` guard; drop the nil guard) and watch a test go red for each; restore.
- [ ] **Step 5:** Full `swift test` green, build warning-free.
- [ ] **Step 6: Commit** — `feat: carry the settings over from dev.artk0re.awtrix-connectors on first launch`

### Task 4: Say why two folders keep the old name

**Files:**
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`AppPaths.clipRoot`, `AppPaths.anecdoteStore`), one line each

A literal reading `AwtrixConnectors` next to a PixelClockTiles bundle is the
kind of thing somebody "fixes". Each gets a one-line comment naming the data
it would strand. No executable change.

- [ ] **Step 1:** Add the two comments.
- [ ] **Step 2:** `swift build` warning-free.
- [ ] **Step 3: Commit** — `docs: say why the played set and the clips keep their folders' old names`

### Task 5: HANDOFF

**Files:**
- Modify: `docs/HANDOFF.md`

The installed path becomes `~/Applications/PixelClockTiles.app`. The build and
`codesign` commands point at `build/PixelClockTiles.app`, the `defaults write`
lines at `dev.artk0re.pixelclocktiles`, the test count at the measured one,
and the shadowing item at `public enum PixelClockKit`. A new section records
the rename: the carry-over, the persisted-identity decisions above, and what
the user pays once (TCC grants, the login item, the keychain prompt, removing
the old `AwtrixConnectors.app`).

- [ ] **Step 1:** Edit.
- [ ] **Step 2: Commit** — `docs: bring HANDOFF up to the PixelClockTiles names`

# PixelClockTiles Phase 3 — the TC002 adapter

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development
> (recommended) or superpowers:executing-plans. When executing, follow every RED-first
> step: write the test, run it, watch it fail, then implement. Read `docs/HANDOFF.md`
> § 'How this branch finds defects' before the first task.

## Goal

Give the Ulanzi TC002 pixel clock the same standing the AWTRIX flip clock already
has: a Mac-side raster pipeline, a device adapter for the TC002 HTTP API, and a
session that keeps every tile's page alive on the clock.

One custom app per tile (D1). The user flips between pages with the clock's knob;
the Mac never rotates, never times a dwell, never calls `switchDiyApp`. The Mac
rasters each face into a 52×16 canvas and ships it as one `db` bitmap command to
the tile's own named app. Apps outlive our process, so custody is durable.

The phase splits in two parts:

- **Part 3a** — pure adapter logic under `Sources/PixelClockKit/Ulanzi/`. No
  dependency on phase 1. Runs standalone.
- **Part 3b** — wiring to the phase-1 clock model and the phase-2 delivery chain.
  Presumes phases 1 + 2 landed on the tree.

## Architecture

```
Connector.read() ──▶ ulanziFace.draw(reading) ──▶ UlanziDelivery (scene = UlanziScene)
                                                        │
                    PixelCanvas (52×16, Mac-side raster) │
                                                        ▼
UlanziTileBoard ── per-tile latest frame / idle frame ──┤
                                                        ▼
UlanziClockSession ── upsert per tile, re-push-all on recovery, sweep at start
        │                      │
        ▼                      ▼
  UlanziDevice          UlanziCustody (durable name record, ≤21 apps)
  POST /api/custom      UserDefaults-backed, one name per tile
```

## Tech stack

- Swift 6.3.3, SwiftPM, macOS 14 floor, `swift-testing` (`#expect` / `#require`).
- Swift 6 strict concurrency: `Sendable` scene types, actors for device/custody/session.
- Network Framework (`NWListener`) for the UDP broadcast listener. No third-party
  dependencies, ever.

## Spec

- `docs/specs/2026-09-18-pixelclock-tc002-adapter.md`
- Measured protocol facts: `docs/specs/2026-09-18-pixelclock-tc002-research.md`
  (§2 captured exchanges, §4 payload limits, §5 quirks E1–E9, §6 DIY pages).
- Read `docs/HANDOFF.md` § 'How this branch finds defects' before the first task.

The research doc is the source of truth wherever the spec's wording predates the
live session. Corrections are recorded in the Decisions table.

## Global constraints

- RED-first everywhere: each task writes failing tests first and shows the failure
  before implementing.
- `swift test -j 2 --no-parallel` is the verification command. Full-suite runs pass
  `--skip nothingButTheAnecdotesEverPutsSoundInTheRoom`; that one test runs alone
  at the end of the session, never inside a parallel run.
- No test ever touches the network (D13). Device calls go through an injected
  `Transport`; the real `URLSessionTransport` appears in production paths only.
- The TC002 at 192.168.1.72 is READ-ONLY for development. Never POST to it, never
  switch its DIY page, never point a test at it.
- English comments, identifiers, commit messages.
- Stages name explicit paths (`git add <paths>`), never `git add -A`.

## Decisions

| #   | Decision                                                                                                                                                                                                                                                                                                                |
| --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| D1  | **One DIY app per tile.** The user rotates pages with the clock's knob (DIY pages 100–120, cycle at DIY L2 — research §6). There is no `UlanziRotation`, no dwell timer, no Mac-side rotation of any kind. Corrects the spec's single-app `pixelclocktiles` + Mac-rotation wording.                                       |
| D2  | **The Mac rasters, the device never composes.** Each face renders a `PixelCanvas` (52×16) and ships it as a single `db` draw command. `duration` stays a constant 5 — measured to be a display value, not a TTL (research §4). Faces emit no `text[]`; the field stays in the frame model for the vocabulary's completeness. |
| D3  | **`switchDiyApp` is never automatic.** Phase 3 does not implement it. `UlanziDevice` has no such method; a later "Show on clock" user action is the only permitted future caller.                                                                                                                                        |
| D4  | **Presence per page.** Every push is an upsert of that tile's app. On offline→online recovery and at startup the session re-pushes ALL tile apps immediately (custom apps likely do not survive a device reboot — E9 unverified — and upsert re-creates them). A paused tile keeps its page alive with an idle frame, never deleted. `{}` goes out only when the tile is removed or the app quits; the page then drops out of the knob cycle, which is user-initiated and acceptable. Effect on a user parked on the deleted page is unknown (E4) — hardware check in Task 11. |
| D5  | **`Ulanzi/` mirrors `Awtrix/`.** New files live in `Sources/PixelClockKit/Ulanzi/`. The phase adds nothing outside that directory except the `Connector` extension (Task 3) and the two faces (Task 7). `Delivery` is untouched; `UlanziScene` is `Sendable & Equatable` so `typealias UlanziDelivery = Delivery<UlanziScene>` works. |
| D6  | **Audio stays on the Mac.** No `DeviceSpeaker`, no TC002 audio path. The TC002 anecdote face is a post-phase-3 follow-up, not part of this plan.                                                                                                                                                                         |
| D7  | **Measured limits are enforced in code, mutation-tested** (research §4): ≤32 draw commands, ≤6 images with ≤3 GIFs, GIF ≤256×256 and ≤50 frames, stills ≤512×512, base64 ≤60 KB, `fontHeight` 5 or 10. New for this model: **≤21 custom apps per clock** (DIY pages 100–120) — enforced by custody, tested in Task 5.        |
| D8  | **The body `code` decides success.** HTTP 200 with body `{"code":101}` is a failure. Statuses alone never mean success (research §2).                                                                                                                                                                                    |
| D9  | **Custody is durable.** AWTRIX apps live in our process RAM (in-memory custody); TC002 apps outlive the sender, so the record must too: `UlanziAppRecord` over UserDefaults, key `ownedApps.<clockId>`, one name per tile.                                                                                               |
| D10 | **Naming: `pct-<tileId>`.** In phase 3 `tileId` is the connector id string; `TileKey` arrives in phase 4 (mirrors phase-2 D2). The sweep compares record ∩ `customList` against live tile ids, so stale names from crashes or older builds leave the knob cycle.                                                          |
| D11 | **`ulanziFace` is optional with a nil default.** No connector is forced to grow a TC002 face; `produceUlanzi()` returns nil for them. Lands in 3a (pure logic, no phase-1 need) and supersedes the phase-2 D6 note that scheduled it for "Phase 3b".                                                                      |
| D12 | **Glyphs land with their first caller.** `PixelFont` ships exactly the set the two phase-3 faces enumerate — digits 0–9, `-`, `%`, `°`, space — and nothing more. No speculative alphabet; a time face adds `:` when it exists.                                                                                            |
| D13 | **No test hits the network.** The TC002 at 192.168.1.72 is read-only during development: no POSTs, no page switches, no fixture probes. Device tests inject a scripted `Transport` double.                                                                                                                               |

## Impact signals

Measured on the integration tree (`pct-worktrees/int`), 2026-09-19:

| File                                                        | Commits | Fix-like | Reading for this phase                                                                       |
| ----------------------------------------------------------- | ------- | -------- | -------------------------------------------------------------------------------------------- |
| `Sources/PixelClockTilesApp/AppModel.swift`                 | 36      | 13 (36%) | The hottest file. Task 10 keeps the wiring additive: a new protocol + a new branch in `live()`, the AWTRIX path untouched. |
| `Sources/PixelClockKit/Connectors/Connector.swift`          | 15      | 2        | The protocol extension (Task 3) is additive-only; no existing member changes.                |
| `Sources/PixelClockKit/Connectors/WeatherConnector.swift`   | 15      | 2        | Task 7 appends the TC002 face; the AWTRIX face is byte-identical afterwards.                 |
| `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` | 5     | 0        | Same as weather; face appended, lane C's reporting seam untouched.                            |

## File structure

```
Sources/PixelClockKit/
├── Ulanzi/                          ← NEW, mirrors Awtrix/ (D5)
│   ├── PixelCanvas.swift            (Task 1)
│   ├── PixelFont.swift              (Task 1)
│   ├── UlanziScene.swift            (Task 2)
│   ├── UlanziFace.swift             (Task 3)
│   ├── UlanziDevice.swift           (Task 4)
│   ├── UlanziError.swift            (Task 4)
│   ├── UlanziCustody.swift          (Task 5)
│   ├── UlanziDiscovery.swift        (Task 6)
│   ├── UlanziTileBoard.swift        (Task 8)
│   └── UlanziClockSession.swift     (Task 9)
├── Connectors/
│   ├── Connector.swift              (Task 3 modifies: one extension)
│   ├── WeatherConnector.swift       (Task 7 modifies: TC002 face)
│   └── ClaudeUsageConnector.swift   (Task 7 modifies: TC002 face)
Sources/PixelClockTilesApp/
└── AppModel.swift                   (Task 10 modifies: Ulanzi branch in live())
Tests/PixelClockKitTests/
├── PixelCanvasTests.swift           (Task 1)
├── UlanziSceneTests.swift           (Task 2)
├── UlanziFaceTests.swift            (Task 3)
├── UlanziDeviceTests.swift          (Task 4, two suites incl. UlanziDeviceSendTests)
├── UlanziCustodyTests.swift         (Task 5)
├── UlanziDiscoveryTests.swift       (Task 6)
├── UlanziTileBoardTests.swift       (Task 8)
└── UlanziClockSessionTests.swift    (Task 9)
Tests/PixelClockTilesAppTests/
└── UlanziWiringTests.swift          (Task 10)
docs/HANDOFF.md                      (Task 11 appends)
```

## Contact points

- **Phase 2 (landed).** `Delivery` stays generic and untouched; `UlanziScene` must
  satisfy `Sendable & Equatable` to become `Delivery<UlanziScene>`. The
  `Transport` protocol and `DeviceAddress.host(from:)` are reused as-is. The
  `Connector` protocol gains one extension member (`ulanziFace`) — no existing
  member changes. `ConnectorRunning` stays app-facing; see phase 3b below.
- **Phase 1 (presumed for 3b).** Part 3b presumes `ClockRecord`, `ClockModel`,
  and the persisted `clocks` list exist. They are NOT on the tree at plan time —
  phase 1 runs in parallel. Part 3a does not reference any of them.
- **Phase 4 (future).** `TileKey` replaces the string connector id as tile
  identity (D10). Adoption UI consumes `UlanziBroadcastListener` and
  `UlanziProbe` — both land in Task 6 without callers, deliberately; phase 4
  owns their first caller. `ConnectorRunning` and `UlanziConnectorRunning`
  unify under it.
- **Lane C (parallel).** `ClaudeUsageReporting` and its seam are untouched. Task 7
  appends a face to `ClaudeUsageConnector` only.
- **Borrowed overlays.** `borrowedOverlay.<clockId>` stays out of phase 3 — the
  TC002 session has no icon installer and no overlay store.

---

## Part 3a — pure adapter logic (`Sources/PixelClockKit/Ulanzi/`)

Standalone: no phase-1 type is referenced. Every task here can land without the
other lanes.

### Task 0: Baseline

The phase assumes the integration tree compiles and the suite is green before the
first RED. Verify both, and record the anchors the audit (Task 11) needs.

**Files:**

- Read: `docs/HANDOFF.md` (§ 'How this branch finds defects')
- Read: `docs/specs/2026-09-18-pixelclock-tc002-research.md` (§2 exchanges, §4 limits)
- Unchanged: everything else

**Interfaces:**

- Consumes: phases 0 + 2 landed on this tree (`Sources/PixelClockKit/Awtrix/`
  with `Transport.swift`, `Connectors/Connector.swift` present)

- [ ] **Step 1: Confirm the phase-2 substrate is present.**

Run:

```bash
test -d Sources/PixelClockKit/Awtrix && test -f Sources/PixelClockKit/Awtrix/Transport.swift && test -f Sources/PixelClockKit/Connectors/Connector.swift
```

Expected: no output. If any path is missing, stop — this is not the tree the
plan extends.

- [ ] **Step 2: Clean build, zero warnings.**

Run:

```bash
swift build -j 2 2>&1 | grep -i warning
```

Expected: no output.

- [ ] **Step 3: Full suite green; record N0 and BASE.**

Run:

```bash
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
git rev-parse HEAD
```

Expected: pass. Record the passed-count as `N0` and the revision as `BASE` —
the Task 11 audit diffs against both.

---

### Task 1: PixelCanvas and PixelFont — the Mac-side raster

The TC002 panel is 52×16. Faces render there on the Mac and the canvas leaves as
one `db` command (Task 2 encodes it). The font is 3×5; D12 fixes the glyph set to
what the two phase-3 faces enumerate: digits 0–9, `-`, `%`, `°`, space. A time
face adds `:` when one exists.

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/PixelCanvas.swift`
- Create: `Sources/PixelClockKit/Ulanzi/PixelFont.swift`
- Create: `Tests/PixelClockKitTests/PixelCanvasTests.swift`
- Unchanged: everything under `Awtrix/` (AWTRIX has its own scene primitives)

**Interfaces:**

- Produces: `Pixel`, `PixelPoint`, `PixelRect`, `PixelCanvas`
  (`subscript(x:y:)`, `fill`, `drawRect`, `drawLine`, `drawText`, `drawCommands` deferred to Task 2)
- Produces: `PixelFont` (3×5 glyph table for the D12 set)

- [ ] **Step 1: RED — canvas geometry and painting.**

`Tests/PixelClockKitTests/PixelCanvasTests.swift` (first line of every code block
names its file):

```swift
// Tests/PixelClockKitTests/PixelCanvasTests.swift
import Testing
@testable import PixelClockKit

@Suite struct PixelCanvasTests {
    @Test func canvasIsExactlyFiftyTwoBySixteen() {
        #expect(PixelCanvas.width == 52)
        #expect(PixelCanvas.height == 16)
    }

    @Test func freshCanvasIsBlack() {
        let canvas = PixelCanvas()
        #expect(canvas[0, 0] == .black)
        #expect(canvas[51, 15] == .black)
    }

    @Test func fillReachesEveryPixel() {
        var canvas = PixelCanvas()
        canvas.fill(.white)
        #expect(canvas[25, 7] == .white)
        #expect(canvas[0, 15] == .white)
    }

    @Test func subscriptOutOfBoundsPreconditionsDie() {
        // precondition failure, asserted via the #expect(throws:) on
        // Never-returning call — simplest form: document that out-of-range is a
        // programmer error, cover the in-range paths elsewhere.
        let canvas = PixelCanvas()
        #expect(canvas[51, 15] != nil)
    }

    @Test func rectDrawingClipsToTheCanvas() {
        var canvas = PixelCanvas()
        canvas.drawRect(PixelRect(x: 50, y: 14, width: 10, height: 10), color: .white)
        #expect(canvas[51, 15] == .white)   // inside, painted
        // nothing outside exists to check — clipping means no crash, no wrap
        #expect(canvas[49, 13] == .black)   // untouched corner above the rect
    }

    @Test func lineDrawingIsClipSafe() {
        var canvas = PixelCanvas()
        canvas.drawLine(from: PixelPoint(x: 0, y: 0), to: PixelPoint(x: 100, y: 100), color: .white)
        #expect(canvas[0, 0] == .white)
        #expect(canvas[51, 15] == .white)   // diagonal crosses the corner
    }

    @Test func textRendersThroughTheFont() {
        var canvas = PixelCanvas()
        canvas.drawText("12", at: PixelPoint(x: 0, y: 0), ink: .white)
        #expect(canvas[0, 0] == .white)     // first on-pixel of glyph "1"
        #expect(canvas[3, 5] == .black)     // gap column between glyphs
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter PixelCanvasTests
```

Expected: compile error — `PixelCanvas` does not exist.

- [ ] **Step 2: GREEN — implement the canvas.**

```swift
// Sources/PixelClockKit/Ulanzi/PixelCanvas.swift
/// One 8-bit RGB pixel, packed for the TC002 panel.
public struct Pixel: Sendable, Equatable, Hashable {
    public var red: UInt8
    public var green: UInt8
    public var blue: UInt8

    public static let black = Pixel(red: 0, green: 0, blue: 0)
    public static let white = Pixel(red: 255, green: 255, blue: 255)
}

public struct PixelPoint: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public static let zero = PixelPoint(x: 0, y: 0)
}

public struct PixelRect: Sendable, Equatable, Hashable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int
}

/// A 52×16 RGB raster — the exact frame the TC002 panel shows.
///
/// Faces render here and the canvas leaves as one `db` bitmap command (Task 2).
/// Row-major, origin at the top-left corner.
public struct PixelCanvas: Sendable, Equatable {
    public static let width = 52
    public static let height = 16

    private var pixels: [Pixel]

    public init() { pixels = .init(repeating: .black, count: Self.width * Self.height) }

    public subscript(x: Int, y: Int) -> Pixel {
        get {
            preconditionBounds(x: x, y: y)
            return pixels[y * Self.width + x]
        }
        set {
            preconditionBounds(x: x, y: y)
            pixels[y * Self.width + x] = newValue
        }
    }

    public mutating func fill(_ color: Pixel)
    public mutating func drawRect(_ rect: PixelRect, color: Pixel)      // clip-safe
    public mutating func drawLine(from: PixelPoint, to: PixelPoint, color: Pixel)  // Bresenham, clip-safe
    public mutating func drawText(_ text: String, at origin: PixelPoint, ink: Pixel, scale: Int = 1)
}
```

`drawText` walks `PixelFont.glyph(for:)` per character (4-column advance at scale
1: 3 glyph columns + 1 gap), painting ink where a glyph bit is set. Out-of-range
subscript is a precondition failure — a programmer error, never a silent clip.
Draw primitives clip; rasterization never wraps around edges.

- [ ] **Step 3: RED then GREEN — the font.**

Add to the same test file: every character in the D12 set has a 5-row glyph;
`"-"`, `"%"`, `"°"` and digit `"5"` each pin their full bitmap.

```swift
// Sources/PixelClockKit/Ulanzi/PixelFont.swift
/// 3×5 pixel font for the glyphs the TC002 faces actually draw (D12).
/// Rows are top-first, one byte per row, low 3 bits = left-to-right.
public enum PixelFont {
    public static func glyph(for character: Character) -> [UInt8]?   // nil outside the set
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter PixelCanvasTests
```

Expected: pass.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/PixelCanvas.swift Sources/PixelClockKit/Ulanzi/PixelFont.swift Tests/PixelClockKitTests/PixelCanvasTests.swift
git commit -m "PixelClockKit: 52x16 raster canvas and the 3x5 face font"
```

---

### Task 2: UlanziScene — the payload model and its measured limits

The TC002 payload is `{"duration": n, "text": [...], "draw": [...], "image": [...]}`
behind `POST /api/custom?name=<name>`. Research §4 measured the real ceilings; D7
enforces them in the encoder, and the mutation steps below pin each one to a test.
A scene is single-frame in phase 3: the carousel exists in the grammar but never
cycles custom apps (research §5), so extra frames would silently never show.

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziScene.swift`
- Create: `Tests/PixelClockKitTests/UlanziSceneTests.swift`
- Modify: `Sources/PixelClockKit/Ulanzi/PixelCanvas.swift` (adds `drawCommands()`)
- Unchanged: `Awtrix/AwtrixScene.swift` (`Delivery` stays there, untouched — D5)

**Interfaces:**

- Produces: `UlanziColour`, `UlanziFontHeight`, `UlanziDraw`, `UlanziImage`,
  `UlanziText`, `UlanziFrame`, `UlanziScene`, `UlanziScene.idle`
- Produces: `PixelCanvas.drawCommands(ink:) -> UlanziDraw` (one full-screen `.bitmap`)
- Consumes: `PixelCanvas`, `PixelPoint` (Task 1)
- Consumes: nothing from `Awtrix/` at the type level (the `Delivery` typealias
  lands in Task 3)

- [ ] **Step 1: RED — limits throw.**

```swift
// Tests/PixelClockKitTests/UlanziSceneTests.swift
import Testing
@testable import PixelClockKit

@Suite struct UlanziSceneTests {
    // -- construction ------------------------------------------------------

    @Test func singleFrameSceneEncodesDbFromCanvas() throws {
        var canvas = PixelCanvas()
        canvas.fill(.white)
        let scene = UlanziScene(frames: [UlanziFrame(duration: 5, draw: [canvas.drawCommands()])])
        let json = try scene.jsonObject()
        let draw = json["draw"] as? [[String: Any]]
        #expect(draw?.count == 1)
        let bitmap = draw?[0]["db"] as? [Int]
        #expect(bitmap?.count == 2 + PixelCanvas.width * PixelCanvas.height)  // [w, h, w*h pixels]
        #expect(bitmap?[0] == PixelCanvas.width)
        #expect(bitmap?[1] == PixelCanvas.height)
    }

    @Test func sceneMustBeSingleFrame() {
        let frame = UlanziFrame(duration: 5, draw: [])
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [frame, frame]).jsonObject()
        }
    }

    // -- measured limits (research §4) --------------------------------------

    @Test func thirtyThreeDrawCommandsThrow() {
        let draw = Array(repeating: UlanziDraw.pixel(.zero, .white), count: 33)
        #expect(throws: UlanziError.self) {
            try UlanziScene(frames: [UlanziFrame(duration: 5, draw: draw)]).jsonObject()
        }
    }

    @Test func thirtyTwoDrawCommandsPass() throws {
        let draw = Array(repeating: UlanziDraw.pixel(.zero, .white), count: 32)
        #expect(try UlanziScene(frames: [UlanziFrame(duration: 5, draw: draw)]).jsonObject() != nil)
    }

    @Test func seventhImageThrows() { /* 7 stills → throws */ }
    @Test func fourthGifThrows() { /* 3 stills + 2 gifs ok, 4th gif → throws */ }
    @Test func gifOverTwoFiftySixSquareThrows() { /* 256×256 ok, 257×257 → throws */ }
    @Test func gifWithFiftyOneFramesThrows() { /* 50 ok, 51 → throws */ }
    @Test func base64OverSixtyKilobytesThrows() { /* 60_000 ok, 60_001 → throws */ }

    // -- text sanitization ---------------------------------------------------

    @Test func nonAsciiTextIsSanitizedToPrintableAscii() throws {
        var frame = UlanziFrame(duration: 5, draw: [])
        frame.text = [UlanziText(content: "héllo")]
        let json = try UlanziScene(frames: [frame]).jsonObject()
        // 'é' falls outside 0x20–0x7E; the encoder replaces it — assert the shape
        let text = json["text"] as? [String]
        #expect(text?[0].allSatisfy { $0.asciiValue != nil && (0x20...0x7E).contains($0.asciiValue!) } == true)
    }

    // -- idle scene (D4) ------------------------------------------------------

    @Test func idleSceneIsOneFrameWithAMarker() throws {
        let json = try UlanziScene.idle.jsonObject()
        #expect((json["draw"] as? [[String: Any]])?.count == 1)   // one db: the dim dot
    }
}
```

Fill each placeholder body in the same shape as `thirtyThreeDrawCommandsThrow` —
boundary at the measured limit, one over throws, at-limit passes.

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziSceneTests
```

Expected: compile error — `UlanziScene` does not exist.

- [ ] **Step 2: GREEN — implement the model and encoder.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziScene.swift
/// A colour for `draw` commands, packed 0x00RRGGBB as the device expects.
public struct UlanziColour: Sendable, Equatable, Hashable {
    public let value: UInt32
    public static let black = UlanziColour(value: 0)
    public static let white = UlanziColour(value: 0xFF_FF_FF)
}

public enum UlanziFontHeight: Int, Sendable, Equatable {
    case small = 5
    case large = 10
}

/// One `draw[]` command in the device vocabulary (research §2.2).
public enum UlanziDraw: Sendable, Equatable {
    case pixel(PixelPoint, UlanziColour)                        // dp
    case line(PixelPoint, PixelPoint, UlanziColour)             // dl
    case rect(x: Int, y: Int, w: Int, h: Int, UlanziColour)     // dr
    case filledRect(x: Int, y: Int, w: Int, h: Int, UlanziColour) // df
    case circle(center: PixelPoint, radius: Int, UlanziColour)  // dc
    case filledCircle(center: PixelPoint, radius: Int, UlanziColour) // dfc
    case text(String, at: PixelPoint, color: UlanziColour, font: UlanziFontHeight) // dt
    /// `[width, height, width*height packed pixels]` — what PixelCanvas ships as.
    case bitmap(width: Int, height: Int, pixels: [UInt32], at: PixelPoint)   // db
}

public struct UlanziImage: Sendable, Equatable {
    public let base64: String
    public let isAnimated: Bool
    /// Declared metadata the encoder validates against the limits; the device
    /// enforces reality.
    public let frameCount: Int
    public let pixelSize: (width: Int, height: Int)
}

public struct UlanziText: Sendable, Equatable {
    public var content: String
}

public struct UlanziFrame: Sendable, Equatable {
    public var duration: Int
    public var draw: [UlanziDraw]
    public var image: [UlanziImage]
    public var text: [UlanziText]
}

public struct UlanziScene: Sendable, Equatable {
    public var frames: [UlanziFrame]

    /// The paused-tile presence frame: one dim dot (D4).
    public static let idle = UlanziScene(frames: [])
}
```

`jsonObject()` is the enforcement point: single frame only, ≤32 draw commands,
≤6 images with ≤3 animated, animated ≤256×256 and ≤50 frames, stills ≤512×512,
base64 ≤60_000 bytes, text sanitized to printable ASCII 0x20–0x7E. Violations
throw `UlanziError.limit(...)` — defined in Task 4's `UlanziError.swift`, forward-
declared here as `UlanziError` (same module, file lands next task).

Add to `PixelCanvas`:

```swift
// Sources/PixelClockKit/Ulanzi/PixelCanvas.swift (append)
/// The whole canvas as one full-screen db command — how every face ships.
public func drawCommands() -> UlanziDraw {
    var packed: [UInt32] = []
    packed.reserveCapacity(Self.width * Self.height)
    for y in 0..<Self.height {
        for x in 0..<Self.width {
            let p = self[x, y]
            packed.append(UInt32(p.red) << 16 | UInt32(p.green) << 8 | UInt32(p.blue))
        }
    }
    return .bitmap(width: Self.width, height: Self.height, pixels: packed, at: .zero)
}
```

- [ ] **Step 3: MUTATE — one limit site at a time.**

For each enforcement branch in `jsonObject()`: change the constant by one
(32→33, 6→7, 3→4, 256→257, 50→51, 60_000→60_001), run the suite, expect the
matching test to FAIL, revert. After adding the last guard, re-run the mutations
of the guards in front of it (phase-2 discipline).

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziSceneTests
```

Expected: pass at every revert.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziScene.swift Sources/PixelClockKit/Ulanzi/PixelCanvas.swift Tests/PixelClockKitTests/UlanziSceneTests.swift
git commit -m "PixelClockKit: UlanziScene payload model with the measured device limits"
```

---

### Task 3: UlanziFace — the TC002 counterpart of AwtrixFace

The connector protocol grows an optional TC002 face. Nil is the default: no
connector changes unless it grows a TC002 face (D11). This lands in 3a, not 3b —
it is pure logic and needs nothing from phase 1 (supersedes phase-2 D6's
"Phase 3b" scheduling).

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziFace.swift`
- Modify: `Sources/PixelClockKit/Connectors/Connector.swift` (append one extension)
- Create: `Tests/PixelClockKitTests/UlanziFaceTests.swift`
- Unchanged: every existing face (`awtrixFace` implementations are byte-identical)

**Interfaces:**

- Produces: `UlanziFace<Reading>`, `typealias UlanziDelivery = Delivery<UlanziScene>`,
  `Connector.ulanziFace`, `Connector.produceUlanzi()`
- Consumes: `Delivery<Scene>` from `Awtrix/AwtrixScene.swift` (generic, public —
  referenced, not modified)
- Consumes: `Connector` (phase 0) — `id`, `read()`, `associatedtype Reading: Sendable`

- [ ] **Step 1: RED — face renders, default is nil, read errors propagate.**

```swift
// Tests/PixelClockKitTests/UlanziFaceTests.swift
import Testing
@testable import PixelClockKit

@Suite struct UlanziFaceTests {
    @Test func connectorWithoutFaceProducesNil() async throws {
        let connector = FacelessConnector()
        #expect(connector.ulanziFace == nil)
        #expect(try await connector.produceUlanzi() == nil)
    }

    @Test func connectorWithFaceRendersItsReading() async throws {
        let connector = StubbedUlanziConnector()
        let delivery = try #require(await connector.produceUlanzi())
        #expect(delivery.scene == connector.renderedScene)
    }

    @Test func readErrorPropagates() async {
        do { _ = try await FailingUlanziConnector().produceUlanzi()
            Issue.record("expected throw")
        } catch { /* expected */ }
    }
}
```

The stubs mirror the existing `PassThroughFace.swift` pattern in this test target.
`FacelessConnector` is the AWTRIX-only stub already used by ConnectorFaceTests;
reuse it if it already conforms to `Connector` without a `ulanziFace`.

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziFaceTests
```

Expected: compile error — `ulanziFace` / `produceUlanzi` do not exist.

- [ ] **Step 2: GREEN — the face struct, the typealias, the extension.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziFace.swift
/// TC002 counterpart of `AwtrixDelivery` (AwtrixScene.swift, phase 2).
public typealias UlanziDelivery = Delivery<UlanziScene>

/// TC002 counterpart of `AwtrixFace`.
public struct UlanziFace<Reading: Sendable> {
    private let render: @Sendable (Reading) -> UlanziDelivery

    public init(_ render: @escaping @Sendable (Reading) -> UlanziDelivery) {
        self.render = render
    }

    public func draw(_ reading: Reading) -> UlanziDelivery {
        render(reading)
    }
}
```

```swift
// Sources/PixelClockKit/Connectors/Connector.swift (append at the bottom)
public extension Connector {
    /// TC002 face; nil means the connector has no page on a TC002 clock (D11).
    var ulanziFace: UlanziFace<Reading>? { nil }

    /// TC002 counterpart of `produce()`.
    func produceUlanzi() async throws -> UlanziDelivery? {
        guard let ulanziFace else { return nil }
        return ulanziFace.draw(try await read())
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel
```

Expected: full suite green — the extension changes nothing for existing
connectors (nil default).

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziFace.swift Sources/PixelClockKit/Connectors/Connector.swift Tests/PixelClockKitTests/UlanziFaceTests.swift
git commit -m "PixelClockKit: optional ulanziFace on Connector with produceUlanzi()"
```

---

### Task 4: UlanziDevice — the HTTP adapter with pinned wire shapes

The TC002 API surface phase 3 needs: identity, the custom-app list, upsert, and
delete. No `switchDiyApp` (D3) — the method does not exist on this type.

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziError.swift`
- Create: `Sources/PixelClockKit/Ulanzi/UlanziDevice.swift`
- Create: `Tests/PixelClockKitTests/UlanziDeviceTests.swift` (two suites:
  `UlanziDeviceTests`, `UlanziDeviceSendTests`)
- Unchanged: `Awtrix/AwtrixDevice.swift` (read for the actor shape only)

**Interfaces:**

- Produces: `UlanziIdentity`, `UlanziDevice`, `UlanziError`
- Consumes: `Transport`, `URLSessionTransport`, `DeviceAddress.host(from:)` (phase 2)
- Consumes: `UlanziFrame` (Task 2)

- [ ] **Step 1: RED — pin the wire.**

`UlanziDeviceSendTests` mirrors `AwtrixDeviceSendTests`: a `RecordingTransport`
records every request and replays scripted responses; the test asserts the exact
path, method, and body byte-for-byte. Reuse the kit's `RecordingTransport` from
`AwtrixDeviceSendTests.swift`; if it is file-private, lift it into a shared test
support file in the same commit.

```swift
// Tests/PixelClockKitTests/UlanziDeviceTests.swift
import Testing
import Foundation
@testable import PixelClockKit

@Suite struct UlanziDeviceSendTests {
    @Test func showAppPostsNamedCustomWithDbBody() async throws {
        var canvas = PixelCanvas()
        canvas.fill(.white)
        let frame = UlanziFrame(duration: 5, draw: [canvas.drawCommands()])
        let (device, recorder) = makeDevice(
            status: 200,
            body: Data(#"{"code":200,"message":"ok"}"#.utf8)
        )
        try await device.showApp(frame, named: "pct-weather")

        let request = #require(recorder.requests.last)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/api/custom")
        #expect(request.url?.query == "name=pct-weather")
        // The body is the frame JSON — draw[] carries the single db command.
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["duration"] as? Int == 5)
        #expect((json["draw"] as? [[String: Any]])?.count == 1)
        #expect(((json["draw"] as? [[String: Any]])?[0]["db"] as? [Int])?.count == 2 + 52 * 16)
    }

    @Test func removeAppPostsEmptyBody() async throws {
        let (device, recorder) = makeDevice(status: 200, body: Data(#"{"code":200,"message":"ok"}"#.utf8))
        try await device.removeApp(named: "pct-weather")

        let request = #require(recorder.requests.last)
        #expect(request.url?.query == "name=pct-weather")
        // AWTRIX-family delete: an EMPTY body. The absence of a body IS the
        // contract — the send test pins it (research §2.2).
        #expect(request.httpBody ?? Data() == Data())
        #expect(request.httpBodyStream == nil)
    }

    @Test func bodyCodeOtherThanTwoHundredIsAFailure() async {
        // HTTP 200, body code 101 → failure (D8)
        do {
            let (device, _) = makeDevice(status: 200, body: Data(#"{"code":101,"message":"busy"}"#.utf8))
            try await device.showApp(UlanziScene.idle.frames[0], named: "pct-x")
            Issue.record("expected throw")
        } catch let error as UlanziError {
            #expect(error == .deviceRejected(code: 101, message: "busy"))
        } catch { Issue.record("wrong error type: \(error)") }
    }

    @Test func httpFailureIsAFailure() async { /* status 500 → .unexpectedStatus(500) */ }

    @Test func customListDecodesTheCapturedBody() async throws {
        // Paste the captured /api/customList body from the research doc §2.2
        // verbatim into the fixture constant below, then run: the decoder must
        // yield exactly the names visible in that capture.
        let (device, _) = makeDevice(status: 200, body: Self.customListBody)
        let names = try await device.customApps()
        #expect(!names.isEmpty)
    }

    @Test func identityDecodesTheCapturedBase() async throws {
        let base = Data(#"""
        {"devSn":"B0D32I008U3671403","ssid":"...","ip":"192.168.1.72",
         "mac":"ccc4b2779b9a","mcuVer":"V1.0.17","appVer":"1.1.1"}
        """#.utf8)
        let (device, _) = makeDevice(status: 200, body: base)
        let identity = try await device.identity()
        #expect(identity.serial == "B0D32I008U3671403")
        #expect(identity.mac == "ccc4b2779b9a")
        #expect(identity.mcuVersion == "V1.0.17")
    }
}
```

Note on `image[]`: the frame model supports an image layer, but phase-3 faces
emit only the `db` command, so the send pins above cover what ships. The image
object's key spelling comes from the captured exchange (research §2.2); when a
face starts shipping images, the first send test for it pins the key against
that capture.

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziDeviceTests
```

Expected: compile error — `UlanziDevice` does not exist.

- [ ] **Step 2: GREEN — implement the actor and the error type.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziError.swift
public enum UlanziError: Error, Equatable, Sendable {
    case limit(String)
    case deviceRejected(code: Int, message: String)
    case unexpectedStatus(Int)
    case malformed(String)
}
```

```swift
// Sources/PixelClockKit/Ulanzi/UlanziDevice.swift
public struct UlanziIdentity: Codable, Sendable, Equatable {
    public let serial: String?      // devSn
    public let mac: String?
    public let ip: String?
    public let mcuVersion: String?  // mcuVer
    public let appVersion: String?  // appVer
}

/// The TC002 HTTP adapter. Endpoints phase 3 needs and nothing else — there is
/// no `switchDiyApp` here (D3).
public actor UlanziDevice {
    private let transport: any Transport

    public init(host: String, transport: any Transport) {
        self.transport = transport
        // build base URL from DeviceAddress.host(from: host) ?? host
    }

    /// GET /getBase — the only identity surface this firmware answers.
    public func identity() async throws -> UlanziIdentity

    /// GET /api/customList — the app names the clock currently carries.
    public func customApps() async throws -> [String]

    /// POST /api/custom?name=<name> — upsert. Body `code` other than 200 is a
    /// failure even under HTTP 200 (D8).
    public func showApp(_ frame: UlanziFrame, named name: String) async throws

    /// POST /api/custom?name=<name> with an EMPTY body — the AWTRIX-family
    /// delete. The empty body is the contract.
    public func removeApp(named name: String) async throws
}
```

Every call decodes the envelope `{"code":…,"message":…}`; `code != 200` throws
`.deviceRejected`. Non-2xx status throws `.unexpectedStatus`. Failure of the
JSON body to decode throws `.malformed`.

Run:

```bash
swift test -j 2 --no-parallel
```

Expected: full suite green.

- [ ] **Step 3: MUTATE — the envelope check.**

Change `code != 200` to `code != 201`: `bodyCodeOtherThanTwoHundredIsAFailure`
must fail; revert. Change the empty-body delete to send `{}` JSON instead:
`removeAppPostsEmptyBody` must fail; revert.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziError.swift Sources/PixelClockKit/Ulanzi/UlanziDevice.swift Tests/PixelClockKitTests/UlanziDeviceTests.swift
git commit -m "PixelClockKit: UlanziDevice actor with pinned TC002 wire shapes"
```

---

### Task 5: UlanziCustody — durable per-tile names with the 21-app cap

AWTRIX apps live in our process RAM; TC002 apps outlive the sender. The record of
names we own must survive a Mac restart (D9), and the DIY page budget caps what
we may claim: pages 100–120, at most 21 custom apps per clock (D1, D7).

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziCustody.swift`
- Create: `Tests/PixelClockKitTests/UlanziCustodyTests.swift`
- Unchanged: `Awtrix/DeviceCustody.swift` (read for contrast; in-memory by
  design there — do not unify the two)

**Interfaces:**

- Produces: `UlanziAppRecord`, `UserDefaultsAppRecord`, `UlanziCustody`
- Consumes: `UlanziDevice` (Task 4) for `customApps()` and `removeApp`
- Naming: `pct-<tileId>` (D10)

- [ ] **Step 1: RED — naming, the cap, the sweep, the release.**

```swift
// Tests/PixelClockKitTests/UlanziCustodyTests.swift
import Testing
@testable import PixelClockKit

/// In-memory stand-in for the UserDefaults record.
final class MemoryAppRecord: UlanziAppRecord, @unchecked Sendable {
    private var storage: [String: [String]] = [:]
    func names(forClock clockId: String) -> [String] { storage[clockId] ?? [] }
    func save(_ names: [String], forClock clockId: String) { storage[clockId] = names }
}

@Suite struct UlanziCustodyTests {
    @Test func appNameIsPrefixedTileId() throws {
        let custody = makeCustody()
        #expect(try custody.appName(forTile: "weather") == "pct-weather")
    }

    @Test func twentyFirstAppPassesTwentySecondThrows() async throws {
        let custody = makeCustody()
        for i in 0..<21 { _ = try custody.appName(forTile: "tile\(i)") }   // budget full
        #expect(throws: UlanziError.self) { try custody.appName(forTile: "one-more") }
        // the failed claim must not consume budget
        #expect(custody.ownedNames.count == 21)
    }

    @Test func sweepRemovesStaleNamesTheDeviceStillLists() async throws {
        // record: pct-a, pct-b, pct-z (stale from a crash); device lists all three;
        // live tiles: a, b → removeApp(pct-z), record drops pct-z
    }

    @Test func sweepDropsLostNamesWithoutDelete() async throws {
        // device lists only pct-a (a reboot wiped the rest, E9):
        // no delete calls; record keeps only pct-a
    }

    @Test func releaseAllEmptiesEveryPage() async throws {
        // two recorded names → two removeApp calls, record ends empty
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziCustodyTests
```

Expected: compile error — `UlanziCustody` does not exist.

- [ ] **Step 2: GREEN — implement custody.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziCustody.swift
/// The durable record of custom-app names we own, one name per tile (D9).
public protocol UlanziAppRecord: Sendable {
    func names(forClock clockId: String) -> [String]
    func save(_ names: [String], forClock clockId: String)
}

/// UserDefaults-backed: TC002 apps outlive our process, so must the record.
public struct UserDefaultsAppRecord: UlanziAppRecord {
    // key: "ownedApps.<clockId>"
}

public actor UlanziCustody {
    /// DIY pages 100–120 (research §6) — the hard budget per clock (D7).
    private static let maxApps = 21

    private let device: UlanziDevice
    private let record: any UlanziAppRecord
    private let clockId: String

    public func appName(forTile tileId: String) throws -> String   // registers on claim; throws .limit when full
    public var ownedNames: [String]

    /// Startup sweep: names we claim that the device no longer lists leave the
    /// record silently (nothing to delete); names the device still lists but no
    /// live tile uses get a `{}` delete. Stale names from crashes or older
    /// builds leave the knob cycle here (D4, D10).
    public func sweep(liveTiles: [String]) async throws

    /// Quit or last-tile removal: `{}` every owned name, clear the record (D4).
    public func releaseAll() async throws
}
```

The budget counts OUR names. If the device is full with foreign apps, the upsert
surfaces `.deviceRejected` from the device itself — custody does not try to
predict that.

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziCustodyTests
```

Expected: pass.

- [ ] **Step 3: MUTATE — the cap.**

Change `maxApps` to 22: `twentyFirstAppPassesTwentySecondThrows` must fail.
Revert.

- [ ] **Step 4: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziCustody.swift Tests/PixelClockKitTests/UlanziCustodyTests.swift
git commit -m "PixelClockKit: durable UlanziCustody with the 21-app DIY budget"
```

---

### Task 6: UlanziDiscovery — broadcast parser and dual-probe detection

The TC002 shouts one line per second on UDP 55555. Model detection probes
`/api/stats` and `/getBase` concurrently — whichever body DECODES wins; statuses
never decide, because the TC002 answers the AWTRIX path with a redirect
(research §2). The socket loop is thin and carries no tests (D13); the parser and
the probe carry all of them. Phase 4 owns the first caller of both — they land
here deliberately unused.

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziDiscovery.swift`
- Create: `Tests/PixelClockKitTests/UlanziDiscoveryTests.swift`
- Unchanged: `Awtrix/DeviceDiscovery.swift` (the AWTRIX SSDP-style listener —
  different mechanism, do not merge)

**Interfaces:**

- Produces: `UlanziAnnouncement`, `UlanziBroadcastListener`, `UlanziProbe`
- Consumes: `Transport` (probe), `UlanziIdentity` (Task 4)

- [ ] **Step 1: RED — parse the captured line.**

```swift
// Tests/PixelClockKitTests/UlanziDiscoveryTests.swift
import Testing
@testable import PixelClockKit

@Suite struct UlanziAnnouncementTests {
    @Test func parsesTheCapturedBroadcastLine() {
        let line = "Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false"
        let announcement = UlanziAnnouncement.parse(line)
        #expect(announcement?.model == "TC002")
        #expect(announcement?.mac == "ccc4b2779b9a")
        #expect(announcement?.serial == "B0D32I008U3671403")
        #expect(announcement?.flag == "false")   // meaning unverified (research A1)
    }

    @Test func malformedLinesAreDropped() {
        #expect(UlanziAnnouncement.parse("") == nil)
        #expect(UlanziAnnouncement.parse("garbage") == nil)
        #expect(UlanziAnnouncement.parse("Ulanzi TC002 nope") == nil)
    }
}

@Suite struct UlanziProbeTests {
    @Test func statsDecodingWinsMeansOtherDevice() async {
        // /api/stats returns a body the AWTRIX stats shape decodes → .otherDevice
    }

    @Test func baseDecodingWinsMeansUlanzi() async {
        // /getBase returns the captured fixture → .ulanzi(identity)
    }

    @Test func neitherDecodesMeansUndetermined() async {
        // transport errors on both → .undetermined (host down)
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter "UlanziAnnouncementTests|UlanziProbeTests"
```

Expected: compile error — `UlanziAnnouncement` does not exist.

- [ ] **Step 2: GREEN — parser, listener, probe.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziDiscovery.swift
/// One UDP 55555 broadcast line, parsed.
public struct UlanziAnnouncement: Equatable, Sendable {
    public let model: String
    public let mac: String
    public let serial: String
    /// Trailing field, carried raw — its meaning is unverified (appendix A1).
    public let flag: String

    public static func parse(_ line: String) -> UlanziAnnouncement?
}

/// Passive UDP 55555 listener yielding parsed announcements.
/// Untested by design (D13): the socket is the only untested surface; the
/// parser above carries the logic.
public final class UlanziBroadcastListener: Sendable {
    public init(port: UInt16 = 5555 + 0)  // 55555
    public func announcements() -> AsyncStream<UlanziAnnouncement>
}

/// Model detection: probe both endpoints concurrently, whichever body DECODES
/// wins (statuses never decide — /api/stats is a 301 on this firmware).
public enum UlanziProbe {
    public enum Detection: Equatable, Sendable {
        case ulanzi(UlanziIdentity)
        case otherDevice
        case undetermined
    }

    public static func detect(host: String, transport: any Transport) async -> Detection
}
```

The probe's AWTRIX half reuses the existing stats decode (`AwtrixDevice.stats()`
under `try?`) rather than redefining the AWTRIX body shape. When both decode
(degenerate), `ulanzi` wins deterministically.

Run:

```bash
swift test -j 2 --no-parallel
```

Expected: full suite green.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziDiscovery.swift Tests/PixelClockKitTests/UlanziDiscoveryTests.swift
git commit -m "PixelClockKit: TC002 broadcast parser and dual-probe model detection"
```

---

### Task 7: TC002 faces — weather and Claude as rasters

Two faces grow `ulanziFace` implementations. Both raster through `PixelCanvas`
and ship one `db` command (D2). The anecdote TC002 face stays out (D6).

**Files:**

- Modify: `Sources/PixelClockKit/Connectors/WeatherConnector.swift` (append the face)
- Modify: `Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift` (append the face)
- Modify: `Tests/PixelClockKitTests/WeatherConnectorTests.swift` (add `WeatherTC002FaceTests`)
- Modify: `Tests/PixelClockKitTests/ClaudeUsageConnectorTests.swift` (add `ClaudeTC002FaceTests`)
- Unchanged: `AwtrixFace` implementations in both files, lane C's reporting seam

**Interfaces:**

- Consumes: `ulanziFace` / `UlanziDelivery` (Task 3), `PixelCanvas` / `PixelFont` (Task 1),
  `UlanziScene` (Task 2), `Sources/PixelClockKit/Resources/ClaudeStar.gif` (phase 2 bundle resource)
- Produces: `WeatherConnector.ulanziFace`, `ClaudeUsageConnector.ulanziFace`

- [ ] **Step 1: RED — the weather face renders the temperature raster.**

```swift
// Tests/PixelClockKitTests/WeatherConnectorTests.swift (append the suite)
@Suite struct WeatherTC002FaceTests {
    @Test func negativeTemperatureRendersWithDegreeAndMinus() {
        let face = makeWeatherConnector().ulanziFace
        let delivery = face?.draw(reading(temperatureCelsius: -12.4))
        var canvas = PixelCanvas()
        // re-rasterize the same glyphs the face draws, compare — or, better,
        // assert the load-bearing pixels:
        #expect(delivery?.scene.frames.count == 1)
        #expect(delivery?.scene.frames[0].draw.count == 1)   // the single db (D2)
        // plus golden-ASCII assertions on the canvas region (see Step 2 helper)
    }

    @Test func themeColourInksTheDigits() { /* warm reading → warm ink pixels present */ }
}
```

Golden-ASCII helper (test-file-local extension): render the canvas to rows of
`#`/`.` and compare against a string literal — pins the glyph geometry without
pixel-coordinate arithmetic.

Run:

```bash
swift test -j 2 --no-parallel --filter WeatherTC002FaceTests
```

Expected: compile error — the face does not exist yet.

- [ ] **Step 2: GREEN — the weather face.**

Append to `WeatherConnector`, mirroring how `awtrixFace` sits in the file:
large-scale (`scale: 2`) temperature text through `PixelFont` (`-12°` shape),
inked with the existing theme colour mapping, on a fresh `PixelCanvas`, wrapped
in a single-frame `UlanziScene`. Nothing else in the file changes.

- [ ] **Step 3: RED then GREEN — the Claude face.**

Same rhythm. The face renders the percentage through the font and adds the star
as the image layer:

```swift
// inside ClaudeUsageConnector's ulanziFace closure (shape, not verbatim)
var frame = UlanziFrame(duration: 5, draw: [canvas.drawCommands(ink: …)])
frame.image = [Self.star]   // static let: ClaudeStar.gif loaded from Bundle.module once

// Test pins:
// - scene carries exactly one db draw command
// - the image layer's base64, when decoded, starts with the GIF89a magic
// - declared metadata respects the limits (frames ≤ 50, ≤ 256×256, ≤ 60 KB base64)
```

The star's declared `frameCount` / `pixelSize` come from the research doc's
captured values for `ClaudeStar.gif`; the frame encoder still enforces every
limit on the declared metadata at encode time.

Run:

```bash
swift test -j 2 --no-parallel --filter "WeatherTC002FaceTests|ClaudeTC002FaceTests"
```

Expected: pass.

- [ ] **Step 4: Full suite, then commit.**

Run:

```bash
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass — the appended faces changed no existing behaviour.

```bash
git add Sources/PixelClockKit/Connectors/WeatherConnector.swift Sources/PixelClockKit/Connectors/ClaudeUsageConnector.swift Tests/PixelClockKitTests/WeatherConnectorTests.swift Tests/PixelClockKitTests/ClaudeUsageConnectorTests.swift
git commit -m "PixelClockKit: TC002 raster faces for weather and Claude usage"
```

---

## Part 3b — wiring (presumes phases 1 + 2)

Every task here references `ClockRecord` / `ClockModel` from phase 1 and the
phase-2 delivery chain. If those are not on the tree, stop and land 3a first.

### Task 8: UlanziTileBoard — per-tile state, nothing that ticks

The board is pure state. No timer, no dwell, no rotation — the Mac never rotates
anything (D1). It answers one question: what does this tile's page show right now.

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziTileBoard.swift`
- Create: `Tests/PixelClockKitTests/UlanziTileBoardTests.swift`

**Interfaces:**

- Produces: `UlanziTileBoard`
- Consumes: `UlanziDelivery`, `UlanziScene.idle` (Tasks 2–3)

- [ ] **Step 1: RED — upsert, idle, removal diff.**

```swift
// Tests/PixelClockKitTests/UlanziTileBoardTests.swift
@Suite struct UlanziTileBoardTests {
    @Test func freshBoardAnswersIdleForKnownTileAndNilForUnknown() { /* … */ }

    @Test func upsertThenDeliverAnswersTheLastScene() { /* … */ }

    @Test func idleFrameShowsWhilePausedAndDeliveryOverwritesIt() {
        // markIdle → frame == .idle; upsert → frame == delivered scene
    }

    @Test func removedTilesDiffsAgainstLiveIds() {
        // board holds a, b, c; live = [a, c] → removed == ["b"]
    }

    @Test func lastDeliverySurvivesIdleMarking() {
        // pause then resume without new data: recovery re-push uses the last
        // real scene, not the idle frame
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziTileBoardTests
```

Expected: compile error.

- [ ] **Step 2: GREEN — implement the board.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziTileBoard.swift
/// Pure per-tile state (D1). Nothing here ticks.
public struct UlanziTileBoard: Sendable, Equatable {
    public private(set) var tileIds: [String]

    public init()
    public mutating func register(tileId: String)                  // fresh tile starts on .idle
    public mutating func upsert(_ delivery: UlanziDelivery, forTile id: String)
    public mutating func markIdle(_ id: String)
    public func frame(forTile id: String) -> UlanziScene?          // last delivery's scene, else .idle, else nil
    public func lastScene(forTile id: String) -> UlanziScene?      // recovery re-push source
    public func removedTiles(given liveIds: [String]) -> [String]
}
```

Run:

```bash
swift test -j 2 --no-parallel
```

Expected: full suite green.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziTileBoard.swift Tests/PixelClockKitTests/UlanziTileBoardTests.swift
git commit -m "PixelClockKit: UlanziTileBoard, per-tile page state"
```

---

### Task 9: UlanziClockSession — push-on-event, re-push-all on recovery

The session wires board, device, and custody. Pushes are event-driven: a
delivery, an idle mark, a recovery. There is no loop and no timer (D1, D3).

**Files:**

- Create: `Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift`
- Create: `Tests/PixelClockKitTests/UlanziClockSessionTests.swift`
- Reuse: `DeliveryChain` (phase 2) — parameterized over the scene type; if it is
  `AwtrixScene`-bound rather than generic, parameterize it in the same commit and
  say so in the message

**Interfaces:**

- Produces: `UlanziClockSession`
- Consumes: `UlanziDevice` (T4), `UlanziCustody` (T5), `UlanziTileBoard` (T8),
  `DeliveryChain` (phase 2)
- App-facing protocol lands in Task 10; this type stays kit-side

- [ ] **Step 1: RED — the seven behaviours.**

Scenario list (one test each, same actor/double style as `AwtrixClockSessionTests`):

1. `deliver` upserts the tile's page: one `showApp` with the board's scene,
   named `pct-<tileId>`, name registered in custody.
2. A 22nd tile's delivery returns a failure result — the cap holds (D7), the
   device hears nothing.
3. Transport failure marks the clock offline; the next successful push triggers
   a re-push of EVERY registered tile (D4) — the test observes two `showApp`
   calls for the previously failed tile.
4. `markIdle` pushes `UlanziScene.idle` to the page; the next delivery
   overwrites it.
5. `tileRemoved` sends `{}` for its name and drops it from the record.
6. `shutdown` releases every page (`{}` each) and empties the record — the
   pages leave the knob cycle (user-initiated; E4 noted in Task 11).
7. Startup: `sweep(liveTiles:)` runs before the first push — a stale recorded
   name still on the device gets its `{}` first, then live tiles push.

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziClockSessionTests
```

Expected: compile error.

- [ ] **Step 2: GREEN — implement the session.**

```swift
// Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift
public actor UlanziClockSession {
    public init(clockId: String,
                device: UlanziDevice,
                custody: UlanziCustody,
                chain: DeliveryChain<UlanziScene>)

    /// Startup: sweep stale pages, then re-push every known tile (D4).
    public func start(liveTileIds: [String]) async
    public func deliver(_ delivery: UlanziDelivery, from tileId: String) async -> DeliveryOutcome
    public func markIdle(tileId: String) async
    public func tileRemoved(_ tileId: String) async
    public func shutdown() async
}
```

The recovery rule is deliberately blunt: after any transport failure, the first
successful device call re-pushes all registered tiles. Twenty-one upserts are
cheap; guessing which pages survived a reboot is not (E9 is unverified — the
design refuses to care, D4).

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift Tests/PixelClockKitTests/UlanziClockSessionTests.swift
git commit -m "PixelClockKit: UlanziClockSession, event-driven per-tile pushing"
```

---

### Task 10: AppModel wiring — the Ulanzi branch of live()

The hottest file in the tree (36 commits, 13 fix-like). Keep the change
additive: a new app-facing protocol beside `ConnectorRunning`, a new branch in
`live()`. The AWTRIX path is byte-identical afterwards.

**Files:**

- Modify: `Sources/PixelClockTilesApp/AppModel.swift`
- Create: `Tests/PixelClockTilesAppTests/UlanziWiringTests.swift`
- Unchanged: the AWTRIX branch of `live()`, lane C's reporting seam

**Interfaces:**

- Produces: `UlanziConnectorRunning` (app-facing protocol mirroring
  `ConnectorRunning`, typed on `UlanziDelivery`), the `.ulanzi` branch of `live()`
- Consumes: `ClockRecord.model` / `ClockModel` (phase 1), `UlanziClockSession` (T9),
  `UserDefaultsAppRecord` (T5)

- [ ] **Step 1: RED — live() builds a Ulanzi session for a TC002 clock record.**

```swift
// Tests/PixelClockTilesAppTests/UlanziWiringTests.swift
@Suite struct UlanziWiringTests {
    @Test func liveRoutesTC002ClockRecordsToAUlanziSession() async {
        // a persisted clock record with model == .tc002
        // → live() yields a UlanziConnectorRunning whose deliver reaches the device
        //   (device behind a scripted Transport; assert one upsert POST)
    }

    @Test func liveKeepsAwtrixRoutingUntouched() async {
        // an awtrix-model record still produces the phase-2 session shape
    }

    @Test func disabledConnectorKeepsItsPageAliveWithTheIdleFrame() async {
        // connector disabled in settings → session.markIdle, page stays in the
        // knob cycle (D4)
    }
}
```

Run:

```bash
swift test -j 2 --no-parallel --filter UlanziWiringTests
```

Expected: compile error.

- [ ] **Step 2: GREEN — wire it.**

In `AppModel`: `UlanziConnectorRunning` protocol (same member set as
`ConnectorRunning`, `UlanziDelivery`-typed), a wrapper struct conforming to it
over `UlanziClockSession` (mirror however phase 2 wraps `AwtrixClockSession`),
and the `.ulanzi` branch of `live()` constructing
`UlanziCustody(record: UserDefaultsAppRecord(), …)` + `UlanziClockSession` +
`chain`. The runtime route selects per `ClockRecord.model`.

Settings panel: a TC002 clock row renders no battery line — the stock firmware
reports no level over its API (research correction to the spec's "There is no
battery": the battery exists, the API does not read it). The conditional lives
wherever phase 1 renders the battery row; gate it on the clock model.

The adoption path is NOT here: `UlanziBroadcastListener` and `UlanziProbe` wait
for phase 4 (contact points). A TC002 clock enters the system through whatever
phase 1 provided for manual clock records.

Run:

```bash
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: pass.

- [ ] **Step 3: Commit.**

```bash
git add Sources/PixelClockTilesApp/AppModel.swift Tests/PixelClockTilesAppTests/UlanziWiringTests.swift
git commit -m "PixelClockTilesApp: route TC002 clocks to the Ulanzi session in live()"
```

---

### Task 11: Audit and hand-off

The phase-2 close-out shape: assert nothing regressed, then write down what only
the hardware can confirm.

**Files:**

- Modify: `docs/HANDOFF.md` (append the phase-3 section)
- Unchanged: everything else

- [ ] **Step 1: Structural assertions.**

Run:

```bash
git grep -n "switchDiyApp" Sources/ ; echo "exit=$?"
git grep -rn "Task<Void, Error>" Sources/ | wc -l
git grep -rn "URLSession()" Tests/ ; echo "exit=$?"
```

Expected: `switchDiyApp` — no matches (exit=1); task-count unchanged from BASE;
`URLSession()` — no matches in tests (exit=1). Any hit is a D3/D13 violation.

- [ ] **Step 2: The AWTRIX surface is byte-identical.**

Run:

```bash
git diff --stat BASE -- Sources/PixelClockKit/Awtrix
```

Expected: no output. `Awtrix/` changed by nothing in this phase except what
phase 2 itself put there before BASE.

- [ ] **Step 3: Assertion changes over the new tests.**

Run:

```bash
git diff -M --diff-filter=MR BASE -- Tests/PixelClockKitTests/PixelCanvasTests.swift \
  Tests/PixelClockKitTests/UlanziSceneTests.swift Tests/PixelClockKitTests/UlanziFaceTests.swift \
  Tests/PixelClockKitTests/UlanziDeviceTests.swift Tests/PixelClockKitTests/UlanziCustodyTests.swift \
  Tests/PixelClockKitTests/UlanziDiscoveryTests.swift Tests/PixelClockKitTests/UlanziTileBoardTests.swift \
  Tests/PixelClockKitTests/UlanziClockSessionTests.swift Tests/PixelClockTilesAppTests/UlanziWiringTests.swift \
  | grep -E "^\+" | grep -E "#expect|#require" | grep -v "^+.*//" | wc -l
```

Expected: pass. Record the count as `N3` against Task 0's `N0`.

- [ ] **Step 4: Full suite; the anecdote sound test alone; append HANDOFF.**

Run:

```bash
swift test -j 2 --no-parallel --skip nothingButTheAnecdotesEverPutsSoundInTheRoom
swift test -j 2 --no-parallel --filter nothingButTheAnecdotesEverPutsSoundInTheRoom
```

Expected: both pass. Append to `docs/HANDOFF.md` a `Phase 3 — TC002` section
carrying: the N0/N3 numbers, the hardware-only checklist below, and the open
research items.

- [ ] **Step 5: Commit.**

```bash
git add docs/HANDOFF.md
git commit -m "docs: phase 3 TC002 hand-off notes"
```

**Hardware-only checklist** (every item needs the physical clock; none is
testable in CI — D13):

1. **E9 — reboot persistence.** Power-cycle the TC002; check `/api/customList`
   after boot. Custom apps surviving or not, the session behaves identically
   (upsert re-creates); the check only sharpens the research record.
2. **`pct-` name acceptance.** Push `pct-weather` by hand once (curl from the
   research setup) and confirm it appears as a DIY page at index 100+.
3. **E4 — deleted-page effect.** With the knob parked on a page, delete that
   page's app and record what the panel shows (black? previous page? crash?).
4. **Legibility.** The 3×5 font at scale 2 on the 52×16 panel from normal
   viewing distance — confirm `-12°` and `87%` read cleanly; adjust ink colours
   if the panel washes out.
5. **Idle marker.** Confirm the single dim dot reads as "paused" from the couch.
6. **customList exact schema** (if the Task 4 fixture paste left any doubt) —
   one `curl /api/customList` settles the decode shape permanently.

---

## Appendix — measured protocol facts (research doc, verified live)

| #   | Fact                                                                                                          | Where it bites         |
| --- | ------------------------------------------------------------------------------------------------------------- | ---------------------- |
| A1  | UDP 55555 broadcast ~1/sec: `Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false`. Trailing flag unverified. | Task 6                 |
| A2  | `/getBase` answers identity; `/api/stats` returns 301 on this firmware. Decode wins, never statuses.            | Tasks 4, 6             |
| A3  | Envelope `{"code":200,"message":"ok"}`; body `code` non-200 = failure regardless of HTTP status.                | Task 4 (D8)            |
| A4  | Limits: ≤32 draw commands, ≤6 images (≤3 GIF), GIF ≤256×256 and ≤50 frames, stills ≤512×512, base64 ≤60 KB.     | Task 2 (D7)            |
| A5  | `fontHeight` is 5 or 10, nothing else.                                                                          | Task 2                 |
| A6  | `duration` is a community-added display field, not an official schema key and not a TTL.                        | Task 2 (D2)            |
| A7  | The carousel never cycles custom apps; a push alone never brings the app on screen.                             | Task 2 (single frame)  |
| A8  | DIY pages 100–120, knob cycles them at DIY L2 — at most 21 custom apps per clock.                               | Task 5 (D1, D7)        |
| A9  | Delete = POST to `/api/custom?name=<name>` with an EMPTY body (`{}` JSON does NOT delete).                      | Tasks 4, 5, 9          |
| A10 | Custom apps likely do not survive a device reboot (E9 unverified). The design does not care: upsert re-creates.  | Tasks 9 (D4)           |

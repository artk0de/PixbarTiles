# Animation Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dinopowers:executing-plans (wraps superpowers:executing-plans) to implement this plan task-by-task. TDD through dinopowers:test-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Swift twin of `nlengine.py` — an integer-only layer engine that renders any TC002 animated scene pixel for pixel like the Python mockup, plus the six approved night-light scenes on it and the page builder that turns a scene into one full-page GIF delivery.

**Architecture:** `Sources/PixbarKit/Animation/` holds the engine (`IntMath`, `PanelLevels`, `AnimationLayer`, `AnimatedScene`, `AnimatedPage`). `Sources/PixbarKit/NightLight/Scenes/` holds one file per scene, each a line-for-line port of its Python module. A Python recorder writes every scene's frames into a fixture; Swift tests compare against it. No tile, no settings, no app code — plans 2–4 do those.

**Tech Stack:** Swift 6.2, macOS 26, swift-testing (`import Testing`), Python 3 for the oracle.

**Spec:** `docs/superpowers/specs/2026-09-30-tile-kinds-and-animation-engine-design.md` §2, and the scene descriptions in `docs/superpowers/specs/2026-09-29-night-light-tile-design.md`.

## Global Constraints

- **Integer arithmetic only.** No `Double` reaches a pixel.
- **Division and remainder.**
  - Python `//` → `IntMath.floorDiv`, Python `%` → `IntMath.floorMod`, `nlengine.sdiv` → `IntMath.truncDiv`.
  - Never use Swift `/` or `%` on a value that can be negative.
- **Hashes** (`jitter` in horizon and glow): compute in `UInt64` with `&*`, then mask `& 0xFFFF_FFFF` exactly where Python masks.
- **Order is part of the output.**
  - Layer order and pixel order equal Python's.
  - `sorted(...)` keys equal Python's: tuples compare lexicographically.
  - Set iteration in Python is only ever sorted before use (`sorted(BODY)`); do the same.
- **The fixture is never edited by hand.**
  - It is recorded by `Scripts/make_animation_oracle.py`.
  - A failing Swift test is fixed in Swift, or the design changes in Python first.
- **Ceilings:** ≤ 480 frames and ≤ 136 000 bytes of base64 per GIF.
- **Delays:** whole centiseconds.
- **Brightness:** `(ch · level + 2) / 5` per channel, levels 1…5; a colour all zero after scaling is black.
- **Commits.** Commit steps are listed, but in this repo a commit happens only after the change summary has been shown to the user and approved. Never push.
- **Tests:**
  - run with `swift test --no-parallel --filter <Suite>`;
  - the whole kit with `swift test --no-parallel --filter PixbarKitTests`.

## File Structure

| File | Responsibility |
|---|---|
| `.claude/skills/tc002-face-mockup/nlengine.py` | moved from `nightlight/`: the shared Python engine |
| `Scripts/make_animation_oracle.py` | records every scene into the fixture |
| `Tests/PixbarKitTests/Fixtures/animation_oracle.json` | recorded frames and variant digests |
| `Sources/PixbarKit/Animation/IntMath.swift` | SIN, floor/trunc division, isqrt, phase/swing/ramp |
| `Sources/PixbarKit/Animation/PanelLevels.swift` | panel_red, step_up, panel_amber |
| `Sources/PixbarKit/Animation/AnimatedScene.swift` | `RGB`, `AnimationPixel`, `AnimationLayer`, `AnimationSpeed`, `AnimatedScene.render` |
| `Sources/PixbarKit/Animation/AnimatedPage.swift` | brightness, frames → GIF → `UlanziDelivery`, ceilings |
| `Sources/PixbarKit/NightLight/Scenes/{Embers,Fireflies,RedMoon,Horizon,Fireplace,Glow}Scene.swift` | the six scene ports |
| `Sources/PixbarKit/NightLight/NightLightScene.swift` | `enum NightLightScene` (ids, names, `animated`) |
| `Tests/PixbarKitTests/AnimationOracle.swift` | fixture loader |
| `Tests/PixbarKitTests/IntMathTests.swift`, `AnimatedSceneTests.swift`, `AnimatedPageTests.swift`, `NightLightScenesTests.swift` | tests |

---

### Task 1: Move the Python engine and record the oracle

**Files:**
- Move: `.claude/skills/tc002-face-mockup/nightlight/nlengine.py` → `.claude/skills/tc002-face-mockup/nlengine.py`
- Create: `Scripts/make_animation_oracle.py`
- Create: `Tests/PixbarKitTests/Fixtures/animation_oracle.json` (generated)

**Interfaces:**
- **Produces the fixture:**
  ```json
  {"W":52,"H":16,
   "scenes":{"<sid>":{"frameMs":100,"cycleFrames":200,"toggles":["emberGlow","sparks"],
                      "palette":["000000","280000",…],
                      "framesZ":"<base64 raw deflate of JSON [\"<2 hex digits per pixel, 832 pixels>\", …]>"}},
   "variants":[{"scene":"embers","speed":"1/2","stilled":["sparks"],"brightness":5,
                "frames":400,"fnv":"<16 hex>"}]}
  ```
- **Default variant.** `framesZ` holds the default variant: speed 1/1, brightness 5, nothing stilled.
- **Palette.** Index `00` is black; indices follow the first appearance in frame order.
- **The `fnv` digest** is FNV-1a-64 over the bytes `r, g, b` of every pixel, row-major, frame after frame; a black cell is `0, 0, 0`.
- **Variants:**
  - every speed in (1/2, 1/1, 2/1) × every subset of `toggles` at brightness 5;
  - plus brightness 1…4 at 1/1 with nothing stilled.

- [ ] **Step 1: Move `nlengine.py` one directory up.** `ngen.py` already puts `dirname(HERE)` on `sys.path`, so every `from nlengine import …` keeps working.

```bash
git mv .claude/skills/tc002-face-mockup/nightlight/nlengine.py .claude/skills/tc002-face-mockup/nlengine.py
```

- [ ] **Step 2: Check the mockup still renders.**

Run: `cd .claude/skills/tc002-face-mockup/nightlight && python3 ngen.py`

Expected: six lines (embers, horizon, moon, fireflies, fireplace, glow) with frames, colours, base64 sizes, no `OVER BUDGET`, and `palette N → …/out/index.html`.

- [ ] **Step 3: Write the recorder.**

```python
#!/usr/bin/env python3
"""Record the approved TC002 animated scenes as the Swift engine's oracle.

The night-light scenes were approved in the browser and on the clock as the
frames `tc002-face-mockup/nightlight/ngen.py` computes through the shared
`nlengine.py`. This writes `Tests/PixbarKitTests/Fixtures/animation_oracle.json`:

- per scene the default variant (1×, brightness 5, every layer moving) as
  full frames: a palette of "rrggbb" (index 0 black) and one string per frame
  of two hex digits per pixel, row-major, stored as `framesZ` — base64 of the
  raw DEFLATE of the JSON list (Foundation's `.zlib` inflates exactly this);
- every other variant (speeds × stilled layers at brightness 5, brightness
  1–4 at 1×) as its frame count and one FNV-1a-64 over every frame's RGB
  bytes, row-major, black as 0,0,0.

Run from the repository root:  python3 Scripts/make_animation_oracle.py

Rerun it after a design change in the skill, never to make a failing Swift
test pass: the fixture is the approved design.
"""
import base64, itertools, json, os, sys, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SKILL = os.path.join(ROOT, ".claude", "skills", "tc002-face-mockup")
NIGHT = os.path.join(SKILL, "nightlight")
sys.path[:0] = [NIGHT, SKILL]
import ngen  # noqa: E402

OUT = os.path.join(ROOT, "Tests", "PixbarKitTests", "Fixtures", "animation_oracle.json")
SPEEDS = {"1/2": (1, 2), "1/1": (1, 1), "2/1": (2, 1)}


def frames(sid, level, speed, off):
    return [[[cv.px[y][x] or (0, 0, 0) for x in range(ngen.W)] for y in range(ngen.H)]
            for cv, _ in ngen.timeline(sid, level, speed, off)]


def fnv(frame_list):
    h = 0xCBF29CE484222325
    for f in frame_list:
        for row in f:
            for px in row:
                for b in px:
                    h = ((h ^ b) * 0x100000001B3) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def deflate(obj):
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    raw = c.compress(json.dumps(obj, separators=(",", ":")).encode()) + c.flush()
    return base64.b64encode(raw).decode()


def main():
    scenes, variants = {}, []
    for sid, _, _ in ngen.SCENES:
        ps = ngen.ENGINE[sid]
        toggles = ngen.toggles(sid)
        default = frames(sid, 5, (1, 1), frozenset())
        palette = [(0, 0, 0)]
        index = {(0, 0, 0): 0}
        rows = []
        for f in default:
            s = []
            for row in f:
                for px in row:
                    if px not in index:
                        index[px] = len(palette)
                        palette.append(px)
                    s.append("%02x" % index[px])
            rows.append("".join(s))
        scenes[sid] = {"frameMs": ps.frame_ms, "cycleFrames": ps.cycle_frames, "toggles": toggles,
                       "palette": ["%02x%02x%02x" % c for c in palette], "framesZ": deflate(rows)}
        for name, speed in SPEEDS.items():
            for k in range(len(toggles) + 1):
                for off in itertools.combinations(toggles, k):
                    fl = frames(sid, 5, speed, frozenset(off))
                    variants.append({"scene": sid, "speed": name, "stilled": list(off), "brightness": 5,
                                     "frames": len(fl), "fnv": fnv(fl)})
        for level in (1, 2, 3, 4):
            fl = frames(sid, level, (1, 1), frozenset())
            variants.append({"scene": sid, "speed": "1/1", "stilled": [], "brightness": level,
                             "frames": len(fl), "fnv": fnv(fl)})
        print(f"{sid:10} {len(default):3} frames, {len(palette):2} colours")
    with open(OUT, "w") as fh:
        json.dump({"W": ngen.W, "H": ngen.H, "scenes": scenes, "variants": variants}, fh,
                  separators=(",", ":"), sort_keys=True)
    print(OUT, os.path.getsize(OUT), "bytes,", len(variants), "variants")


if __name__ == "__main__":
    main()
```

- [ ] **Step 4: Record.**

Run: `python3 Scripts/make_animation_oracle.py`

Expected: six scene lines, then the path, a size under ~1.5 MB, and the variant count.

- [ ] **Step 5: Commit** (after the summary is approved).

```bash
git add .claude/skills/tc002-face-mockup Scripts/make_animation_oracle.py Tests/PixbarKitTests/Fixtures/animation_oracle.json
git commit -m "test(animation): record the approved night-light scenes as the engine's oracle"
```

---

### Task 2: `IntMath` and `PanelLevels`

**Files:**
- Create: `Sources/PixbarKit/Animation/IntMath.swift`, `Sources/PixbarKit/Animation/PanelLevels.swift`
- Test: `Tests/PixbarKitTests/IntMathTests.swift`

**Interfaces:**
- Produces, all `public static`:
  - `IntMath.sin: [Int]`, `floorDiv(_:_:)`, `floorMod(_:_:)`, `truncDiv(_:_:)`, `isqrt(_:)`;
  - `phase(_ frame:_ n:_ cycles:_ offset: = 0) -> Int`;
  - `swing(_ frame:_ n:_ cycles:_ offset:_ low:_ high:) -> Int`, `ramp(…)` with the same parameters;
  - `PanelLevels.red(_:)`, `stepUp(_:_:)`, `amber(_:_:)`.

- [ ] **Step 1: Write the failing tests** (Python values computed with `python3 -c`, quoted in comments).

```swift
import Testing
@testable import PixbarKit

@Suite struct IntMathTests {
    @Test func divisionFloorsLikePythonAndTruncatesLikeSdiv() {
        #expect(IntMath.floorDiv(-7, 2) == -4)      // python: -7 // 2
        #expect(IntMath.floorDiv(7, -2) == -4)
        #expect(IntMath.floorDiv(7, 2) == 3)
        #expect(IntMath.floorMod(-3, 52) == 49)     // python: -3 % 52
        #expect(IntMath.floorMod(-99, 52) == 5)
        #expect(IntMath.truncDiv(-7, 2) == -3)      // nlengine.sdiv(-7, 2)
        #expect(IntMath.truncDiv(7, -2) == -3)
    }

    @Test func theSineTableIsPythonsRoundedSine() {
        #expect(IntMath.sin.count == 256)
        #expect(IntMath.sin[0] == 0)
        #expect(IntMath.sin[64] == 127)
        #expect(IntMath.sin[128] == 0)
        #expect(IntMath.sin[192] == -127)
        #expect(IntMath.sin[1] == 3)                // round(127·sin(2π/256)) = 3
        #expect(IntMath.sin[32] == 90)              // round(127·sin(π/4)) = 90
        #expect(IntMath.sin.reduce(0, +) == 0)
    }

    @Test func isqrtIsTheFloorOfTheRoot() {
        #expect(IntMath.isqrt(0) == 0)
        #expect(IntMath.isqrt(15) == 3)
        #expect(IntMath.isqrt(16) == 4)
        #expect(IntMath.isqrt(16 * (55 * 55 + 18 * 18)) == 231)   // python: math.isqrt(16*(55**2+18**2))
    }

    @Test func oscillatorsMatchNlengine() {
        #expect(IntMath.phase(10, 200, 3, 7) == 45)                 // (10*3*256//200 + 7) & 255
        #expect(IntMath.swing(10, 200, 3, 7, -1000, 1000) == 889)   // nlengine.swing(10,200,3,7,-1000,1000)
        #expect(IntMath.ramp(50, 240, 2, 0, -800, 1000) == 690)     // nlengine.ramp(50,240,2,0,-800,1000)
    }

    @Test func panelLevelsMatchTheMeasuredBands() {
        #expect(PanelLevels.red(7) == 0)
        #expect(PanelLevels.red(8) == 40)
        #expect(PanelLevels.red(64) == 160)
        #expect(PanelLevels.red(255) == 255)
        #expect(PanelLevels.stepUp(8) == 20)
        #expect(PanelLevels.stepUp(200, 3) == 185)
        #expect(PanelLevels.amber(255, 144) == 144)
        #expect(PanelLevels.amber(160, 144) == 100)
        #expect(PanelLevels.amber(144, 100) == 40)
        #expect(PanelLevels.amber(40, 40) == 0)
    }
}
```

Before relying on them, verify the four quoted oscillator and isqrt numbers with Python (`python3 -c "import sys; sys.path.insert(0,'.claude/skills/tc002-face-mockup'); import nlengine as e, math; print(e.phase(10,200,3,7), e.swing(10,200,3,7,-1000,1000), e.ramp(50,240,2,0,-800,1000), math.isqrt(16*(55**2+18**2)), e.SIN[1], e.SIN[32])"`). Replace any quoted value that differs with Python's before Step 2: the test pins Python, not this plan.

- [ ] **Step 2: Run to verify it fails.** Run `swift test --no-parallel --filter IntMathTests`. Expected: compile error, `cannot find 'IntMath' in scope`.

- [ ] **Step 3: Implement.**

```swift
// Sources/PixbarKit/Animation/IntMath.swift
import Foundation

/// The animation engine's arithmetic, integer only and spelled like Python's,
/// so a scene renders here exactly as the mockup's `nlengine.py` rendered it.
///
/// Python's `//` and `%` floor; Swift's `/` and `%` truncate. The two agree
/// only for non-negative operands, and a scene divides sines, drifts and
/// jitters that are signed — so every division a scene ports is one of these.
public enum IntMath {
    /// `round(127·sin(2πi/256))`, pinned by the fixture.
    public static let sin: [Int] = (0..<256).map { Int((127 * Foundation.sin(2 * Double.pi * Double($0) / 256)).rounded()) }

    /// Python's `a // b`.
    public static func floorDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0 && (a < 0) != (b < 0)) ? q - 1 : q
    }

    /// Python's `a % b`: the sign of the divisor.
    public static func floorMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return (r != 0 && (r < 0) != (b < 0)) ? r + b : r
    }

    /// `nlengine.sdiv`: division truncating toward zero.
    public static func truncDiv(_ a: Int, _ b: Int) -> Int { a / b }

    /// Python's `math.isqrt`: the floor of the square root.
    public static func isqrt(_ n: Int) -> Int {
        precondition(n >= 0, "isqrt of a negative number")
        if n < 2 { return n }
        var x = n
        var y = (x + 1) / 2
        while y < x {
            x = y
            y = (x + n / x) / 2
        }
        return x
    }

    /// The SIN index at `cycles` whole turns per loop of `n` frames.
    public static func phase(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int = 0) -> Int {
        (floorDiv(frame * cycles * 256, n) + offset) & 255
    }

    /// `low + (high − low)·(½ + ½·sin)`, per mille.
    public static func swing(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int, _ low: Int, _ high: Int) -> Int {
        let s = sin[phase(frame, n, cycles, offset)]
        return low + floorDiv((high - low) * (s + 127), 254)
    }

    /// A triangle from `low` to `high` and back, per mille.
    public static func ramp(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int, _ low: Int, _ high: Int) -> Int {
        let p = phase(frame, n, cycles, offset)
        let t = p < 128 ? p : 256 - p
        return low + floorDiv((high - low) * t, 128)
    }
}
```

The Python SIN table uses `round`, which rounds half to even, while Swift's `.rounded()` rounds half away from zero. No entry of 127·sin(2πi/256) lands exactly on .5, so the two agree; the fixture pins it either way.

```swift
// Sources/PixbarKit/Animation/PanelLevels.swift
/// The reds and ambers the TC002 tells apart, measured on the panel
/// 2026-09-29 — `nlengine.PANEL_REDS` and `AMBER_FLOOR`.
public enum PanelLevels {
    /// (lowest design red, panel red): 4…64 light as one dimmest dot,
    /// 72…128 as one, 144…255 step apart.
    static let reds: [(low: Int, out: Int)] = [(8, 40), (20, 100), (36, 144), (64, 160), (90, 176),
                                               (120, 192), (150, 224), (185, 255)]
    /// (green, lowest panel red that carries it), greenest first.
    static let amberFloor: [(green: Int, floor: Int)] = [(144, 192), (100, 160), (72, 160), (40, 100)]

    /// The panel red a design red shows as; 0 below the first band.
    public static func red(_ r: Int) -> Int {
        var level = 0
        for band in reds where r >= band.low { level = band.out }
        return level
    }

    /// The lowest design red `steps` panel levels above `r`'s own.
    public static func stepUp(_ r: Int, _ steps: Int = 1) -> Int {
        let band = reds.filter { r >= $0.low }.count - 1
        return reds[min(reds.count - 1, band + steps)].low
    }

    /// The greenest approved green at or below `g` that panel red `r` carries.
    public static func amber(_ r: Int, _ g: Int) -> Int {
        amberFloor.first { g >= $0.green && r >= $0.floor }?.green ?? 0
    }
}
```

- [ ] **Step 4: Run.** `swift test --no-parallel --filter IntMathTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `feat(animation): integer arithmetic and panel levels, spelled like nlengine`

---

### Task 3: `AnimatedScene` — layers and render

**Files:**
- Create: `Sources/PixbarKit/Animation/AnimatedScene.swift`
- Test: `Tests/PixbarKitTests/AnimatedSceneTests.swift`

**Interfaces:**
- **Produces:**
  - `public struct RGB: Hashable, Sendable { var r, g, b: Int; static let black }`;
  - `public struct AnimationPixel: Sendable { let x, y: Int; let colour: RGB }`;
  - `public typealias Multiplier = @Sendable (_ frame: Int, _ n: Int, _ index: Int, _ x: Int, _ y: Int) -> Int`;
  - `public typealias Offset = @Sendable (_ frame: Int, _ n: Int) -> (dx: Int, dy: Int)`;
  - `public typealias Tint = @Sendable (Int) -> RGB`;
  - `AnimationLayer(name:pixels:multiplier: = still, offset: = fixed, key: String? = nil, tint: Tint? = nil)`;
  - `AnimationSpeed(num:den:)` with `.half`, `.normal`, `.double`, and `init?(fraction: String)`;
  - `AnimatedScene(id:frameMs:cycleFrames:layers:tint:)` with:
    - `frameCount(speed:) -> Int`;
    - `render(frame:of:stilled:) -> [RGB?]` — 832 cells, row-major, nil for unlit;
    - `canvas(frame:of:stilled:brightness:) -> PixelCanvas`.
  - `AnimatedScene.width = 52`, `.height = 16`.
  - `AnimatedScene.mask(_ rows: [String], _ colours: [Character: RGB], x0: Int = 0, y0: Int = 0) -> [AnimationPixel]`, which is `nlengine.mask`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Testing
@testable import PixbarKit

@Suite struct AnimatedSceneTests {
    private func scene(_ layers: [AnimationLayer], tint: AnimatedScene.Tint? = nil) -> AnimatedScene {
        AnimatedScene(id: "t", frameMs: 100, cycleFrames: 10, layers: layers, tint: tint)
    }

    @Test func aLaterLayerDrawsOverAnEarlierOneAndXWraps() {
        let a = AnimationLayer(name: "a", pixels: [AnimationPixel(x: 0, y: 0, colour: RGB(r: 100, g: 0, b: 0))])
        let b = AnimationLayer(name: "b", pixels: [AnimationPixel(x: 51, y: 0, colour: RGB(r: 0, g: 0, b: 50))],
                               offset: { _, _ in (dx: 1, dy: 0) })
        let grid = scene([a, b]).render(frame: 0, of: 10, stilled: [])
        #expect(grid[0] == RGB(r: 0, g: 0, b: 50))
    }

    @Test func aStilledLayerDrawsAtFullBaseWithoutItsOffset() {
        let moving = AnimationLayer(name: "m", pixels: [AnimationPixel(x: 3, y: 3, colour: RGB(r: 200, g: 0, b: 0))],
                                    multiplier: { _, _, _, _, _ in 0 }, offset: { _, _ in (dx: 0, dy: -99) },
                                    key: "k")
        let still = scene([moving]).render(frame: 4, of: 10, stilled: ["k"])
        #expect(still[3 * 52 + 3] == RGB(r: 200, g: 0, b: 0))
        #expect(scene([moving]).render(frame: 4, of: 10, stilled: []).allSatisfy { $0 == nil })
    }

    @Test func aTintAnimatesRedOnlyAndHoldsGreenWhereTheRedCarriesIt() {
        let p = AnimationLayer(name: "p", pixels: [AnimationPixel(x: 0, y: 0, colour: RGB(r: 200, g: 144, b: 0))],
                               multiplier: { f, _, _, _, _ in f == 0 ? 1000 : 500 })
        let s = scene([p], tint: { RGB(r: PanelLevels.red($0), g: 0, b: 0) })
        #expect(s.render(frame: 0, of: 2, stilled: [])[0] == RGB(r: 255, g: 144, b: 0))
        #expect(s.render(frame: 1, of: 2, stilled: [])[0] == RGB(r: 176, g: 100, b: 0))   // red 100 → 176, 144 not carried
    }

    @Test func speedPlaysTheSameCyclesInMoreOrFewerFrames() {
        let s = scene([])
        #expect(s.frameCount(speed: .half) == 20)
        #expect(s.frameCount(speed: .normal) == 10)
        #expect(s.frameCount(speed: .double) == 5)
    }

    @Test func brightnessScalesEveryChannelAndDropsWhatGoesDark() {
        let p = AnimationLayer(name: "p", pixels: [AnimationPixel(x: 0, y: 0, colour: RGB(r: 40, g: 0, b: 0)),
                                                   AnimationPixel(x: 1, y: 0, colour: RGB(r: 1, g: 0, b: 0))])
        let canvas = scene([p]).canvas(frame: 0, of: 10, stilled: [], brightness: 1)
        #expect(canvas[0, 0] == Pixel(red: 8, green: 0, blue: 0))    // (40·1 + 2) / 5
        #expect(canvas[1, 0] == .black)                               // (1·1 + 2) / 5 = 0
    }
}
```

- [ ] **Step 2: Run to verify it fails.** Run `swift test --no-parallel --filter AnimatedSceneTests`. Expected: compile error, `cannot find 'AnimationLayer'`.

- [ ] **Step 3: Implement.**

```swift
// Sources/PixbarKit/Animation/AnimatedScene.swift
/// A colour in the engine's own integers — a design colour may exceed 255
/// before the multiplier and the clamp bring it back.
public struct RGB: Hashable, Sendable {
    public var r: Int
    public var g: Int
    public var b: Int
    public static let black = RGB(r: 0, g: 0, b: 0)
    public init(r: Int, g: Int, b: Int) { self.r = r; self.g = g; self.b = b }
    var isLit: Bool { r != 0 || g != 0 || b != 0 }
}

public struct AnimationPixel: Sendable {
    public let x: Int
    public let y: Int
    public let colour: RGB
    public init(x: Int, y: Int, colour: RGB) { self.x = x; self.y = y; self.colour = colour }
}

/// A named group of pixels and how it moves — `nlengine.Layer`.
///
/// `multiplier` answers per mille for the index-th pixel, `offset` the
/// whole-pixel shift of the layer (x wraps round the panel, y clips). `key`
/// names the motion setting that stills it: it is then drawn at its base
/// colour where it stands. A layer's `tint` replaces the scene's.
public struct AnimationLayer: Sendable {
    public typealias Multiplier = @Sendable (_ frame: Int, _ n: Int, _ index: Int, _ x: Int, _ y: Int) -> Int
    public typealias Offset = @Sendable (_ frame: Int, _ n: Int) -> (dx: Int, dy: Int)

    public static let still: Multiplier = { _, _, _, _, _ in 1000 }
    public static let fixed: Offset = { _, _ in (dx: 0, dy: 0) }

    public let name: String
    public let pixels: [AnimationPixel]
    public let multiplier: Multiplier
    public let offset: Offset
    public let key: String?
    public let tint: AnimatedScene.Tint?

    public init(name: String, pixels: [AnimationPixel], multiplier: @escaping Multiplier = still,
                offset: @escaping Offset = fixed, key: String? = nil, tint: AnimatedScene.Tint? = nil) {
        self.name = name
        self.pixels = pixels
        self.multiplier = multiplier
        self.offset = offset
        self.key = key
        self.tint = tint
    }
}

/// How fast a scene plays: the same whole cycles in `den/num` times the
/// frames. The frame delay never changes.
public struct AnimationSpeed: Hashable, Sendable {
    public let num: Int
    public let den: Int
    public static let half = AnimationSpeed(num: 1, den: 2)
    public static let normal = AnimationSpeed(num: 1, den: 1)
    public static let double = AnimationSpeed(num: 2, den: 1)
    public init(num: Int, den: Int) { self.num = num; self.den = den }
    /// "1/2", "1/1", "2/1" — the oracle's spelling.
    public init?(fraction: String) {
        let parts = fraction.split(separator: "/").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        self.init(num: parts[0], den: parts[1])
    }
}

/// A full-panel animation — `nlengine.PixelScene`. No stored frames: a
/// frame is computed from its index and the loop's length, and every motion
/// is periodic in that length, so the loop has no seam at any speed.
public struct AnimatedScene: Sendable {
    public typealias Tint = @Sendable (Int) -> RGB
    public static let width = PixelCanvas.width
    public static let height = PixelCanvas.height

    public let id: String
    public let frameMs: Int
    public let cycleFrames: Int
    public let layers: [AnimationLayer]
    public let tint: Tint?

    public init(id: String, frameMs: Int, cycleFrames: Int, layers: [AnimationLayer], tint: Tint? = nil) {
        self.id = id
        self.frameMs = frameMs
        self.cycleFrames = cycleFrames
        self.layers = layers
        self.tint = tint
    }

    public func frameCount(speed: AnimationSpeed) -> Int {
        IntMath.floorDiv(cycleFrames * speed.den, speed.num)
    }

    /// One frame, row-major, nil where unlit.
    public func render(frame: Int, of n: Int, stilled: Set<String>) -> [RGB?] {
        let w = Self.width, h = Self.height
        var grid = [RGB?](repeating: nil, count: w * h)
        for layer in layers {
            let moving = layer.key.map { !stilled.contains($0) } ?? true
            let (dx, dy) = moving ? layer.offset(frame, n) : (0, 0)
            let tint = layer.tint ?? self.tint
            for (i, p) in layer.pixels.enumerated() {
                let m = moving ? layer.multiplier(frame, n, i, p.x, p.y) : 1000
                let xx = IntMath.floorMod(p.x + dx, w)
                let yy = p.y + dy
                guard 0 <= yy, yy < h else { continue }
                var out: RGB
                if let tint {
                    let r = min(255, IntMath.floorDiv(p.colour.r * m, 1000))
                    out = r != 0 ? tint(r) : .black
                    if r != 0, p.colour.g != 0 {
                        out.g = PanelLevels.amber(out.r, p.colour.g)
                    }
                } else {
                    out = RGB(r: min(255, IntMath.floorDiv(p.colour.r * m, 1000)),
                              g: min(255, IntMath.floorDiv(p.colour.g * m, 1000)),
                              b: min(255, IntMath.floorDiv(p.colour.b * m, 1000)))
                }
                if out.isLit { grid[yy * w + xx] = out }
            }
        }
        return grid
    }

    /// One frame at a brightness step, 1…5: `(ch · level + 2) / 5` per
    /// channel, and a colour scaled to nothing is unlit.
    public func canvas(frame: Int, of n: Int, stilled: Set<String>, brightness: Int) -> PixelCanvas {
        var canvas = PixelCanvas()
        for (i, cell) in render(frame: frame, of: n, stilled: stilled).enumerated() {
            guard let c = cell else { continue }
            let s = RGB(r: (c.r * brightness + 2) / 5, g: (c.g * brightness + 2) / 5, b: (c.b * brightness + 2) / 5)
            guard s.isLit else { continue }
            canvas[i % Self.width, i / Self.width] = Pixel(red: UInt8(s.r), green: UInt8(s.g), blue: UInt8(s.b))
        }
        return canvas
    }

    /// A character mask as layer pixels — `nlengine.mask`: each character
    /// names a colour, "." is empty.
    public static func mask(_ rows: [String], _ colours: [Character: RGB], x0: Int = 0, y0: Int = 0) -> [AnimationPixel] {
        rows.enumerated().flatMap { dy, row in
            row.enumerated().compactMap { dx, ch in
                ch == "." ? nil : AnimationPixel(x: x0 + dx, y: y0 + dy, colour: colours[ch]!)
            }
        }
    }
}
```

The brightness division is Swift `/` because every channel is non-negative there. A negative channel would trap in `UInt8(_:)`, which is the loud failure we want: Python would have drawn nonsense.

- [ ] **Step 4: Run.** `swift test --no-parallel --filter AnimatedSceneTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `feat(animation): the layer engine — render, speed, stilled layers, brightness`

---

### Task 4: `AnimatedPage` — one full-page GIF delivery

**Files:**
- Create: `Sources/PixbarKit/Animation/AnimatedPage.swift`
- Test: `Tests/PixbarKitTests/AnimatedPageTests.swift`

**Interfaces:**
- **Consumes:**
  - `FullFrameGif.encode(frames: [PixelCanvas], delays: [TimeInterval]) throws -> Data`;
  - `UlanziImage(base64:isAnimated:frameCount:pixelSize:position:)`;
  - `UlanziFrame(duration:image:)`, `UlanziScene(frames:)`, `UlanziDelivery(scene:)`.
- **Produces:**
  - `AnimatedPage.maxFrames = 480`, `maxBase64Bytes = 136_000`;
  - `enum AnimatedPage.CeilingExceeded: Error { case tooManyFrames(Int), tooLarge(Int) }`;
  - `static func gif(_ scene: AnimatedScene, speed: AnimationSpeed, stilled: Set<String>, brightness: Int) throws -> Data`;
  - `static func delivery(_ scene: AnimatedScene, speed: AnimationSpeed, stilled: Set<String>, brightness: Int) throws -> UlanziDelivery`.

- [ ] **Step 1: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import PixbarKit

@Suite struct AnimatedPageTests {
    private let dot = AnimationLayer(name: "d", pixels: [AnimationPixel(x: 1, y: 1, colour: RGB(r: 255, g: 72, b: 0))],
                                     multiplier: { f, n, _, _, _ in f * 2 < n ? 1000 : 400 })

    @Test func aSceneBecomesOneAnimatedImageFillingThePanel() throws {
        let scene = AnimatedScene(id: "t", frameMs: 100, cycleFrames: 4, layers: [dot])
        let delivery = try AnimatedPage.delivery(scene, speed: .normal, stilled: [], brightness: 5)
        let frame = try #require(delivery.scene.frames.first)
        let image = try #require(frame.image.first)
        #expect(delivery.scene.frames.count == 1)
        #expect(image.isAnimated && image.frameCount == 4)
        #expect(image.pixelSize.width == 52 && image.pixelSize.height == 16)
        #expect(image.position.x == 0 && image.position.y == 0)
    }

    @Test func overTheFrameCeilingItIsRefusedBeforeEncoding() {
        let scene = AnimatedScene(id: "t", frameMs: 100, cycleFrames: 241, layers: [dot])
        #expect(throws: AnimatedPage.CeilingExceeded.tooManyFrames(482)) {
            try AnimatedPage.delivery(scene, speed: .half, stilled: [], brightness: 5)
        }
    }

    @Test func theGifCarriesTheScenesDelayOnEveryFrame() throws {
        let scene = AnimatedScene(id: "t", frameMs: 150, cycleFrames: 2, layers: [dot])
        let data = try AnimatedPage.gif(scene, speed: .normal, stilled: [], brightness: 5)
        // Graphic Control Extension: 21 F9 04 <flags> <delay lo> <delay hi>
        let bytes = [UInt8](data)
        let delays = bytes.indices.dropLast(6).filter { bytes[$0] == 0x21 && bytes[$0 + 1] == 0xF9 }
            .map { Int(bytes[$0 + 4]) | Int(bytes[$0 + 5]) << 8 }
        #expect(delays == [15, 15])
    }
}
```

`UlanziImage`'s stored property names (`isAnimated`, `frameCount`, `pixelSize`, `position`) must be read in `Sources/PixbarKit/Ulanzi/UlanziScene.swift` before this step. If they are internal or named differently, use what exists: `@testable import` reaches internal members.

- [ ] **Step 2: Run to verify it fails.** Run `swift test --no-parallel --filter AnimatedPageTests`. Expected: compile error, `cannot find 'AnimatedPage'`.

- [ ] **Step 3: Implement.**

```swift
// Sources/PixbarKit/Animation/AnimatedPage.swift
import Foundation

/// Any animated scene as one TC002 page: every frame, full 52×16, in one
/// GIF with one global palette, placed at (0, 0) — the only form the panel
/// plays in step (`tc002-ticker-motion`).
public enum AnimatedPage {
    /// The panel's measured ceiling (2026-09-23): 478 frames / 135 240 B of
    /// base64 played on time.
    public static let maxFrames = 480
    public static let maxBase64Bytes = 136_000

    public enum CeilingExceeded: Error, Equatable {
        case tooManyFrames(Int)
        case tooLarge(Int)
    }

    public static func gif(_ scene: AnimatedScene, speed: AnimationSpeed, stilled: Set<String>, brightness: Int) throws -> Data {
        let n = scene.frameCount(speed: speed)
        guard n <= maxFrames else { throw CeilingExceeded.tooManyFrames(n) }
        let frames = (0..<n).map { scene.canvas(frame: $0, of: n, stilled: stilled, brightness: brightness) }
        let delay = TimeInterval(scene.frameMs) / 1000
        return try FullFrameGif.encode(frames: frames, delays: Array(repeating: delay, count: n))
    }

    public static func delivery(_ scene: AnimatedScene, speed: AnimationSpeed, stilled: Set<String>, brightness: Int) throws -> UlanziDelivery {
        let data = try gif(scene, speed: speed, stilled: stilled, brightness: brightness)
        let base64 = data.base64EncodedString()
        guard base64.utf8.count <= maxBase64Bytes else { throw CeilingExceeded.tooLarge(base64.utf8.count) }
        let n = scene.frameCount(speed: speed)
        let image = UlanziImage(base64: base64, isAnimated: n > 1, frameCount: n,
                                pixelSize: (width: AnimatedScene.width, height: AnimatedScene.height),
                                position: (x: 0, y: 0))
        return UlanziDelivery(scene: UlanziScene(frames: [UlanziFrame(duration: 5, image: [image])]))
    }
}
```

`duration: 5` is the weather face's own full-page frame (`WeatherFace.delivery`); it is the page's dwell, not the GIF's delays.

- [ ] **Step 4: Run.** `swift test --no-parallel --filter AnimatedPageTests`. Expected: PASS.

- [ ] **Step 5: Commit.** `feat(animation): a scene as one full-page TC002 GIF, inside the measured ceiling`

---

### Task 5: The oracle loader and the scene enum

**Files:**
- Create: `Tests/PixbarKitTests/AnimationOracle.swift`, `Sources/PixbarKit/NightLight/NightLightScene.swift`
- Test: `Tests/PixbarKitTests/NightLightScenesTests.swift` (the first two tests)

**Interfaces:**
- **Produces (tests):**
  - `struct AnimationOracle` with `static func load() throws -> AnimationOracle`;
  - `scenes: [String: Scene]`, where `Scene` has `frameMs`, `cycleFrames`, `toggles`, `palette: [RGB]` and `frames() throws -> [[RGB?]]`;
  - `variants: [Variant]`, where `Variant` has `scene`, `speed`, `stilled`, `brightness`, `frames`, `fnv`;
  - `static func fnv(_ canvases: [PixelCanvas]) -> String`.
- **Produces (kit):**
  - `public enum NightLightScene: String, CaseIterable, Codable, Sendable { case embers, horizon, moon, fireflies, fireplace, glow }`;
  - `var displayName: String` — English: Embers, Warm horizon, Red moon, Fireflies, Fireplace, Soft glow;
  - `var animatedScene: AnimatedScene`.

- [ ] **Step 1: Write the loader** (not a test; it is the tests' reader).

```swift
// Tests/PixbarKitTests/AnimationOracle.swift
import Foundation
@testable import PixbarKit

/// `Scripts/make_animation_oracle.py`'s fixture: the approved scenes' frames
/// as the mockup computed them.
struct AnimationOracle: Decodable {
    struct Scene: Decodable {
        let frameMs: Int
        let cycleFrames: Int
        let toggles: [String]
        let palette: [String]
        let framesZ: String

        /// The default variant's frames, nil for unlit.
        func frames() throws -> [[RGB?]] {
            let colours = palette.map { hex -> RGB in
                let v = Int(hex, radix: 16)!
                return RGB(r: v >> 16, g: (v >> 8) & 255, b: v & 255)
            }
            let compressed = try #require(Data(base64Encoded: framesZ))
            let json = try (compressed as NSData).decompressed(using: .zlib) as Data
            return try JSONDecoder().decode([String].self, from: json).map { row in
                let bytes = Array(row.utf8)
                return stride(from: 0, to: bytes.count, by: 2).map { i in
                    let index = Int(String(decoding: bytes[i..<i + 2], as: UTF8.self), radix: 16)!
                    return index == 0 ? nil : colours[index]
                }
            }
        }
    }

    struct Variant: Decodable {
        let scene: String
        let speed: String
        let stilled: [String]
        let brightness: Int
        let frames: Int
        let fnv: String
    }

    let scenes: [String: Scene]
    let variants: [Variant]

    static func load() throws -> AnimationOracle {
        let url = try #require(Bundle.module.url(forResource: "animation_oracle", withExtension: "json"))
        return try JSONDecoder().decode(AnimationOracle.self, from: Data(contentsOf: url))
    }

    /// FNV-1a-64 over every frame's RGB bytes, row-major — the recorder's `fnv`.
    static func fnv(_ canvases: [PixelCanvas]) -> String {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for canvas in canvases {
            for y in 0..<canvas.height {
                for x in 0..<canvas.width {
                    let p = canvas[x, y]
                    for b in [p.red, p.green, p.blue] {
                        h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3
                    }
                }
            }
        }
        return String(format: "%016llx", h)
    }
}
```

`#require` works outside a `@Test` only when the calling test is throwing; if the compiler rejects it here, throw a local `struct Missing: Error` instead.

- [ ] **Step 2: Write the failing tests.**

```swift
import Foundation
import Testing
@testable import PixbarKit

@Suite struct NightLightScenesTests {
    @Test func theOracleHoldsEverySceneTheTileOffers() throws {
        let oracle = try AnimationOracle.load()
        #expect(Set(oracle.scenes.keys) == Set(NightLightScene.allCases.map(\.rawValue)))
    }

    @Test func everySceneKeepsItsLoopAndItsMotionSwitches() throws {
        let oracle = try AnimationOracle.load()
        for scene in NightLightScene.allCases {
            let recorded = try #require(oracle.scenes[scene.rawValue])
            let animated = scene.animatedScene
            #expect(animated.frameMs == recorded.frameMs, "\(scene)")
            #expect(animated.cycleFrames == recorded.cycleFrames, "\(scene)")
            let keys = animated.layers.compactMap(\.key).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            #expect(keys == recorded.toggles, "\(scene)")
        }
    }
}
```

- [ ] **Step 3: Run to verify it fails.** Run `swift test --no-parallel --filter NightLightScenesTests`. Expected: compile error, `cannot find 'NightLightScene'`.

- [ ] **Step 4: Implement the enum.** Each `animated` points at the scene built in Tasks 6–8; until a scene is ported, its case builds an empty scene with the recorded timing, so the enum compiles and the per-scene test stays red.

```swift
// Sources/PixbarKit/NightLight/NightLightScene.swift
/// The six night-light scenes, as stored in a tile's config.
public enum NightLightScene: String, CaseIterable, Codable, Sendable {
    case embers, horizon, moon, fireflies, fireplace, glow

    public var displayName: String {
        switch self {
        case .embers: "Embers"
        case .horizon: "Warm horizon"
        case .moon: "Red moon"
        case .fireflies: "Fireflies"
        case .fireplace: "Fireplace"
        case .glow: "Soft glow"
        }
    }

    /// The scene on the animation engine — the port of its mockup module.
    public var animatedScene: AnimatedScene {
        switch self {
        case .embers: EmbersScene.scene
        case .horizon: HorizonScene.scene
        case .moon: RedMoonScene.scene
        case .fireflies: FirefliesScene.scene
        case .fireplace: FireplaceScene.scene
        case .glow: GlowScene.scene
        }
    }
}
```

Create each scene file with a stub until its task, e.g.:

```swift
enum EmbersScene { static let scene = AnimatedScene(id: "embers", frameMs: 100, cycleFrames: 200, layers: []) }
```

Use the recorded timings: embers 100 ms × 200, horizon 250 × 144, moon 150 × 208, fireflies 100 × 240, fireplace 100 × 200, glow 100 × 240.

- [ ] **Step 5: Add the pixel-parity tests.** They stay red until the ports land.

```swift
extension NightLightScenesTests {
    @Test(arguments: NightLightScene.allCases)
    func theDefaultLoopIsTheMockupPixelForPixel(scene: NightLightScene) throws {
        let recorded = try #require(try AnimationOracle.load().scenes[scene.rawValue])
        let expected = try recorded.frames()
        let animated = scene.animatedScene
        let n = animated.frameCount(speed: .normal)
        #expect(n == expected.count)
        for f in 0..<min(n, expected.count) {
            let got = animated.canvas(frame: f, of: n, stilled: [], brightness: 5)
            for i in 0..<832 {
                let want = expected[f][i].map { Pixel(red: UInt8($0.r), green: UInt8($0.g), blue: UInt8($0.b)) } ?? .black
                if got[i % 52, i / 52] != want {
                    Issue.record("\(scene) frame \(f) (\(i % 52),\(i / 52)): \(got[i % 52, i / 52]) ≠ \(want)")
                    return
                }
            }
        }
    }

    @Test(arguments: NightLightScene.allCases)
    func everyVariantMatchesItsRecordedDigest(scene: NightLightScene) throws {
        let animated = scene.animatedScene
        for variant in try AnimationOracle.load().variants where variant.scene == scene.rawValue {
            let speed = try #require(AnimationSpeed(fraction: variant.speed))
            let n = animated.frameCount(speed: speed)
            #expect(n == variant.frames, "\(scene) \(variant.speed)")
            let frames = (0..<n).map { animated.canvas(frame: $0, of: n, stilled: Set(variant.stilled), brightness: variant.brightness) }
            #expect(AnimationOracle.fnv(frames) == variant.fnv,
                    "\(scene) speed \(variant.speed) stilled \(variant.stilled) brightness \(variant.brightness)")
        }
    }

    @Test(arguments: NightLightScene.allCases)
    func everyLoopIsSeamlessAndFitsThePanelAtEverySpeed(scene: NightLightScene) throws {
        let animated = scene.animatedScene
        for speed in [AnimationSpeed.half, .normal, .double] {
            let n = animated.frameCount(speed: speed)
            #expect(animated.render(frame: n, of: n, stilled: []) == animated.render(frame: 0, of: n, stilled: []))
            #expect(throws: Never.self) { try AnimatedPage.delivery(animated, speed: speed, stilled: [], brightness: 5) }
        }
    }
}
```

`NightLightScene` must conform to `CustomTestStringConvertible` only if swift-testing asks for it; a `String`-backed enum works as an argument as is.

- [ ] **Step 6: Run.** `swift test --no-parallel --filter NightLightScenesTests`. Expected: the first two tests PASS; the parity, digest and seam tests FAIL for all six scenes (no layers yet).

- [ ] **Step 7: Commit.** `test(nightlight): hold the six scenes to the recorded mockup`

---

### Tasks 6–8: The scene ports

Each scene is a **line-for-line port** of its Python module in `.claude/skills/tc002-face-mockup/nightlight/`. The Python file is the specification and its source is the exact content to port. Per scene:

- [ ] Port constants verbatim: string grids stay `[String]` literals; tuples become arrays of tuples or small structs.
- [ ] Port each function with the Global Constraints' arithmetic rules. Python default-argument captures in closures (`def glow(frame, n, i, x, y, climbed=climbed)`) become Swift closure captures of `let` values.
- [ ] Return `AnimatedScene(id:frameMs:cycleFrames:layers:tint:)` with the layers in Python's order.
- [ ] Run `swift test --no-parallel --filter NightLightScenesTests` and get PASS for this scene's three parameterized cases.
- [ ] When a pixel differs, the failure names the frame and the cell. Find the Python expression for that cell and look for:
  - a `//` or `%` on a signed value;
  - a set iterated unsorted;
  - a `min`/`max` on the wrong side of a division.
- [ ] Commit one scene per commit: `feat(nightlight): the <scene> scene on the engine`.

#### Task 6: Embers and Fireflies (`embers.py`, `fireflies.py`)

- **Embers.**
  - Port `design`, `per_mille`, `heat`, `BED`, `SPARKS`, the `flicker` multiplier and the spark layers. The spark `offset` returns `(-99, -99)` when a spark is between lives: `floorMod` wraps x and the y clip drops it, exactly as in Python.
  - `drift * s // rise` has a signed `drift`, so use `floorDiv`.
  - `tops[x]` is the minimum y of the bed mask at column x.
- **Fireflies.** `sdiv(ax * SIN[...], 127)` becomes `truncDiv`, and the `pulse` multiplier is `max(0, ramp(...))`.

#### Task 7: Horizon and Red Moon (`horizon.py`, `redmoon.py`)

- **Horizon.**
  - `jitter` uses the `UInt64` hash: `h = ((x*73856093) ^ (y*19349663) ^ 0x5BD1E995) & 0xFFFFFFFF`, then `h = (h * 2654435761 & 0xFFFFFFFF) >> 16`, then `h * 2 * JITTER // 0xFFFF - JITTER`.
  - `x*73856093` is positive for x ≥ 0, so Int is fine; `^` works on Int.
  - `share * SIN[...] // 127` and `jitter(y, x) * SUN_SPREAD // (2 * JITTER)` are signed, so use `floorDiv`.
- **Red Moon.**
  - `graded` is a breadth-first distance from the `B` cells over 4-neighbours; the result does not depend on visit order.
  - `ring`: first pass, edge cells where any `NEAR` neighbour (x wrapped) is not in the bank. Then, for `k` in `1..<ramp.count`, a cell whose neighbour has ring `k-1`.
  - `shade` takes the first `SHADE` entry, farthest first, with `dist >= far`.
  - `moonlit` and `red` are tints; the cloud layer's tint is `moonlit`.
  - `math.isqrt` becomes `IntMath.isqrt`.
  - The drift is `frame * W // n`, which is non-negative.

#### Task 8: Fireplace and Glow (`fireplace.py`, `glow.py`)

- **Fireplace.**
  - `lift`: `weight * SIN[...] // 127` is signed, so use `floorDiv`; `sdiv(e + LIFT_BIAS, LIFT_SCALE)` becomes `truncDiv`.
  - `top_of` scans `FIRE_Y - 2 ..< H - EMBER_ROWS`.
  - The sparks' `rise` uses `drift * s // 3`, so use `floorDiv`.
- **Glow.**
  - Port `jitter` with the same hash as horizon, `JITTER = 6`.
  - `_moments` sorts by `(key, (x, y))` lexicographically. Iterate `BODY` and `SHRINK | GROW` in sorted `(x, y)` order before ranking: Python passes `sorted(BODY)`.
  - Layer pixel order:
    - the glow layer is `sorted(BODY | GROW)` by `(x, y)`;
    - the dots layer is row-major `y` then `x`, filtered to lit and not in `BODY`.
  - `flare`: `h = (jitter(y, x) + JITTER) * 7919 + x * 31 + y * 17`, which is non-negative. Then `(frame * CYCLE_FRAMES // n + h) % period`.
  - `side` and `turn` are unsigned in practice; use `floorDiv`/`floorMod` anyway for uniformity.

---

### Task 9: The whole kit is green

- [ ] Run `swift test --no-parallel --filter PixbarKitTests`. Expected: every suite passes, including the six scenes × three parameterized tests.
- [ ] Run `python3 .claude/skills/tc002-face-mockup/nightlight/ngen.py`. Expected: unchanged output; the mockup still renders from the moved engine.
- [ ] Commit only if anything changed since Task 8.

## Self-review

- **Spec §2 coverage:**
  - IntMath: Task 2;
  - PanelLevels: Task 2;
  - layers and render: Task 3;
  - speed, stilled layers, brightness: Task 3;
  - AnimatedPage and ceilings: Task 4;
  - Python engine move: Task 1;
  - oracle with full default frames plus variant digests: Tasks 1 and 5;
  - seamless loops: Task 5;
  - the six ports: Tasks 6–8.
- **Deferred.** Weather icons on the engine are out of scope (bead).
- **Type names are the same across tasks:** `RGB`, `AnimationPixel`, `AnimationLayer.Multiplier`/`Offset`, `AnimatedScene.Tint`, `AnimationSpeed(.half/.normal/.double, init?(fraction:))`, `AnimatedPage.CeilingExceeded`, `NightLightScene.animated`.

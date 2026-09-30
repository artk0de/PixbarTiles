# Night light tile — design

A TC002 tile that turns the clock into a night light: one of six slow, warm
scenes filling the 52×16 panel, dimmed to taste, that comes up on its own when
the night starts and hands the panel back in the morning.

The scenes follow the user's mockup sheet of 2026-09-29 ("Ulanzi TC002 —
Варианты ночника"). Their pixels are designed in the `tc002-face-mockup` skill
and approved in the browser and on the panel before any Swift face exists
(`.claude/rules/tile-design.md`); `.claude/skills/tc002-face-mockup/nightlight/`
becomes their pixel source of truth.

## What the brief asks for

1. A **Night light** tile with six scenes: Embers, Warm horizon, Red moon,
   Fireflies, Fireplace, Soft glow.
2. A warm palette only, with a stated reason for it (below).
3. Settings: **brightness**; **turning on and off by itself** on a macOS Sleep
   Focus or on set hours; **which of the six scenes**; smooth, worked-out
   animation.
4. Default: the tile works at night only. Sleep Focus when the Mac can tell
   Sleep apart, 22:00–06:00 otherwise.

## Why a warm palette

| Claim | What it means for the panel |
|---|---|
| Melatonin suppression peaks in the blue band (melanopsin, ~480 nm) and is weakest in long-wavelength red | No blue, no green, no cold white — not even in a spark's core |
| Long-wavelength red, ~620–700 nm, is the band recommended for night-time light | The darkest two palette entries are deep reds |
| Warm amber around 2100 K is comfortable to the eye and reads as "fire", not "screen" | The brightest entry is amber, never white |

The palette, darkest first — every scene draws from these five and the
interpolations between them, scaled by the brightness step:

| # | Hex | Role |
|---|---|---|
| 1 | `#4A0A0A` | ember floor, moon halo, the dimmest visible dot |
| 2 | `#8C0F14` | body red |
| 3 | `#D2321E` | flame, crescent |
| 4 | `#E8640F` | hot orange |
| 5 | `#F0A040` | amber core — the brightest a scene ever gets |

The hexes are the sheet's swatches as first guesses. What the panel does with
them, measured with `tc002-calibrate` on 2026-09-29 at the clock's maximum
brightness:

| Finding | Consequence |
|---|---|
| Every red from 4 to 64 lights as the same dimmest dot; 72…128 read as one level; 144…255 step apart | A scene draws with about eight reds: 0, 40, 100, 144, 160, 176, 192, 224, 255 (`nlengine.PANEL_REDS` maps a design red to its band) |
| A small green or blue (the sheet's `r, 8 %, 5 %` tint) lights at the floor and reads as another colour | A channel is either off or above its floor. A green shows only above a red floor: 40 from panel red 100, 72 and 100 from 160, 144 from 192 (`panel_amber`); a dimmed amber pixel turns red, never yellow-green |
| Beside a bright red (232), green 0 / 72 / 96 read as one harmonious red-to-amber family; 128 is too orange. Green under ~72 falls to the floor | Every scene uses the approved grid (red 255 / 192 / 160 / 100 / 40 × green 0 / 40 / 72 / 100 / 144, picked on the panel 2026-09-29): pure red at every level, green 40 down to red 100, green 72 and 100 down to 160, green 144 at 255 and 192. Red Moon, first drawn pure red, looked dull and now uses it too |
| A brightness that changes between levels reads as steps; alternating two levels every 30 ms reads as flicker | Nothing breathes by brightness. Motion is position (whole-pixel drift) and twinkle |
| A cloud whose pixels change level as it moves reads as noise | A moving sprite keeps each pixel's level; only a rim lit near the moon steps up |
| Drift of a non-integer number of frames per pixel judders | The loop is a whole number of frames per pixel at every speed |

## Decisions taken while designing

| Question | Decision | Why the alternative lost |
|---|---|---|
| Clock models | **TC002 only.** The catalogue lists the tile for TC002 alone | The app's AWTRIX encoder carries text and an icon only — a full-screen animated scene needs a new `draw` encoder and a hardware measurement first. Filed as a follow-up bead |
| Brightness | **Scaled palette inside the GIF**, five steps: 20 / 40 / 60 / 80 / 100 % | Brightness is device-global on the TC002 and its write endpoint was never measured; scaling the pixels touches nothing but this page. Cost: a step change is one GIF upload |
| Coming up at night | **Opt-in "Turn on by itself"**: when the tile's policy starts letting it run, the app switches the clock to its page | The one deliberate exception to D3 ("the app never switches pages on a schedule"). D3 protects a user mid-tool; at Sleep or at 22:00 nobody is turning the knob, and a night light that has to be found by hand is not one |
| Going off in the morning | **The page goes to the idle frame and the clock is switched to a chosen tile** — "In the morning show", defaulting to the first tile in the clock's order | The TC002 cannot say which page it showed before, so "go back" has nothing to go back to. Deleting the page costs a full GIF re-upload each night; leaving it lit keeps a night light glowing all day |
| When is "night" | **The tile's ordinary `TilePolicy`** — the same "Works in" boxes and Hours as every tile | A second scheduler would be a second truth about whether it is night |
| Default policy | **Sleep only** when Sleep can be named (Focus authorised AND the Do Not Disturb database readable, i.e. Full Disk Access); **22:00–06:00** otherwise | Without Full Disk Access every Focus is `.unknown`; "any Focus" would light the panel for a daytime Work Focus |
| Where the auto-switch lives | **The kind's wiring: `NightLightWiring.arrived` / `left`**, which `TileScheduler.reconcileTiles` calls on a change of the tile's verdict (the kinds refactor, `2026-09-30-tile-kinds-and-animation-engine-design.md` §1, replaced the planned branch in `reconcileTiles`) | A `bringsToFront` flag on `TilePolicy` would edit a hub (fan-in 8, transitive impact 26), its Codable form and a migration, for one consumer. A separate controller would duplicate the scheduler |
| Scene choice | **One scene per tile**, picked in settings | Rotating scenes is a feature nobody asked for; a second night-light tile on one clock is not allowed either (`.single`) |

## Behaviour

### Policy

`TileDefaults` gains two rows and `NightLightConnector.defaultPolicy` picks
one by asking an injected `canNameSleep`:

```swift
/// Only while the Mac is in Sleep: every other state silenced, and an unnamed
/// Focus held — it may be a Work Focus at noon.
public static let nightLightSleep = TilePolicy(
    refreshSeconds: 3_600,
    focus: FocusRule(silencedIn: [.noFocus, .work, .personal, .doNotDisturb], whenUnknown: .hold)
)

/// 22:00 to 05:59, whatever the Focus says.
public static let nightLightHours = TilePolicy(
    refreshSeconds: 3_600,
    window: .active(HourWindow(startHour: 22, endHour: 6))
)
```

`canNameSleep` is `focusStatus.access == .authorized &&
DoNotDisturbDatabase.activeMode() != .cannotTell`, evaluated when the tile is
added. The policy is copied into the tile then and is the tile's own from then
on, like every other tile's.

The refresh is an hour: the scene is a loop the clock plays by itself, and a
run only re-pushes what `onDevice` already holds — a byte-identical upsert is
skipped. Settings changes push at once through `pushDisplaySettings`.

### Coming up and going off

`TileScheduler.reconcileTiles` does its own `left` / `arrived` handling, then
tells the tile's wiring through `TileArrivalActions`. `NightLightWiring`, for a
config that says `autoShow`:

| Change | What the app does |
|---|---|
| `arrived` | `run` (the scene is on the page), then `show(key)` — the eye click's own path |
| `left` | `idle(key)` (`markIdle(tileId:)` on the TC002 session), then `show(morning)` where `morning` is `morningTile(clockId, morningTileId, key)`: the configured tile when it is on the clock, else the first unpaused, page-owning tile in the clock's order that is not this one |

A tile without `autoShow` behaves like any silent tile: it runs inside its
window and is held outside it, and its page stays wherever the knob is.

Only a change is acted on (`TileVerdicts`): a launch never switches the clock.

**Known limit.** A launch outside the window does not idle a page left lit by
an earlier night (a tile's first look is not a change). Filed as a follow-up
bead; the next `left` edge idles it.

### Settings block

`NightLightTileBlock`, under the shared policy editor:

- **Scene** — six choices; the window's preview column plays the chosen one
  as the GIF the clock will get.
- **Brightness** — a five-step stepped slider.
- **Animation speed** — ½× / 1× / 2×, one setting for every scene. The engine
  plays the same whole cycles in twice or half as many frames; the frame delay
  never changes.
- **Motion** — per-layer switches the scene declares (Red Moon: star twinkle,
  cloud motion). A switched-off layer is drawn still.
- **Turn on by itself** — a toggle, on by default.
- **In the morning show** — the tiles on this clock, plus "First in order"
  (default). Disabled while "Turn on by itself" is off.

## Kit

| File | Owns |
|---|---|
| `NightLight/NightLightScene.swift`, `NightLight/Scenes/*` | the six scenes on the animation engine, their stored names, display names |
| `NightLight/NightLightTileConfig.swift` | `scene`, `brightness` (1…5), `speed` (`NightLightSpeed`: ½ / 1 / 2), `stilled: Set<String>` (layer keys switched off), `autoShow`, `morningTileId: String?`; a `TileParameters`, writes nothing at the defaults |
| `NightLight/NightLightConnector.swift` | `id "nightlight"`, silent and ambient, `.single`; its reading is `AnimatedPage.delivery` at the tile's settings; `defaultPolicy` from `canNameSleep` |
| `Tiles/Kinds/NightLightKind.swift` | the kind: category system, `moon.stars`, TC002 only |
| `Animation/*` | the engine: layers, brightness, `FullFrameGif`, one full-page `UlanziScene` |

Edited: `TileKinds.all` (one line), `TileDefaults` (two rows). The config is
stored under the kind's id (`{"nightlight":{…}}`) with no edit to
`TileConfig`. The catalogue lists the tile on TC002 alone because a kind
narrows a live connector's models: the connector's required AWTRIX face is
never offered.

### The animation engine

No scene stores frames. A scene is a stack of layers; a layer is a set of
pixels with their base colours, a multiplier per pixel (per mille) and a
whole-pixel offset, both functions of the frame index and the loop length:

```text
pixel(frame) = base colour × multiplier(frame, n, pixel) / 1000,
               drawn at (x + dx(frame, n)) mod 52, y + dy(frame, n)
```

A layer never changes its drawing: it scales its pixels' brightness and a
drifting layer moves as a whole by whole pixels. No fractional coordinates, no
filtering, no blur — every operation is on the 832 physical pixels. A scene
may set a `tint`: only the red channel is animated and the tint derives the
pixel; a base colour's green is an accent held while red animates and shown
only where the red carries it (`panel_amber`). A layer may set its own tint.
Tints map the design red onto the panel's levels (`panel_red`) or onto a
scene's approved colour steps, so a GIF carries 5–11 colours and what the
browser shows is what the clock shows.

Red Moon as approved on the panel: 208 frames of 150 ms (31.2 s, 4 frames a
pixel of drift). A still crescent graded by its steps from the inner limb —
255/100, 255/72, 192/40, then red 160 at the back, 144 thin edges, 100 rim.
The sheet's cloud bank as a fixed picture drifting one width a loop through
moonlight fixed on the screen under the crescent: a lit cloud pixel walks down
the crescent's own colours, one step per ring under the bank's edge and one
per band of distance from the limb's foot (a column counts 4 to the left, 6 to
the right, a row 3; bands of 14), so under the moon the edge glows four or
five rings deep and at the pool's rim only the edge, dimly; the amber lines up
with the crescent's and the light is gone about x 18. Out of the light the
bank darkens with distance: at most 144 from about x 20, 100 from x 25, and
from x 33 a floor-level body under a 100 edge. 18 stars, the bright ones
amber, twinkle behind the clouds.

Warm horizon as approved on the panel: the sheet's panel quantised onto seven
approved colours — a horizon line along the bottom, the band fading to dark
red within three rows, a sun gone under at x 8–14 whose dome rises two rows
higher. Nothing moves; the light does: two sines along the band lift a pixel
above the line a step where they peak and drop it where they trough, so only
a few pixels change at a time, and the dome warms a step and back once a
loop. The line never changes. 144 frames of 250 ms.

Fireflies as approved on the panel: some twenty fireflies wander on closed
loops across a dark field and glow up and out one by one, every colour an
amber from the panel pick — a firefly never dims through red, and its core
stays short of gold. A big one wears a dim amber halo at its brightest; a
small one is a single dot. 240 frames of 100 ms.

Fireplace as approved on the panel: the sheet's small fire round x 27 — a
narrow core held at amber 255/100 (no yellow at night), a red body with dark
holes and side licks, a sparse bed of embers. The embers swing a step on
their own 2–5 s periods; every flame column slides its cells −1…+2 rows on a
smoothly drifting energy, so the tongues rise and fall; at most three sparks
rise a row every 400 ms, fading and drifting aside. 200 frames of 100 ms.

Soft glow as approved on the panel: the tail of a red-amber lamp just past
the bottom-right corner — an oval of light, near-yellow at its core (255/144,
as the mock was judged), its rim broken into dim red dots. The glow breathes
a step up and down on a 12 s sine, each pixel at its own moment so the change
flows out from the corner; the rim grows and draws back by a pixel on a 24 s
sine; the free dots flare and settle on their own periods. A pixel steps
within its own family. 10 frames a second.

Embers as approved on the panel: a bed of coals on rows 10–15 in eight heat
steps (40, 100, 160, 192 red; 255 with green 40 / 72 / 100 / 144), every hot
pixel (heat 6 and up) flickering two steps and a third of the rest one step —
a still yellow dot read as a fault; ten sparks climbing 4–9 rows at 4
frames a row and cooling on the way; 200 frames of 100 ms.

Every scene follows the same rule: 80–95 % of the panel stays black, motion
is slow, brightness is low. The masks are hand-drawn pixel art, traced from or
drawn after the sheet; the Python generator lives in
`tc002-face-mockup/nightlight/` (`nlengine.py` and one module per scene).

### Pixel parity with the Python oracle

The Swift generators must reproduce the Python frames pixel for pixel, so
both sides use integer arithmetic only: a seeded 32-bit LCG for every random
choice, a 256-entry integer sine table for every oscillation, and integer
colour interpolation with round-half-up. No `Double` reaches a pixel.

### Seamless loops

Each scene is one GIF of `N` frames at a fixed delay. Every motion is periodic
in `N` — oscillators run whole cycles over the loop, wanderers follow closed
paths — so frame `N` is frame `0` and the loop has no seam. `N` and the delay
are chosen in the mockup inside `UlanziScene`'s ceiling (≤ 480 frames,
≤ 136 000 bytes of base64); the delay is a whole number of centiseconds
(`tc002-ticker-motion`).

## App

| File | Change |
|---|---|
| `Kinds/NightLightWiring.swift` | new — the per-clock factory, the naming instance, the glyph, the block, `arrived` / `left` |
| `NightLightTileBlock.swift` | new — the settings block |
| `Kinds/TileKindWiring.swift` | one line in `AppTileKinds.all`; `canNameSleep` on `TileEnvironment` and `TileNaming` |
| `AppComposition.swift` | `canNameSleep` (Focus authorised and the Do Not Disturb database readable) |
| `AppModel.swift` | `morningTile` in the `TileArrivalActions` it hands the scheduler |
| `PanelGlyphs.swift` | the crescent glyph |

No dispatch file changes: the factories, the settings window and the glyph
lookup read the wiring.

## Tests

| Suite | Pins |
|---|---|
| `NightLightTileConfigTests` | round-trip under the `nightlight` key; defaults write nothing; the two default policies; a kind narrowing a connector's models |
| `NightLightConnectorTests` | `defaultPolicy` for Sleep nameable / not; silent, ambient, single; the delivery is the engine's at the tile's settings |
| `AnimatedSceneTests`, `NightLightScenesTests` | every scene's frames equal the animation oracle; each GIF inside the ceiling; each loop seamless |
| `NightLightWiringTests` | `arrived` + autoShow → run then show; `left` + autoShow → idle then show the morning tile, the chosen one first; autoShow off → nothing; the naming instance's policy follows `canNameSleep` |
| `TileArrivalTests` | the scheduler tells a wiring once per change, never on a first look |
| `NightLightTileBlockTests` | motion switches per scene; the morning choices; a change saved at once |

The oracle: `Scripts/make_animation_oracle.py` records the engine's frames into
`Tests/PixbarKitTests/Fixtures/animation_oracle.json`. Never edited by hand.

## Order of work

1. Mockup: the six scenes in `tc002-face-mockup/nightlight/`, played in
   `index.html`, then on the panel; palette and steps through
   `tc002-calibrate`. **Gate: the user signs off on the frames.**
2. In parallel with 1 — nothing here draws a pixel: config, `TileConfig`,
   defaults, connector (face kept out of the catalogue until the gate), the
   auto-show wiring, the settings block.
3. After the gate: the oracle recorder and fixture, then the Swift generators
   against it, then the face in the catalogue.

## Follow-ups (beads)

- Night light on the TC001: measure AWTRIX `draw`, then a 32×8 face.
- Idle a page left lit when the app launches outside the window.
- Hardware brightness on the TC002, if a write endpoint turns out to exist.
- **Open: the Brightness setting.** Scaling pixels by 20…80 % pushes most of a
  scene under the panel's floor, where eight levels collapse into one. Before
  the setting ships, measure the reds at the clock's lower brightness and
  decide whether a step removes levels from the top (fewer, dimmer levels)
  rather than scaling every pixel.

# PixelClockTiles — modern UI design

The app works and looks like a 2014 menu-bar utility: one popover, a flat list
of tiles, a settings sheet bolted on the side. This design replaces the surface
layer with something native to macOS 26 and gives tiles a real home — a store to
pick them from and a settings window that shows what the clock will actually
display.

Nothing below changes the kit. `PixelClockKit` — connectors, faces, the TC002
adapter, `TileCatalogue` — stays as it is, apart from the presentation metadata
§4 adds to `TileCandidate`. This is a design of the app target.

## What the brief asks for

Restated from the request, as the requirements the design must satisfy:

1. Clicking the menu bar icon shows **tiles with the status** of every added
   clock.
2. The panel carries **one general gear**: add a clock, set default parameters.
3. Every clock carries **its own gear**: add tiles, change their order.
4. **Clock order** is changed in settings.
5. Adding a tile happens in a **store window** — a form with categories, each
   tile with its own icon.
6. Every tile has **its own settings window**, and that window **renders what
   the tile will draw**.
7. The weather tile — **Better Weather** — configures humidity, °C/°F, and
   feels-like, with the result visible on the preview as it is changed.

## Decisions taken while designing

| Question | Decision | Why the alternative lost |
|---|---|---|
| Deployment floor | **macOS 26 only**, `platforms: [.macOS(.v26)]` | Back-deploying to 14 means every new surface carries a fallback branch and the app gets none of the material the redesign is for. This is a personal tool on a machine that runs 26. |
| One window or several | **Panel + separate windows** | A single "app window" turns a menu-bar utility into a dock app. The panel stays transient; anything the user dwells in gets its own window. |
| Store contents in v1 | **Existing connectors only** | A store listing tiles that do not exist is a mock. The catalogue already knows every connector; the store renders that, and grows as connectors do. |
| Preview fidelity | **Render the real face** | A hand-drawn mock of a clock face drifts from the face the moment either changes. The preview runs the same face code the clock runs, so it cannot lie. |
| How the UI is restructured | **Facades over `AppModel`** | `AppModel` is a working composition root with tested wiring. Rewriting it to fit new views risks behaviour for layout. New view models sit in front of it and take ownership of one surface each. |

## Design research — what the platform prescribes

Three findings from the macOS 26 HIG that the design follows rather than
re-litigates:

- **Liquid Glass is a navigation-layer material.** It belongs on toolbars,
  sidebars, popovers and menus — the chrome that floats above content. Content
  itself stays opaque. So: the panel and the store sidebar take the material;
  the tile list rows and the preview do not.
- **A popover is for transient content; persistent preferences belong to a
  `Settings` scene.** This is why the general gear opens a real Settings window
  (⌘, works, the window is restorable) instead of pushing a settings view inside
  the popover. The current app does the latter.
- **A live preview beside its controls is a sanctioned pattern**, not a novelty
  — the system uses it wherever a setting has a visual result. §5 is the HIG
  pattern, applied to a 52×16 panel.

## Surfaces and navigation

Four surfaces, each with one job:

| Surface | Kind | Opened by | Holds |
|---|---|---|---|
| **Panel** | `MenuBarExtra` popover | menu bar icon | clocks, their status, their tiles |
| **Settings** | `Settings` scene | general gear, ⌘, | clocks, defaults, general |
| **Store** | `Window` | a clock's gear → Add tile | categories and tile cards |
| **Tile settings** | `Window` | a tile row, or after adding | that tile's controls + preview |

The tile-settings window is **one window whose content swaps**, not one window
per tile. Opening settings for a second tile re-targets the existing window.
Ten open tile windows is not a state worth supporting, and `openWindow` with a
value-typed identity gives the re-targeting for free.

### The panel

```text
┌──────────────────────────────┐
│ PixelClockTiles           ⚙  │   ← title + general gear
├──────────────────────────────┤
│ ● Kitchen (TC002)         ⚙  │   ← clock header, status dot, clock gear
│     Weather        ▶  ⋯  ✕   │
│     Claude usage   ▶  ⋯  ✕   │
│ ● Desk (TC001)            ⚙  │
│     VPN: work      ▶  ⋯  ✕   │
└──────────────────────────────┘
```

Tiles are **grouped under the clock they sit on**, which is the change that
makes the panel answer the brief's first requirement. Today they are one flat
list and the clock is a detail inside the row.

The status dot is three-valued, driven by the clock's session state:

| Dot | Means |
|---|---|
| green | last push succeeded |
| yellow | reachable, nothing pushed yet, or a push is in flight |
| red | unreachable, or the last push failed |

Row controls keep their current meaning — ▶ push now, ⋯ open tile settings,
✕ remove. The clock gear opens a menu: **Add tile…** (→ store), **Reorder
tiles**, **Clock settings…** (→ Settings, Clocks tab, that clock selected).

### Settings window

Three tabs:

- **Clocks** — the list of added clocks, drag to reorder, add by discovery or by
  address, remove. The content of today's `ClocksSettings` moves here: the
  discovered rows, `AddByAddressRow`, and the outcome lines. It is already the
  right view in the wrong container.
- **Defaults** — the default parameters a newly added tile starts with: push
  interval, units, brightness policy.
- **General** — launch at login, quit, diagnostics.

Clock order is a settings concern (requirement 4) and tile order is a
per-clock concern (requirement 3). Keeping them in different surfaces is the
distinction the brief draws, and it holds: reordering clocks changes the panel's
sections, reordering tiles changes one section's rows.

### Tile store

```text
┌──────────┬────────────────────────────────────┐
│ All      │  ┌────────┐ ┌────────┐ ┌────────┐  │
│ Weather  │  │  icon  │ │  icon  │ │  icon  │  │
│ System   │  │ Better │ │ Claude │ │  VPN   │  │
│ Dev      │  │Weather │ │ usage  │ │        │  │
│ Network  │  │ blurb  │ │ blurb  │ │ blurb  │  │
│          │  │ + Add  │ │ Added  │ │ + Add  │  │
└──────────┴────────────────────────────────────┘
```

Category sidebar, card grid. Each card: a 32×32 icon, the name, a one-line
blurb, and an action.

`TileCandidate` gains three presentation fields — `category`, `storeIcon`,
`blurb` — alongside the four it already carries (`connectorId`, `models`,
`instancing`, `isAudible`). They live there because `TileCandidate` is already
the "a connector as the picker needs to see it" type; a parallel presentation
registry would be a second list to keep in step with the first.

Icons are **SF Symbols in v1**. Drawn artwork per tile is a follow-up, not a
blocker — and the bundled weather art is 8×8 AWTRIX-era anyway, so the icon work
and the face work want doing together.

**The availability mapping needs a correction.** `TileCatalogue.availability`
returns `.available`, `.unavailable(String)`, `.notListed`, and today
`.notListed` means "a single tile of this connector is already on this clock —
do not show the row". A menu can drop a row; a card grid cannot, because a grid
with holes in it reads as a bug. So the store maps:

| `TileAvailability` | Card shows |
|---|---|
| `.available` | **+ Add**, enabled |
| `.unavailable(reason)` | disabled card, reason under the blurb |
| `.notListed` | **Added**, disabled, no reason |

The kit rule does not change — the case is renamed at the presentation boundary,
not in `TileCatalogue`. The menu keeps dropping the row; the store draws it as
Added.

Adding a card is a two-step commit: add the tile, then open its settings window
on the new tile. A tile added with defaults and never configured is the common
mistake this avoids.

### Tile settings and the live preview

```text
┌─────────────────────────┬──────────────────────┐
│ Units    (°C) (°F)      │   ┌──────────────┐   │
│ Humidity      [ x ]     │   │  52×16 face  │   │  ← real render, ×6
│ Feels like    [ x ]     │   └──────────────┘   │
│ Interval   [ 10 min ▾ ] │    Kitchen (TC002)   │
└─────────────────────────┴──────────────────────┘
```

Controls left, the clock's silhouette right. The preview is **the real face**:
the tile's connector renders its face for the target model, that face is
encoded to a GIF by the same path that feeds the clock, and the GIF is shown as
an animated `NSImage` at ×6 nearest-neighbour.

The cost is a re-render on every control change, so changes are debounced
(~120 ms) and the render runs off the main actor. The gain is that the preview
cannot drift from the device: it is not a drawing of the face, it is the face.

For **Better Weather**, the controls are exactly requirement 7 — a °C/°F picker,
a humidity toggle, a feels-like toggle — and each flips the preview because each
changes what the face composes.

The preview needs one thing the app does not have yet: the TC002 face encoded
to a GIF **inside the app**. The `Scripts/` pipeline (`MakeTimedGif.py`, the
5×7 BDF font, full-frame GIF89a assembly) proved the format live; porting that
assembly into the kit is the prerequisite task, and the same encoder then serves
both the preview and the device push.

### Facades

Three view models, `@Observable`, one per surface:

| Facade | Owns |
|---|---|
| `PanelModel` | clock sections, status dots, row actions |
| `StoreModel` | categories, cards, availability mapping, add |
| `TileSettingsModel` | one tile's settings + the debounced preview render |

`AppModel` stays the composition root and is **not rewritten**. Each facade
takes a dependency on it, and the sections of `AppModel` that a facade takes
over are deleted from `AppModel` as that facade lands — so the two never hold
the same state in parallel. `AppModel` is `ObservableObject` today; it may stay
that way, since the facades are what the new views observe.

### Platform floor

`Package.swift` moves `platforms: [.macOS(.v14)]` → `[.macOS(.v26)]`. Hard bump,
no `if #available` branches anywhere in the app target. A redesign that keeps
a 14-compatible path is two designs, and the second one is the one nobody looks
at.

## Testing

- **Facades are unit-tested, TDD.** They are plain types over `AppModel`:
  status-dot derivation, availability→card mapping, the add-then-open sequence,
  the debounce boundary. Written before the views.
- **Preview determinism.** Same tile settings ⇒ byte-identical GIF. This is the
  test that keeps the preview honest, and it is cheap because the encoder is
  deterministic by construction (fixed palette order, full frames).
- **`PanelRenderingTests` migrate with the layout.** They currently pin a flat
  list; they get rewritten to pin the grouped sections, not deleted.
- No test touches the network or a real clock. The TC002 adapter is already
  tested against fixtures and stays that way.

## Phases

| Phase | Lands |
|---|---|
| 1 | `.macOS(.v26)` bump; `PanelModel` + the grouped panel with status dots |
| 2 | `Settings` scene; `ClocksSettings` content migrates; clock reorder |
| 3 | GIF encoder ported from `Scripts/` into the kit |
| 4 | `TileSettingsModel` + the live preview; Better Weather controls |
| 5 | `TileCandidate` presentation fields; `StoreModel`; the store window |

Phase 3 gates phase 4 and nothing else, so it can run in parallel with 1–2.

## Follow-ups

- Drawn 32×32 store icons, and 16×16 TC002 weather art to replace the 8×8
  AWTRIX-era bundle. Both want a person drawing them, not a generator.
- Tile reorder by drag inside the panel section (v1 uses a menu).
- Per-tile preview in the store card, once the encoder is in the kit.

## Out of scope

- Any new connector. The store lists what exists.
- Rewriting `AppModel`.
- iOS, iPadOS, or a dock-app mode.
- Clock-side sound. The audible rule in `TileCatalogue` stands as written.

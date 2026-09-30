# Tile kinds, a shared animation engine, and AppModel by GRASP — design

Adding the Night light tile would have touched about ten files, most of them
the codebase's churn hotspots: the closed `TileConfig` enum (six places),
`TilePresentation.of`, `TileCandidate` (which hard-codes `[.awtrix3]`),
`ConnectorFactories`, `AppModel.live`, the `if connector is …` chain in
`TileSettingsWindow.connectorBlock`, one setter per tile in
`TileSettingsModel`, and the `switch` in `PanelGlyphs.tile`. The user's goal
(2026-09-29): a new tile is **its description, plus a scene on a shared
animation engine when it animates** — nothing else.

Three parts, one branch:

1. **Tile kinds** — one descriptor per tile in the kit, one wiring per tile in
   the app, and every dispatch reads them.
2. **The animation engine** — `nlengine.py`'s layer model in Swift, integer
   only, held pixel for pixel to the Python oracle; any TC002 face can use it.
3. **AppModel and App.swift by GRASP** — the 3 577-line hub split into
   information experts behind an unchanged facade.

The Night light tile (`2026-09-29-night-light-tile-design.md`) is the first
consumer of all three.

## Risk signals (tea-rags, 2026-09-29)

| File | Signal | Consequence |
|---|---|---|
| `AppModel.swift` | 45 commits, bug-fix rate 27 %, fan-in 10, fan-out 73 | the facade keeps its public surface; extraction is one cluster per green commit |
| `TileConfig.swift` | a chunk with 8 commits, relative churn 1.61 | every tile edits it today — the first thing the kinds remove |
| `TileSettingsWindow.swift` | 11 commits, the dispatch chain changed 7 times | the chain becomes one call |
| `ConnectorFactories.swift` | bug-fix rate 33 % | becomes a loop over wirings |
| `PanelGlyphs.swift`, `TileStore`, `TileRecord` | hubs (fan-in 8–9) | `TileStore`/`TileRecord` are not changed; the glyph table loses its tile switch only |

## 1. Tile kinds

### Kit

```swift
/// A tile's own settings. Every tile config conforms.
public protocol TileParameters: Codable, Sendable, Equatable {}

/// Everything the kit knows about one kind of tile.
public protocol TileKind: Sendable {
    associatedtype Parameters: TileParameters
    /// The connector id — and the key the config is stored under.
    static var id: String { get }
    static var presentation: TilePresentation { get }
    /// The models it has a face for.
    static var models: Set<ClockModel> { get }
    static var instancing: Instancing { get }
    static var isAudible: Bool { get }
    /// The name beside the tile's own for a `.perKey` tile; nil by default.
    static func secondaryName(of tile: TileRecord, parameters: Parameters?) -> String?
}

/// The one list in the kit.
public enum TileKinds {
    public static let all: [any TileKind.Type]
    public static func kind(id: String) -> (any TileKind.Type)?
}
```

- **`TileConfig`** becomes a struct `{ kindId: String, value: any TileParameters }`.
  - **Coding.** The JSON stays exactly as stored today (`{"weather":{…}}`). Decoding looks the key up in `TileKinds.all` and throws on zero or two keys, as now. Equality compares kind id and value through an erased `isEqual`.
  - **Source compatibility.** The existing facade stays, so no test changes: `.weather(_:)`, `.vpn(_:)`, `.zai(_:)`, `.claude(_:)`, `.github(_:)`, `.weather(Coordinates)`, `weatherConfig`, `location`, `lamp`, `key`, `claudeConfig`, `github`, `parameters`.
  - **New generic access.** `value(as:)` and `init(_ value: some TileParameters, kind:)`.
  - **Legacy form.** The legacy `{"claude":"daily"}` form is decoded by `ClaudeTileConfig` itself, as today.
- **`TilePresentation.of(connectorId:)`, `secondaryName(of:)` and `TileCandidate.init`** read the kind.
  - The kind's `models` replace the "an AWTRIX face is always there" inference.
  - `TileCandidate(vpn)` becomes the VPN kind.
  - Unknown ids keep the "unknown app" mark.
- **Kinds for the existing tiles:** weather, claude, zai, github, anecdotes, vpn. VPN stays a lamp (its indicator path in the app is unchanged); only its catalogue facts move into the kind.
- **Replacing exhaustiveness.** The closed enum's exhaustiveness is replaced by one test: every kind in `TileKinds.all` has a unique id, round-trips a config, and has exactly one app wiring.

### App

```swift
/// What the app does with one kind: builds its connectors, draws its block,
/// wears its glyph, reacts to its window.
@MainActor protocol TileKindWiring {
    associatedtype Kind: TileKind
    /// Built once per clock — holds that clock's state (the Claude reporter,
    /// GitHub snapshots and refusals) — and returns the per-tile factory.
    func factory(for clock: ClockRecord, _ env: TileEnvironment) -> (TileRecord) -> any Connector
    /// The instance the app registry holds so the store and panel can ask it.
    func namingInstance(_ env: TileEnvironment) -> any Connector
    var glyph: [String] { get }                    // 11×11, B/G
    var namesItsOwnRefresh: Bool { get }           // default false
    associatedtype Block: View
    @ViewBuilder func block(_ context: TileBlockContext<Kind.Parameters>) -> Block   // default EmptyView
    /// The tile's policy window opened / closed (a change, never a first look).
    func arrived(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions)  // default nothing
    func left(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions)     // default nothing
}

enum AppTileKinds { static let all: [any TileKindWiring] }   // the one list in the app
```

- **`TileEnvironment`** holds what `ConnectorFactories` holds today: transport, defaults, secrets, the shared `OpenMeteoSource`, the shared anecdote connector, the Claude reporter factory, and `canNameSleep`.
- **`TileBlockContext<P>`** gives a block its tile's `key` and a `Binding<P>` onto its parameters (saved through one generic `TileSettingsModel.setParameters`). It also carries the ready `TileRefreshControl` and narrow actions for what a block does beyond its config: save a key or token, open the history.
  - The weather block keeps its draft; it is the weather wiring's business.
- **`TileArrivalActions`** is the narrow facade a wiring may use:
  - `run(key)`, `show(key)`, `idle(key)`;
  - `morningTile(on clockId:, excluding:)`.
- **What reads the wirings:**
  - `ConnectorFactories.registry(for:)` and `namingInstances` become loops;
  - `TileSettingsWindow.connectorBlock` becomes one `wiring.block(context)`;
  - `namesItsOwnRefresh` becomes a property;
  - `PanelGlyphs.tile(forConnectorId:)` becomes a lookup;
  - `reconcileTiles` calls `arrived`/`left` for the keys it already computes.
- **Migrations.** They do not change. `TileMigration` is marker-gated and has already run; `QuietHoursMigration` filters by `isAudible`.

**A new tile is then:** `XKind.swift` (+ its parameters) in the kit,
`XWiring.swift` (+ its block, when it has one) in the app, and one line in each
list.

## 2. The animation engine

`Sources/PixbarKit/Animation/`, the Swift twin of `nlengine.py`:

```swift
public enum IntMath {
    public static let sin: [Int]                      // round(127·sin(2πi/256)), literal
    public static func floorDiv(_ a: Int, _ b: Int) -> Int    // Python //
    public static func floorMod(_ a: Int, _ b: Int) -> Int    // Python %
    public static func truncDiv(_ a: Int, _ b: Int) -> Int    // nlengine.sdiv
    public static func isqrt(_ n: Int) -> Int
    public static func phase(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int = 0) -> Int
    public static func swing(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int, _ low: Int, _ high: Int) -> Int
    public static func ramp(_ frame: Int, _ n: Int, _ cycles: Int, _ offset: Int, _ low: Int, _ high: Int) -> Int
}

public enum PanelLevels {                             // TC002 facts, measured 2026-09-29
    public static func red(_ designRed: Int) -> Int   // nlengine.panel_red
    public static func stepUp(_ r: Int, _ steps: Int = 1) -> Int
    public static func amber(_ red: Int, _ green: Int) -> Int   // nlengine.panel_amber
}

public struct AnimationLayer: Sendable {
    public let name: String
    public let key: String?                           // the motion switch that stills it
    public let pixels: [AnimationPixel]               // (x, y, Pixel), drawing order
    public let multiplier: @Sendable (_ frame: Int, _ n: Int, _ index: Int, _ x: Int, _ y: Int) -> Int
    public let offset: @Sendable (_ frame: Int, _ n: Int) -> (dx: Int, dy: Int)
    public let tint: (@Sendable (Int) -> Pixel)?
}

public struct AnimatedScene: Sendable {
    public let id: String
    public let frameMs: Int
    public let cycleFrames: Int
    public let layers: [AnimationLayer]
    public let tint: (@Sendable (Int) -> Pixel)?
    public func frameCount(speed: AnimationSpeed) -> Int            // cycleFrames·den/num
    public func render(frame: Int, of n: Int, stilled: Set<String>) -> PixelCanvas
}

public enum AnimatedPage {
    public static let maxFrames = 480, maxBase64Bytes = 136_000
    /// frames → brightness → FullFrameGif → one full-page UlanziImage at (0, 0).
    public static func delivery(_ scene: AnimatedScene, speed: AnimationSpeed,
                                stilled: Set<String>, brightness: Int) throws -> UlanziDelivery
}
```

- **`render` is `PixelScene.render` verbatim:**
  - layers in order, pixels in order, later over earlier;
  - `x` wraps with floor-mod, `y` clips;
  - a stilled layer draws at 1000 ‰ with no offset;
  - with a tint only red is animated and green comes from `PanelLevels.amber`;
  - an all-zero result leaves the cell as it was.
- **Brightness:** `(ch · level + 2) / 5` per channel, levels 1…5, as the mockup and the oracle apply it. A gate in the plan checks levels 1–4 on the panel; the function is swapped in both engines if the low steps collapse.
- **Arithmetic parity.** Every Python `//` and `%` is `floorDiv` / `floorMod` in Swift: SIN, drift and jitter are signed. The glow and horizon hash is `UInt64` with wrapping multiply, masked to 32 bits.
- **Python.** `nlengine.py` moves from `nightlight/` to the root of `.claude/skills/tc002-face-mockup/` as the mockup skill's shared engine; a change starts there.
- **Oracle.** `Scripts/make_animation_oracle.py` writes `Tests/PixbarKitTests/Fixtures/animation_oracle.json`:
  - every scene at 1×, brightness 5, all layers moving, as full frames (palette + one index string per frame);
  - every other variant (½×, 2×, each layer stilled, brightness 1–4) as one FNV-1a-64 per frame over the frame's RGB bytes in row order.
  - It is never edited by hand.
- **Engine tests (Swift, on their own):**
  - `floorDiv`/`floorMod` on negative operands;
  - `isqrt`;
  - the hash against Python literals;
  - every scene seamless (frame n = frame 0) at every speed;
  - `AnimatedPage` refuses over-ceiling scenes.

Weather icons are not moved onto the engine here (bead).

## 3. AppModel and App.swift by GRASP

`AppModel` holds 15 clusters, ~50 stored properties (22 `@Published`), a
27-parameter `init`, 11 task handles and a shared run counter. Views and four
facades read it; tests build it through `testModel` (308 sites) and
`modelOverRealHost` (11); `init` is called directly in three places.

**Constraint:** `AppModel`'s public members, its `init` and `live` stay
source-compatible — business-logic tests are not rewritten. `AppModel` becomes
a thin Controller/Facade: it owns the experts, forwards to them, and relays
their `objectWillChange`.

| Expert (`@MainActor final class`) | Cluster | Owns |
|---|---|---|
| `ClockDirectory` | clocks | the clock list, selection, add / rename / remove / move, the address and location fields |
| `ClockSessions` | sessions | sessions, the per-clock registry cache, `session(for:)`, `connector(for:)`, `ulanziSession(for:)` |
| `ClockHealthMonitor` | health | AWTRIX and TC002 health, `poll`, reachability, battery lines, `isDeviceOnline`; is the `ReachabilityReading` |
| `TileBook` | tiles | tile CRUD, policies, catalogue and availability, order, titles, `rekey(tile:to:config:)` |
| `TileScheduler` | scheduling + labels | timers, verdicts, launch debt, `reschedule`, `reconcile` (with the wiring hooks), next-run labels |
| `TileRunner` | runs | `runNow`, `runAndReport`, the outcome maps, display pushes, `retract`, restock |
| `LampController` | VPN | lamps, the network and Focus watchers |
| `PageFollower` | detail + page | detail window, page follow, `tileOnScreen`, `showOnClock`, `idle` |
| `AnecdoteHistory` | history | history, replay, copy |
| `MicrophoneWatch` | mic | the gate, held runs |
| `IconMaintenance` | icons | icon removal |

- **Secrets and GitHub** (z.ai key, GitHub token, add GitHub tile, change repo) move to their wirings' actions.
  - `changeGitHubRepo` and `changeLampVPN`, which duplicate one re-key pattern, become `TileBook.rekey`.
- **`TaskBag`** (Pure Fabrication): an owned-task registry with keys. It replaces the 11 handles and the shared counter; `teardown` asks every expert to `cancelAll()`.
- **Narrow protocols** `ReachabilityReading`, `TileRunning` and `TileScheduling` break the book → scheduler → runner → book cycle (Indirection, Protected Variations).
- **`AppComposition.swift`** takes `AppModel.live` and `anecdoteWiring` (Creator); the wirings replace `ConnectorFactories`' body.
- **`App.swift`** splits into four files:
  - `PixbarTilesApp.swift` — the scenes;
  - `AppGlyph.swift` — `AppGlyph` and the `MenuBarGlyph` view;
  - `PanelWindowReader.swift` — with `WindowReportingView`;
  - `AppDelegate.swift`, with `PanelWindowLifecycle` (pin, drag, level) and `ClockBrowsingPolicy` (Bonjour) extracted.
- **Tests.**
  - Each expert gets its own unit tests.
  - Existing suites keep passing unchanged through the facade.
  - `testModel` may change inside, never its call sites.

## Order of work

Every step is a green commit.

1. Split `App.swift` (mechanical).
2. `TaskBag`, then the experts one at a time:
   1. `ClockSessions`
   2. `ClockHealthMonitor`
   3. `TileBook`
   4. `TileRunner` and `TileScheduler`
   5. `LampController`
   6. `PageFollower`
   7. `AnecdoteHistory`
   8. `MicrophoneWatch`
   9. `IconMaintenance`
   10. `ClockDirectory`
   11. `AppComposition`
3. `TileKind` + `TileConfig` as a struct; wirings for the six existing tiles; the dispatches read them.
4. The engine and its oracle. Independent of 1–3, can run beside them.
5. Night light as the first kind on the engine (its own spec).

## Follow-ups (beads)

- Weather icons on the animation engine.
- AWTRIX `draw` measurement and a 32×8 night light.
- The brightness function, if the panel gate shows collapsed low steps.

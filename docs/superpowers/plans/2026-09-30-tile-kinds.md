# Tile Kinds Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dinopowers:executing-plans (wraps superpowers:executing-plans) to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adding a tile means one kind in the kit and one wiring in the app, each listed once, instead of edits across ten files.

**Architecture:** The kit gets `TileParameters`, `TileKind` and the list `TileKinds.all`. `TileConfig` stops being a closed enum and becomes a struct of `{kindId, value}` behind the facade it has today. The app gets `TileKindWiring` and the list `AppTileKinds.all`. The places that switch on a connector id (the factories, the naming instances, the settings block, the glyph, the refresh flag) now loop over or look up that list. `reconcileTiles` gains `arrived`/`left` hooks, which do nothing by default.

**Tech Stack:** Swift 6, SwiftUI, Swift Testing, SwiftPM (`swift test --no-parallel --filter …`).

**Spec:** `docs/superpowers/specs/2026-09-30-tile-kinds-and-animation-engine-design.md`, §1.

## Global Constraints

- The stored JSON does not change: `{"weather":{…}}`, `{"vpn":{…}}`, `{"zai":{…}}`, `{"claude":{…}}` (and the legacy `{"claude":"daily"}`), `{"github":{…}}`.
- `TileConfig`'s facade stays source-compatible: `.weather(_:)`, `.weather(Coordinates)`, `.vpn(_:)`, `.zai(_:)`, `.claude(_:)`, `.github(_:)`, `weatherConfig`, `location`, `lamp`, `key`, `claudeConfig`, `github`, `parameters`.
- Business-logic tests are not rewritten. The one `case let .zai(config)?` pattern (in `TileSecretsTests`, a test written during plan 2) may move to the facade.
- The public API of `TileCandidate` and `TilePresentation` stays. Their answers for the six existing ids do not change.
- TDD: a failing test first, then the code. Run the full kit suite and the full app suite before each commit.
- Before each commit, check new names with `get_naming_lexicon`. After each commit, reindex the clone with `tea-rags index-codebase --project pixelclocktiles-worktree-night-light-tile`.
- Never push.

## Impact signals (tea-rags, blastRadius)

| File | fanIn / transitive | Treatment |
|---|---|---|
| `PanelGlyphs.swift` | hub 9 / 20 | Task 4 touches one function (`tile(forConnectorId:)`) and nothing else |
| `TileCatalogue.swift` | 3 / 22 | Task 3; public API frozen, answers pinned by a table test |
| `TileScheduler.swift` | 2 / 23 | Task 6 on its own; the hooks are no-ops by default |
| `TileConfig.swift` | 0 / 0 | Task 2 rebuilds it behind the facade |
| `ConnectorFactories.swift`, `TileSettingsWindow.swift`, `TileSettingsModel.swift` | leaves | Tasks 4–5 |

All files have one owner (artk0de).

## File structure

| File | Role |
|---|---|
| `Sources/PixbarKit/Tiles/TileKind.swift` (new) | `TileParameters`, `NoParameters`, `TileKind`, `TileKinds` |
| `Sources/PixbarKit/Tiles/Kinds/{Weather,Claude,Zai,GitHub,Anecdotes,VPN}Kind.swift` (new) | One kind per tile: id, presentation, models, instancing, audibility, secondary name |
| `Sources/PixbarKit/Tiles/TileConfig.swift` | The struct, its coding, its facade |
| `Sources/PixbarKit/Tiles/TileCatalogue.swift` | `TileCandidate` / `TilePresentation` read the kinds |
| `Sources/PixbarTilesApp/Kinds/TileKindWiring.swift` (new) | `TileEnvironment`, `TileKindWiring`, `TileBlockContext`, `TileArrivalActions`, `AppTileKinds` |
| `Sources/PixbarTilesApp/Kinds/{Weather,Claude,Zai,GitHub,Anecdotes,VPN}Wiring.swift` (new) | Factory, naming instance, glyph, refresh flag, block |
| `Sources/PixbarTilesApp/ConnectorFactories.swift` | Becomes a loop over `AppTileKinds.all` |
| `Sources/PixbarTilesApp/TileSettingsWindow.swift` | `connectorBlock` becomes one `wiring.block(context)` |
| `Sources/PixbarTilesApp/PanelGlyphs.swift` | `tile(forConnectorId:)` becomes a lookup |
| `Sources/PixbarTilesApp/TileScheduler.swift` | `reconcileTiles` calls `arrived`/`left` |

---

### Task 1: `TileKind` and the six kinds (kit)

**Files:**
- Create: `Sources/PixbarKit/Tiles/TileKind.swift`, `Sources/PixbarKit/Tiles/Kinds/*.swift`
- Modify: the five config types gain `TileParameters` (`WeatherTileConfig`, `VPNTileConfig`, `ZaiTileConfig`, `ClaudeTileConfig`, `GitHubTileConfig`)
- Test: `Tests/PixbarKitTests/TileKindsTests.swift`

**Interfaces — Produces:**

```swift
public protocol TileParameters: Codable, Sendable, Equatable {}
public struct NoParameters: TileParameters { public init() {} }

public protocol TileKind: Sendable {
    associatedtype Parameters: TileParameters
    static var id: String { get }
    static var presentation: TilePresentation { get }
    static var models: Set<ClockModel> { get }
    static var instancing: Instancing { get }       // default .single
    static var isAudible: Bool { get }              // default false
    static func secondaryName(of tile: TileRecord, parameters: Parameters?) -> String?  // default nil
}

public enum TileKinds {
    public static let all: [any TileKind.Type]      // weather, claude, zai, github, anecdotes, vpn
    public static func kind(id: String) -> (any TileKind.Type)?
}
```

The facts each kind carries are exactly what the code answers today:

| Kind | id | models | instancing | isAudible | Parameters |
|---|---|---|---|---|---|
| Weather | `WeatherConnector.appName` | awtrix3, ulanziTC002 | single | false | `WeatherTileConfig` |
| Claude | `ClaudeUsageConnector.id` | awtrix3, ulanziTC002 | single | false | `ClaudeTileConfig` |
| Zai | `ZaiUsageConnector.connectorId` | awtrix3, ulanziTC002 | single | false | `ZaiTileConfig` |
| GitHub | `GitHubConnector.connectorId` | awtrix3, ulanziTC002 | perKey | false | `GitHubTileConfig` |
| Anecdotes | `"anecdotes"` | awtrix3 | single | true | `NoParameters` |
| VPN | `VPNConnector.id` | awtrix3 | perKey | false | `VPNTileConfig` |

`presentation` is the row of today's `TilePresentation.of(connectorId:)` table for that id. The GitHub and VPN `secondaryName` bodies are the two arms of today's `TilePresentation.secondaryName(of:)`.

- [ ] **Step 1: Write the failing test.** It checks four things:
  - the ids in `TileKinds.all` are unique;
  - `kind(id:)` finds each kind and answers nil for `"nope"`;
  - each kind's `presentation`, `models`, `instancing` and `isAudible` equal a table written out literally in the test (the one above plus today's presentation rows);
  - `models` equals what `TileCandidate(connector)` computes for the shipped connectors, for weather, claude, zai and github.
- [ ] **Step 2:** `swift test --no-parallel --filter TileKindsTests`. Expected: it does not compile (`TileKinds` is missing).
- [ ] **Step 3:** Implement `TileKind.swift`, the six kinds, and the `TileParameters` conformances. A config that is only `Equatable, Sendable` today gains `Codable` through the conformance it already has in an extension.
- [ ] **Step 4:** The kit suite passes (1383 plus the new tests).
- [ ] **Step 5:** Commit `feat(kit): TileKind — every tile's catalogue facts in one type, listed once`.

### Task 2: `TileConfig` as a struct behind its facade (kit)

**Files:**
- Modify: `Sources/PixbarKit/Tiles/TileConfig.swift`
- Test: `Tests/PixbarKitTests/TileConfigStructTests.swift`

**Interfaces:**
- Consumes: `TileKinds`, `TileKind.Parameters`.
- Produces:

```swift
public struct TileConfig: Equatable, Sendable, Codable {
    public let kindId: String
    public let value: any TileParameters
    public init<P: TileParameters>(_ value: P, kind: some TileKind.Type)  // kind.Parameters == P
    public func value<P: TileParameters>(as type: P.Type) -> P?
    // facade, unchanged in spelling:
    public static func weather(_ c: WeatherTileConfig) -> TileConfig
    public static func weather(_ place: Coordinates) -> TileConfig
    public static func vpn(_ c: VPNTileConfig) -> TileConfig
    public static func zai(_ c: ZaiTileConfig) -> TileConfig
    public static func claude(_ c: ClaudeTileConfig) -> TileConfig
    public static func github(_ c: GitHubTileConfig) -> TileConfig
    public var weatherConfig, location, lamp, key, claudeConfig, github, parameters
}
```

Decoding reads the single key, finds the kind with `TileKinds.kind(id:)`, and decodes that kind's `Parameters` through `extension TileKind { static func decodeParameters(from: KeyedDecodingContainer<AnyKey>, key: AnyKey) throws -> any TileParameters }`. Zero keys, two keys or an unknown key throw `dataCorrupted`, with the message "a tile config names exactly one connector" for the key-count case. Equality compares `kindId` and then `value` through `extension TileParameters { func isEqual(_ other: any TileParameters) -> Bool }`.

- [ ] **Step 1: Write the failing test.** It covers:
  - round trips of the five JSON shapes in the header comment, including legacy `{"claude":"daily"}`, compared byte for byte after re-encoding;
  - that `{}`, `{"weather":{…},"vpn":{…}}` and `{"nope":{}}` throw;
  - `value(as:)` for the right type and a wrong one;
  - equality across and within kinds.
- [ ] **Step 2:** It fails to compile (`value(as:)`, `kindId` are missing).
- [ ] **Step 3:** Rewrite `TileConfig.swift`. Move `TileSecretsTests`' `case let .zai(config)?` to `config?.key`.
- [ ] **Step 4:** Both suites pass. No other test changes.
- [ ] **Step 5:** Commit `refactor(kit): TileConfig is a kind id and its parameters; the JSON and the facade stay`.

### Task 3: The catalogue reads the kinds (kit)

**Files:**
- Modify: `Sources/PixbarKit/Tiles/TileCatalogue.swift`
- Test: `Tests/PixbarKitTests/TileCatalogueKindsTests.swift`

**Interfaces:** Changes are internal only; the public API is unchanged.
- `TilePresentation.of(connectorId:)` answers `TileKinds.kind(id:)?.presentation`, or the "unknown app" mark for an unknown id.
- `TilePresentation.secondaryName(of:)` asks the kind, passing it the tile's parameters opened to the kind's type.
- `TileCandidate.init(_ connector:)` takes `models` from the kind when there is one, and falls back to today's face inference for an id that no kind knows.
- `TileCandidate.init(_ vpn:)` reads `VPNKind`.

- [ ] **Step 1: Write the failing test.** For every kind, `TileCandidate(connectorId:…)` built from `kind.presentation` equals today's literal values. A test-only kind that is registered nowhere keeps the "unknown app" mark. The test fails because presentation is still the switch: the unregistered kind's id falls into `default`, and a fake kind declaring a different icon exposes the old table.
- [ ] **Step 2:** Run it and confirm it fails.
- [ ] **Step 3:** Replace the switches with lookups.
- [ ] **Step 4:** Both suites pass.
- [ ] **Step 5:** Commit `refactor(kit): the catalogue asks the kinds, not a switch on the connector id`.

### Task 4: `TileKindWiring` and the six wirings — factories, naming, glyph, refresh flag (app)

**Files:**
- Create: `Sources/PixbarTilesApp/Kinds/TileKindWiring.swift`, `Sources/PixbarTilesApp/Kinds/*Wiring.swift`
- Modify: `ConnectorFactories.swift` (the registry becomes a loop), `PanelGlyphs.swift` (`tile(forConnectorId:)` becomes a lookup), `TileSettingsWindow.swift` (`namesItsOwnRefresh` reads the wiring), `AppComposition.swift` (the naming instances come from the wirings)
- Test: `Tests/PixbarTilesAppTests/TileKindWiringTests.swift`

**Interfaces — Produces:**

```swift
struct TileEnvironment {
    let transport: any Transport
    let defaults: UserDefaults
    let secrets: any SecretStoring
    let weather: OpenMeteoSource
    let anecdotes: any Connector
    let claudeReporter: @Sendable () -> any ClaudeUsageReporting
}

@MainActor protocol TileKindWiring {
    associatedtype Kind: TileKind
    /// Built once per clock; nil for a kind that is not a Connector (the VPN lamp).
    func factory(for clock: ClockRecord, _ env: TileEnvironment) -> ((TileRecord) -> any Connector)?
    /// The instance the app registry holds for naming; nil where the registry gets it elsewhere.
    func namingInstance(_ env: TileEnvironment) -> (any Connector)?
    var glyph: [String] { get }
    var namesItsOwnRefresh: Bool { get }            // default false
}

enum AppTileKinds {
    static let all: [any TileKindWiring]
    static func wiring(for connectorId: String) -> (any TileKindWiring)?
}
```

Each wiring's `factory` is today's `register(factory:)` closure for its id. The per-clock state it closes over moves with it: the stored place, the reporter, and the GitHub snapshots, diagnoses and refusals. `namingInstance` returns today's `namingInstances` entry, for zai and github. Anecdotes registers the shared instance. The glyphs are today's (`weatherTile`, `terminalTile` for claude and zai, `anecdoteTile`, `vpnTile`, `githubTile`). `namesItsOwnRefresh` is true for weather, claude and zai.

- [ ] **Step 1: Write the failing test.** It checks that:
  - every `TileKinds.all` id has exactly one wiring, and every wiring's `Kind.id` is in `TileKinds.all`;
  - `ConnectorFactories.registry(for:)` holds a connector for exactly the ids whose wiring returns a factory, plus anecdotes;
  - `PanelGlyphs.tile(forConnectorId:)` answers each wiring's glyph, and `unknownTile` for `"nope"`;
  - `namesItsOwnRefresh` is true exactly for weather, claude and zai.
- [ ] **Step 2:** It fails to compile (`AppTileKinds` is missing).
- [ ] **Step 3:** Implement the wirings and rewire the four readers.
- [ ] **Step 4:** Both suites pass. The existing registry, glyph and settings tests stay unchanged.
- [ ] **Step 5:** Commit `refactor(app): one wiring per kind builds its connectors and wears its glyph`.

### Task 5: The settings block comes from the wiring (app)

**Files:**
- Modify: `Kinds/TileKindWiring.swift` (block API), the six wirings, `TileSettingsWindow.swift` (`connectorBlock` becomes one call)
- Test: `Tests/PixbarTilesAppTests/TileBlockContextTests.swift`

**Interfaces — Produces:**

```swift
struct TileBlockActions {
    let loadHistory: @MainActor () -> Void             // opens the anecdote history sheet
    let hasZaiKey: Bool; let zaiOutcome: AppModel.ZaiKeyOutcome?
    let saveZaiKey: @MainActor (String) -> Void
    let hasGitHubToken: Bool; let gitHubOutcome: AppModel.TokenOutcome?
    let saveGitHubToken: @MainActor (String) -> Void
    let setGitHubRepo: @MainActor (String) -> Void
    let changeLampVPN: @MainActor (String) -> Void
    let claudeCode: ClaudeCodeLink
}

struct TileBlockContext<P: TileParameters> {
    let key: TileKey
    let parameters: Binding<P?>                          // saved through TileSettingsModel.setParameters(_:)
    let refresh: TileRefreshControl                      // ladder + policy binding, label chosen by the wiring
    let settings: TileSettingsModel                      // the weather block's draft lives here
    let actions: TileBlockActions
}

extension TileKindWiring {
    associatedtype Block: View                           // on the protocol, default EmptyView
    @ViewBuilder func block(_ context: TileBlockContext<Kind.Parameters>) -> Block
}
```

`TileSettingsModel` gains one generic `setParameters<P: TileParameters>(_ value: P, kind: some TileKind.Type)`, which saves `TileConfig(value, kind:)` through `model.saveTile`. The typed setters that already exist stay, because the weather block uses them.

- [ ] **Step 1: Write the failing test.** Build a context for a GitHub tile and set `parameters` to a new repo config; the tile's stored config then changes. `AppTileKinds.wiring(for:)` of an id with no block renders an `EmptyView` (checked through `type(of:)`).
- [ ] **Step 2:** Run it and confirm it fails.
- [ ] **Step 3:** Move each branch of `connectorBlock` into its wiring's `block`. The window keeps `parametersBlock` and `lampBlock` as helpers the wirings call.
- [ ] **Step 4:** Both suites pass. The window's tests stay unchanged.
- [ ] **Step 5:** Commit `refactor(app): a tile's settings block is its wiring's`.

### Task 6: `arrived` / `left` hooks (app)

**Files:**
- Modify: `Kinds/TileKindWiring.swift`, `TileScheduler.swift`, `AppModel.swift` (wiring of the actions)
- Test: `Tests/PixbarTilesAppTests/TileArrivalTests.swift`

**Interfaces — Produces:**

```swift
struct TileArrivalActions {
    let run: @MainActor (TileKey) -> Void                // TileRunner.runNow
    let show: @MainActor (TileKey) -> Void               // PageFollower.showOnClock
    let idle: @MainActor (TileKey) -> Void               // the TC002 session's markIdle
    let morningTile: @MainActor (_ clockId: UUID, _ excluding: TileKey) -> TileKey?
}

extension TileKindWiring {
    func arrived(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions)  // default nothing
    func left(_ key: TileKey, _ parameters: Kind.Parameters?, _ actions: TileArrivalActions)     // default nothing
}
```

`TileScheduler` takes `wirings: @MainActor (String) -> (any TileKindWiring)?`, which defaults to `AppTileKinds.wiring(for:)`, and `arrivalActions: TileArrivalActions`. `reconcileTiles` keeps what it does today. For every key in `change.arrived` and `change.left`, it also calls the wiring's hook with the tile's parameters. `morningTile` answers the first tile on that clock, in stored order, that owns a page and is not `excluding`.

- [ ] **Step 1: Write the failing test.** A test wiring records its calls. A tile's window opens (the policy's hours begin) and then closes; each hook is called once, with the key and parameters. A tile with no change calls nothing.
- [ ] **Step 2:** Run it and confirm it fails.
- [ ] **Step 3:** Implement it.
- [ ] **Step 4:** Both suites pass. The `reconcileTiles` tests stay unchanged.
- [ ] **Step 5:** Commit `feat(app): a wiring hears its tile's window open and close`.

---

## Self-review

- **Spec coverage (§1).**

  | Spec item | Task |
  |---|---|
  | `TileParameters`, `TileKind`, `TileKinds` | 1 |
  | `TileConfig` struct, coding, facade, generic access | 2 |
  | Presentation, secondary name and candidate read the kind | 3 |
  | `TileEnvironment`, factory, naming, glyph, refresh flag | 4 |
  | Block, context, one generic `setParameters` | 5 |
  | `arrived`/`left`, `TileArrivalActions` | 6 |
  | Exhaustiveness test (unique id, round trip, one wiring each) | 1, 2, 4 |

  Migrations do not change, as the spec says.
- **Deliberate deviations.**
  - `factory` and `namingInstance` are optional. The VPN lamp is not a `Connector`, and weather, claude and anecdotes reach the app registry another way today.
  - `TileBlockContext` carries `settings` because the weather draft is the weather wiring's business, which the spec allows. Every other action it carries is a narrow closure.
- **Consistency.** These names are used identically across tasks: `TileKinds.kind(id:)`, `AppTileKinds.wiring(for:)`, `TileConfig(_:kind:)`, `value(as:)`, `TileArrivalActions`.

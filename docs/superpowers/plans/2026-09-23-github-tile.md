# GitHub Tile Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use dinopowers:executing-plans (wraps superpowers:executing-plans / subagent-driven-development) to implement this plan task by task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A GitHub tile that shows a repository's stars, forks and open PRs on either clock, several per clock, and celebrates new stars, forks and PRs.

**Architecture:** First three pieces of substrate: an encrypted secret store behind a port, scene tiles executed per `TileKey` rather than per connector, and an `Interruption` carried on `Delivery`. Then the connector (GraphQL client, pure event detector, persisted snapshot) and its faces. The TC002 face is a port of `.claude/skills/tc002-face-mockup/github/ggen.py` and is tested against fixtures recorded from it.

**Tech Stack:** Swift 6, Swift Testing (`@Suite` / `@Test`), CryptoKit, SwiftUI, Python 3 (the face oracle).

**Spec:** `docs/superpowers/specs/2026-09-23-github-tile-design.md`

## Global Constraints

- Platform `.macOS(.v26)`; package `PixelClockTiles`, kit `PixelClockKit`, app `PixelClockTilesApp`, tests `PixelClockKitTests` / `PixelClockTilesAppTests`.
- The arbiter is `swift test --no-parallel`. Use `swift test --filter <Suite>` while iterating, and run the full no-parallel suite before every commit. Wall-clock tests can flake under load (docs/HANDOFF.md). Re-run a red one alone before you treat it as a defect.
- TDD: write the failing test, watch it fail, then implement. Never edit a test that pins existing business behaviour to make it pass. Moving a test is allowed; rewriting its assertion is not.
- Comments match the codebase: they explain why and what was measured, the way the neighbouring files do.
- `AppModel.live` must not grow. New wiring goes in `ConnectorFactories` (Task 4).
- TC002 face pixels come only from `ggen.py`. Change the Python, re-record fixtures with the script, then change Swift. Never hand-edit a fixture.
- The TC002 GIF ceilings are ≤ 480 frames and ≤ 136 000 base64 bytes. Do not lower them.
- Star gold `#FFD84A`, fork `#58A6FF`, PR `#3FB950`, person glyph `#909090`, labels `#606060`, dim `#404040`.
- The PAT lives under `SecretAccount.connector("github")`. Never log it, never put it in a tile record.
- Commits: conventional (`feat(scope):`, `test:`, `refactor:`), English, ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`. Commit in the worktree only. No push.

## File map

| File | Responsibility | Task |
|---|---|---|
| `Sources/PixelClockKit/Secrets/SecretStoring.swift` (moved from `Zai/TileKeyStoring.swift`) | port, `SecretAccount`, `MemorySecretStore`, `LoginKeychainStore` (legacy, migration only) | 1 |
| `Sources/PixelClockKit/Secrets/EncryptedFileSecretStore.swift` | AES-GCM file store, HKDF key from the hardware id | 1 |
| `Sources/PixelClockKit/Secrets/HardwareIdentity.swift` | `IOPlatformUUID` reader | 1 |
| `Sources/PixelClockTilesApp/SecretsMigration.swift` | one-time keychain → file move | 2 |
| `Sources/PixelClockKit/Connectors/Connector.swift`, `ConnectorRegistry.swift` | `instancing`, per-tile factories | 3 |
| `Sources/PixelClockKit/Tiles/TileRecord.swift` | `TileKey.tileId` | 3 |
| `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`, `Scheduling/DeliveryChain.swift` | run per tile id | 3 |
| `Sources/PixelClockTilesApp/ConnectorFactories.swift` | every connector's per-tile construction | 4 |
| `Sources/PixelClockTilesApp/AppModel.swift`, `UlanziClockHost.swift` | schedule and events per `TileKey` | 4 |
| `Sources/PixelClockKit/Connectors/Interruption.swift`, `Delivery.swift` | the interruption | 5 |
| `Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift` | overwrite + restore | 5 |
| `Sources/PixelClockKit/GitHub/GitHubAPI.swift` | GraphQL client | 6 |
| `Sources/PixelClockKit/GitHub/GitHubEvents.swift` | snapshot, detector, reading | 7 |
| `Sources/PixelClockKit/GitHub/GitHubConnector.swift`, `GitHubTileConfig.swift` | the connector | 8 |
| `Sources/PixelClockKit/GitHub/GitHubFace.swift`, `GitHubGlyphs.swift` | the TC002 face | 9 |
| `Scripts/make_github_face_oracle.py`, `Tests/PixelClockKitTests/Fixtures/github_face_oracle.json` | the oracle | 9 |
| `Sources/PixelClockKit/GitHub/GitHubAwtrixFace.swift` | the TC001 face | 10 |
| `Sources/PixelClockTilesApp/GitHubTileBlock.swift`, `PanelGlyphs.swift` | settings block, pixel `?` | 11 |

---

### Task 1: Secrets port and encrypted file store (S1a)

**Files:**
- Move: `Sources/PixelClockKit/Zai/TileKeyStoring.swift` → `Sources/PixelClockKit/Secrets/SecretStoring.swift`
- Create: `Sources/PixelClockKit/Secrets/EncryptedFileSecretStore.swift`, `Sources/PixelClockKit/Secrets/HardwareIdentity.swift`
- Move + extend: `Tests/PixelClockKitTests/TileKeyStoringTests.swift` → `Tests/PixelClockKitTests/SecretStoringTests.swift`
- Create: `Tests/PixelClockKitTests/EncryptedFileSecretStoreTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public enum SecretAccount: Hashable, Sendable, Codable {
      case tile(TileKey)
      case connector(String)
      /// Stable string form, the file's JSON key: "tile:<clockId>.<connectorId>.<instance>" / "connector:<id>"
      public var storageKey: String { get }
  }
  public protocol SecretStoring: Sendable {
      func secret(for account: SecretAccount) -> String?
      func save(_ secret: String, for account: SecretAccount) throws
      func remove(for account: SecretAccount) throws
  }
  public final class MemorySecretStore: SecretStoring, @unchecked Sendable
  public final class EncryptedFileSecretStore: SecretStoring, @unchecked Sendable {
      public init(fileURL: URL, hardwareId: @escaping @Sendable () -> String?)
      public static func live() -> EncryptedFileSecretStore   // Application Support/PixelClockTiles/secrets.enc, HardwareIdentity.platformUUID
  }
  public enum HardwareIdentity { public static func platformUUID() -> String? }
  public struct SecretStoreError: Error, Equatable, Sendable { public let reason: String }
  ```
  `LoginKeychainStore` keeps its `key(for: String)` / `removeKey(for:)` API unchanged. It is legacy, used only by Task 2's migration. The `TileKeyStoring` protocol is deleted after Task 2 moves its last user.

- [ ] **Step 1: Move the contract tests and run them against both stores.** `git mv` the test file. Turn each existing test into a parameterised `@Test(arguments:)` over `[any SecretStoring]` factories: `{ MemorySecretStore() }` and `{ EncryptedFileSecretStore(fileURL: tmpFile(), hardwareId: { "HW-1" }) }`. Keep every assertion as it is and only replace the account strings with `SecretAccount`: round-trip, replace, remove-missing succeeds, missing reads nil.

- [ ] **Step 2: Write the file-store tests.**

```swift
@Suite struct EncryptedFileSecretStoreTests {
    func tmpFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("secrets.enc")
    }

    @Test func aFileWrittenOnOneMachineDoesNotOpenOnAnother() throws {
        let url = tmpFile()
        try EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
            .save("ghp_x", for: .connector("github"))
        #expect(EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-2" })
            .secret(for: .connector("github")) == nil)
        #expect(EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
            .secret(for: .connector("github")) == "ghp_x")
    }

    @Test func theSecretIsNotOnDiskInTheClear() throws {
        let url = tmpFile()
        try EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
            .save("ghp_secret_value", for: .connector("github"))
        let bytes = try Data(contentsOf: url)
        #expect(bytes.prefix(5) == Data("PCTS".utf8) + Data([1]))
        #expect(bytes.range(of: Data("ghp_secret_value".utf8)) == nil)
    }

    @Test func aTruncatedFileReadsAsNoSecretsAndTheNextSaveReplacesIt() throws {
        let url = tmpFile()
        let store = EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
        try store.save("a", for: .connector("github"))
        try Data(contentsOf: url).prefix(9).write(to: url)
        #expect(store.secret(for: .connector("github")) == nil)
        try store.save("b", for: .connector("github"))
        #expect(store.secret(for: .connector("github")) == "b")
    }

    @Test func anUnknownVersionReadsAsNoSecrets() throws {
        let url = tmpFile()
        let store = EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" })
        try store.save("a", for: .connector("github"))
        var bytes = try Data(contentsOf: url)
        bytes[4] = 9
        try bytes.write(to: url)
        #expect(store.secret(for: .connector("github")) == nil)
    }

    @Test func theFileIsOwnerOnly() throws {
        let url = tmpFile()
        try EncryptedFileSecretStore(fileURL: url, hardwareId: { "HW-1" }).save("a", for: .connector("github"))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func noHardwareIdRefusesToSaveRatherThanWritingAWeakKey() {
        let store = EncryptedFileSecretStore(fileURL: tmpFile(), hardwareId: { nil })
        #expect(throws: SecretStoreError.self) { try store.save("a", for: .connector("github")) }
        #expect(store.secret(for: .connector("github")) == nil)
    }

    @Test func tileAndConnectorAccountsDoNotCollide() throws {
        let store = EncryptedFileSecretStore(fileURL: tmpFile(), hardwareId: { "HW-1" })
        let key = TileKey(clockId: UUID(), connectorId: "github", instance: "")
        try store.save("tile", for: .tile(key))
        try store.save("conn", for: .connector("github"))
        #expect(store.secret(for: .tile(key)) == "tile")
        #expect(store.secret(for: .connector("github")) == "conn")
    }
}
```

- [ ] **Step 3: Run the new tests to verify they fail.** Run `swift test --filter "SecretStoringTests|EncryptedFileSecretStoreTests"`. They should fail to compile because the types do not exist yet.

- [ ] **Step 4: Implement.** In `SecretStoring.swift`, put `SecretAccount` (its `storageKey` uses `clockId.uuidString`), the protocol, and `MemorySecretStore` (lock plus dictionary, the old fixture's shape). Keep `LoginKeychainStore` and `TileKeyError` unchanged below them.

`EncryptedFileSecretStore`:

```swift
import CryptoKit
import Foundation

public final class EncryptedFileSecretStore: SecretStoring, @unchecked Sendable {
    static let magic = Data("PCTS".utf8)
    static let version: UInt8 = 1
    /// Compiled in so the key needs the app AND the machine; not a secret on its own.
    static let salt = Data((0..<32).map { UInt8(truncatingIfNeeded: $0 &* 37 &+ 11) })
    static let info = Data("PixelClockTiles secrets v1".utf8)

    private let fileURL: URL
    private let hardwareId: @Sendable () -> String?
    private let lock = NSLock()

    public init(fileURL: URL, hardwareId: @escaping @Sendable () -> String?) {
        self.fileURL = fileURL
        self.hardwareId = hardwareId
    }

    public static func live() -> EncryptedFileSecretStore {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PixelClockTiles", isDirectory: true)
        return EncryptedFileSecretStore(
            fileURL: dir.appendingPathComponent("secrets.enc"),
            hardwareId: { HardwareIdentity.platformUUID() })
    }

    private func key() -> SymmetricKey? {
        guard let id = hardwareId(), !id.isEmpty else { return nil }
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: Data(id.utf8)),
            salt: Self.salt, info: Self.info, outputByteCount: 32)
    }

    /// Every failure to open reads as "no secrets": a secret that cannot be
    /// read is one the user pastes again, and refusing to start is worse.
    private func load() -> [String: String] {
        guard let key = key(), let bytes = try? Data(contentsOf: fileURL),
              bytes.count > 5, bytes.prefix(4) == Self.magic, bytes[4] == Self.version,
              let box = try? AES.GCM.SealedBox(combined: bytes.dropFirst(5)),
              let plain = try? AES.GCM.open(box, using: key),
              let map = try? JSONDecoder().decode([String: String].self, from: plain)
        else { return [:] }
        return map
    }

    private func store(_ map: [String: String]) throws {
        guard let key = key() else { throw SecretStoreError(reason: "no hardware identity") }
        let plain = try JSONEncoder().encode(map)
        guard let sealed = try AES.GCM.seal(plain, using: key).combined else {
            throw SecretStoreError(reason: "seal produced no combined form")
        }
        let dir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".secrets-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: tmp.path, contents: Self.magic + Data([Self.version]) + sealed,
                                       attributes: [.posixPermissions: 0o600])
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: tmp)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func secret(for account: SecretAccount) -> String? {
        lock.withLock { load()[account.storageKey] }
    }

    public func save(_ secret: String, for account: SecretAccount) throws {
        try lock.withLock {
            var map = load()
            map[account.storageKey] = secret
            try store(map)
        }
    }

    public func remove(for account: SecretAccount) throws {
        try lock.withLock {
            var map = load()
            guard map.removeValue(forKey: account.storageKey) != nil else { return }
            try store(map)
        }
    }
}
```

`HardwareIdentity.platformUUID()` reads `kIOPlatformUUIDKey` from `IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))` through `IORegistryEntryCreateCFProperty`. Release the service with `IOObjectRelease`. Add `.linkedFramework("IOKit")` to the kit target in `Package.swift` if the build needs it.

- [ ] **Step 5: Run the tests to verify they pass.** Run `swift test --filter "SecretStoringTests|EncryptedFileSecretStoreTests"`. Expected: PASS.

- [ ] **Step 6: Commit.** `feat(secrets): an encrypted file store behind a secret port, keyed per tile or per connector`

### Task 2: Move z.ai onto the port, migrate the keychain (S1b)

**Files:**
- Create: `Sources/PixelClockTilesApp/SecretsMigration.swift`, `Tests/PixelClockTilesAppTests/SecretsMigrationTests.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`init(keychain:)` → `init(secrets: any SecretStoring = EncryptedFileSecretStore.live())`, `saveZaiKey`, `hasZaiKey`, `live`), `Sources/PixelClockKit/Zai/ZaiTileConfig.swift`, `Sources/PixelClockTilesApp/TileSettingsModel.swift`, `Sources/PixelClockTilesApp/TileSettingsWindow.swift`, and the tests that name `MemoryKeychainStore` (`ZaiTileWiringTests`, `UsageFaceSettingsTests`, `Doubles.swift`), which switch to `MemorySecretStore`.

**Interfaces:**
- Consumes: Task 1's `SecretStoring`, `SecretAccount.tile(_:)`, `LoginKeychainStore.key(for:)` / `removeKey(for:)`.
- Produces: `struct SecretsMigration { static let markerKey = "migration.secretsToFile"; init(defaults:, keychain: LegacyKeychainReading, secrets: any SecretStoring); func run() }`, where `protocol LegacyKeychainReading { func key(for: String) -> String?; func removeKey(for: String) throws }`. `LoginKeychainStore` conforms, and tests stub it.
- A z.ai key is read from `secrets.secret(for: .tile(key))`, with the full `TileKey` including its instance. `ZaiTileConfig.keyAccount` stays in the record and is used only to find the legacy item.

- [ ] **Step 1: Write the failing migration tests.** Mirror `VPNTileMigrationTests`, with `MigrationFixtures` for defaults and a z.ai tile record whose `config` is `.zai(ZaiTileConfig(keyAccount: "<clock>.zai", …))`.
  - `movesEveryZaiKeyAndDeletesTheKeychainItem`: the stub keychain holds the account, then `secrets.secret(for: .tile(key)) == "k"` and the stub records a removal.
  - `aRefusedReadLeavesTheItemAndStillSetsTheMarker`: the stub returns nil. Nothing is saved, the marker is set, and nothing is removed.
  - `runsOnce`: a second `run()` makes no keychain calls.
  - `aTileWithoutAKeyIsSkipped`.
- [ ] **Step 2: Run** `swift test --filter SecretsMigrationTests` and confirm it FAILS.
- [ ] **Step 3: Implement `SecretsMigration`** in the `VPNTileMigration` shape: guard on the marker, iterate `TileStore(defaults:).all()` where `config?.key != nil`, read `keychain.key(for: keyAccount)`, save it under `.tile(record.key)`, then `removeKey`. Set the marker last. Call it in `AppModel.live` beside the other migrations, before the first registry is built.
- [ ] **Step 4: Rewire z.ai.** In the app the z.ai key closure becomes `{ secrets.secret(for: .tile(tileKey)) }`, `saveZaiKey` saves or removes `.tile(key)`, and `hasZaiKey` reads it. Delete the `TileKeyStoring` protocol and `MemoryKeychainStore`. Keep `LoginKeychainStore`, now conforming to `LegacyKeychainReading`.
- [ ] **Step 5: Run** `swift test --no-parallel`. Expected: all PASS, including the moved z.ai wiring tests with their assertions unchanged.
- [ ] **Step 6: Commit.** `feat(secrets): z.ai keys leave the keychain for the encrypted file, moved once`

### Task 3: Instanced tiles in the kit (S2a)

**Files:**
- Modify: `Sources/PixelClockKit/Tiles/TileRecord.swift`, `Sources/PixelClockKit/Connectors/Connector.swift`, `Sources/PixelClockKit/Connectors/ConnectorRegistry.swift`, `Sources/PixelClockKit/Tiles/TileCatalogue.swift`, `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift`, `Sources/PixelClockKit/Tiles/TileSettingsStore.swift`
- Test: `Tests/PixelClockKitTests/TileKeyTests.swift` (new), `ConnectorRegistryTests.swift`, `TileCatalogueTests.swift`, `AwtrixClockSessionTests.swift` (extend)

**Interfaces:**
- Produces:
  ```swift
  extension TileKey {
      /// The key's name on the wire and in custody: the connector id alone for a
      /// single tile — every page already on a clock keeps its name — else "<connectorId>.<instance>".
      public var tileId: String { get }
  }
  extension Connector { public var instancing: Instancing { .single } }   // requirement + default
  public final class ConnectorRegistry {
      public typealias Factory = @Sendable (TileRecord) -> any Connector
      public func register(factory: @escaping Factory, for connectorId: String)
      /// The connector that runs THIS tile: its factory's product, else the registered connector.
      public func connector(for tile: TileRecord) -> (any Connector)?
  }
  // AwtrixClockSession: runOnce(tile: TileRecord) / maintain(tile:) / nextDelay(tile:interval:);
  // settings and backoff are keyed by tile.key.tileId.
  // TileSettingsStore: storedSettings(for key: TileKey) keyed with the instance.
  ```
  `runOnce(connectorId:)` stays as a thin overload that builds a `TileRecord` with an empty instance, so the existing tests keep passing until Task 4 moves the callers.

- [ ] **Step 1: Write the failing tests.**
```swift
@Test func aSingleTileKeepsItsConnectorIdAsItsName() {
    #expect(TileKey(clockId: UUID(), connectorId: "weather").tileId == "weather")
}
@Test func anInstancedTileIsNamedByConnectorAndInstance() {
    #expect(TileKey(clockId: UUID(), connectorId: "github", instance: "artk0de/tea-rags").tileId
            == "github.artk0de/tea-rags")
}
@Test func aFactoryBuildsTheConnectorForItsOwnTile() {
    let registry = ConnectorRegistry()
    registry.register(factory: { tile in StubConnector(id: "github", tag: tile.key.instance) }, for: "github")
    let a = TileRecord(key: TileKey(clockId: UUID(), connectorId: "github", instance: "a/x"),
                       policy: TilePolicyRecord(isPaused: false, refreshSeconds: 60))
    #expect((registry.connector(for: a) as? StubConnector)?.tag == "a/x")
}
@Test func aPerKeyConnectorAlreadyOnTheClockIsStillListed() {
    // TileCandidate(connector) with instancing .perKey → availability .available even
    // with a tile of that connector on the clock.
}
@Test func twoInstancesBackOffIndependently() async {
    // AwtrixClockSession with a failing connector for instance "a" and a succeeding one
    // for "b": nextDelay(tile: a) grows, nextDelay(tile: b) == interval.
}
```
  Fill in the last two tests with the doubles those suites already use (`StubConnector` in `ConnectorRegistryTests`, the session's recording device in `AwtrixClockSessionTests`). The `tag` property is added to the test double, not to production code.
- [ ] **Step 2: Run** `swift test --filter "TileKeyTests|ConnectorRegistryTests|TileCatalogueTests|AwtrixClockSessionTests"` and confirm it FAILS.
- [ ] **Step 3: Implement.**
  - `tileId`: `instance.isEmpty ? connectorId : "\(connectorId).\(instance)"`.
  - `instancing` becomes a protocol requirement with a default in the `extension Connector` that holds the other defaults.
  - `TileCandidate.init(_ connector:)` passes `connector.instancing`.
  - The registry gets a `factories: [String: Factory]` next to `storage`, under the same lock.
  - The session looks connectors up with `connector(for:)`. `DeliveryChain` already keys on a string, so the session passes `tile.key.tileId`.
- [ ] **Step 4: Run** `swift test --no-parallel`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(tiles): scene connectors run per tile — a key names its tile, a factory builds its connector`

### Task 4: Instanced tiles in the app, and wiring out of `AppModel.live` (S2b)

**Files:**
- Create: `Sources/PixelClockTilesApp/ConnectorFactories.swift`, `Tests/PixelClockTilesAppTests/InstancedTilesTests.swift`
- Modify: `Sources/PixelClockTilesApp/AppModel.swift` (`ConnectorRunning`, `UlanziConnectorRunning`, `tick`, `runAndReport`, `restock`, `noteNextRun`, `setPaused`, `removeTile`, `giveBackDeviceState`, `retract`, `connector(for:)`, `makeRegistry` → factories, `projected`), `Sources/PixelClockTilesApp/UlanziClockHost.swift`, `Sources/PixelClockTilesApp/StoreModel.swift`, `Tests/PixelClockTilesAppTests/Doubles.swift` (`SpyHost` records tile ids)

**Interfaces:**
- Consumes: Task 3's `TileKey.tileId`, `ConnectorRegistry.register(factory:for:)`, `connector(for:)`, the session's `runOnce(tile:)`.
- Produces:
  ```swift
  protocol ConnectorRunning: Sendable {
      func maintain(tile: TileRecord) async -> MaintenanceResult
      func runOnce(tile: TileRecord) async -> RunResult
      func deliver(_ output: AwtrixDelivery) async -> RunResult
      func nextDelay(tile: TileRecord, interval: TimeInterval) async -> TimeInterval
      func restoreDeviceState(borrowedBy tileId: String?) async
      var indicators: IndicatorCustody? { get }
  }
  /// Builds the per-clock registry: every connector as a factory over its own tile record.
  struct ConnectorFactories {
      init(transport: any Transport, defaults: UserDefaults, secrets: any SecretStoring,
           weather: OpenMeteoSource, anecdotes: any Connector)
      func registry(for clock: ClockRecord) -> ConnectorRegistry
  }
  ```
  Each factory reads its config from the `TileRecord` it receives: `tile.config?.weatherConfig`, `tile.config?.claude`, `.tile(tile.key)` for z.ai. The `.first { connectorId == }` closures are deleted.

- [ ] **Step 1: Write the failing tests** in `InstancedTilesTests`. Use `SpyHost` and `StubConnector` with `instancing: .perKey`.
  - `twoInstancesOnOneClockRunIndependently`: two keys, same connector, instances `a/x` and `b/y`. `tick` runs both, and the spy records `github.a/x` and `github.b/y`.
  - `pausingOneInstanceIdlesOnlyItsPage`: `markIdle(tileId: "github.a/x")` and nothing for `b/y`.
  - `removingOneInstanceReleasesOnlyItsPage`.
  - `aSingleTileKeepsItsPageName`: the weather tile still delivers to `"weather"`.
- [ ] **Step 2: Run** `swift test --filter InstancedTilesTests` and confirm it FAILS.
- [ ] **Step 3: Move `makeRegistry` into `ConnectorFactories.registry(for:)`.** This is a mechanical move plus the `TileRecord` parameter, so the moved code keeps its comments. `AppModel.live` calls `ConnectorFactories(...)` once and passes `factories.registry(for:)` where `makeRegistry` was. `AppModel.live` must get shorter. Check with `grep -c "" AppModel.swift` before and after.
- [ ] **Step 4: Carry the key everywhere.** Change the protocol and `UlanziClockHost` (`runOnce(tile:)` → `session.deliver(delivery, toTile: tile.key.tileId)`; `liveTiles` maps `\.key.tileId`). In `AppModel`, every `key.connectorId` handed to a host becomes `key.tileId`, and `storedTile(key)` supplies the `TileRecord`. `projected` drops its `instance.isEmpty` filter for scene connectors whose instancing is `.perKey`.
- [ ] **Step 5: Run** `swift test --no-parallel`. Expected: PASS. Existing wiring tests are updated only where a call signature changed (`connectorId:` → `tile:`). Their assertions stay as they are.
- [ ] **Step 6: Commit.** `refactor(app): the schedule and every tile event carry the whole key; connector wiring leaves AppModel.live`

### Task 5: Interruptions on `Delivery` (S3)

**Files:**
- Create: `Sources/PixelClockKit/Connectors/Interruption.swift`, `Tests/PixelClockKitTests/UlanziInterruptionTests.swift`
- Modify: `Sources/PixelClockKit/Connectors/Delivery.swift`, `Sources/PixelClockKit/Ulanzi/UlanziClockSession.swift`, `Sources/PixelClockKit/Awtrix/AwtrixClockSession.swift` (`send`), `Tests/PixelClockKitTests/AwtrixClockSessionTests.swift`

**Interfaces:**
- Produces:
  ```swift
  public struct Interruption<Scene: Sendable & Equatable>: Sendable, Equatable {
      public enum Scope: Sendable, Equatable { case everyPage, ownPage }
      public var scene: Scene
      public var scope: Scope
      public var duration: TimeInterval
      public init(scene: Scene, scope: Scope, duration: TimeInterval)
  }
  // Delivery gains `public var interruptions: [Interruption<Scene>]` (init parameter, default [];
  // the AWTRIX convenience init gains it too). Played in order, each on its own scope, so one read
  // that brings stars AND a fork shows both: the stars on every page, then the fork on its own.
  // UlanziClockSession gains an injected `sleep: @Sendable (TimeInterval) async -> Void`
  // (default Task.sleep) so tests drive the window.
  ```

- [ ] **Step 1: Write the failing TC002 tests.** Use the recording device the `UlanziClockSession` tests already use and an instant, recorded `sleep`.
```swift
@Test func everyPageIsOverwrittenThenRestoredFromTheBoard() async {
    // board: weather (showing W), zai (showing Z), github (showing G)
    // deliver github's delivery with interruption(scene: C, scope: .everyPage, duration: 8)
    // pushes, in order: pct-github=G, then pct-weather=C, pct-zai=C, pct-github=C,
    // then after sleep(8): pct-weather=W, pct-zai=Z, pct-github=G
}
@Test func ownPageTouchesOnlyItsTile() async { /* only pct-github gets C, then G */ }
@Test func anIdlePageReturnsIdle() async { /* markIdle(zai) first; restore pushes UlanziScene.idle */ }
@Test func interruptionsInOneDeliveryPlayInOrderEachOnItsScope() async {
    // interruptions [stars(.everyPage, 8), fork(.ownPage, 5)]: every page gets S, sleep(8),
    // then only pct-github gets F, sleep(5), then one restore pass over every page
}
@Test func aSecondInterruptionInsideTheWindowExtendsIt() async {
    // two deliveries with interruptions 2 s apart (the sleep stub records): one restore pass, after the later window
}
@Test func theBoardNeverHoldsTheCelebration() async {
    // after the interruption, lastScene(forTile: "weather") == W
}
```
- [ ] **Step 2: Write the failing TC001 test.**
```swift
@Test func anInterruptionIsANotificationWithItsJingleAfterTheApp() async {
    // produce: scene .app("github.a/x") "★1234", interruption scene .notification "★ +3 alice", jingle "coin:…", duration 8
    // device receives: custom app upsert, then notify(text: "★ +3 alice", rtttl: "coin:…", duration: 8)
}
```
- [ ] **Step 3: Run** `swift test --filter "UlanziInterruptionTests|AwtrixClockSessionTests"` and confirm it FAILS.
- [ ] **Step 4: Implement.** In `UlanziClockSession.deliver`, after the delivery's own push, for each entry of `interruptions` in order: pick targets (`board.tileIds` or `[tileId]`) and push the interruption frame to each through `chain.deliver` without `board.upsert`. sleep its duration before the next entry. After the last, record `restoreDue = now` plus the remaining window and the union of targets (union with any window already open). If no restore task is running, start one that sleeps until `restoreDue`, loops while a later interruption has moved `restoreDue`, then pushes `board.frame(forTile:)` for every target through the chain. In `AwtrixClockSession.send`, after the main scene, send each `interruptions[i].scene` in order through the same notification path (the device queues notifications itself) (its `jingle` and `duration` are already on the scene), ignoring `scope`.
- [ ] **Step 5: Run** `swift test --no-parallel`. Expected: PASS.
- [ ] **Step 6: Commit.** `feat(delivery): an interruption rides on a delivery — pages overwritten and restored on the TC002, a notification on AWTRIX`

### Task 6: GitHub GraphQL client (F1a)

**Files:**
- Create: `Sources/PixelClockKit/GitHub/GitHubAPI.swift`, `Tests/PixelClockKitTests/GitHubAPITests.swift`

**Interfaces:**
- Consumes: `Transport` (`Sources/PixelClockKit/Device/Transport.swift`).
- Produces:
  ```swift
  public struct GitHubRepoState: Sendable, Equatable {
      public var nameWithOwner: String
      public var stars: Int, forks: Int, openPRs: Int
      public var stargazers: [(login: String, starredAt: Date)]   // oldest → newest; wrap in a struct `Stargazer` for Equatable
      public var forkEvents: [(login: String, createdAt: Date)]    // struct `ForkEvent`
      public var openPRNumbers: [(number: Int, author: String)]    // struct `OpenPR`
  }
  public protocol GitHubReporting: Sendable { func state(of repo: String) async throws -> GitHubRepoState? }
  public struct GitHubAPI: GitHubReporting {
      public static let endpoint = URL(string: "https://api.github.com/graphql")!
      public init(transport: any Transport, token: @escaping @Sendable () -> String?)
      public enum Failure: Error, Equatable, Sendable { case status(Int), graphQL(String), badRepo(String) }
  }
  ```
  `state(of:)` returns nil when there is no token. It posts the spec's query with variables `owner` and `name` split from `repo`. Headers: `Authorization: Bearer <token>`, `Content-Type: application/json`, `User-Agent: PixelClockTiles`. An `errors` array in the body throws `.graphQL(firstMessage)`.

- [ ] **Step 1: Write the failing tests** with a recording transport shaped like `ZaiUsageConnectorTests`' `RoutingTransport` (a private copy in this file):
  - `noTokenAsksNothing`: nil result, zero requests.
  - `theRequestCarriesTheQueryAndTheBearer`: a POST to the endpoint with `Authorization == "Bearer t"`, a body JSON with `variables.owner == "artk0de"` and `variables.name == "tea-rags"`, and a query containing `stargazerCount`.
  - `aRecordedAnswerDecodes`: a fixture JSON string in the test with 1234 stars, 45 forks, 3 open PRs, two stargazers, one fork and PR #42 by dave, mapped field by field. Dates are ISO 8601.
  - `aGraphQLErrorThrows`: `{"errors":[{"message":"Could not resolve to a Repository"}]}` → `.graphQL("Could not resolve to a Repository")`.
  - `aRefusedTokenThrowsTheStatus`: 401 → `.status(401)`.
  - `aRepoWithoutASlashIsRefusedBeforeTheWire`: `.badRepo`, zero requests.
- [ ] **Step 2: Run** `swift test --filter GitHubAPITests` and confirm it FAILS.
- [ ] **Step 3: Implement** with `Decodable` mirror structs of the GraphQL response and an `ISO8601DateFormatter`. Map `stargazers.edges` into `Stargazer`, `forks.nodes` into `ForkEvent` (`owner.login`), and `openPRs.nodes` into `OpenPR` (`author?.login ?? "ghost"`).
- [ ] **Step 4: Run** `swift test --filter GitHubAPITests`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(github): a GraphQL client for a repository's counts and newest stars, forks and PRs`

### Task 7: Snapshot and event detector (F1b)

**Files:**
- Create: `Sources/PixelClockKit/GitHub/GitHubEvents.swift`, `Tests/PixelClockKitTests/GitHubEventsTests.swift`

**Interfaces:**
- Consumes: Task 6's `GitHubRepoState`.
- Produces:
  ```swift
  public struct GitHubSnapshot: Codable, Sendable, Equatable {
      public var lastStarAt: Date?, lastForkAt: Date?, openPRs: Set<Int>
      public var isBaseline: Bool { lastStarAt == nil && lastForkAt == nil && openPRs.isEmpty }
  }
  public struct GitHubEvents: Sendable, Equatable {
      public var newStars: [String] = []            // logins, newest first
      public var newForks: [String] = []
      public var newPRs: [OpenPR] = []              // newest first
      public var isEmpty: Bool { get }
  }
  public enum GitHubEventDetector {
      /// First call (snapshot nil) returns no events and the baseline.
      public static func detect(_ state: GitHubRepoState, since snapshot: GitHubSnapshot?)
          -> (events: GitHubEvents, snapshot: GitHubSnapshot)
  }
  public protocol GitHubSnapshotStoring: Sendable {
      func snapshot(for tile: TileKey) -> GitHubSnapshot?
      func save(_ snapshot: GitHubSnapshot, for tile: TileKey)
  }
  public struct UserDefaultsGitHubSnapshots: GitHubSnapshotStoring   // key "githubSnapshot.<tileId>.<clockId>"
  ```

- [ ] **Step 1: Write the failing tests.**
```swift
@Test func theFirstReadIsABaselineAndCelebratesNothing() {
    let (events, snap) = GitHubEventDetector.detect(state(stars: [("a", t0)]), since: nil)
    #expect(events.isEmpty)
    #expect(snap.lastStarAt == t0)
}
@Test func starsNewerThanTheLastSeenAreNewAndNewestFirst() {
    let (events, _) = GitHubEventDetector.detect(
        state(stars: [("a", t0), ("b", t1), ("c", t2)]), since: GitHubSnapshot(lastStarAt: t0, lastForkAt: nil, openPRs: []))
    #expect(events.newStars == ["c", "b"])
}
@Test func anUnstarAndAStarInOneIntervalStillCelebratesTheStar() {
    // count unchanged (unstar + star), but a starredAt > lastStarAt exists → one new star
}
@Test func aPROpenedAndAnotherMergedCelebratesTheOpenedOne() {
    // snapshot openPRs [41]; state openPRNumbers [42] → newPRs == [#42]
}
@Test func aClosedPRIsNotAnEvent() { /* snapshot [41,42], state [42] → none */ }
@Test func forksByCreatedAt() { /* like stars */ }
@Test func theSnapshotSurvivesTheStore() {
    let d = UserDefaults(suiteName: UUID().uuidString)!
    let store = UserDefaultsGitHubSnapshots(defaults: d)
    let key = TileKey(clockId: UUID(), connectorId: "github", instance: "a/x")
    store.save(GitHubSnapshot(lastStarAt: t1, lastForkAt: nil, openPRs: [7]), for: key)
    #expect(store.snapshot(for: key)?.openPRs == [7])
}
```
  (`state(...)` is a builder helper in the test file; `t0 < t1 < t2` are fixed dates.)
- [ ] **Step 2: Run** `swift test --filter GitHubEventsTests` and confirm it FAILS.
- [ ] **Step 3: Implement** the pure detector and the defaults-backed store (JSON-encoded `GitHubSnapshot`). The new snapshot always advances to the newest seen `starredAt` / `createdAt`, and `openPRs` becomes the current set.
- [ ] **Step 4: Run** `swift test --filter GitHubEventsTests`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(github): new stars, forks and PRs found by identity against a persisted snapshot`

### Task 8: The connector and its config (F1c)

**Files:**
- Create: `Sources/PixelClockKit/GitHub/GitHubConnector.swift`, `Sources/PixelClockKit/GitHub/GitHubTileConfig.swift`, `Tests/PixelClockKitTests/GitHubConnectorTests.swift`
- Modify: `Sources/PixelClockKit/Tiles/TileConfig.swift` (`github` case, `Key`, decode, encode, accessor `github`), `Sources/PixelClockKit/Tiles/TileCatalogue.swift` (presentation: `.dev`, `"star"`, `"A repository's stars, forks and PRs"`), `Sources/PixelClockTilesApp/ConnectorFactories.swift` (the GitHub factory), `Tests/PixelClockKitTests/TileConfigTests.swift`

**Interfaces:**
- Consumes: Tasks 3, 5, 6 and 7.
- Produces:
  ```swift
  public struct GitHubTileConfig: Codable, Sendable, Equatable {
      public var repo: String                 // "owner/name"
      public var shortName: String?
      public var celebrationSeconds: Int = 8  // 5 / 8 / 10 / 15
      public static let celebrationChoices = [5, 8, 10, 15]
  }
  public struct GitHubReading: Sendable, Equatable {
      public enum Content: Sendable, Equatable { case noToken, noData, state(GitHubRepoState) }
      public var content: Content
      public var events: GitHubEvents
      public var config: GitHubTileConfig
  }
  public struct GitHubConnector: Connector {
      public static let connectorId = "github"
      public init(tile: TileRecord, source: any GitHubReporting, snapshots: any GitHubSnapshotStoring,
                  faces: GitHubFaces = .standard)
      // instancing .perKey; defaultInterval 60; isAudible true (the TC001 jingle); isAmbient false
  }
  ```
  `read()` behaves as follows:
  - No token (`source.state` returns nil): `.noToken`, and the snapshot is left alone.
  - A thrown error: `.noData`, and the snapshot is kept.
  - A state: detect the events, save the snapshot, return `.state` with the events.

  The faces are wired in Tasks 9 and 10. Until then `GitHubFaces.standard` is a placeholder that draws `.idle` / text, and Task 9 replaces it.

- [ ] **Step 1: Write the failing tests.** A stub `GitHubReporting` and `MemoryGitHubSnapshots`.
  - `aMissingTokenReadsNoToken`.
  - `aFailureReadsNoDataAndKeepsTheSnapshot`.
  - `theSecondReadCarriesTheNewStars`: baseline first, then one star.
  - `itIsInstancedPerKey`.
  - `TileConfigTests.aGitHubConfigRoundTrips`: `{"github":{"repo":"a/x","shortName":null,"celebrationSeconds":8}}`, with a missing `celebrationSeconds` decoding to 8.
- [ ] **Step 2: Run** `swift test --filter "GitHubConnectorTests|TileConfigTests"` and confirm it FAILS.
- [ ] **Step 3: Implement.** Register the GitHub factory in `ConnectorFactories`: `{ tile in GitHubConnector(tile: tile, source: GitHubAPI(transport:, token: { secrets.secret(for: .connector("github")) }), snapshots: UserDefaultsGitHubSnapshots(defaults:)) }`. Register one naming instance in the app-level registry the way z.ai does.
- [ ] **Step 4: Run** `swift test --no-parallel`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(github): the GitHub connector — one tile per repo, a shared token, events since its snapshot`

### Task 9: The TC002 face from the oracle (F2a)

**Files:**
- Create: `Scripts/make_github_face_oracle.py`, `Tests/PixelClockKitTests/Fixtures/github_face_oracle.json` (generated), `Sources/PixelClockKit/GitHub/GitHubFace.swift`, `Sources/PixelClockKit/GitHub/GitHubGlyphs.swift` (the octicon coverage table and the glyph additions), `Tests/PixelClockKitTests/GitHubFaceTests.swift`
- Modify: `Sources/PixelClockKit/Ulanzi/PixelFont*.swift` (proportional additions `j _ + # ☺`, big additions `+ k m ★`, only where the kit's tables lack them), `Sources/PixelClockKit/GitHub/GitHubConnector.swift` (`ulanziFace`)

**Interfaces:**
- Consumes: `ggen.py`'s `build(case, dwell, celebrate)` and `CASES`. Also `FullFrameGif.encode(frames:delays:)`, `UlanziImage`, `UlanziFrame`, `PixelCanvas`, and the `UsageFace.delivery` pattern.
- Produces: `GitHubFace.timeline(ambient: GitHubRepoState?, noToken: Bool, config: GitHubTileConfig, dwellMs: Int) -> [(PixelCanvas, Int)]`, `GitHubFace.celebration(kind: GitHubEventKind, events: GitHubEvents, config:) -> [(PixelCanvas, Int)]`, and `GitHubFace.delivery(for reading: GitHubReading) -> UlanziDelivery`, which carries the ambient GIF plus one `Interruption` per event kind present, in the order stars (`.everyPage`), forks (`.ownPage`), PRs (`.ownPage`), each with `duration = max(config.celebrationSeconds, its timeline length)`.
  Add the test `aReadWithStarsAndAForkCarriesTwoInterruptionsInOrder`.

- [ ] **Step 1: Write the oracle script.** It follows `Scripts/make_weather_face_oracle.py`, imports `ggen` from `.claude/skills/tc002-face-mockup/github/`, and writes `{cases: [{id, dwell, celebrate, frames: [[16 hex rows]], ms: []}]}` for every `CASES` entry at `dwell=10000, celebrate=8000`, plus `a1` at `dwell=5000`. Run it and commit the fixture as generated.
- [ ] **Step 2: Write the failing oracle tests**, parameterised over the fixture cases like `WeatherFaceTests`: the Swift timeline for the same input equals the oracle frame by frame and delay by delay. Also `everyTimelineFitsTheCeiling` (frames ≤ 480, base64 ≤ 136 000) and `glyphTablesMatchTheOracle` (the Swift glyph rows equal `ggen.G` / `ggen.B` for every added character, exported by the script).
- [ ] **Step 3: Run** `swift test --filter GitHubFaceTests` and confirm it FAILS.
- [ ] **Step 4: Port `ggen.py` to Swift, function by function, in the same order.** The Python functions map as follows:
  - `glyph`, `octocat`, `star_icon`, `pulse` → icons.
  - `hero`, `line_area`, `gap_after` → text.
  - `area_frame`, `ticker_segments`, `lace`, `edge_marquee` → timeline.
  - `ambient`, `celebration`.

  Use Python arithmetic where it matters: `round` is half-even (`.toNearestOrEven`), `//` is floor, and bilinear `sample` must use the same float expressions. The octicon table is the `octicons.py` hex rows as a Swift literal, emitted by the oracle script into the fixture and asserted equal.
- [ ] **Step 5: Run** `swift test --filter GitHubFaceTests`. Expected: PASS.
- [ ] **Step 6: Commit.** `feat(github): the TC002 face, held to the mockup generator frame by frame`

### Task 10: The TC001 face (F2b)

**Files:**
- Create: `Sources/PixelClockKit/GitHub/GitHubAwtrixFace.swift`, `Tests/PixelClockKitTests/GitHubAwtrixFaceTests.swift`
- Modify: `Sources/PixelClockKit/GitHub/GitHubConnector.swift` (`awtrixFace`)

**Interfaces:**
- Produces: `enum GitHubJingle { static let star, fork, pr: String }`, all RTTTL. The star jingle is the Mario coin: `"coin:d=8,o=6,b=180:b5,4e6"`. Fork is the 1-up: `"oneup:d=16,o=6,b=150:e,g,e7,c7,d7,g7"`. PR is the power-up: `"power:d=16,o=5,b=200:c,e,g,c6,e6,g6"`. `GitHubAwtrixFace.draw(_ reading:) -> AwtrixDelivery`.

- [ ] **Step 1: Write the failing tests.**
  - `ambientIsAnAppNamedByTheTile`: surface `.app("github.a/x")`, text `"★1234"`, icon `.bundled("github")`.
  - `starsInterruptWithTheCoin`: the interruption scene `.notification`, text `"★ +2 alice"`, jingle `GitHubJingle.star`, duration = `celebrationSeconds`.
  - `aForkUsesTheOneUp`, `aPRUsesThePowerUp` (text `"PR #42 dave"`).
  - `starsAndAForkInOneReadAreTwoNotificationsInOrder`.
  - `noTokenAndNoDataShowTheirWords`.
- [ ] **Step 2: Run** `swift test --filter GitHubAwtrixFaceTests` and confirm it FAILS.
- [ ] **Step 3: Implement.** Add the bundled icon as an 8×8 GIF in `Sources/PixelClockKit/Resources/`, drawn from the `mark` octicon. The AWTRIX icon size is 8×8, so downsample the coverage table with the Task 9 helper.
- [ ] **Step 4: Run** `swift test --no-parallel`. Expected: PASS.
- [ ] **Step 5: Commit.** `feat(github): the AWTRIX face — an app in the loop, a notification with a jingle for each event`

### Task 11: Tile settings: repo, short name, celebration, shared PAT with the pixel `?` (F2c)

**Files:**
- Create: `Sources/PixelClockTilesApp/GitHubTileBlock.swift`, `Tests/PixelClockTilesAppTests/GitHubTileSettingsTests.swift`
- Modify: `Sources/PixelClockTilesApp/TileSettingsWindow.swift` (`connectorBlock` branch), `Sources/PixelClockTilesApp/TileSettingsModel.swift` (`setGitHubConfig`), `Sources/PixelClockTilesApp/AppModel.swift` (`saveGitHubToken`, `hasGitHubToken`, `addTile` with the instance from the repo), `Sources/PixelClockTilesApp/PanelGlyphs.swift` (the `?` glyph), `Sources/PixelClockTilesApp/StoreModel.swift` (adding a GitHub tile asks for the repo)

**Interfaces:**
- Consumes: Tasks 1, 4 and 8.
- Produces:
  - `AppModel.saveGitHubToken(_ token: String) -> TokenOutcome`, where blank removes the token.
  - `AppModel.hasGitHubToken: Bool`.
  - `AppModel.addGitHubTile(repo: String, to clockId: UUID) -> Bool`: validates `^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$`, sets the instance to the lowercased repo, and refuses a duplicate on the clock.
  - `enum GitHubTokenHelp { static let createURL: URL; static let text: String }`. `createURL` is the spec's prefilled link, verbatim.

- [ ] **Step 1: Write the failing tests.**
  - `theTokenIsSharedByEveryGitHubTile`: save through tile A's model, and tile B's `hasGitHubToken` becomes true. The secret is stored under `.connector("github")`, not `.tile`.
  - `aBadRepoIsRefused`, `aDuplicateRepoOnOneClockIsRefused`, `theSameRepoOnTwoClocksIsAllowed`.
  - `theHelpLinkIsThePrefilledForm`: `GitHubTokenHelp.createURL.absoluteString` equals the spec's link, and the help text names `Public repositories`, `Metadata: read` and `Pull requests: read`.
- [ ] **Step 2: Run** `swift test --filter GitHubTileSettingsTests` and confirm it FAILS.
- [ ] **Step 3: Implement the block.**
  - Repo shown read-only once the tile exists, because the repo is the tile's identity.
  - Short-name field with a note, shown when the name will scroll, computed with the kit's proportional width against 34 px.
  - Celebration picker 5 / 8 / 10 / 15 s.
  - PAT `SecureField` plus a Save button, with a presence line shared by all GitHub tiles.
  - A `PanelGlyph.question` pixel `?`, 5×7 in the panel's pixel-art style: rows `.###.`, `#...#`, `...#.`, `..#..`, `..#..`, `.....`, `..#..`. On hover it shows a popover with `GitHubTokenHelp.text` and a `Link("Create a token", destination: GitHubTokenHelp.createURL)`. Hover uses `.onHover` plus `.popover`. `.help` alone cannot hold a link.

  In the store, adding GitHub opens a sheet asking for `owner/name` before the tile exists.
- [ ] **Step 4: Run** `swift test --no-parallel`. Expected: PASS.
- [ ] **Step 5: Build the app** (`./Scripts/bundle.sh debug`) and look at the block yourself. Screenshot through the `run` skill if available.
- [ ] **Step 6: Commit.** `feat(github): tile settings — the repo, a short name, the celebration length, and one shared token with its help`

### Task 12: Live validation (user-gated)

- [ ] Install `build/PixelClockTiles.app` and add a GitHub tile for a repo the user controls to the TC002 and to the TC001 if present. Set the PAT.
- [ ] Ask the user to watch the TC002. The ambient page `pct-github.<repo>` should cycle name → forks → PRs with the octicons, in step.
- [ ] Ask the user to star the repo (or unstar and star it again). Within one refresh the star celebration should cover every `pct-*` page for M seconds and then each page should return to its own content. Ask one question at a time, per `tc002-ticker-motion`'s "Verifying motion".
- [ ] Relaunch the app and confirm no celebration fires again for the same star.
- [ ] Record the outcome in `docs/HANDOFF.md` (a short section) and commit: `docs(github): live validation on the TC002 and TC001`.

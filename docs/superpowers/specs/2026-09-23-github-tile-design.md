# GitHub tile — design

A tile that watches one GitHub repository: its stars, forks and open pull
requests on the clock, and a celebration when someone stars it, forks it or
opens a pull request. Several GitHub tiles may sit on one clock, one per repo.

Getting there needs three pieces of substrate the app does not have yet — an
encrypted secret store, scene tiles that can be instanced per key, and an
interruption a delivery can carry — and then the connector and its faces. The
face was designed in the `tc002-face-mockup` skill, approved in the browser and
on the panel on 2026-09-23; `.claude/skills/tc002-face-mockup/github/ggen.py`
is its pixel source of truth.

## What the brief asks for

1. A GitHub tile showing the GitHub mark, the repo name, forks, open PRs and
   stars. Several of them may be added — **the multi-instance ability belongs
   in the substrate**, not in this connector.
2. Refetch every N seconds.
3. When stars arrive, a full-screen star with `+N` for M seconds (a separate
   setting) and the Mario coin sound. The same for forks with another sound.
   Added while designing: a newly opened PR celebrates too; stars celebrate on
   **every** page the app owns, forks and PRs on the GitHub page only.
4. The celebration names **who** — the logins.
5. The token is a PAT, set on any GitHub tile and used by all of them. Secrets
   leave the keychain for good: an encrypted file on disk, because the
   keychain prompts for the password after every re-sign and a certificate did
   not stop it. **The encryption is substrate.**
6. The PAT field carries a pixel `?`; hovering it names the scopes needed and
   links to the PAT creation page.
7. The TC001 (AWTRIX) gets a face of its own; the TC002 is the model this is
   designed for.
8. A long repo name scrolls rather than being refused.

## Decisions taken while designing

| Question | Decision | Why the alternative lost |
|---|---|---|
| Sound on the TC002 | **None.** The celebration is silent there | The stock protocol exposes no audio: the official limitations table says "TTS / MP3 / audio playback — Not exposed by the protocol", re-checked against the protocol as of 2026-09-22. `tc002-audiod` plays uploaded sounds, but only inside a runtime that replaces the stock app and `/api/custom` with it. Root adb is one OTA from closed. The user chose silence over Mac speakers. |
| Sound on the TC001 | **RTTTL on the buzzer**, `AwtrixScene.jingle` | The buzzer plays RTTTL natively; the Mario coin is a classic RTTTL tune. Nothing plays on the Mac, so the tile does not occupy "the voice in the room" and may sit on several clocks. |
| Celebration visibility on the TC002 | **Stars overwrite every `pct-*` page for M s; forks and PRs only their own page** | The TC002 has no notification surface and the Mac may not switch pages (`switchDiyApp` throws a user out of an open tool, D3). Covering every page we own shows a star wherever the carousel stands on one of ours. |
| Data source | **GraphQL with a required fine-grained PAT** | REST without a token cannot count open PRs (`open_issues_count` mixes them with issues), has no stargazer logins, and allows 60 requests an hour per IP. One GraphQL query per tile gives everything within 5 000 points an hour. |
| Event detection | **By identity, not by count delta** | Stars by `starredAt` newer than the last seen, forks by `createdAt`, PRs by numbers not in the previous snapshot. A delta hides an unstar-and-star or an opened-and-merged pair inside one interval. |
| First fetch | **Sets the baseline, celebrates nothing** | Otherwise adding a tile celebrates the repo's whole history. |
| Secret key | **HKDF-SHA256 from `IOPlatformUUID` + an in-app salt → AES-GCM**, nothing on disk | Protects the file where it leaks — backups, Time Machine, dotfile sync, another Mac. It does not protect against a process of the same user; neither does an ad-hoc-signed keychain, which only prompts. A random key file beside the ciphertext leaks with it; a Secure Enclave key lives in the keychain and brings the prompt back. |
| Existing z.ai keys | **Migrated once**: read from the keychain, written to the file, deleted from the keychain | One last keychain prompt, and no key to paste again. |
| How the celebration travels | **As part of `Delivery`** (`interruption`) | A separate event channel would be a second pipeline beside the delivery chain, with its own queue and quiet rules. The face stays a pure function of one reading. |
| Ambient layout | **Hybrid**: stars as the hero; the ticker line brings its own icon | A 5 px PR glyph does not read — every candidate read as a letter. The octicon beside the count names it, and the slide is the weather Hybrid the panel already proved. |
| Long repo names | **Edge marquee**, short name an optional override | The user's call. Recorded as the one exception to "names never scroll" in `tc002-tile-screen`. |
| TC001 scope | **In, as a minimal face** | The connector supports both models from day one; `TileCandidate.models` stays honest. |

## Substrate

### S1 — Secrets

`TileKeyStoring` moves out of `Zai/` into `Sources/PixelClockKit/Secrets/` as
the port `SecretStoring`, keyed by a typed account:

```swift
public enum SecretAccount: Hashable, Sendable {
    case tile(TileKey)          // one secret per tile (z.ai)
    case connector(String)      // one secret per connector (the GitHub PAT)
}
public protocol SecretStoring: Sendable {
    func secret(for account: SecretAccount) -> String?
    func save(_ secret: String, for account: SecretAccount) throws
    func remove(for account: SecretAccount) throws
}
```

The contract is the one `TileKeyStoring` already pins — no cache, a failed read
is no secret, removing what is absent succeeds — and its tests move with it.

`EncryptedFileSecretStore` is the production store:

- One file, `Application Support/PixelClockTiles/secrets.enc`, mode 0600.
- Format: a 4-byte magic `PCTS`, a version byte `1`, then one AES-GCM sealed
  box (nonce, ciphertext, tag) over a JSON object `{account-string: secret}`.
- Key: HKDF-SHA256, input key material `IOPlatformUUID`, salt a 32-byte
  constant compiled into the app, info `"PixelClockTiles secrets v1"`. The
  hardware id is injected, so tests run with a fixed one and a second id proves
  a file does not open on another machine.
- Writes are atomic: a temp file in the same directory, then `rename`.
- A file that does not open — wrong machine, truncated, a newer version — reads
  as no secrets, and the next save replaces it. A secret that cannot be read is
  a secret the user pastes again; refusing to start is worse.

`MemorySecretStore` replaces `MemoryKeychainStore` as the test fixture.
`LoginKeychainStore` stays in the tree only for the migration.

`SecretsMigration` (app target, the `VPNTileMigration` shape — a marker, the
work, the marker last): for every z.ai tile, read its key from the keychain,
write it under `.tile(key)`, delete the keychain item. A key the keychain
refuses to give up is left where it is and the marker is still set — the tile
reads "no key", which is the state it would be in after any other loss.

### S2 — Instanced scene tiles

Timers are already per `TileKey`. Everything after the timer is per
`connectorId`: the session's `runOnce`, the backoff, `TileSettingsStore`, the
TC002 page name, the z.ai account, and every `tiles.first { connectorId == }`
config closure. S2 carries the whole key through:

- `ConnectorRunning.runOnce(tile: TileKey)`, `maintain(tile:)`,
  `nextDelay(tile:interval:)`; `DeliveryChain` failure counts keyed by tile.
- A connector is resolved **per tile**: `ConnectorRegistry` keeps naming
  connectors by id for the store and previews, and gains
  `connector(for tile: TileRecord) -> (any Connector)?`, backed by a factory
  per connector id (`(TileRecord) -> any Connector`). The per-clock registries
  in `AppModel.live` become factories, so a connector reads its own tile's
  config by construction instead of searching the store for it — which also
  removes the `.first { }` closures.
- The factories are built outside `AppModel.live`, in a `ConnectorFactories`
  type of the app target: `AppModel.live` is the hottest method in the project
  (263 lines, fan-out 60) and must shrink, not grow.
- The TC002 tile id becomes the key's own string: `connectorId` for an empty
  instance — so every page already on a clock keeps its name — and
  `connectorId.instance` otherwise. `UlanziCustody` names pages from it.
- `Connector` gains `var instancing: Instancing { get }`, default `.single`;
  `TileCandidate.init(_ connector:)` reads it instead of hard-coding `.single`.
- `TileSettingsStore`, pause, remove and restore paths take the key with its
  instance.

### S3 — Interruption

```swift
public struct Interruption<Scene: Sendable & Equatable>: Sendable, Equatable {
    public enum Scope: Sendable, Equatable { case everyPage, ownPage }
    public var scene: Scene
    public var scope: Scope
    public var duration: TimeInterval
}
// Delivery gains:
public var interruption: Interruption<Scene>?
```

- **TC002** (`UlanziClockSession`): after the delivery's own push, the
  interruption's frame goes through the delivery chain to every tile on the
  board (`.everyPage`) or to its own (`.ownPage`) — without touching the board,
  so the board still holds each page's real content. After `duration`, each of
  those pages is re-pushed from `UlanziTileBoard.frame(forTile:)` (an idle page
  goes back to idle). A second interruption arriving inside the window extends
  the window; it does not stack restores. The recovery sweep already re-pushes
  from the same board, so an outage during a celebration restores correctly.
- **TC001** (`AwtrixClockSession`): the interruption is a `.notification`
  scene with `duration` and a `jingle`, sent after the ambient `.app` scene.
  The scope does not apply: a notification already covers the whole clock.
- The quiet rules decide as before: a Focus or quiet hours that hold an audible
  tile hold its run, celebration included. The GitHub connector is audible on
  the TC001 (its jingle) and silent on the TC002.
- **The snapshot** that decides what is new is per tile and survives a
  relaunch: `GitHubSnapshot` (last `starredAt`, last fork `createdAt`, the open
  PR numbers) is stored beside the tile record. A relaunch does not celebrate
  again; an outage celebrates everything it missed, once, aggregated.

## The connector — F1

- `GitHubTileConfig`: `repo` (`owner/name`), `shortName?`, `celebrationSeconds`
  (default 8). A new `TileConfig.github` case; the refresh interval is the
  tile's ordinary policy (default 60 s).
- `GitHubConnector`: `instancing: .perKey`, the instance being `owner/name`
  lowercased. Category `.dev` in the store.
- `GitHubAPI` over the app's `Transport`: one GraphQL POST to
  `https://api.github.com/graphql` with `Authorization: Bearer <PAT>` —

  ```graphql
  query($owner: String!, $name: String!) {
    repository(owner: $owner, name: $name) {
      nameWithOwner
      stargazerCount
      forkCount
      pullRequests(states: OPEN) { totalCount }
      stargazers(last: 20) { edges { starredAt node { login } } }
      forks(last: 20, orderBy: {field: CREATED_AT, direction: ASC}) { nodes { createdAt owner { login } } }
      openPRs: pullRequests(states: OPEN, last: 20) { nodes { number author { login } } }
    }
  }
  ```

  The PAT is read from `.connector("github")` at every read, never held.
- `GitHubReading`: the counts, and the events since the snapshot (stars,
  forks, PRs, each with logins and PR numbers) — computed by a pure
  `GitHubEventDetector(snapshot, response) -> (events, snapshot)`.
- Missing data: no PAT → the `no token` page; a failed or refused request →
  `no data`, and the snapshot is kept, so the next good read still celebrates
  what arrived meanwhile.

## The faces — F2

### TC002

Pixel for pixel `ggen.py`, recorded as fixtures by
`Scripts/make_github_face_oracle.py` and tested the way `UsageFace` and
`WeatherFace` are. Every design change starts in `ggen.py`.

- **Ambient**, one 52×16 GIF: the hero is a big star and the star count in
  `#FFD84A` (GitHub's `#E3B341` read orange on the LEDs; picked on the panel),
  exact to 9 999, then `12k` / `123k` / `1m`. The ticker rotates
  three states, each bringing its own icon (Hybrid, 3 rows per step for the
  icon, 1 for the line, 60 ms): the repo name with the GitHub mark, the fork
  count with the fork octicon (`#58A6FF`), the open PR count with the PR
  octicon (`#3FB950`). The mark's shine sweeps every 2.4 s; fork and PR run a
  commit along the branch. A name wider than 34 px edge-marquees.
- **Celebration**, the interruption's scene: the event's octicon — the star
  pops in and twinkles — `+N` as the hero, then a ticker: what happened
  (`stars`, `fork`, `pr #42`), then up to three lowercased logins, each after a grey
  `#909090` person glyph — `@` does not read at 5 px, the bust was picked on
  the panel (`☺alice`;
  `#42 dave` for several PRs), then `+K more`. M is a minimum: a marquee
  always finishes its pass.
- Glyphs added to the proportional table: `j _ + #` and the person `☺`; to the big table:
  `+ k m ★`.

### TC001

- Ambient: an `.app("github.<instance>")` scene, text `★1234`, the GitHub
  icon bundled.
- Celebration: `.notification`, text `★ +3 @alice`, duration M, the star or
  fork or PR jingle — the Mario coin for stars, the 1-up for forks, the
  power-up for PRs, as RTTTL strings in the connector.

### Tile settings

A `GitHubTileBlock` beside the existing blocks in `TileSettingsWindow`:

- Repo field (`owner/name`, validated on the shape; the tile's instance is set
  from it when the tile is added).
- Short name, optional, with a live note when the name will scroll.
- Celebration seconds: 5 / 8 / 10 / 15.
- PAT field, shared: saving it on any GitHub tile saves `.connector("github")`;
  every GitHub tile's block shows the same presence line. Beside it a pixel
  `?` glyph (a new `PanelGlyph`), whose hover card says:
  - Public repositories: a fine-grained token with *Repository access →
    Public repositories*; no permissions needed.
  - Private repositories: *Only select repositories*, and `Metadata: read`,
    `Pull requests: read`.
  - Repository access cannot be preset by a link; pick it on the page.
  - A link to
    `https://github.com/settings/personal-access-tokens/new?name=PixelClockTiles&description=Read-only+stars,+forks+and+PRs+for+the+GitHub+tile&expires_in=366&metadata=read&pull_requests=read`
    — GitHub documents prefilling the form by these parameters.

## CI of the default branch (added 2026-09-24)

The first design left CI out on the agent's own call; the user asked for it
back. Decided in the browser and on the panel (2026-09-23/24):

- **A lamp, only when something needs a look.** A 3×3 badge on the icon's
  bottom-right corner (`ggen.LAMP_CELLS`), painted over whatever icon the
  ticker shows. `pending` = amber `#D29922`, a ring filling to a full square
  and back every 500 ms; `failure` = red `#F85149`, blinking 500/500 ms.
  `success`, and a repo without checks, draw nothing — a green lamp on every
  healthy repo was "too much". Picked over a column beside the hero (it
  touched a fourth digit) and one in the gutter.
- **An event on the transition to failure.** A new failing head commit of the
  default branch is an interruption like a fork or a PR: own page only on the
  TC002 (ggen case `c8-ci-failed`: the failed-check octicon, red with a white
  cross, hero `ci`, then `<branch> fail`, then `☺<commit author>`); on the
  TC001 a notification with its own jingle. The same failing commit never
  celebrates twice: the snapshot remembers the last failing head commit.
- **Data.** The GraphQL query gains the default branch's head commit:
  `defaultBranchRef { name target { ... on Commit { oid author { user { login } }
  statusCheckRollup { state } } } }`. `SUCCESS` → success, `FAILURE`/`ERROR` →
  failure, `PENDING`/`EXPECTED` → pending, no rollup → none.
- **Budget.** The lamp cuts frames at its 500 ms phase; the worst case, a
  marquee name with a blinking lamp, is 353 frames at the fixed 10 s dwell
  (`a13-ci-worst`).
- **TC001.** No lamp (the AWTRIX face is one text line); the failure event
  only.

## Testing

- S1: the moved contract suite runs against both stores; the file store adds
  round-trip, other machine, truncated file, unknown version, atomic write,
  mode 0600. The migration: moves, deletes, survives a refused read, runs once.
- S2: two GitHub tiles on one clock run, back off, pause and remove
  independently; an empty-instance tile keeps its TC002 page name; the catalogue
  lists a `.perKey` connector already on the clock.
- S3: `.everyPage` and `.ownPage` push to the right pages and restore each from
  the board; an idle page returns idle; a second interruption extends; an
  outage during the window restores; the TC001 sends one notification with the
  jingle.
- F1: the detector over every event mix, the first-fetch baseline, the
  snapshot across a relaunch, the request shape against a recording transport.
- F2: the oracle fixtures, frame by frame and delay by delay; the settings
  block's shared PAT.
- Live: the app's own `pct-github.*` page on the TC002, and a star given to a
  test repo, watched on the panel.

## Out of scope

- Sound on the TC002.
- Issues, releases, traffic, stargazer trends — candidates for a later page
  of the same tile. (CI status moved in scope on 2026-09-24, see below.)
- Moving the anecdote or weather tiles onto instancing.

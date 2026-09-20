# PixelClockTiles — multi-clock tiles design

Status: approved for planning · 2026-09-18

AWTRIX Connectors becomes PixelClockTiles: a menu bar app that drives several
pixel clocks at once — the Ulanzi TC001 on AWTRIX 3 and the Ulanzi TC002 on
its stock firmware — where every connector is a small app the user places on a
clock as a tile. A connector draws each clock model through a face of its own,
and a connector with no face for a model cannot be placed on that model.

Free software; a Sublime-style donation prompt is a later concern and is not
part of this design.

## Decisions taken while designing

Recorded so the plan does not re-open them.

| # | Question | Decision |
| --- | --- | --- |
| 1 | One clock or several | Several at once, both models together, managed in the general settings |
| 2 | What a tile is bound to | A tile is one connector on one specific clock |
| 3 | The same connector twice on one clock | No — one tile per connector per clock. VPN is the single exception (decision 9) |
| 4 | VPN lamps and battery warnings | VPN becomes a tile connector; battery stays part of the clock's status |
| 5 | Audible connectors on several clocks | An audible tile whose sound plays through the Mac can sit on one clock only |
| 6 | TC002 rendering and on-device audio | Out of this design; investigated separately after it (follow-up F1) |
| 7 | How several clocks are regulated | A list of clocks in the settings; two clocks listed means two driven. No mode switch |
| 8 | How defaults reach a tile | Copied from the connector when the tile is created, then the tile owns them |
| 9 | Several VPNs on one clock | One tile per VPN; tiles may share a lamp at different times or Focuses |
| 10 | Two VPN tiles claiming one lamp at the same moment | Refused when saved |
| 11 | Where the Claude figure comes from | Claude Code's status line, written to a file the app reads. The keychain reader and `/api/oauth/usage` are removed. The figure is as fresh as the last Claude Code reply |
| — | Approach | Faces inside the connector, typed per-model scenes, one session per clock |
| — | Name | PixelClockTiles; the kit becomes PixelClockKit |

## Measured device facts — TC002

Verified against the clock on the desk (`192.168.1.72`) on 2026-09-14, not taken
from documentation.

| Fact | Evidence |
| --- | --- |
| The TC002 answers on the address the TC001 used to hold | UDP broadcast from `192.168.1.72`; `awtrix_a07f9c.local` does not answer |
| It announces itself on UDP 55555 (documented as about once a second) | caught within five seconds of listening: `Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false` |
| `GET /getBase` identifies it | `{"devSn":"B0D32I008U3671403","ssid":…,"ip":"192.168.1.72","mac":"ccc4b2779b9a","mcuVer":"V1.0.17","appVer":"1.1.1"}` |
| AWTRIX's stats endpoint does not exist on it | `GET /api/stats` → HTTP 301 |
| A custom app is created by name | `POST /api/custom?name=probe_claude` → `{"code":200,"message":"ok"}` |
| Custom apps are listed | `GET /api/customList` → `{"apps":["probe_claude"],"count":1}` |
| An empty body deletes one; `{}` does not | `POST /api/custom?name=probe_claude` with an empty body → list back to `{"apps":[],"count":0}`. `{}` alone does not delete — corrected on re-measurement, 2026-09-18 |
| `switchDiyApp` takes the UI away from where the user left it | `{"code":200,"message":"app switch requested","data":{"name":"probe_claude","index":100}}`; the user saw the interface move from L3 to L2 |
| A pushed frame shows full screen — because `switchDiyApp` was called | the probe (`CLAUDE 42%` over a drawn bar) was shown full screen, and read to the user as a picture rather than as a native app. A push alone never brings a custom app on screen; the screen changed because the same session called `switchDiyApp` |
| Ports | 80 open, 5555 (adb) open, 1883 closed |

From the reverse-engineered documentation (`atomicstack/tc002-customisation`,
`CUSTOM-APP.md`, `HTTP-API.md`), the official repository and protocol —
reconciled by the F1 spike (research § 5); each one the plan leans on got its
live check:

- The payload schema is `{text[], image[], draw[]}`, shared by HTTP and MQTT;
  `duration` is sent by the community but is not in the official schema and is
  not a TTL.
- Text is ASCII 0x20–0x7E; the device does not scroll. Whether lowercase
  letters render is unresolved — official samples use lowercase after the
  v1.1.0 font fix (this clock runs 1.1.1), while the community still reports
  partial glyphs (#20); experiment E5 settles it. `fontHeight` is 5 or 10
  (official; the community also reports tiers 3–5, 6–8 and 10, #25).
- `draw` primitives: `dp` pixel, `dl` line, `dr` rectangle outline, `df` filled
  rectangle, `db` bitmap, plus `dc`, `dfc` and `dt` — at most 32 commands per
  app. Colours are `#RRGGBB` strings.
- `image` elements carry base64 — the exact spelling on the wire (bare base64
  or a data URI) is unverified and sits on the hardware checklist. GIFs up to
  256×256 and 50 frames are accepted and clipped to 52×16; stills go up to
  512×512; base64 up to 60 KB; at most 6 images per app.
- There is no `lifetime`: an app persists after its sender goes away.
- No notification, indicator, overlay, battery-reading, or audio endpoint
  exists on the stock firmware. Audio is reachable only from software running
  on the clock.

## Architecture

```text
            driving adapters                        driven ports
  ┌───────────────────────────────┐        ┌──────────────────────────────┐
  │ menu bar panel, tile detail,  │        │ AwtrixDevice   (TC001)       │
  │ settings, system events       │        │ UlanziDevice   (TC002)       │
  │ (network path, Focus, timers) │        │ AudioSink      (Mac speakers)│
  └──────────────┬────────────────┘        │ ClockDiscovery (Bonjour, UDP)│
                 │                          └──────────────▲───────────────┘
        ┌────────▼─────────┐   programs    ┌───────────────┴──────────────┐
        │ tiles + policies │──────────────►│ ClockSession (one per clock) │
        │ connectors:      │               │ DeliveryChain · custody ·    │
        │ read() + faces   │               │ health · lamp ownership      │
        └──────────────────┘               └──────────────────────────────┘
```

### Clock

A record in the Clocks section of the settings.

| Field | Meaning |
| --- | --- |
| `id: UUID` | This app's stable key |
| `name` | What the user calls it — "Desk", "Kitchen" |
| `model: ClockModel` | `.awtrix3` or `.ulanziTC002`, detected when the clock is added, never chosen |
| `address` | Host or IP |
| `hardwareIdentity` | AWTRIX `uid` from `/api/stats`; TC002 `devSn` from `/getBase`. Nil until the clock has answered once |

Adoption and relocation work on `hardwareIdentity`: a DHCP lease moving is the
same clock on a new address, not a new clock. This is `DeviceAdoption`'s rule,
applied per clock.

### Connector

A type in code, not a record.

```swift
enum ClockModel: Sendable { case awtrix3, ulanziTC002 }

protocol Connector: Sendable {
    associatedtype Reading: Sendable
    var id: String { get }
    var displayName: String { get }
    var trigger: Trigger { get }            // .every(interval) | .events(stream, recheck: interval)
    var narrator: Voice { get }
    var isAudible: Bool { get }
    var instancing: Instancing { get }      // .single | .perKey
    var defaultPolicy: TilePolicy { get }   // what a new tile of this connector starts from
    func read() async throws -> Reading
    var awtrixFace: AwtrixFace<Reading> { get }    // Reading -> AwtrixDelivery
    var ulanziFace: UlanziFace<Reading>? { get }   // Reading -> UlanziScene, nil by default
}
```

- The models a connector supports are the faces it has. Nothing else declares
  support, so the two cannot disagree.
- `awtrixFace` is required while every connector has one; it becomes optional
  in the phase that adds the first connector without one. `ulanziFace` is
  optional, with a `nil` default, from phase 3.
- There is no `Config` associated type. A tile's settings are
  `TileRecord.config: TileConfig?`, a closed enum (`.weather(Coordinates)`,
  `.vpn(VPNTileConfig)`), and they reach a connector through the connector each
  clock's session is built with — the weather connector of a clock reads its
  place from that clock's weather tile, closed over at session build.
- The VPN is not a `Connector`. A lamp is not a scene, so it cannot carry the
  required `awtrixFace` honestly; it is a lamp connector of its own
  (`VPNConnector`, `read(config:)` and a lamp face), offered on AWTRIX clocks
  as `.perKey`, written through the clock's indicator custody off the delivery
  chain. `awtrixFace` therefore stays required, and the "becomes optional when
  the first connector without one lands" clause is not triggered by it.
- A face is a pure function. It never reaches a network or a device, which is
  what lets every drawing be tested against a value.
- `isAmbient` is removed. It existed to hide rows the user had not asked for;
  the user now places every tile, so there is nothing to hide. An ambient tile
  simply has no "Run now".
- `ConnectorMaintaining` stays, per connector type. The anecdote queue is one
  queue, and its background pass runs while any clock carries an unpaused
  anecdote tile.

### Tile

One connector on one clock.

- Key: `TileKey(clockId, connectorId, instance)`. `instance` is empty for
  `.single` connectors, so a second tile of the same connector on the same
  clock is impossible by construction. The VPN connector is `.perKey`, keyed by
  the VPN it watches.
- `policy: TilePolicy` — the common component below, on every tile.
- `lastDeliveredAt` — carried over from `ConnectorSettings` unchanged, so the
  cadence survives a relaunch per tile.
- `config` — what one connector needs and no other does: the weather location,
  the VPN tile's VPN, lamp and colours.

Typing: a connector with an associated type does not reach the UI as an
existential. When a `ClockSession` is built, each tile becomes a program for
that clock's model — `() async throws -> Delivery<AwtrixScene>` or
`() async throws -> Delivery<UlanziScene>` — with `read` and the face closed
over. An AWTRIX scene cannot be handed to a TC002 session; it does not compile.

### TilePolicy — the common component

Every tile carries one, edited by one shared editor. Defaults are copied from
the connector when the tile is created, then belong to the tile.

| Field | Meaning |
| --- | --- |
| `isPaused` | Stop without losing the settings. Removing a tile is `✕`, and is a different act |
| `refresh` | Seconds between runs. Floor 30 s for every connector. For an event-driven tile it is the recheck period between events |
| `focus.silencedIn: Set<MacFocus>` | The Focuses the tile does not work in, edited as "works in" checkboxes |
| `focus.whenUnknown: .run \| .hold` | What to do under a Focus outside the four. It alone decides the Focus that cannot be named; a `.unknown` in `silencedIn` is inert |
| `window: .always \| .quiet(HourWindow) \| .active(HourWindow)` | Silent hours, or working hours, or neither |

The refresh scale: 30 s, 1, 2, 3 min, then 5–60 min in steps of 5, then 2–12 h.
It is **stored in seconds** and snapped to the nearest scale value when read;
a tie — only a value nobody chose on the slider can tie — takes the longer
step.
Today the stored value is an index into the scale; putting 30 s in front of it
would move every stored interval, so migration goes index → duration →
seconds.

`MacFocus` is closed: `.noFocus`, `.work`, `.personal`, `.doNotDisturb`,
`.sleep`, `.unknown`. It is `MacFocus` rather than the spec's first choice
`FocusState` because SwiftUI declares `FocusState`, and the collision breaks
every Phase 5 view file that imports both. The idle case is `.noFocus` rather
than `.none` because `if last == .none` on an optional reads as `Optional`'s
own case and compiles to the wrong thing. The four built-in modes are matched
on identifiers macOS ships and users cannot edit — `com.apple.focus.work`,
`com.apple.focus.personal`,
`com.apple.donotdisturb.mode.default`, `com.apple.sleep.sleep-mode`.
`ModeConfigurations.json` is not read. How the state is resolved, keeping the
app-wide gate's rules:

| What macOS says | MacFocus |
| --- | --- |
| `INFocusStatusCenter` not authorized | `.noFocus` — the hours alone decide, as the app-wide window did |
| Authorized, a mode read from `Assertions.json` | the matching case, or `.unknown` for any other identifier |
| Authorized, no mode readable, `isFocused == false` | `.noFocus` |
| Authorized, no mode readable, `isFocused == true` | `.unknown` |

`HourWindow` is the app-wide quiet window without the direction: whole hours,
wrapping midnight. A zero-length window restricts nothing, for `.quiet` and
`.active` alike — read as "no working hours", `.active` of zero length is a
tile that never runs again because a picker landed on its own start. `.quiet`
silences inside it; `.active` silences outside it.

Evaluation order stays what `FocusGate.silence` fixed: the window first, then
the Focus. The reason the first answer names the window is load-bearing today —
the nightly refresh reads it to decide whether it may spend — and it stays so.

Every policy is a function of (MacFocus, hour): six states by 24 hours, a
144-cell boolean grid. That makes two checks exact rather than heuristic: the
lamp-overlap refusal (below) and the tests, which enumerate the grid.

Defaults, copied into a new tile:

| Connector | `refresh` | Not working in | `whenUnknown` | `window` |
| --- | --- | --- | --- | --- |
| weather | 600 s | — | run | always |
| claude | 300 s | Do Not Disturb, Sleep | run | always |
| anecdotes | 1800 s | Do Not Disturb, Sleep | hold | quiet 23:00–08:00 |
| vpn | 60 s recheck | — | run | always |

The microphone hold stays a Mac-wide rule for audible tiles: it is about the
room, not about any one tile.

### Adding a tile

`TileCatalogue.availability(connector, on: clock)` returns `.available` or
`.unavailable(reason)`, and the Add tile menu shows the reason beside a
disabled entry. Uniqueness is **per clock**: a `.single` connector is placed
once per clock and may sit on every clock at once — never once per install.
A `.multi` connector may be placed several times, even on the same clock;
the VPN presets are `.multi`.

1. No face for `clock.model` → "not supported on TC002".
2. A `.single` connector already on this clock → not listed.
3. An audible connector whose sound plays through `MacSpeakers`, already placed
   on another clock → "already speaking through Kitchen". Evaluated against the
   current state, not stamped at creation, so a clock gaining a sink of its own
   later changes the answer.
4. A VPN tile whose lamp is already claimed at an overlapping moment → refused
   when saved (see VPN tiles).

### ClockSession — one per clock

Replaces `ConnectorHost`. It holds the model's adapter, a delivery chain,
the model's custody, and the clock's health. Backoff stays by `TileKey` in the
spec's sense — a session is one clock, so inside it a scene connector's id
already is the tile key — and the delivery chain stays keyed by connector id
rather than re-keyed: renaming it would move every session test for no change
in behaviour.

`DeliveryChain` is `ConnectorHost` with the model taken out: `queued`,
`classify`, the outcome recording and `nextDelay`, with every cancellation rule
from waves 1–3 kept as it is. Sessions do not share a chain: a clock that has
stopped answering holds up only its own tiles.

Audio is not part of a scene. A face produces
`Delivery<Scene>{scene, localAudio: [SpokenClip], holdUntilAudioEnds}`, and the audio
goes to an `AudioSink` port — `MacSpeakers` today, which is the existing
`SequentialAudioPlayer`. Which clock a tile is on does not decide where its
sound plays.

### AWTRIX adapter (TC001)

- Scene: a struct whose `surface` is `.notification(…)` or
  `.app(name, payload, overlay?)`, beside the fields the send reads.
- Lamps are not scenes. An indicator write goes straight to
  `IndicatorCustody`, off the delivery chain, so a lamp never waits behind a
  playing anecdote.
- Port: the existing `AwtrixDevice` actor, unchanged.
- Icons: `IconReference` (`catalogue`, `bundled`, `installed`) and
  `CatalogueIconInstaller` become AWTRIX vocabulary.
- Custody, three kinds, all existing behaviour:
  - the borrowed `OVERLAY`, recorded durably (`BorrowedOverlayStore`), now per
    clock;
  - apps in the loop, recorded in memory, because the clock keeps them in RAM;
  - indicator lamps, moved here from `VPNLampDisplay`: what each slot shows,
    written only when it changes, forgotten when a write fails, all put out on
    quit.
- Health: `stats()` and `BatteryTrajectory`; battery history keyed by
  `hardwareIdentity`, so two clocks' trends never mix. Battery warnings name the
  clock: "Desk: 20%".

### Ulanzi adapter (TC002)

- One DIY app per tile — the tile's own page on the clock. Custom apps take
  DIY pages 100–120, so a clock holds at most 21 of them; the user flips
  between the pages with the clock's knob, at DIY level 2. A push alone never
  brings a custom app on screen: the user parks on the page once, and from
  then on every push shows at once. The Mac never rotates anything and never
  times a dwell.
- Scene: `.app(name, UlanziFrame)`, where `UlanziFrame` is `{text[], image[],
  draw[]}` — the official schema's three fields. A constant `duration` is
  still sent, the way the community does; it is not a TTL and nothing relies
  on it.
- Port: a new `UlanziDevice` actor — `showApp(_:named:)` (an upsert),
  `removeApp(named:)`, `customApps()`, `identity()`. Deleting an app is a POST
  to `/api/custom?name=` with an **empty body**; `{}` does not delete —
  measured. It has no `switchDiyApp`: the measured effect of that call is the
  user's interface moving away from where they left it. Only an explicit user
  action — a "Show on clock" panel action, if one comes — may ever call it;
  never a schedule, a launch, or any automatic path.
- Images: `UlanziImage.bundled(name)`, 16 px art shipped as resources and sent
  inline as bare base64 per element. There is no flash to install into and no
  catalogue.
- Custody: `UlanziCustody` keeps a **durable** record of the app names this
  app pushed to each clock, one per tile, because apps outlive the sender
  here. The rule is the opposite of AWTRIX's, which is why custody belongs to
  the adapter:
  - every push is an upsert; at session start and on offline→online recovery
    the session re-pushes ALL tile apps at once, because custom apps most
    likely do not survive a clock reboot;
  - the start-up sweep (`customApps()` ∩ record) deletes the names no live
    tile claims — leftovers from crashes or older builds;
  - a paused tile keeps its page, held by an idle frame; it is never deleted;
  - a tile removed → its app deleted at once; quit → everything recorded
    deleted;
  - `lifetime` is emulated: a tile with no successful delivery for longer than
    its face's lifetime has its page flipped to the idle frame — the stale
    figure must not stand, and the page is not deleted while the tile lives.
    After a crash of the Mac the last frame stays until the next launch; that
    residual is accepted.
- Health: reachable when `/getBase` answers. The clock has a 3600 mAh battery,
  but no stock API reports its level, so the panel draws no battery line at
  all rather than a placeholder.

### Discovery and model detection

- `ClockDiscovery` merges the existing Bonjour browse for AWTRIX with a new
  `UlanziBroadcastListener` on UDP 55555. A broadcast carries the MAC and the
  serial, which is the identity relocation needs. Listening is passive, but it
  runs under the same rule as the browse: while the Add clock sheet is open, or
  while a configured clock is not answering.
- A clock added by address is probed with `GET /api/stats` and `GET /getBase`
  concurrently; its model is whichever response **decodes**. Status codes are
  not trusted — the TC002 answers the AWTRIX path with 301, and firmwares
  answer foreign paths unpredictably. This is `CatalogueIconInstaller`'s rule
  of trusting the magic bytes over the status.

### Connectors and faces

| Connector | Reading | Trigger | AWTRIX face | TC002 face |
| --- | --- | --- | --- | --- |
| weather | `WeatherReading` → `WeatherTheme` | every 600 s | as today: `.app("weather")`, 8×8 icon, overlay, lifetime 3600 | `.app("weather")`: 16×16 sky GIF on the left, temperature coloured by how it feels; `°` is outside the font's ASCII and is drawn as pixels; no overlay exists, so the icon carries the sky; lifetime 3600 emulated |
| claude | `ClaudeUsageReading`, from the status-line file | every 300 s | as today: progress bar, `ClaudeStar` 8×8, lifetime 900 | `.app("claude")`: `ClaudeStar` 16 px, `42%`, bar from `dr` and `df` along the bottom, lifetime 900 emulated |
| anecdotes | `PreparedAnecdote`; reading it retires it | every 1800 s + maintenance | as today: held banner, RTTTL jingle, audio on the Mac | none yet — on-device sound does not exist on the stock firmware, so audio stays on the Mac; a visual banner face (raster, Mac-side marquee) is a possible later follow-up |
| vpn | `VPNState` for one watched VPN | events + 60 s recheck | a lamp write through `IndicatorCustody`, not a scene | none — the TC002 has no global indicators |
| z.ai usage | `ZaiUsageReading` from the z.ai coding-plan usage API, keyed by the tile's API key | every 600 s | the shared three-row usage face, the metrics the API returns | the shared three-row usage face |

The z.ai tile's config carries its API key. The key is pasted in the tile's
detail and stored in the login keychain, keyed by the tile; the tile record
itself holds no secret. Its face is the shared three-row usage layout, the
same component the Claude TC002 face uses.

The usage endpoints are the dashboard's own routes: `GET
https://api.z.ai/api/monitor/usage/model-usage`, per-model consumption over a
time range, is the tile's reading source; `GET
api.z.ai/api/monitor/usage/quota/limit` carries the limits beside it (Zhipu
plans: host `open.bigmodel.cn`). `Authorization: <key>` without `Bearer`.
z.ai documents no usage API — these are the dashboard routes the community
trackers use, and they carry no stability contract. The decoder tolerates
missing and extra fields and pins only what a live response shows; when a
route dies, the connector reports failing and nothing else breaks.

Carried-over rules:

- The existing drawing tests (`ClaudeUsageConnector.output(for:)`, the weather
  output) stay where they are: they already exercise the face through
  `output(for:)` and `produce()`. Moving them to face files is optional, and
  moving is all it may ever be — never a rewrite.
- A Focus change retracts a tile whose policy no longer allows it, on both
  models: `removeApp` on AWTRIX, an empty-body delete on the TC002. This is
  what `FocusGatedConnector` does for Claude today, generalised. On the TC002
  it is what keeps a figure from standing for a whole emulated lifetime.
- `OpenMeteoSource` caches one answer today, `(reading, at, of: Coordinates)?`.
  Two weather tiles at two locations would evict each other on every poll. The
  cache becomes keyed by coordinates.
- The History belongs to the anecdote tile, and Play again delivers through the
  session of the clock that tile is on.

### Claude usage — read from Claude Code's status line

The Claude tile no longer handles a credential. Claude Code runs a configured
status-line command after each reply and hands it a JSON document on stdin. For
Pro and Max accounts that document carries `rate_limits.five_hour` and
`rate_limits.seven_day`, each with `used_percentage` (0–100) and `resets_at`
(Unix seconds). This is a documented contract. `/api/oauth/usage`, which the
app polls today, is not, and `ClaudeUsageReading` already records one wrong
guess at its shape.

- **The hook.** A POSIX `sh` script the app writes to
  `~/Library/Application Support/PixelClockTiles/claude-statusline.sh`. It
  reads stdin once. When the text contains `"rate_limits"`, it writes the whole
  document to `claude-status.json` beside itself through a temporary file and
  `mv`, which is atomic on one volume. When a status line was configured before
  this one, it then pipes the same input into that command and passes its
  output through. No `jq`, no interpreter: the script stores, the app parses.
  Skipping documents without `rate_limits` keeps a session that has not had
  its first reply yet from blanking the figure another session wrote.
- **Connecting.** It edits one key of `~/.claude/settings.json`, `statusLine`,
  and only on the user's action ("Connect Claude Code" in the general
  settings). The value it replaces is kept in `claudeStatusLine.previous`, and
  "Disconnect" puts it back, or removes the key when there was none. Every other
  key keeps its value. A file that does not parse as a JSON object is left
  alone and the action says why. The confirmation names the cost: with any
  custom status line, Claude Code stops showing most of its footer hints,
  `esc to interrupt` among them.
- **Reading.** `StatusLineClaudeUsageReporter` conforms to
  `ClaudeUsageReporting` and decodes the file on each tile refresh. It is a
  local read, so there is no watcher. A document missing one window keeps the
  last value this process saw for it.
- **What a reading means.** `ClaudeUsageReading` keeps `utilization` and
  `resetsAt` for the weekly window, which both faces draw, and gains
  `fiveHour`, which no face draws yet. It also carries `observedAt`, the file's
  modification time. Once the weekly `resets_at` has passed, the reporter
  answers nil rather than zero. The window it described is over, spending since
  then is unknown, and zero would be a calm, confident lie — the rule the
  reporter already follows. The tile then leaves the clock at the end of its
  lifetime, and comes back at the next Claude Code reply.
- **Freshness.** The figure moves only when a Claude Code session gets a reply.
  Spending in claude.ai or the desktop app shows up at the next one.
  `claude -p` does not run the status line.
- **Removed**, with their tests: `KeychainClaudeCredentials`,
  `FileClaudeCredentials`, `AnyClaudeCredentials`, `ClaudeCredentialSearch`,
  the HTTP `ClaudeUsageReporter` with its token cache, and
  `ClaudeUsageReading.init?(json:)`. The app no longer reads another program's
  credential, so there is no keychain prompt, before or after the bundle id
  changes.

### VPN tiles

`VPNPresence` recognises a tunnel by its process: the application bundle plus
the binaries that exist only while a tunnel is up (`WatchedVPN`). A tile's VPN
is chosen from a catalogue of these presets — Pritunl and Amnezia today. A user
cannot describe a bundle and its tunnel binaries, so a new VPN is added to the
catalogue in code.

Tile config:

| Field | Meaning |
| --- | --- |
| `vpn` | A `WatchedVPN` preset |
| `slot` | top, middle or bottom lamp |
| `upColour` | `#RRGGBB`, from a SwiftUI `ColorPicker` or the palette |
| `whenDown` | `.off` or `.blink(colour)`, blinking at today's 500 ms |

`VPNIndicatorPolicy` stops reading the Focus. A tile's lamp says one thing —
whether its VPN is up — while the tile's `TilePolicy` allows it to run; when
the policy does not, the tile lets go of the lamp.

Several tiles may share a lamp. At any moment the lamp belongs to the one tile
whose policy allows it; with none, the lamp is off. Two tiles on the same slot
whose 144-cell grids intersect are refused when saved, naming the overlap:
"Pritunl and WireGuard both claim the middle lamp: Work, 10:00–19:00".

The palette — saturated on purpose, because at brightness 2–3 the LEDs wash
pastels towards white:

| Name | Colour |
| --- | --- |
| Electric Lime | `#A3FF12` |
| Cyber Cyan | `#00F0FF` |
| Hot Magenta | `#FF2BD6` |
| Ultraviolet | `#8B5CF6` |
| Neon Mint | `#3DFFB0` |
| Sunset Orange | `#FF6B1A` |
| Solar Yellow | `#FFE600` |
| Alarm Red | `#FF1744` |

## Menu bar UI

### The panel

1. Header: `PixelClockTiles` and the gear.
2. Clock switcher — one segment per clock, hidden when there is one. The
   selection persists (`selectedClockId`) and is the "current clock" the Add
   tile menu is checked against.
3. The selected clock's status: `DeviceStatusLine`; `BatteryLine` on AWTRIX
   only; `DiscoveryStatusLine` while it is not answering.
4. Tile rows: connector icon and name, a short result (`12°C`, `42%`,
   `in 12 min`, `up`), a state badge (paused, held by Focus, silent hours,
   failing with backoff), and `▶` (not for ambient tiles), `⋯`, `✕`. `✕`
   confirms inline — "Remove Weather from Desk?" — because removing loses the
   tile's settings and, on the TC002, takes its app off the clock. Rows drag
   to reorder; the order is the tiles record's order and is the same on every
   clock.
5. `+ Add tile` — every connector, with `TileCatalogue.availability` deciding
   which are enabled and why the others are not.

### Tile detail

A surface opened by `⋯`, in the panel's window like the settings and the
History today. The shared `TilePolicy` editor on top, the connector's own block
under it:

```text
┌ ← Weather · Desk ─────────────────────────────┐
│ Paused                                    [ ] │
│ Refresh      ●──────────  30 s                │
│ Works in Focus:                               │
│   ☑ No Focus  ☑ Work  ☑ Personal              │
│   ☐ Do Not Disturb  ☐ Sleep                   │
│   Other Focus / cannot tell:     [Run ▾]      │
│ Hours        [Always ▾]                       │
│ ── Weather ─────────────────────────────────  │
│ Location     [Tbilisi                   🔍]  │
└───────────────────────────────────────────────┘
```

The anecdote tile's block carries the History button, which opens the existing
`HistoryMenu`. The VPN tile's block carries the VPN, lamp, palette and
`ColorPicker`, and the down behaviour. The Claude tile's block carries the
Claude settings — the whole of them, Connect / Disconnect included. The state
they edit is machine-wide and shared by every Claude tile: editing it in any
one tile's detail edits it for all of them. General settings carries no
Claude section.

The Claude tile's block also carries a display selector — daily limit, weekly
window, or current session. On the TC001 the choice picks one of three faces;
on the TC002 the face draws all three at once on the tile's page. That
three-row usage layout is a **shared face component**, not Claude's own: any
usage tile reuses it, and a z.ai coding-plan-usage tile ships on it.

### General settings

- Clocks: the list with name, model, address and status; rename; remove with
  confirmation, which takes every tile off that clock through its custody; add
  from what discovery found — both models — or by address.
- Mac-wide: the microphone hold for audible tiles, the Full Disk Access line
  (what it changes about Focus matching), the login item, and Connect /
  Disconnect Claude Code with the time of the last status-line document.
- Gone from here: the weather switch (now a tile), the location (now the
  weather tile's), the quiet hours (now every tile's `TilePolicy`).

### Behaviour

- The menu bar glyph shows offline for the **selected** clock. "Any clock
  offline" would be permanent on a laptop that has left the kitchen clock
  behind.
- No clocks: "No clocks yet" and "Add clock…", which opens the Clocks section.
  A clock with no tiles shows only `+ Add tile`.
- Text and availability are computed in plain types (`TileRowLine`,
  `AddTileMenuItem`) and tested like `NextRunLine` is; the views stay thin.
  `MenuPanel.swift` is split into `ClockSwitcher`, `ClockStatusBlock`,
  `TileRow`, `AddTileMenu`, `TileDetail` and `ClocksSettings`. `PanelWidth` and
  `ResizeBorder` are reused as they are.

## Persistence and migration

New `UserDefaults` keys, JSON-encoded: `clocks: [ClockRecord]`,
`tiles: [TileRecord]`, `selectedClockId`, `ownedApps.<clockId>` (TC002
custody), `borrowedOverlay.<clockId>` (AWTRIX custody),
`batteryHistory.<hardwareIdentity>`.

Migration of an existing installation runs as steps. Each step runs once and is
idempotent: its marker is written last, so a step that fails part-way runs
again from the old keys on the next launch rather than leaving half a model.
The old keys are never written or removed. A row moves in the phase that stops
the app writing its source key. Before then the old UI still writes it, and a
copy taken earlier would be stale by the time anything read it — for the
borrowed overlay, a loan already given back.

| Old | New | Step · phase |
| --- | --- | --- |
| `deviceHost`; absent, `192.168.1.72`, the address the launch used | one AWTRIX clock named "Clock" | `migration.clocks` · 1 |
| `deviceUID` | that clock's `hardwareIdentity` | `migration.clocks` · 1 |
| `connector.<id>` for every registered connector; absent or unreadable, the connector's defaults | a tile on that clock; `isEnabled` → `!isPaused`; interval index → duration → seconds; `lastDeliveredAt` kept | `migration.tiles` · 1 |
| `quietStartHour` / `quietEndHour` | `window: .quiet(…)` on the audible tiles; hours never written are the 23:00–08:00 the app kept | `migration.quietHours` · 4 |
| `weatherLocation` | the weather tile's `config` | `migration.weatherLocation` · 4 |
| the always-on VPN lamps | two VPN tiles, both `whenUnknown: hold` (today a Focus that cannot be named leaves both lamps dark): Pritunl on the top lamp, working in Work only, `#90EE90`, down → blink `#FF0000`; Amnezia on the bottom lamp, working in Work and Personal, `#A855F7`, down → off | `migration.vpnTiles` · 4 — on the first clock, and not at all when it is a TC002: a TC002 has no lamps |
| the borrowed overlay | `borrowedOverlay.<clockId>` of that clock | `migration.borrowedOverlay` · 4 — an AWTRIX first clock only; a TC002 now answering at the old address inherits no loan |
| `batteryHistory` | `batteryHistory.<uid>` | `migration.batteryHistory` · 4 |

Behaviour that changes on purpose, so it is not reported as a regression:

- A Focus outside the four built-in modes now follows `whenUnknown`. For the
  anecdote tile that is hold, where today any named mode other than Do Not
  Disturb and Sleep speaks.
- The VPN lamps now need `INFocusStatusCenter` authorisation as well as Full
  Disk Access to follow a Focus, like every other tile; today they read the
  mode with Full Disk Access alone.
- The Claude figure shows nothing until Claude Code is connected and has
  replied once, and it moves only with Claude Code replies. Today it polls
  every five minutes whatever the user is doing.

## Rename — phase 0

- Executable target `AwtrixConnectorsApp` → `PixelClockTilesApp`; bundle
  `PixelClockTiles.app`; `Package.swift`, `Scripts/bundle.sh`, `Info.plist`.
- `AwtrixKit` → `PixelClockKit`, since it holds both firmwares' adapters.
- AWTRIX-specific types keep their names — `AwtrixDevice`, `AwtrixError`,
  `DeviceDiscovery.isAwtrixInstance`. In this architecture they are the AWTRIX
  adapter, and the name says exactly what is inside.
- Bundle id `dev.artk0re.awtrix-connectors` → `dev.artk0re.pixelclocktiles`,
  with the old domain's keys copied into the new one on first launch.
- Paid once by the user: macOS asks again for location, notifications and
  Focus, because grants are bound to the bundle id and the signature; the login
  item is registered again.
- The repository directory stays `awtrix-connectors` until decided otherwise;
  renaming it breaks the tea-rags registration.

## Error handling

- A clock that stops answering stalls only its own session. Its tiles back off
  as today; other clocks carry on.
- Custody failures are kept, not dropped: AWTRIX keeps the overlay record, the
  TC002 keeps the owned-name record, and the next restore or launch retries.
- Quit restores every session concurrently inside the existing quit budget; a
  second clock does not double the time a quit may take.
- TC002 answers carry their own `code` in the body — every live answer so far
  did (`{"code":200,"message":"ok"}`), and the documentation lists
  `{"code":400,…}` and `{"code":404,"message":"custom app not found"}`. The
  adapter treats a non-200 `code` as a failure whatever the HTTP status says,
  until a live check shows how the two relate.
- A migration failure leaves the old keys untouched and the marker unwritten.
- Claude Code's settings file is written only on the user's action and only
  when it parses as a JSON object. A write goes through a temporary file and a
  rename, so a crash never leaves a half-written settings file behind.

## Testing

- Faces: pure functions; the existing drawing tests already exercise them.
- `TilePolicy`: every one of the 144 cells, the lamp overlap, the 30 s floor,
  the scale and its snapping.
- Adapters: against the existing `Transport` double. `UlanziDeviceSendTests`
  pins exact paths and JSON bodies, as `AwtrixDeviceSendTests` does.
- Fixtures captured from the clock in this design's session: the UDP broadcast,
  `/getBase`, the 301 on `/api/stats`, the `customList` bodies.
- `UlanziCustody`: reconciliation against a fake `customList`, lifetime
  emulation, quit.
- Migration: snapshots of old `UserDefaults` in, records out; a second run
  changes nothing.
- Claude status line: the hook run by the tests with `/bin/sh` against sample
  documents — with and without `rate_limits`, with a previous command chained,
  with a previous command that fails. The settings edit against fixture files —
  no `statusLine`, an existing one, one that does not parse, other keys kept.
  The reporter against fixture documents, including a missing window and a
  `resets_at` in the past.
- Mutation, as HANDOFF lays down: one site at a time, and after adding a guard,
  re-run the mutations of the guards in front of it.

What only a person at the hardware can settle, added to HANDOFF's list:

1. A weather frame and a Claude frame on the TC002, read from across the room.
2. Two VPN tiles sharing a lamp: switching Focus hands the lamp from one to the
   other with no flash of the wrong colour.
3. With Full Disk Access on a signed build, Work and Personal are recognised by
   `com.apple.focus.work` and `com.apple.focus.personal`. `VPNIndicatorPolicy`
   already records these two as unverified from outside the app, and now every
   tile depends on them.
4. Removing a TC002 tile takes its app off the clock, and a relaunch after a
   force quit removes an app whose tile is gone.
5. The `image[]` element spelling on the wire: the encoder emits bare base64
   per element; whether the device also accepts a data URI prefix is
   unverified.

## Phases

Each phase is a series of small commits with the tree green before and after.

| # | Phase | What becomes true |
| --- | --- | --- |
| 0 | Rename | PixelClockTiles, PixelClockKit, the new bundle id and the key copy. No behaviour change |
| 1 | Domain and persistence | Clock and tile records and the migration. The app reads its one clock from `clocks` instead of `deviceHost`, and each connector's cadence and pause from its tile instead of `connector.<id>` — the records have a reader from the commit that adds them |
| 2 | Ports and AWTRIX parity | `DeliveryChain`, the AWTRIX `ClockSession`, connectors split into `read` and `awtrixFace`, indicator custody. No behaviour change; the existing tests are moved, not rewritten |
| 3 | TC002 adapter | `UlanziDevice`, `UlanziCustody`, the UDP listener, model detection, the weather and Claude TC002 faces. The app still drives one clock — the first in `clocks`, of whichever model — so the TC002 works with the current panel from here |
| 4 | Several clocks and tiles | A session per clock, scheduling by `TileKey`, `TilePolicy` with its grid and overlap check in place of the global `FocusGate`, `TileCatalogue.availability`, VPN tiles with lamp ownership, the keyed weather cache, retraction on Focus change, health and battery history per session |
| 5 | UI | The switcher, tile rows, Add tile, tile detail with the policy editor and colour picker, the Clocks section; `MenuPanel` split up |
| C | Claude via the status line | The hook, Connect / Disconnect, `StatusLineClaudeUsageReporter`; the keychain reader and `/api/oauth/usage` removed |

Each phase gets its own implementation plan. A type lands in the phase that
first reads it, never ahead of its caller.

The phases do not run strictly in order. After phase 0, five lanes run at once,
each in its own worktree:

- phase 1;
- phase 2;
- part A of phase 3, the TC002 adapter's leaf types;
- part A of phase 4, `TilePolicy` as pure types;
- lane C.

Parts B of phases 3 and 4 follow once phases 1 and 2 have landed, and phase 5
comes last. Parts A are a deliberate exception to the rule above. Their types
reach their callers in parts B of the same program, and nothing reaches
`master` before the callers do. Lane C touches the Claude connector, which
phase 2 splits into `read` and a face; the `ClaudeUsageReporting` protocol is
the seam both keep.

The TC002 comes third rather than last because it is the clock in use: after
phase 3 it shows the weather and the Claude figure while tiles and the new UI
are still being built.

Phase 2 is the riskiest, and it is held to parity for that reason: it runs
through `AppModel.swift` (1,948 lines, 31 commits, 42% of them fixes) and
`MenuPanel.swift` (21 commits, 48% fixes). New capability arrives only once the
structure stands on the moved tests.

## Follow-ups

- **F1 — TC002 rendering and on-device sound.** Done, 2026-09-18
  (`research/2026-09-18-tc002-screens-and-sound.md`): the screens, the DIY
  pages, the payload limits and the delete semantics are in "Measured device
  facts" above, and the per-tile app model is in the Ulanzi adapter. No
  `DeviceSpeaker`: the stock protocol exposes no audio endpoint, so anecdotes
  stay on `MacSpeakers` on both models. A visual anecdote face (raster banner,
  Mac-side marquee) remains possible later; a device audio sink would be what
  makes availability rule 3 matter per clock.
- More VPN presets in the catalogue.
- An anecdote face for the TC002 — a raster banner scrolled by re-pushing;
  audio stays on `MacSpeakers` either way.

## Out of scope

- The donation prompt and anything else about distribution.
- A licence review of the voice pipeline (XTTS-v2 and the cloned voices)
  before the app is given to anyone else. Required before then, not now.
- MQTT. The payload is the same; a broker adds a process and nothing the app
  needs.
- Replacing the TC002's stock application.
- Custom Focus modes beyond the four built-ins, which would need
  `ModeConfigurations.json`.
- An App Store build. The app edits Claude Code's settings file and reads the
  Focus database from outside a sandbox.
- Drawing the five-hour Claude window on a face. The reading carries it; which
  face shows it, and how, is a later decision.

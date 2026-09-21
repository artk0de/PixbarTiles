# TC002 screens, rendering and on-device sound — spike F1

Status: research, recommendation only · 2026-09-18

Follow-up F1 of
[the multi-clock design](../specs/2026-09-18-pixelclocktiles-multi-clock-design.md).
Nothing here changes code. The device was touched only by read-only HTTP GETs, a
passive UDP listen and TCP port checks. Every step that needs a state change is in
[Proposed experiments for the user](#6-proposed-experiments-for-the-user).

Every claim carries one of three marks:

- **measured** — seen on the clock at `192.168.1.72` today, with the command;
- **documented** — written down by Ulanzi or by a community project, with the link;
- **inferred** — a conclusion drawn from the two above, not checked.

## Answers in brief

1. **Screens.** The stock UI is three levels deep. L1 is the top level (four dots
   on the right edge), a short knob press enters or leaves L2 (the apps of one
   group), and a long press opens an app's functions, which is L3.
   `switchDiyApp` is specified to "enter DIY level-2 display", so it pulled the
   user out of an L3 tool into the DIY group. Custom apps are pages of the DIY
   group, the carousel never visits them, and a push alone does not bring them on
   screen. No custom app can be shown without moving the user.
2. **Rendering.** A custom app is the only surface third-party code can draw on
   without replacing the firmware. The probe looked like a picture because it
   sat in the DIY group as a still, full-screen frame with no motion and no
   native chrome, and because the payload itself was clipped and dim. The device
   draws pixels 1:1 and never scales, so crisp output means drawing pixel-exact
   art on the Mac and sending it as a `db` bitmap or a PNG/GIF.
3. **Sound.** The stock protocol has no audio at all. Root adb works today but
   depends on an open root backdoor and needs a player we would build ourselves.
   A FlyThings app replaces the whole stock application, `/api/custom` included.
   The community runtime replaces it too, and its sound store holds 192 kB per
   sound, about six seconds of speech. None of the three is fit for anecdotes now.
4. **Recommendation.** Tiles go out as one custom app per clock, rendered as
   bitmaps on the Mac and rotated by the Mac. `switchDiyApp` is called only when
   the user presses a button asking for it. Anecdote audio stays on
   `MacSpeakers`, so no `DeviceSpeaker` is needed and rule 3 stays as it is. A
   visual anecdote face for the TC002 becomes possible, because Cyrillic can be
   drawn as pixels.

## 0. What was measured today

All at 2026-09-18 16:10 UTC from this Mac.

| Command | Result | Mark |
| --- | --- | --- |
| `curl -s http://192.168.1.72/getBase` | `{"devSn":"B0D32I008U3671403",…,"mcuVer":"V1.0.17","appVer":"1.1.1"}` | measured |
| `curl -s http://192.168.1.72/api/customList` | `{"apps":[],"count":0}`: no probe left behind | measured |
| `curl -s http://192.168.1.72/getConfig` | `"brightness":{"level":"low","low":50,…}`, `"volume":4`, **`"carouselSpeed":0`** (carousel off), `"scrollSpeed":7` | measured |
| `curl -s http://192.168.1.72/getToolsConfig` | enabled: clock, weather (Москва, lat/lon set), busy, tomato, soundlight; `toolsOrder` 1–9 | measured |
| `curl -s http://192.168.1.72/getDiyImages` | `{"images":[],"imageOrder":[],"enable":true}`: no DIY pictures stored | measured |
| `curl -s http://192.168.1.72/getSocial`, `/getCalendar` (printed enable flags only, because both return secrets in clear) | douyin on; icloud on | measured |
| `curl -s http://192.168.1.72/getMqttStatus` | `{"enabled":true,"connected":false}` | measured |
| UDP listen on 55555 for 6 s (Python `socket.bind(('',55555))`) | 5 datagrams, ~1.02 s apart (one 1.95 s gap): `Ulanzi TC002 9b9a:ccc4b2779b9a:B0D32I008U3671403:false` | measured |
| `nc -z -w 2 192.168.1.72 <port>` | open: 80, 5555. Closed: 22, 23, 443, 1883, 8000, 8080, 8888, 9000 | measured |
| `which adb` | not installed, so no adb reads were made | measured |

The API cannot report which app is on screen or which level the UI is at. That
is documented ([atomicstack README](https://github.com/atomicstack/tc002-customisation),
[official issue #26](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/26)),
so every screen question below ends in an experiment the user has to watch.

## 1. Screens

### 1.1 The three levels

What Ulanzi says, verbatim:

- [TC002 FAQ](https://docs.ulanzistudio.com/tc002/en/faq/): "The TC002 interface
  has three levels: Four dots on the far-right side of the screen indicate that
  you are on the first level. Press the knob once to enter or leave the second
  level. Rotate the knob left or right to switch between applications on the same
  level. The scoreboard, Pomodoro timer, stopwatch, and similar features are on
  the third level. Press and hold the knob for three seconds; after the beep, the
  third level opens." — **documented**
- [Product page](https://www.ulanzi.com/products/tc002-pixbar-smart-pixel-clock-ii):
  "Rotate: Switch between apps at the same level", "Short press: Enter/exit the
  current app level", "Long press: Access app functions"; the centre button
  "Quickly enter/exit 'BUSY Clock' mode". — **documented**
- [Tools guide](https://docs.ulanzistudio.com/tc002/en/tools/guide.html): "rotate
  the knob to Tools. Press the knob to open the Tools category. Rotate the knob to
  select Weather, Focus Clock, or BUSY Clock. Press and hold the knob to open the
  selected tool." It also warns that until the knob is pressed inside Focus Clock,
  "the center button still switches between apps". — **documented**
- [Studio guide](https://docs.ulanzistudio.com/tc002/en/software/ulanzi-studio.html):
  "TC002 combines Calendar, Tools, Social Media, and DIY apps". — **documented**

The model that follows, marked **inferred** until experiment E1 confirms it:

| Level | What is on screen | Knob |
| --- | --- | --- |
| L1 | the top level: one entry per group (Calendar, Tools, Social Media, DIY), marked by four dots on the right edge, most likely one dot per group | rotate moves between groups; short press enters one |
| L2 | the apps of one group: clock, weather, BUSY… for Tools; DIY pictures and custom apps for DIY | rotate moves between that group's apps; short press goes back to L1 |
| L3 | an opened app in its interactive state: the FAQ names scoreboard, Pomodoro and stopwatch; the Tools guide opens Weather, Focus Clock and BUSY the same way | long press (3 s, beep) enters; the buttons now drive the tool |

The API numbers the same groups. `/switchApp` takes `type` =
`social | calendar | diy | tools`, and the `diy` indices are "0–20 (host) /
100–120 (HA) — Dynamic"
([official protocol, § 2.3](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/protocol/Ulanzi_TC002_protocol-http-mqtt_CN.md)).
— **documented**

### 1.2 What `switchDiyApp` does, and why the UI went from L3 to L2

- The official protocol document (PDF `自定义APP协议_0813.pdf` in
  [PR #18](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/pull/18))
  says: "切换后进入 DIY 二级显示": after the switch the device enters the DIY
  level-2 display. The markdown protocol puts it as "Request accepted, enters DIY
  level-2 display". — **documented**
- The reply `{"message":"app switch requested","data":{"name":"probe_claude","index":100}}`
  carries the app's DIY index. Dynamically created apps take indices 100–120
  (official § 2.3), and `customList` holds them internally as 100, 101, …
  ([issue #22](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/22)).
  — **documented**
- The switch is queued, "the switch happens on the next UI tick"
  ([atomicstack HTTP-API](https://github.com/atomicstack/tc002-customisation/blob/HEAD/HTTP-API.md#apiswitchdiyappnameapp--jump-to-a-custom-app)).
  — **documented**
- The endpoint answers **POST only**: `GET /api/switchDiyApp?name=pct-duo`
  returns `Error 404: Not Found`, the same query sent as POST returns the 200
  with the index. — **measured** 2026-09-21
- The sibling routes: upsert is `POST /api/custom?name=<name>` with the render
  envelope as the body (`{"code":200,"message":"ok"}`); the list read is
  `GET /api/customList` (§ 0). `GET /api/custom` — no such route — answers
  404. — **measured** 2026-09-21

So the user was inside an opened tool at L3 (the enabled tools on this clock are
clock, weather, BUSY, tomato and soundlight, per the measured `getToolsConfig`),
and the call dropped them into DIY at L2, positioned on `probe_claude`. It did
not go back to where they had been. Nothing in the documentation says a running
timer survives that; we
treat it as possibly lost (**inferred**, see E10). This matches the user's
account: "the screen opened by itself … I had the interface on L3, but it
switched to L2 on its own" (session transcript, 2026-09-14 19:12).

### 1.3 Where custom apps sit next to the built-in screens

- A custom app is a **DIY app**. It shows up "in the device's own UI as a DIY
  app as soon as the first frame is pushed"
  ([atomicstack CUSTOM-APP](https://github.com/atomicstack/tc002-customisation/blob/HEAD/CUSTOM-APP.md#lifecycle)),
  and "Hello World appears on the DIY screen of TC002"
  ([MQTT guide](https://docs.ulanzistudio.com/tc002/en/software/mqtt.html)).
  — **documented**
- The DIY group also holds the DIY images, the still pictures uploaded through
  Ulanzi Studio and stored in `/data/diy/`, up to six of them
  ([DIY image guide](https://docs.ulanzistudio.com/tc002/en/software/diy-image.html)).
  Images take DIY indices 0–20 and custom apps 100–120. — **documented**
- Knob rotation at DIY L2 moves between these pages. "Each app name is a DIY page
  on the clock; use the knob to cycle between them"
  ([doitian/ulanzi-tc002](https://github.com/doitian/ulanzi-tc002)).
  — **documented** (community)
- Built-in tools, calendars and social counters are closed code inside
  `/res/lib/libzkgui.so`. Their HTTP handler is `ConfigWebServer::doTask` in the
  same library
  ([atomicstack HTTP-API](https://github.com/atomicstack/tc002-customisation/blob/HEAD/HTTP-API.md)).
  A third party can switch them on and off, reorder them and configure them. It
  cannot draw into them. — **documented**

### 1.4 Can a custom app be shown without switching the user's screen?

No. The options are:

| Way | What the user sees | Mark |
| --- | --- | --- |
| Push only (`POST /api/custom?name=`) | nothing, unless the clock is already parked on that DIY page. "Pushing content does **not** switch the app — the device must already be showing that custom app" ([official § 3.1](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/protocol/Ulanzi_TC002_protocol-http-mqtt_CN.md)). While parked there, each push updates the screen at once | documented |
| `switchDiyApp` | the UI jumps to DIY L2 from wherever it was, L3 tools included | documented, measured on 2026-09-14 |
| `/switchApp {"type":"diy","index":10x}` | the same jump by index | documented |
| `/keyEvent` (knob/buttons) | simulated navigation, just as intrusive and blind, since the API cannot say where the UI is | documented |
| overlay, notification, indicator | none on stock firmware: "AWTRIX-style notify — Not supported" (official § 7) | documented |

The one non-intrusive arrangement is for the **user** to park the clock on our
DIY page. From then on every push shows up immediately, and the user leaves with
the knob whenever they like. — **inferred**

### 1.5 Rotation, persistence, expiry

- **Rotation.** "Carousel cycles built-in tools only; custom apps are shown on
  demand via push/switch"
  ([official README, FAQ](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/README_EN.md));
  the same is reported in [issue #22](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/22).
  On this clock `carouselSpeed` is `0`, so nothing rotates automatically at all
  (**measured**). The only published way to rotate custom apps is an external
  timer that calls `switchDiyApp` in turn (issue #22 comment), which is exactly
  the disruption to avoid. — **documented**
- **Persistence while running.** An app stays listed after its sender goes away
  and after its `duration` runs out, until `{}` is posted to its name
  ([issue #24](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/24),
  atomicstack CUSTOM-APP). — **documented**
- **Across a reboot.** Custom apps are "created/pushed live over HTTP/MQTT (no
  file on disk)" (official README FAQ) — **documented**. They are therefore most
  likely lost on reboot — **inferred**; atomicstack marks it *not established*.
  See E9.
- **Expiry.** No `lifetime` exists. `duration` is not part of the official
  payload schema, which is `text`, `image`, `draw` only (official § 3.1, § 4). It
  is not a time-to-live: `duration: 8` left the app listed indefinitely (issue
  #24). Whether it affects the page on screen is unknown; see E8. — **documented**
- **Capacity.** The dynamic DIY range 100–120 implies at most 21 custom apps.
  — **inferred**

## 2. Rendering

### 2.1 What third-party code can draw on

| Surface | How it is fed | Can we draw into it? | Mark |
| --- | --- | --- | --- |
| Built-in tools (clock, weather, BUSY…), calendar, social | `/setToolsConfig`, `/setCalendar`, `/setSocial`, written to `/data/setting.ini` | no, only enable, reorder and configure | documented |
| DIY images | `/setDiyImages`, files in `/data/diy/`, at most 6, 52×16 PNG/JPEG/GIF | yes, but only as stored pictures written to flash (`/data` is jffs2), shown in the same DIY group | documented |
| Custom apps | `POST /api/custom?name=`, kept in RAM | yes, `text[]` + `draw[]` + `image[]`, live | documented |
| A native app of our own | a FlyThings project compiled to `libzkgui.so`, or the community runtime | yes, anything, but it **replaces** the stock application (§ 3) | documented |

So on the stock firmware, "custom app or screen" has only one answer: a custom
app. A "native screen" means replacing the firmware, which the spec lists as out
of scope. — **inferred** from the rows above.

A native half-measure exists for weather alone: a TC002 weather tile could write
the tile's coordinates into the built-in weather tool (`/setToolsConfig`,
`weather.lat/lon`) instead of drawing anything. This clock already runs that tool
with Moscow coordinates (**measured**). It would look native and join the
carousel. The cost is that it overwrites the user's own device setting, uses
Ulanzi's cloud weather (QWeather/OpenWeather) rather than Open-Meteo, and leaves
the face nothing to decide. Not recommended. — **inferred**

### 2.2 Payload limits

Official figures come from the
[protocol § 4](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/protocol/Ulanzi_TC002_protocol-http-mqtt_CN.md),
the [README pitfalls](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/README_EN.md)
and the PR #18 samples. The community figures were observed on this same firmware,
1.1.1.

| Area | Limit | Source |
| --- | --- | --- |
| Canvas | 52×16, origin top-left, anything outside is clipped silently | documented (official) |
| Text charset | ASCII 0x20–0x7E only; `°` is dropped without a gap | documented (official; [#20](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/20)) |
| Lowercase | official samples send lowercase (`"Sunny"`, `"t-1 AT"`) after the v1.1.0 font fix; PixDeck reports it blank and #20 "partially/incorrectly" | conflicting, see E5 |
| `fontHeight` | official: "Only 5 or 10", other values ignored. Community: tiers 3–5 small, 6–8 medium, 10 large ([#25](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/25)) | conflicting, see E5 |
| Glyph width | a 10 px glyph is about 6 px wide | documented (atomicstack, PixDeck's estimate) |
| Placement | `x`/`y` are relative to `rect`; `align`/`valign` apply **only when `x`/`y` ≤ −999**; `charSpacing` 0–10 | documented (official) |
| Aligned text | only the **first** `text[]` element that uses `align`+`rect` is drawn; a second one is dropped without an error | documented ([#23](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/23)) |
| Scroll | none; long strings are clipped. A marquee means re-pushing every 0.4–0.5 s — or a pre-rendered scrolling GIF, which the panel plays by itself | documented (official FAQ; [#21](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/21)); GIF route **measured** 2026-09-21 |
| Font | the official demo ships the AWTRIX-modified TomThumb 3×5 ([#17](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/17)); that the stock renderer uses it for the small tier is **inferred** | documented / inferred |
| `draw[]` ops | `dp` pixel, `dl` line, `dr` / `df` rectangle, `dc` / `dfc` circle, `dt` text (fixed 10 px), `db` bitmap (`w*h` ints `0x00RRGGBB`) | documented (official) |
| `draw[]` count | **at most 32 commands per app** | documented (official README) |
| Colours | `#RRGGBB`, no alpha | documented (official) |
| `image[]` | PNG or GIF data URL; still images up to 512×512, GIF up to 256×256 and ≤ 50 frames, base64 ≤ 60 KB; **clipped from the top-left, never scaled**; PNG alpha blended onto black; at most 6 images per app (≤ 3 GIF + ≤ 3 PNG) | documented (official) |
| Animated GIF | plays and loops, per-frame delays honoured; two frames with `DelayTime` 5.0 alternate on the panel by themselves — the sanctioned time-multiplexing for one page, no Mac-side rotation | documented ([#27](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/27)), **measured** live 2026-09-21 |
| GIF frame structure | every frame must be a **full 52×16 image at (0,0)** under one global palette, no per-frame crops, no local tables. ImageIO crops frames to the changed region (`rect=(1,0,51,15)`, `(0,4,52,11)`, …) and relies on the decoder holding the previous frame; the stock decoder paints those sub-rects over the accumulated picture instead, and the page smears within seconds. A hand-assembled full-frame GIF renders pixel-stable | **measured** 2026-09-21 |
| Envelope element spellings | `text[]` entries are objects — `{content, fontHeight, x, y, color}` (+ optional `align`/`valign`/`rect`/`charSpacing`); `image[]` entries are objects — `{data: "data:image/gif;base64,…", position: [x, y]}`. A plain string in `text[]` and a bare base64 payload in `image[]` — string or data URL — each render nothing: the page stays black | **measured** (live TC002, appVer 1.1.1, 2026-09-21) |
| Update rate | full-screen `db` frames at about 8 per second over HTTP work | documented (atomicstack CUSTOM-APP, from PixDeck) |
| Transitions | switching between apps is an instant cut, with no effects | documented ([#30](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/30)) |

### 2.3 Why the "Claude limits" probe read as a picture

The payload pushed on 2026-09-14 (session transcript):

```json
{"duration":30,
 "text":[{"content":"CLAUDE 42%","fontHeight":10,"x":0,"y":1,"color":"#D97757",
          "align":"center","rect":[0,0,52,11]}],
 "draw":[{"dr":[1,12,50,3,"#303030"]},{"df":[2,13,20,1,"#D97757"]}]}
```

Asked what "as a picture" meant, the user answered «В», option b: full screen,
flat and static; the font and the bar look like an inserted image, not like the
built-in apps. Four causes, the first structural and the rest in the payload:

1. **It was shown as a picture.** It sat in the DIY group, the group built for
   stored pixel-art pictures (this clock holds none, **measured**), as a
   full-screen still frame, and appeared with an instant cut (#30). Built-in apps
   come with things a custom app cannot have:
   the four-dot level marker, the weekday bar, split-screen layouts (product
   page), and pixels that change on their own, like seconds ticking. —
   **documented** for the listed features, **inferred** as the cause.
2. **The text was clipped and not centred.** `x: 0` switches `align` off (official:
   align applies only at `x ≤ −999`), so the text started at the left edge. Ten
   glyphs at about 6 px plus a 1 px space come to about 70 px on a 52 px panel,
   so `CLAUDE 42%` was cut at the right. — **inferred** from documented rules.
3. **The large tier filled the screen.** `fontHeight: 10` uses 10 of the 16 rows
   and leaves no room for an icon or a label beside the figure, which is not how
   the built-in faces are laid out. — **inferred**
4. **The bar barely showed.** The track was a 1 px `#303030` outline, and the
   panel runs at the `low` preset, 50 % (**measured**), so an outline that dark is
   close to invisible. The fill was a single 20×1 row. — **inferred**

The LED panel does not blur. Images are clipped and never scaled, so whatever is
pushed lands 1:1. "Picture-like" is a problem of design and placement, not of
resampling. — **inferred** from the documented no-scaling rule.

### 2.4 How to get crisp, native-looking output

1. **Draw on the Mac, send pixels.** Render each face into a 52×16 RGB raster in
   Swift, using our own pixel fonts, and send it as a single `db` (one of the 32
   commands, about 3–6 KB of JSON) or as a PNG `image[]`. This gets past every
   text limit in § 2.2: Cyrillic, lowercase and `°` all work, layouts are exact,
   the second-aligned-text bug no longer applies, and the 32-command cap is never
   reached. It is what Ulanzi's own Claude app does: `apps/mqtt/claude-bot`
   renders its 52×16 GIF with a hand-made 3×5 font
   ([`render_usage.py`](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/apps/mqtt/claude-bot/lab/render_usage.py)).
   — **documented**
2. **Follow the built-in layout.** Icon on the left, value on the right, and a
   3×5 or 6×10 digit face like AWTRIX's (the bundled font is AWTRIX's TomThumb,
   #17). A bar should be at least 2 px tall with a track bright enough to show at
   50 % brightness. E7 finds the lowest grey that still shows. — **inferred**
3. **Give it motion.** A small animated GIF, such as a twinkling `ClaudeStar` on
   ≤ 3 GIF layers, or a re-push every minute, makes the page read as live rather
   than as a picture. — **inferred**. A GIF built with ImageIO must nest each
   frame's `DelayTime` inside `kCGImagePropertyGIFDictionary`; at the top level
   ImageIO drops it silently and the panel flips frames at full rate. —
   **measured** 2026-09-21
4. **Scroll on the Mac.** The anecdote banner needs a marquee: pre-render the
   scrolling raster into a GIF and let the panel play it by itself — the
   device-side route that the 2026-09-21 session proved. The re-push every
   0.4–0.5 s with the raster shifted (the PixDeck method) is the fallback; a
   GIF marquee cannot carry long text within 50 frames. — **documented**
   method, GIF route **measured** 2026-09-21
5. **Ship full-frame GIFs assembled by hand.** The smearing from § 2.2's
   frame-structure row is not something to wait out: `Scripts/MakeTimedGif.py`
   builds the GIF89a byte by byte — full 52×16 frames at (0,0), one global
   palette, no local tables, `disposal=1` — with its own LZW encoder and a
   pure-stdlib decoder for the animated icon, and is validated pixel-exact
   against ImageIO as an independent decoder (44/44 frames of the live demo).
   This is the reference path for every TC002 face the kit renders. —
   **measured** 2026-09-21
6. **Use a real pixel font, not rasterized vector text.** A vector font
   rendered at 8× and thresholded onto the LED grid stayed unreadable on the
   panel (the user's verdicts: «нельзя разобрать», «всратый — выдумывай не
   свой»), and the firmware's own text route is ASCII-only (§ 2.2). The
   working face is the X11 Fixed 5×7 (Sony, ISO10646-1, full Cyrillic),
   trimmed to ASCII + U+0410–044F and vendored at
   `Scripts/font5x7-cyrillic.bdf` (18 KB, 159 glyphs). Its Cyrillic «Т» ships
   with a 3 px top bar shifted one pixel right (`0x70`) — patched in the
   vendored file to the symmetric 5 px bar (`0xF8`). Layout numbers the panel
   confirmed: a 5×7 glyph plus a 1 px space is a 6 px advance, so seven
   characters fill the 42 px right of an 8 px icon column; two bands at rows
   0–6 and 9–15 tile all 16 rows; a marquee row is clipped at x ≥ 8 so it
   never covers the icon; some glyphs (`/`) descend below the baseline
   (BBX 5 9 −2) and need canvas clipping. — **measured** 2026-09-21

E6 is a ready-made side-by-side check of this approach against the built-in
screens.

## 3. On-device sound

Baseline: the stock protocol has no audio. The official limitations table lists
"TTS / MP3 / audio playback — Not exposed by the protocol" and "Audio MQTT
topics — Not supported" (official § 7). The hardware has a speaker, "MP3
playback, volume 0–6" (official README), running through SigmaStar's `mi_ao`
with no ALSA (atomicstack README, KERNEL). — **documented**

Anecdote clips are XTTS output, several `turn-N.wav` per anecdote
(`SidecarSpeechSynthesizer`). No played clips were left on this Mac to measure,
because the reaper had removed them. Assuming a 20–60 s anecdote as 24 kHz 16-bit
mono WAV, that is roughly 1–3 MB. — **inferred**

### 3.1 Option A — root adb on 5555

- **Feasibility.** `adbd` answers on 5555 as root, with no pairing
  ([atomicstack SECURITY #4](https://github.com/atomicstack/tc002-customisation/blob/HEAD/SECURITY.md)),
  and the port is open here (**measured**). The stock system has **no
  command-line player**. Its `/bin` holds only basic tools, and the stock
  busybox resolves only `top` and `ifconfig`
  ([atomicstack DEVICE](https://github.com/atomicstack/tc002-customisation/blob/HEAD/DEVICE.md#shell-access)).
  MP3 is decoded inside the app (`libzkmedia` + `libmad`). To play anything we
  would push our own armv7 player, linked against the vendor's `libmi_ao.so` as
  atomicstack's `tc002-audiod` is, into `/tmp`, and start it with `adb shell`.
  — **documented** parts, **inferred** plan.
- **Risk.** Nothing is flashed if the player lives in `/tmp`, and a power cycle
  clears it, so the brick risk is low. The known hazard: "a wrong `SendFrame`
  payload wedges the audio device until the box is rebooted" (atomicstack
  RUNTIME § sound). The stock app uses the same device for its beeps, so the two
  may collide (**inferred**). The whole route depends on an open root service
  that the community has asked Ulanzi to close
  ([issue #31](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/31)),
  so one OTA could end it. The official protocol's example `/getBase` reply
  shows `appVer V1.4.0` while this clock runs 1.1.1, which suggests newer
  firmware exists (**inferred**). Warranty: no persistent change.
  Security: shipping this normalises a root backdoor. — **documented / inferred**
- **Hazard to note for any adb work.** Never `cat` the sysfs files `usb_device`,
  `usb_host` or `usb_null` beside `otg_role`: "they are *actions*, and reading
  one performs that switch" (atomicstack DEVICE § adb). — **documented**
- **Effort.** A Swift ADB client, or a dependency on the `adb` binary, plus
  cross-building and validating the armv7 player, plus transcoding. This is a
  sub-epic of about 8–12 commits with hardware novelty (×1.3) and no substrate.
  P25 3 / P50 4 / P75 6 burst days, about 1.5 calendar weeks at 3 burst days a
  week. — **inferred**
- **`DeviceSpeaker` would need:** transcode to PCM, `adb push` to `/tmp`, start
  and stop the player, and a completion signal taken from the known duration.

### 3.2 Option B — the official `AudioManager` in a FlyThings app

- **Feasibility.** `awtrix::AudioManager::playAudio(path)` wraps FlyThings'
  `base::MediaPlayer` and plays MP3 from a file path
  ([`AudioManager.cpp`](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/Z21_TC002_Demo/src/managers/AudioManager.cpp)).
  A FlyThings project, however, **is** the application: it builds
  `libzkgui.so` ([owlanzi-tc002](https://github.com/Surio89/owlanzi-tc002):
  "The result is a native ARM library, `libzkgui.so`"), and the stock HTTP API
  lives in that same library. Running our own app removes the stock UI, the
  built-in tools, the cloud client and `/api/custom`. We would have to rebuild
  whatever we still need: a frame API, a renderer, Wi-Fi onboarding, and the
  anti-brick property `sys.zkapp.state=running`, without which the system "rolls
  back to the official firmware" (official README). The IDE is Windows-only.
  "Download & Debug does not persist"; persistence takes an `update.img` on a TF
  card (official README). — **documented**
- **Risk.** It is the route Ulanzi sanctions: "the second-generation pixel clock
  is open source" (FAQ), and there is an official restore (hold reset beside
  USB-C while powering on). The device loses every stock feature while our app
  runs. — **documented**
- **Effort.** A firmware program of 40–80 commits on a foreign toolchain.
  owlanzi, a comparable FlyThings app, first ran on 2026-09-09 and still lists
  permanent installation as unfinished. P25 3 / P50 5 / P75 8 calendar weeks.
  — **inferred**
- **`DeviceSpeaker` would need:** our own HTTP endpoint in that firmware to
  upload MP3 and play it. MP3 makes 30–60 s clips practical.

### 3.3 Option C — the community runtime's `POST /sound`

- **Feasibility.** atomicstack's runtime replaces the stock app while it runs:
  "the stock `zkgui` app (and with it the stock http api on port 80, the cloud
  client, the built-in apps) is not running". It serves an authenticated
  `/api/v1` with scenes, canvas, notifications and sound
  ([RUNTIME](https://github.com/atomicstack/tc002-customisation/blob/HEAD/RUNTIME.md)).
  Sound is **WAV PCM only, 192 kB per sound (six seconds of 16-bit 16 kHz mono,
  twenty-four of 8-bit 8 kHz), 256 kB for the whole store**, uploaded in 4 KB
  chunks, one sound at a time, and off by default (RUNTIME § sound). An anecdote
  does not fit. It could be sent as a chain of 8-bit 8 kHz chunks with gaps
  between them: telephone quality, and not something the runtime was designed
  for. — **documented** limits, **inferred** fit.
- **Risk.** It is installed by flashing the `res` partition (volatile `/tmp`
  runs exist for development). Recovery works over adb on USB, or with the reset
  key, which wipes `/data` and reflashes whatever is in `/mnt/storage`, an older
  firmware on atomicstack's unit
  ([FIRMWARE § recovery](https://github.com/atomicstack/tc002-customisation/blob/HEAD/FIRMWARE.md#recovery-routes-verified-and-not)).
  The project is beta and its API moves between commits. Warranty: modified
  firmware. The spec lists replacing the stock application as out of scope.
  — **documented / inferred**
- **Effort.** A third adapter against `/api/v1` (tokens, frames, chunked sound
  upload): about 10–15 commits, P25 2 / P50 3 / P75 5 burst days. Audio of
  anecdote length stays blocked by the store until upstream changes it.
  — **inferred**
- **`DeviceSpeaker` would need:** WAV transcoding, the chunked `PUT
  /api/v1/sounds/{name}?offset=N&final=1`, `POST /sound`, and a status poll.

### 3.4 Side by side

| | A: root adb | B: FlyThings app | C: community runtime |
| --- | --- | --- | --- |
| Keeps `/api/custom` and the stock UI | yes | **no** | **no** |
| Plays a 30–60 s anecdote | yes, with our own player | yes, MP3 | **no**: 6 s at 16 kHz, 24 s at 8 kHz 8-bit |
| Flash writes | none (`/tmp`) | yes (`update.img`) | yes (`res`) |
| Brick risk | low | low to medium, official restore | medium, recovery documented |
| Longevity | one OTA can close it (#31) | stable, official | beta, API moves |
| Effort (P50) | about 4 burst days | about 5 weeks | about 3 burst days, audio still blocked |
| Spec scope | inside | outside ("Replacing the TC002's stock application") | outside |

## 4. Recommendation

### 4.1 Tiles on the TC002: a custom app, drawn on the Mac, one per clock

1. **Custom app, never a native screen.** It is the only surface the stock
   firmware opens to us (§ 2.1).
2. **Faces produce a pixel raster.** Each TC002 face draws into a 52×16
   `PixelCanvas` with the app's own fonts and art, and the adapter encodes the
   raster as one `db` (or a PNG), plus up to three GIF layers for motion. Text
   rendering on the device is not used. This also lets the existing drawing tests
   move to face tests as pixel assertions.
3. **One device app per clock, rotated by the Mac.** The clock never rotates
   custom apps (§ 1.5), and forcing it with `switchDiyApp` is the disruption
   measured on 2026-09-14. The TC002 session therefore owns **one** app name, for
   example `tiles`, and cycles its tiles' latest frames through it with a dwell
   time per clock. The user parks the clock on that DIY page once, and after that
   the tiles rotate the way AWTRIX's loop does, until the user turns the knob
   away. Custody shrinks to one name per clock. Retracting a tile on a Focus
   change or on emulated lifetime means taking it out of the rotation, not
   deleting a page the user may be looking at. Deleting the viewed page has an
   unknown effect (E4). Not chosen: one app per tile. It needs no
   scheduler, but the user would have to turn the knob to see each tile, and
   every retraction would delete a DIY page.
4. **`switchDiyApp` only by explicit request.** A "Show on clock" action in the
   panel may call it, because then the user asked for the jump. It is never
   called on a schedule or at launch.
5. **Keep sending a constant `duration`, and do not rely on it.** It is not a
   TTL (#24) and not in the official schema.

### 4.2 Anecdote audio: stay on `MacSpeakers`

No `DeviceSpeaker` in this program. A is feasible but rests on a root backdoor
that may close. B and C replace the stock application, which the spec rules out,
and C cannot hold an anecdote anyway. Revisit if Ulanzi adds audio to the
protocol (official § 7 says "not exposed", not "never") or if the user decides to
move the TC002 onto the community runtime and its store grows.

Anecdotes do become **visually** possible on the TC002. With Mac-rendered
rasters, the Cyrillic banner is just pixels, scrolled by re-pushing (§ 2.4), and
the audio plays through the Mac.

### 4.3 Consequences for phase 3

- `UlanziFrame` stays the wire model, but faces fill it from a `PixelCanvas`
  raster. Add `dc` / `dfc` / `dt` to the vocabulary only if some face needs them.
  Enforce the device limits in the adapter and test them: ≤ 32 draw commands,
  ≤ 6 images (≤ 3 GIF), GIF ≤ 50 frames, base64 ≤ 60 KB.
- The TC002 `ClockSession` gains a `UlanziRotation` that pushes the next tile's
  latest frame into the clock's one app slot every dwell. `UlanziDevice` keeps
  `showApp(_:named:)` and is always called with that slot's name. The TC002
  weather and Claude faces from phase 3 rotate through it.
- `UlanziCustody` records one app name per clock. Keep the start-up sweep of
  `customList ∩ record` for names left by older builds or crashes.
- The TC002 weather face draws `°` as pixels within the same raster; this is no
  longer a special case.
- The anecdotes row of the connectors table changes from "none in this design —
  F1's" to "possible later as a visual face (raster banner, Mac-side marquee),
  audio via `MacSpeakers`". The face itself is a follow-up after phase 3, not part
  of phase 3.
- Health: the TC002 **has** a 3600 mAh battery (product page; atomicstack), but
  the stock API does not report its level. The panel still draws no battery
  line, and the spec's wording "There is no battery" should say that instead.

### 4.4 Consequences for availability rule 3

Only `MacSpeakers` exists, so rule 3 applies as written across both models: an
audible tile, anecdotes, can sit on one clock only, TC001 **or** TC002, evaluated
against the current state. The per-clock branch ("a clock gaining a sink of its
own later changes the answer") stays dormant. Its test should stay: it is the
hook a future `DeviceSpeaker` needs.

## 5. Corrections to the spec's device facts

| Spec statement | What the evidence says |
| --- | --- |
| "A pushed frame shows full screen" | It showed because `switchDiyApp` was called. A push alone never brings a custom app on screen (official § 3.1). The row should name the switch. |
| (unverified list) "lowercase letters render blank" | Official samples use lowercase after the v1.1.0 font fix, and this clock runs 1.1.1. The community still reports partial glyphs (#20). Unresolved until E5. |
| "`fontHeight: 10` is the size known to work" | Official: 5 and 10. Community: tiers 3–5, 6–8 and 10 (#25). |
| "`draw` primitives: `dp`, `dl`, `dr`, `df`, `db`" | Also `dc`, `dfc`, `dt`, with at most 32 commands per app. |
| "animated GIFs play at any size up to 52×16" | GIFs up to 256×256 and 50 frames are accepted, clipped to 52×16; stills up to 512×512; base64 ≤ 60 KB; ≤ 6 images per app. |
| payload `{duration, text[], draw[], image[]}` | The official schema is `text`, `image`, `draw`. `duration` is sent by the community but is not a TTL (#24). |
| "There is no battery" (Ulanzi adapter, Health) | There is one, 3600 mAh, but no API reads it. |
| Measured rows: ports 80 and 5555 open, 1883 closed; UDP about once a second; `/getBase` fields | Confirmed again today (§ 0). |

## 6. Proposed experiments for the user

Each experiment needs the user watching the clock. Commands run from the Mac
after `set H http://192.168.1.72` (fish) or `H=http://192.168.1.72` (bash, zsh);
they are written to work in both. Nothing is left on the clock once each
experiment's undo has run.

**E1 — map the levels (no API call).** Start on the clock face. Note whether the
four dots are showing. Press the knob once, rotate, and note which apps appear.
Press again to go back. Long-press for 3 s on BUSY or Pomodoro and note what
changes. Also note where the DIY group is and whether DIY holds any pages now
(there should be none). *Observe:* whether the table in § 1.1 is right.
*Undo:* short-press back to L1.

**E2 — a push does not move the user.**

```sh
curl -s -X POST "$H/api/custom?name=f1_probe" -H 'Content-Type: application/json' \
  -d '{"text":[{"content":"F1","fontHeight":10,"x":-1000,"y":-1000,"align":"center","valign":"middle","color":"#FFFFFF"}]}'
```

*Observe:* the screen must not change. Then navigate with the knob to DIY L2 and
find `F1`. Note its position, and whether DIY L2 shows any dots or other
markers. *Undo:* `curl -s -X POST "$H/api/custom?name=f1_probe" -H
'Content-Type: application/json' -d '{}'`.

**E3 — live update while parked.** With the clock parked on `f1_probe`, repeat
E2 with `"content":"F2"`. *Observe:* the change is immediate, with no flicker and
no transition. *Undo:* as E2.

**E4 — deleting the page being viewed.** While parked on `f1_probe`, post `{}`
to it. *Observe:* where the UI goes: the next DIY page, L1, or a blank screen.
This decides how a tile is retracted. *Undo:* nothing; navigate back by hand.

**E5 — font sheet.** Push each payload in turn while parked on `f1_probe`:

```sh
curl -s -X POST "$H/api/custom?name=f1_probe" -H 'Content-Type: application/json' \
  -d '{"text":[{"content":"AbCxyz 09%","fontHeight":5,"x":0,"y":0,"color":"#FFFFFF"},{"content":"Hit 29°C","fontHeight":5,"x":0,"y":8,"color":"#FFCB52"}]}'
curl -s -X POST "$H/api/custom?name=f1_probe" -H 'Content-Type: application/json' \
  -d '{"text":[{"content":"Abt 42%","fontHeight":10,"x":0,"y":3,"color":"#FFFFFF"}]}'
curl -s -X POST "$H/api/custom?name=f1_probe" -H 'Content-Type: application/json' \
  -d '{"text":[{"content":"Abt 42%","fontHeight":7,"x":0,"y":4,"color":"#FFFFFF"}]}'
```

*Observe:* whether the lowercase letters are whole, whether `°` is dropped,
whether 7 renders as a separate tier from 5 and 10, and the glyph width in 10 px
(count the columns taken by `42%`). *Undo:* `{}` as in E2.

**E6 — Mac-rendered face against the built-in screens.** Save the script below
as `e6_face.py`. It uses only the Python standard library and draws an 11×11
asterisk, `42%` in 6×10 digits and a 2 px bar into one `db` (832 ints, about
4 KB of JSON). Its output was checked on the Mac for 0, 42 and 100 and not sent
to the clock.

```python
import json, sys
W, H = 52, 16
px = [[0] * W for _ in range(H)]
FONT = {"0": "111101101101111", "1": "010110010010111", "2": "111001111100111",
        "3": "111001111001111", "4": "101101111001001", "5": "111100111001111",
        "6": "111100111101111", "7": "111001001010010", "8": "111101111101111",
        "9": "111101111001111", "%": "101001010100101"}
def glyphs(s, x, y, c, k):
    for ch in s:
        for i, bit in enumerate(FONT[ch]):
            if bit == "1":
                for dy in range(k):
                    for dx in range(k):
                        px[y + (i // 3) * k + dy][x + (i % 3) * k + dx] = c
        x += 4 * k
def fill(x, y, w, h, c):
    for yy in range(y, y + h):
        for xx in range(x, x + w):
            px[yy][xx] = c
pct = int(sys.argv[1]) if len(sys.argv) > 1 else 42
ORANGE, TRACK, WHITE = 0xD97757, 0x3A3A3A, 0xFFFFFF
for i in range(1, 10):
    px[i][5] = px[5][i] = ORANGE             # the asterisk's cross
for d in range(1, 4):
    for sx, sy in ((1, 1), (-1, 1), (1, -1), (-1, -1)):
        px[5 + sy * d][5 + sx * d] = ORANGE   # and its diagonals
glyphs(f"{pct}%", 16, 1, WHITE, 2)
fill(1, 13, 50, 2, TRACK)
fill(1, 13, round(50 * pct / 100), 2, ORANGE)
print(json.dumps({"draw": [{"db": [0, 0, W, H, [c for row in px for c in row]]}]}))
```

```sh
python3 e6_face.py 42 | curl -s -X POST "$H/api/custom?name=f1_probe" \
  -H 'Content-Type: application/json' --data-binary @-
```

*Observe:* next to the built-in clock and weather, does it still read as a
picture? Are the edges crisp? Is the track visible at the `low` preset? *Undo:*
`{}`.

**E7 — the lowest visible grey.**

```sh
curl -s -X POST "$H/api/custom?name=f1_probe" -H 'Content-Type: application/json' \
  -d '{"draw":[{"df":[0,0,6,7,"#101010"]},{"df":[7,0,6,7,"#202020"]},{"df":[14,0,6,7,"#303030"]},{"df":[21,0,6,7,"#404040"]},{"df":[28,0,6,7,"#505050"]},{"df":[35,0,6,7,"#606060"]},{"df":[42,0,6,7,"#808080"]},{"df":[0,9,6,7,"#D97757"]},{"df":[7,9,6,7,"#FF0000"]},{"df":[14,9,6,7,"#00FF00"]},{"df":[21,9,6,7,"#0000FF"]},{"df":[28,9,6,7,"#FFCB52"]},{"df":[35,9,6,7,"#3EE08A"]},{"df":[42,9,6,7,"#FFFFFF"]}]}'
```

*Observe:* the first grey block that is visible at `low`, `mid` and `high` (the
user switches presets with long presses on −/+), and whether Claude orange
`#D97757` keeps its hue. *Undo:* `{}`, and restore the brightness preset the
user had, which was `low`.

**E8 — what `duration` does.** While parked, push E2's payload with
`"duration":5` added. *Observe for 15 s:* whether the page stays, blanks or
leaves. *Undo:* `{}`.

**E9 — reboot persistence.** Push E2's payload, restart the clock by hand, then
run `curl -s "$H/api/customList"`. *Observe:* whether `f1_probe` is listed.
*Undo:* `{}` if it survived.

**E10 (optional) — what `switchDiyApp` does to a running tool.** Start a Pomodoro
at L3, then run `curl -s -X POST "$H/api/switchDiyApp?name=f1_probe"` (create the
app as in E2 first). *Observe:* whether the timer keeps running when the user
goes back to it. *Undo:* `curl -s -X POST "$H/switchApp" -H 'Content-Type:
application/json' -d '{"type":"tools","index":1}'` returns to the clock, then
`{}` to `f1_probe`. This decides how strongly the "Show on clock" button must
warn.

**E11 (optional, needs `brew install android-platform-tools`, the user's call)
— read-only adb inventory.** `adb connect 192.168.1.72:5555`; then `adb shell
getprop ro.product.model`, `adb shell cat /res/etc/EasyUI.cfg`, `adb shell ls
/res/ui/font_image /data/diy`, `adb shell ps`. Run `adb logcat -d` while the user
performs E1 and E2, and pipe it through `tail -n 300` on the Mac, since the
device has no `tail`. *Observe:* the log lines for level changes and custom-app
pushes, and which font atlases exist. **Do not** read the `usb_device`,
`usb_host` or `usb_null` sysfs files: reading one switches the USB role.
*Undo:* `adb disconnect`.

Sound experiments are not proposed. Every route either plays audio through a
binary we have not written (A) or replaces the firmware (B, C), and § 4.2 does
not need them.

## 7. Sources

Official (Ulanzi):

- [Ulanzi-U-Clock-TC002 repository](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002):
  [README_EN](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/README_EN.md),
  [protocol (CN/EN)](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/blob/main/protocol/Ulanzi_TC002_protocol-http-mqtt_CN.md),
  [PR #18: protocol PDF, samples, firmware v1.1.0](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/pull/18),
  [`claude-bot`](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/tree/main/apps/mqtt/claude-bot),
  [`Z21_TC002_Demo`](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/tree/main/Z21_TC002_Demo),
  issues [#17](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/17),
  [#20](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/20)–[#27](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/27),
  [#30](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/30),
  [#31](https://github.com/UlanziTechnology/Ulanzi-U-Clock-TC002/issues/31)
- [TC002 documentation](https://docs.ulanzistudio.com/tc002/en/): FAQ, Tools
  guide, Studio guide, MQTT guide, DIY image guide
- [Product page](https://www.ulanzi.com/products/tc002-pixbar-smart-pixel-clock-ii)

Community:

- [atomicstack/tc002-customisation](https://github.com/atomicstack/tc002-customisation):
  `HTTP-API.md`, `CUSTOM-APP.md`, `DEVICE.md`, `SECURITY.md`, `FIRMWARE.md`,
  `RUNTIME.md`, `SETUP.md`
- [cailurus/PixDeck](https://github.com/cailurus/PixDeck),
  [doitian/ulanzi-tc002](https://github.com/doitian/ulanzi-tc002),
  [Surio89/owlanzi-tc002](https://github.com/Surio89/owlanzi-tc002)

Session: `956b209a-…jsonl`, lines 259 (the probe payload), 465–474 (the user's
"as a picture" answer and the L3→L2 report).

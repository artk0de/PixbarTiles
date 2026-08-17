# AWTRIX Connectors — design

Status: approved for planning · 2026-08-17

A native macOS menu bar application that runs pluggable connectors and pushes
their output to a Ulanzi TC001 running AWTRIX 3. The first connector reads the
day's popular anecdotes, voices them with cloned character voices, and shows
them on the clock on a user-set interval.

## Measured device facts

Everything below was verified against the live device (`192.168.1.72`,
AWTRIX 0.98, `type: 0` stock Ulanzi TC001), not taken from documentation. The
prototype under `prototype/` is the harness that produced them.

| Fact | Evidence |
| --- | --- |
| The buzzer plays RTTTL only; uploaded MP3 never reaches the sound path | `/api/sound` returned 404 for a name backed by `ttest.mp3` and 200 for the same name once `ttest.txt` existed |
| `/MELODIES/<name>.txt` holds RTTTL text; `<name>` is the play key | same experiment |
| Arbitrary RTTTL plays over `/api/rtttl` | eight melodies, all 200 |
| The font renders Cyrillic without transliteration | screen capture showed `К ОТ КУРЬ` mid-scroll of a Russian sentence |
| Device flash is writable over `/edit` and listable over `/list?dir=` | melody and icon round-trips, both cleaned up |
| The LaMetric CDN serves any icon by id without auth | `GET /content/apps/icon_thumbs/<id>.gif` |
| The LaMetric search endpoint needs all five query parameters | omitting `category` or `guest_icons` returns a framework error page, which reads like a block |
| The matrix buffer is readable as 256 packed `0xRRGGBB` values | `/api/screen`, rendered to PNG for inspection |

`scrollSpeed` direction is **not** established. A correlation-based measurement
produced no monotonic trend because the test text was a repeating alphabet, so
shift matching degenerated. Pick the value by eye during UI work.

Two consequences bind the design:

1. **Speech cannot play on the clock.** The hardware has a passive buzzer and no
   decoder. Synthesized audio plays on the Mac; the clock gets scrolling text, an
   animated icon, and an RTTTL jingle.
2. **Russian text needs no preprocessing.** Send it as-is.

## Architecture

One signed `.app`. Connectors are a first-class concept inside it rather than a
separate distribution unit — the plugin boundary is a protocol, not a process.

```
MenuBarExtra (SwiftUI)
   │  status, per-connector toggles, interval slider
   ▼
ConnectorHost ──── ConnectorRegistry ──── [Connector]
   │  scheduling, enable/disable, retry
   ▼
AwtrixDevice ──── DeviceMonitor
   │  notify / rtttl / files / icons        polls /api/stats
   ▼
Ulanzi TC001
```

### AwtrixDevice

Direct port of `prototype/awtrix/client.py`. Owns every HTTP call to the device
and nothing else: `notify`, `playRTTTL`, `playMelody`, `customApp`, plus flash
operations (`list`, `upload`, `delete`) and their icon and melody wrappers.
Errors surface as a typed `AwtrixError` carrying status, body, and endpoint.

The Python client is the reference: it was written stdlib-only so that every
construct has a Foundation equivalent and the port stays a translation.

### DeviceMonitor

Polls `/api/stats` on a timer and publishes connection state, battery, and
firmware version. Feeds the tray icon and the status line. Device discovery is
by mDNS (`_http._tcp`, instance `awtrix_<mac-suffix>`) with a manual IP override
— that is how the device was found in the first place.

### Connector contract

```swift
protocol Connector {
    static var id: String { get }
    var displayName: String { get }
    var defaultInterval: TimeInterval { get }
    func produce() async throws -> ConnectorOutput
}

struct ConnectorOutput {
    var text: String
    var icon: IconRef?          // installed icon name, or a catalogue id to fetch
    var jingle: String?         // RTTTL, played before the text
    var localAudio: [URL]       // played on the Mac, in order, while the text scrolls
    var duration: Int?
    var color: String?
}
```

`ConnectorHost` owns everything a connector should not care about: the timer,
the enabled flag, persistence of both, backoff on failure, and serialization so
two connectors never talk to the device at once. A connector fetches and returns;
it never touches `AwtrixDevice`.

Adding a connector is one file plus one registration line. That is the intended
cost — a process boundary buys hot-loading nobody has asked for, and costs a
protocol, process supervision, and signing.

### Anecdote connector

Pipeline, each stage independently testable:

1. **Source** — fetch the day's popular anecdotes. Returns raw text items.
2. **DialogueParser** — split an item into ordered `Turn(speaker:text:)`. A line
   starting with a dash opens a new speaker turn; consecutive dashes alternate
   speakers; narration outside dashes is its own turn.
3. **VoiceCaster** — assign a voice per distinct speaker. Narration and the
   trailing `АХАХАХАХА` are always Arthas. The second actor is Peon. Further
   actors draw from the remaining voice pool in first-appearance order.
4. **Speech** — hand each turn to the TTS sidecar, receive a WAV per turn.
5. **Emit** — build `ConnectorOutput`: text is the joke prefixed with
   `ВНИМАНИЕ, АНЕКДОТ:` and suffixed with `АХАХАХАХАХА`, icon is the animated
   laughing face, jingle is the Nokia melody, `localAudio` is the turn WAVs in
   order.

Reference values chosen during the probe: laughing icon is LaMetric id `9039`
(yellow face, wide open mouth, animated); the jingle is
`nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a`.

### TTS sidecar

XTTS-v2 exists only in Python, so speech synthesis stays a Python process. It
lives at `~/.local/share/tts-voices/`, is started once as `speak.py --serve`, and
speaks JSON Lines — one request object per line in, one response per line out:

```
in   {"voice":"arthas","text":"Внимание, анекдот","out":"/tmp/turn-0.wav"}
out  {"ok":true,"voice":"arthas","out":"/tmp/turn-0.wav","duration":1.995}
out  {"ok":false,"error":"unknown voice: foo (have: arthas, peon)"}
```

A voice is addressed by **name**, and the sidecar resolves it to
`voices/<name>.wav`. Adding a third actor is dropping a file in that directory —
no code change on either side. `out` is optional; when omitted the sidecar picks
a temp path and the caller owns the file.

The process is started once and reused. Model load costs seconds, and
conditioning latents are cached per voice after first use, so alternating voices
mid-dialogue costs nothing beyond the synthesis itself. Verified with an
Arthas → Peon → Arthas → Peon run in a single process. Spawning per phrase would
throw that cache away every time. The app supervises the process: start on first
use, restart if it exits, surface a degraded state in the tray if it will not
come up.

Available voices: `arthas` (19.39 s reference) and `peon` (23.16 s). Both are
built from peon-ping packs by concatenating the longest clips through ffmpeg
silence removal and loudness normalization, targeting roughly 20 seconds.

Four environment constraints are load-bearing and will resurface on any rebuild:

- `transformers` must stay below 5.x — 5.x removed `isin_mps_friendly`, which
  coqui-tts imports.
- The process must not run with a working directory containing a `coverage/`
  directory; it shadows the PyPI package and surfaces as an unrelated numba error.
- ffmpeg's `loudnorm` filter resamples to 192 kHz internally and writes that rate
  out unless `-ar` is set explicitly. Always pass the target rate.
- Python's `wave` module cannot read `WAVE_FORMAT_EXTENSIBLE` headers, which
  ffmpeg emits at non-standard rates. A duration probe that trips on this fails
  *after* successful synthesis and masquerades as a generation error.

Output is loudness-normalized at `I=-18 TP=-2`, measured at −2.4 dB and −2.0 dB
peak, so there is headroom. XTTS emits 24000 Hz mono; resample explicitly if the
audio ever joins a pipeline with another rate.

**Listened to and accepted, 2026-08-17.** Both clones were played back to back:
Arthas and Peon are clearly distinguishable, Russian prosody holds, and the
mandatory `АХАХАХАХАХА` comes out usable — laughter is a traditional TTS weak
spot, so it was checked on its own. This was the project's largest open risk,
because indistinguishable clones would have made a voiced dialogue pointless and
sent the multi-voice requirement back to design. It is closed; XTTS-v2 stays, and
the Silero+RVC fallback is off the table.

## Menu bar UI

Clicking the tray icon opens a panel with:

- **Status** — connected / disconnected, device IP, battery, firmware.
- **Connector list** — one row each, with an on/off toggle and last-run result.
- **Interval slider** — 23 discrete positions, non-linear:
  5 to 60 minutes in 5-minute steps (12 positions), then 2 to 12 hours in
  1-hour steps (11 positions). The slider reports positions; the host maps a
  position to a duration. A linear time slider is unusable across that range.
- **Test button** per connector — run once now, ignoring the schedule.

The tray icon reflects device reachability, so a disconnected clock is visible
without opening the panel.

## Error handling

Connector failure is expected, not exceptional. A failed `produce()` is logged
against the connector, shown in its row, and retried with exponential backoff
capped at the connector's interval. The device being unreachable pauses
scheduling rather than burning retries; `DeviceMonitor` resumes it. Nothing a
connector does can crash the host — a throwing connector is caught at the host
boundary.

Device flash is small. Anything the app uploads is namespaced and removable, and
the app cleans up what it created.

## Testing

`AwtrixDevice` is tested against a stubbed HTTP layer for request shape, and the
prototype's live smoke test stays as the manual hardware check. `DialogueParser`
and `VoiceCaster` are pure functions over text and get ordinary unit tests —
they carry the logic most likely to be wrong. `ConnectorHost` scheduling is
tested with an injected clock.

## Out of scope

MQTT transport, DFPlayer hardware modification, custom firmware, a settings
window beyond the tray panel, and connectors other than the anecdote one.

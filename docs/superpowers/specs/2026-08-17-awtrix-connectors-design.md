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

### Voices

Five, all speaking Russian, each measured by median fundamental frequency so the
separation is a number rather than an impression:

| Voice | F0 | Source |
| --- | --- | --- |
| `acolyte` | 92 Hz | Undead Acolyte, Warcraft 3 RU |
| `arthas` | 134 Hz | Arthas, Warcraft 3 RU |
| `peon` | 262 Hz | Orc Peon, Warcraft 3 RU |
| `crystal` | 296 Hz | Crystal Maiden, Dota 2 RU — the only female voice |
| `batrak` | 329 Hz | WC2 Peon RU |

**How NOT to pick the clips.** The first references took the longest clips from
each pack. That silently selected for declamation: the three most steeply falling
pitch contours in the Arthas pack all landed in his reference, and every rising,
question-like line was excluded for being short. The clone then read questions
with a falling contour. Build a reference with both contours in it — measure each
clip's pitch from its first third to its final sixth and keep a mix, roughly a
third rising. Crystal's reference was built that way: 93 clips fetched over two
rounds because the first round yielded only three rising ones, 14 kept, 5 rising.

**Normalise every clip to one format before concatenating.** Packs are not
internally consistent — Crystal's source was 22050 Hz with mixed mono and stereo,
Arthas's was 48000 Hz. ffmpeg's concat demuxer applies the first file's
parameters to the rest, and the result was 59% too long with its pitch dragged
from 211 Hz down to 108 Hz. It was a plausible-looking file; the F0 number is
what exposed it.

There is no Russian female voice in the peon-ping registry — all nine of its
Russian packs are male Warcraft characters. Crystal Maiden comes from the Dota 2
Russian wiki instead, which is why the one female voice is not Warcraft.

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

### Text normalisation before synthesis

Every rule below was settled by listening, and each one fixes a specific audible
defect. The clock keeps the original text; only the synthesizer gets the
normalised version.

| Rule | What it fixes |
| --- | --- |
| Strip `«» "" „" ' `` | XTTS vocalises quotation marks. `точка»` came out as "точкала" — the closing quote became a syllable of the word. |
| Drop a dash between spaces | Kept, it produced a pause long enough to sound like a fault: "вкусно …… и точка". |
| Remove a trailing full stop | It provoked the decoder into appending an audible fragment after the sentence — a spurious "по", separated from the real speech by 0.2 s of true digital silence at −94 dB. |
| Keep a trailing `?` or `!`, and add a space | The punctuation carries the intonation; without the trailing space the final consonant is swallowed, and "Анекдот!" lost its Т. |

The question mark does work. Measured on the same sentence with and without it,
the pitch contour ends 18.5 Hz higher relative to the statement — a consistent
difference, not noise. An earlier claim that it did nothing came from comparing
different sentences on single samples of a stochastic model, which is not a
measurement.

### Stress marking works, but only after the vowel — and the reason is the tokenizer

Russian needs stress to disambiguate homographs, and stock XTTS gets them wrong:
`Он открыл замок` is read за́мок (the castle) where замо́к (the lock) is meant.
It is also plainly wrong on words that are not homographs at all — `храпишь`
comes out хра́пишь, and stays wrong with the word alone, with a full stop, and
inside a longer sentence, so neither punctuation nor context is the cause.

Four conventions were tested by ear:

| Convention | Result |
| --- | --- |
| combining acute `замо́к`, `храпи́шь` | **the stress moves, and the word survives** |
| `+` before the vowel, the RUAccent/Silero standard | the word breaks apart: "зам ок" |
| capital `замОк` | lowercased before tokenization, ignored |
| doubled vowel `замоок` | in-vocabulary, but sounds bad |

An earlier version of this section claimed the acute was absent from the BPE
vocabulary, encoded to `[UNK]`, and ate the following consonant, and concluded
that stress marking was impossible. **That was wrong**, and it was wrong because
it reasoned from a symptom instead of reading the tokenizer. Encoding the
strings settles it:

```
храпишь    х · ра · пи · шь
храпи́шь    х · ра · пи · [UNK] · шь
замо́к      за · мо · [UNK] · к
зам+ок     за · м  · [UNK] · о · к
```

Every letter survives in all three marked forms. The acute does become `[UNK]`
— it is genuinely not a Cyrillic token, and the only vocabulary entry carrying
U+0301 is the Latin `é` — but `[UNK]` is **inserted between tokens rather than
consuming one**. Position is what decides the outcome:

- The acute goes **after** the stressed vowel, which in Russian ends a syllable,
  so the `[UNK]` lands on a syllable boundary and the word stays intact.
- `+` goes **before** the vowel, which is inside the syllable, so it splits
  `мо` into `м` and `о` — and "зам ок" is exactly what that reads as.

The RUAccent and Silero convention is therefore not merely unsupported here; it
marks the one position that breaks the word. Precomposed accented Cyrillic
(`ѝ` U+045D, `ѐ` U+0450) is absent from the vocabulary entirely and is not an
escape route.

Checked across ten words, an acute placed after a vowel never lost a letter. One
word retokenized around it — `вертоле́те` splits `лет·е` into `ле·те` — which is
a different segmentation, not damage.

**DECISION 2026-08-18: no stress marking ships.** The user called the growing
set of guards a crutch and was right. Marking was tried end to end — RUAccent
placing marks, the acute moved across the vowel, guards for line length, for
app-owned strings, for words whose final letter the mark would strand — and the
balance measured negative by ear: over one session it corrected two words and
degraded nine. The model is usually right, we cannot predict where it is wrong,
and every rule that guesses is wrong on text nobody has heard.

Two replacements were evaluated against the same five sentences and rejected.
`omogr/xtts-ru-ipa` resolves stress from the phonemes themselves, so no mark is
needed and `[UNK]` cannot arise — but it trails half a second of audible tail
that `speed` does not shrink, it is non-commercial, and fed Cyrillic by mistake
it does not fail: it emits four seconds of plausible babble in the speaker's own
voice, which no metric distinguishes from a real line. `ResembleAI/chatterbox`
(MIT, 23 languages, native Russian, tails at or below stock) is the strongest
candidate seen and remains worth revisiting; it was set aside because the user
concluded stress is not worth the change of engine.

Wrong stress on a rare word is accepted as a cosmetic flaw. The two words this
was ever about are храпишь and сосиску.

**What this does not solve** is where the marks come from. Feed text is
unmarked, so using this needs a Russian stress dictionary or accentuation model
to mark the text before synthesis. That is a real subsystem and it is not built.
A hand-maintained list of problem words was considered and rejected: it would be
right about the words in it and silently wrong about everything else, which is
the failure mode this project has spent the most effort avoiding.

**No fine-tune can fix this.** `tensorbanana/xttsv2_banana` (to which
`Ftfyhh/xttsv2_banana` redirects) ships a `vocab.json` byte-identical to stock,
verified by md5. It was evaluated and rejected: it does not address stress, its
livelier intonation comes with swallowed phonemes, and the swallowing could not
be tuned out — lowering the sampling temperature removes the liveliness along
with it, and `length_penalty` is silently ignored as an invalid generation flag
by this version of transformers. `omogr/xtts-ru-ipa` does resolve homographs
correctly but runs 1.3–2.3× slower with a one-second failure-to-stop tail and a
non-commercial licence.

Wrong stress on a homograph is accepted as a cosmetic flaw. Everything that was
actually broken has been fixed.

### Models that do not work for this, and why

Recorded so nobody proposes them again. All three are strong models; all three
fail on the same axis.

- **F5-TTS** — no Russian in the base checkpoints, English and Chinese only.
- **VibeVoice** (Microsoft) — the model card states it plainly: "the model is
  trained only on English and Chinese data; outputs in other languages are
  unsupported and may be unintelligible or offensive." Its multi-speaker
  long-form design fits this product well, which makes the language gap the more
  frustrating. Microsoft also withdrew the TTS inference code from the public
  repository in September 2025 over deepfake misuse.
- **Cross-lingual cloning** — an English reference speaking Russian was tried
  with Jaina Proudmoore's Warcraft 3 lines. It produces Russian, and it sounds
  bad. That closed off every English-only voice pack as a source.
- **Silero + RVC** — Silero has native Russian with automatic stress, but does
  not clone; RVC would restore the timbre but needs roughly ten minutes of
  material per voice against the 20–28 seconds these references have.

### Voice quality, listened to and accepted, 2026-08-17

Both clones were played back to back:
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

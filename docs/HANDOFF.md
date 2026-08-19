# Handoff — 2026-08-19

Everything needed to resume without the conversation that produced it. Read this,
the spec, and the SDD ledger; the rest is in git.

- Spec: `docs/superpowers/specs/2026-08-17-awtrix-connectors-design.md`
- Plan: `docs/superpowers/plans/2026-08-17-awtrix-connectors.md` (29 tasks)
- Ledger: `.superpowers/sdd/2026-08-17-awtrix-connectors/progress.md` (git-ignored,
  local only — every ruling and deferred finding lives there)

## What this is

A native macOS menu bar app that runs pluggable connectors and pushes their
output to a Ulanzi TC001 clock running AWTRIX 3. The first connector reads the
day's popular anecdotes, voices them with cloned game-character voices, and shows
them on the clock on a user-set interval.

## State

**Every planned task is implemented.** 29 tasks plus a whole-branch review and
its fix round, on `feat/menu-bar-app`: 73 commits, **698 tests**, zero build
warnings, and **zero red in 30 consecutive full runs on a quiet machine**.
Nothing is merged and nothing is pushed.

Under heavy load the suite is a different animal — 21 red in 25 runs against ten
saturating processes — and always in the same four tests, all wall-clock budgets
rather than logic: `theProducersPacingIsObeyedPerClipNotAveraged`,
`theModelKnowsWhenTheNextRunIsDue`,
`theDueTimeFollowsABackoffRatherThanTheNominalInterval`,
`theShippedPlayerWaitsOutRealAudioForAsLongAsItLasts`. Read a red run against
what else the machine was doing before treating it as a defect.

The app is installed at `~/Applications/AwtrixConnectors.app`. Rebuild it with
`./Scripts/bundle.sh debug` and it lands in `build/`.

What it does now: prepares ten anecdotes ahead, refreshed daily and played
best-first by feed rank; speaks them in five cloned voices with the female one
reserved; shows a History with replay and copy; pauses when the clock is
unreachable, when macOS reports a Focus, and while a watched microphone is
capturing; warns on battery thresholds with a discharge ETA; mirrors the local
weather onto the clock's own overlay; and finds the device over Bonjour.

## How this branch finds defects

Worth reading before writing a line, because it is what the reviews are for. Over
35 real defects have come out of the plan's own code, and **most were found by
mutating a passing test and watching it stay green** — not by reading. Examples
that a green suite reported as healthy:

- an actor reentrancy bug that queued every anecdote twice, so each played twice
- a random generator that hung `swift test` forever rather than failing
- a recursive directory delete whose target came from an untrusted JSON store
- a cancelled run that left the clock banner up permanently
- a check that silently retired the clip reaper for ever, failing safe and so
  invisible
- flattening every tuned pause to one value — the rhythm destroyed, 196 tests green

Two rules earned the hard way. **Mutate one site at a time**: a mutation applied
to several sites at once dies on whichever runs first and proves nothing about
the others — that exact mistake hid a real gap. And **after adding a guard,
re-run the mutations of the guards it sits in front of**: a new check can swallow
an older test's purpose, and nothing reports that.

## Hardware, measured not assumed

Device at `192.168.1.72`, AWTRIX 0.98, `type: 0` (stock TC001). Found by mDNS: it
advertises `_http._tcp` as `awtrix_a07f9c`, and `awtrix.local` does NOT resolve.

- The buzzer plays RTTTL only. An uploaded `.mp3` sits on flash and never reaches
  the sound path: `/api/sound` answers 404 for a name backed by `.mp3` and 200 for
  the same name once a `.txt` exists. Speech therefore plays on the Mac.
- The font renders Cyrillic. Confirmed by reading the matrix buffer back.
- `/api/screen` returns 256 packed `0xRRGGBB` values, so what the clock shows can
  be rendered and inspected rather than trusted.
- The LaMetric CDN serves any icon by id with no auth. **Corrected 2026-08-18:** a
  missing id answers **404 with HTML** — earlier notes said 200 with an error
  page. The installer trusts the GIF magic bytes rather than the status, which is
  right under either reality. The claimed User-Agent challenge does not reproduce
  under any UA, including none.
- The catalogue's "animated" flag is unreliable — it marks single-frame icons
  animated. Count frames instead. The laughing icon is `66558`, 55 frames.

## The icon

AWTRIX 3 publishes **no square logo**. Its repository holds one wide AI-rendered
cover banner (1792x1024) whose wordmark is illegible below roughly 64pt, under
CC BY-NC-SA; the firmware itself serves an **empty** `/favicon.ico` — HTTP 200,
zero bytes — and 404s every other asset path. Both were checked, not assumed.

So the mark is drawn: `Scripts/MakeIcon.swift` renders a dark slab with a 32x8
LED panel, generated at bundle time into git-ignored `build/`, which keeps binary
art out of the repository and makes the design reviewable as code. Run it alone
with `swift Scripts/MakeIcon.swift` and look at `build/icon/preview-*.png`.

Three rules inside it, each of which was arrived at by rendering and looking:

- Lit pixels come from a hash of their coordinates, never a random source, so two
  runs are byte-identical and a diff in the art means a design change.
- One master at 1024, resampled down for every other size. Drawing simplified
  art per size was tried first and lost: the resampled wordmark still reads at
  32px, the directly-drawn one aliases into noise. The comparison sheet stays in
  the generator's previews as the record.
- The menu bar glyph is a separate, far coarser drawing, and a template image —
  macOS throws away its colour, so it must work as a silhouette. It is the body
  with a display cut out of it and lit pixels inside, on a **30x18** canvas:
  the bar caps an item's height at its own (~18pt, so ~36 physical pixels on a
  Retina display, and that is the whole detail budget) but does not cap its
  width, so the width is where the room is. `@2x` and `@3x` are emitted and
  macOS picks by display scale; a larger file does not buy a larger glyph.
- Online and offline are two glyphs — a screen with pixels, a dark screen — not
  one glyph plus a badge. The other three candidate styles stay in the generator
  behind `SHIPPED_STYLE`, because the comparison sheet is what settled the
  choice and re-deciding should mean rendering them again, not arguing.

## Voices

Five, all Russian, at `~/.local/share/tts-voices/voices/`. Median F0 in brackets:
`acolyte` (92 Hz), `arthas` (134), `peon` (262), `crystal` (296), `batrak` (329).
`crystal` is the only female voice and the only one not from Warcraft — there is
no Russian female pack in the peon-ping registry, so she comes from the Dota 2
Russian wiki.

Two traps when building a reference, both paid for once already:

1. **Do not pick clips by length.** It selects for declamation: the three most
   steeply falling contours in the Arthas pack all landed in his reference and
   every rising, question-like line was excluded, so the clone read questions with
   a falling pitch. Measure each clip's contour and keep a mix.
2. **Normalise every clip to one format before concatenating.** ffmpeg's concat
   demuxer applies the first file's parameters to the rest; one reference came out
   59% too long with its pitch dragged from 211 Hz to 108 Hz, and looked like a
   valid file. The F0 number is what exposed it.

## Speech

Stock XTTS-v2 through `~/.local/share/tts-voices/speak.py`, driven as a
long-lived `--serve` process speaking JSON Lines. **Do not modify that script** —
Swift code is written against its contract.

Loading the model is the entire cost: a cold demo run takes 70 seconds, a fully
cached one 0.28 s of CPU. That single measurement is why the connector never
synthesizes on demand and a preparer fills a queue in batches.

### Stress marking was built, measured, and removed — do not rebuild it

2026-08-18. The full path was implemented: RUAccent placing marks, the acute
moved across the vowel, guards for line length, for app-owned strings, and for
words whose final letter the mark would strand. **The balance measured negative
by ear: over one session it corrected two words and degraded nine.** The model is
usually right, we cannot predict where it is wrong, and every rule that guesses is
wrong on text nobody has heard. The user called the growing guard set a crutch and
that was the correct read.

What the investigation established, worth keeping:

- The combining acute is **not** absent from the XTTS vocabulary in the sense
  earlier notes claimed. It becomes `[UNK]`, but `[UNK]` is **inserted between
  tokens rather than consuming one** — every letter survives. Read the tokenizer
  before theorising: `храпи́шь` is `х · ра · пи · [UNK] · шь`.
- Position decides everything. The acute goes **after** the stressed vowel, which
  ends a Russian syllable, so it lands on a token boundary. `+` (the
  RUAccent/Silero convention) goes **before** it, splitting `мо` into `м` and `о`
  — and "зам ок" is exactly what that reads as.
- It still breaks a word when the mark strands a **word-final single-letter
  token**: `анекдо́т` is `до · [UNK] · т` and reads "анекдо тот"; `замо́к` loses
  its к. The same lone letter mid-word is harmless.

Two replacement engines were evaluated on the same five sentences and rejected:

- **`omogr/xtts-ru-ipa`** — its vocabulary is 294 IPA phonemes, so stress lives in
  the phoneme choice (unstressed о is `ɐ`/`ə`, stressed stays `o`) and no mark is
  needed at all. Homographs resolve in both directions from context. Killed by a
  ~0.55 s audible tail that `speed` does not shrink (speech 2.14 → 1.54 s while the
  tail stayed 0.59/0.53/0.59), a non-commercial licence, and a **silent failure
  mode**: fed Cyrillic by mistake it emits 4–6 seconds of plausible babble in the
  speaker's own voice rather than an error. If this path is ever revisited,
  transcription must be a hard gate, not an improvement.
- **`ResembleAI/chatterbox`** — MIT, 23 languages, native Russian, plain text in,
  tails 0.02–0.30 s (at or **below** stock's 0.15 median). The strongest candidate
  seen and not rejected on merit; the user concluded stress was not worth changing
  engine for. Install traps for whoever returns: it downgrades torch/transformers
  so it needs its **own** venv; the weights carry CUDA tensors so `torch.load`
  needs `map_location`; and its mandatory Perth watermarker needs `pkg_resources`,
  which setuptools **removed in v81** — pin `setuptools<81`.

**VibeVoice has no Russian.** Re-checked rather than trusted: all four official
TTS repos declare `en, zh`, and the repos that surface with a `ru` tag are
VibeVoice-**ASR** — recognition, not synthesis. Zero of 200 declare `ru`.

Wrong stress on a rare word is accepted as a cosmetic flaw. The two words this
was ever about are храпишь and сосиску.

## Requirements settled with the user

- Anecdotes must not repeat. Played `<guid>`s persist; when the primary feed is
  exhausted the source widens (`export_top` → `export_bestday` → `export_j`)
  rather than resetting.
- The clock shows a short `ВНИМАНИЕ, АНЕКДОТ!` banner, held until the speech ends
  — not the joke, which is heard rather than read.
- The announcement is spoken, not merely scrolled.
- Each audio clip carries its own `leadIn`, so the connector sets the rhythm and
  the player never learns what a punchline is. Tuned by ear: 0 / 0.7 / 0.25 / 0.7.
- The laugh scales with the joke's length; short jokes draw at random from three
  variants.
- A female line — detectable from Russian past-tense verb endings — uses the
  female voice.

## Not yet in Swift

**Female voice — implemented in the Python prototype only.** `speaker_genders` in
`prototype/demo_anecdote.py` flags an actor who uses a feminine past-tense verb
(`-ла`, `-лась`) with the pronoun `я` within two tokens. The self-reference window
is what makes the suffix usable: bare `-ла` also ends школа, сила and стрела, and
we do not care whether a line contains a feminine verb, only whether the speaker
uses one about herself. First signal wins, and a line carrying BOTH signals decides
nothing — that shape is reported speech, and a man in a woman's voice is a louder
failure than a miss.

Measured across the whole cascade — 72 anecdotes, 19 with dialogue, 55 actor lines
— it fires once on a woman and three times on men, every one correct on the line
that actually decided. `prototype/test_gender.py` holds thirteen cases pinning the
rule, including the traps: `Я сила!` (a noun), `У меня сила воли` (`меня` is not
`я`), and a feminine verb about somebody else. **Those cases are the acceptance
set for the Swift port.**

One measurement trap, paid for once: the first validation script printed each
flagged speaker's FIRST line rather than the line that decided, which makes a false
positive look like a correct call. Print the deciding line.

Casting changed with it, and the second half mattered as much as the detector:
`cast` had been handing the narrator and actor(0) the same `pool[0]`, so a woman's
line drew `acolyte` — the deepest voice at 92 Hz. Only `crystal` is now reserved;
the narrator voice deliberately stays in the actor pool, because that is the
casting every approved demo used.

**Marked speakers — still designed only.** Two forms count: `<label>: <dash>
<text>` always, and `<label>: <text>` only when the same anecdote carries two or
more distinct labels. The paired requirement is what rejects ordinary prose —
`Идея для свидания:` and `Верховный суд РФ:` both appear in the real feed. Zero
false positives on the measured corpus.

Neither has a task. Both extend closed tasks, so each needs one written.

## What later tasks owe

Recorded so they are not deferred a fourth time. All are in the plan already.

**Task 13 (device monitor)** — nothing outstanding.

**Task 14 (menu bar app)** carries the most:

- Call `maintain(connectorId:)` before each timer-driven run. `produce()` only
  awaits a refill when the queue is empty, so a timer that never maintains turns
  every firing into a 70-second model load on the play path.
- Wire a **required** `clipRoot` from the composition root's `outputDirectory`. A
  defaulted one would read as a guarantee while supplying none.
- Read `Connector.defaultInterval` when the store has never saved. It is invisible
  today only because `AnecdoteConnector` coincidentally matches the position-5
  default; a second connector with a different interval makes it a live bug.
- **The quit budget, as one decision rather than two.** Cancelling a queued run
  stops the work but does not release the caller, and `releaseBanner` is
  deliberately uncancellable for up to the transport's 15-second timeout. The quit
  handler must grant that window or macOS kills the app and the banner stays — which
  would undo the banner fix at the exact moment it matters most. The audio player is
  not a term here: its cancellation is 0.9–6.3 ms mid-clip, 123–198 ms on the first
  cancel in a process.
- **Remove installed icons.** This is the only thing the app writes to device
  flash and nothing removes it, breaking the plan's own constraint. The bare
  `<id>.gif` name is deliberate — it lets the skip-by-name check reuse an icon the
  user installed themselves — so removal cannot be "delete everything with our
  prefix". Track what the app uploaded and offer an explicit menu action. Icons
  must survive quit, so a teardown hook would be wrong.
- A disable during a playing anecdote does not retract an already-queued run.
- **Ship the app's icon.** `Scripts/MakeIcon.swift` already renders it; Task 14
  wires it in — `bundle.sh` runs the generator, `iconutil` builds the `.icns`
  into `Contents/Resources`, `Info.plist` gains `CFBundleIconFile`, and
  `MenuBarExtra` swaps its SF Symbol for the template glyph. The trap:
  `NSImage(named:)` reads `Contents/Resources`, which does not exist under a bare
  `swift run`, so keep the SF Symbol fallback or the unbundled binary shows an
  empty menu bar slot.

**Task 15 (retry policy)** — `.cancelled` now shares the `catch` with real errors
and must NOT advance the failure counter. A run the app tore down is not evidence
the feed is sick.

**Also open, with no owner yet:** `public enum AwtrixKit` shadows the module name,
which is why `IconRef` had to be renamed `IconReference` (LaunchServices declares
its own `IconRef`). Pre-1.0, compile-time only, fails loudly. Its own task.

## Running the demonstration

The Python prototype does end to end what the Swift app will do, against the real
device:

```bash
cd ~/Dev/Personal/awtrix-connectors/prototype
python3 demo_anecdote.py колобок      # a pinned anecdote, always available
python3 demo_anecdote.py              # first dialogue in today's feed
python3 demo_anecdote.py вертолёт     # the other pinned one — has the female line
python3 test_gender.py                # the female-voice acceptance set
```

Clips are cached by voice and text under `prototype/cache/`, so a repeat never
starts the synthesis model at all.

## What only a person at the hardware can settle

Nothing below is testable from a process that is never an active app. Each is
one look or one click.

1. The menu bar glyph flips when the clock goes offline. (Its *direction* is now
   pinned by a test; that the swap reaches the screen is not.)
2. The gear opens the settings, the History button opens the History, and
   "Run now" is wired to something. A SwiftUI `Button`'s action cannot be
   invoked without a window and a run loop.
3. History → click away → click the menu bar item returns to the **panel**. The
   reset hangs on `didResignKey`, which a test process never posts.
4. Wi-Fi off shows a line that does **not** claim "nothing on this network".
5. Denying Local Network in System Settings produces the refusal line.
6. The battery dialog at 20% — and whether a modal there is as intrusive as it
   sounds.
7. The weather overlay actually appears, and hands back the value that was
   there before.

### Confirmed by observation, 2026-08-19 — no longer owed

Half of item 7 is settled. After the app's process ended, `GET /api/loop`
listed only the four firmware built-ins with no `weather`, and `OVERLAY` read
`clear`. So a clean quit does take this app's own app back out of the rotation
and does put the overlay back. What is still unwitnessed is a hand-back of a
NON-clear overlay, because the sky was clear throughout.

### Added by wave 2

8. The History opens on the FIRST press. This is the defect that was reported;
   the fix it received addresses a real defect in the window observer but was
   never proven to be that symptom's cause. If it still takes two presses, say
   so — the diagnosis is then wrong, not the fix incomplete.
9. Clicking away from the panel still returns the menu to the panel next time.
   This is the one that would break if the panel's window is never identified:
   the reader that learns it cannot be exercised headlessly, and if it comes
   back nil, NO surface ever closes. Open panel, open History, click another
   app, reopen — it must show the panel.
10. The weather app on the clock carries an animated icon, and the temperature
    is coloured from how it feels rather than from the sky.
11. The panel has no weather row, and the gear has the weather toggle.
12. On mains the line reads plug and percentage, with no time estimate and no
    trend word beside it.
13. The percentage does not flicker between two values while nothing is
    happening. It is ratcheted to the direction of travel; the underlying
    reading is what the warnings still read.

## Signing, and three Apple APIs that are inert without it

This machine has **zero code-signing identities** and the bundle is ad-hoc
signed by the linker. Three authorization APIs were probed and all three refuse:

- `UNUserNotificationCenter.requestAuthorization` → refused, `UNErrorDomain` 1.
  System notifications never arrive; **the dialog is the only channel**.
- `INFocusStatusCenter.requestAuthorization` → the handler is never called and
  the status stays `notDetermined` for ever. **The user-set quiet window is what
  actually silences the schedule**, not Focus.
- CoreLocation → `requestLocation` fails `kCLErrorDenied`. Typed coordinates are
  the path that works.

Each has a fallback that was designed in from the start precisely because the
brief said not to trust an unprobed capability. Sign the app and all three light
up; none of them is wired to a stub.

Also: running the binary **directly** rather than through the bundle aborts on a
TCC privacy violation — LaunchServices, not the path on disk, is what attributes
`Info.plist`. And `open` forwards the calling shell's environment, so launching
from a terminal is **not** a faithful reproduction of a Finder launch.

## Deferred findings

The ledger carries roughly forty deferred minor findings from the task reviews,
each with the reason it was deferred. The final whole-branch review triages them.

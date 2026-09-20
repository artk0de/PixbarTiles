# Handoff — 2026-08-19

Everything needed to resume without the conversation that produced it. Read this,
the spec, and the SDD ledger; the rest is in git.

- Spec: `docs/superpowers/specs/2026-08-17-awtrix-connectors-design.md`
- Plan: `docs/superpowers/plans/2026-08-17-awtrix-connectors.md` (29 tasks)
- Next: `docs/superpowers/specs/2026-09-18-pixelclocktiles-multi-clock-design.md`,
  one plan per phase — phase 0 is
  `docs/superpowers/plans/2026-09-18-pixelclocktiles-phase0-rename.md`
- Ledger: `.superpowers/sdd/2026-08-17-awtrix-connectors/progress.md` (git-ignored,
  local only — every ruling and deferred finding lives there)

## What this is

A native macOS menu bar app that runs pluggable connectors and pushes their
output to a Ulanzi TC001 clock running AWTRIX 3. The first connector reads the
day's popular anecdotes, voices them with cloned game-character voices, and shows
them on the clock on a user-set interval.

## State

**Wave 3 shipped on top of a finished branch.** 52 tasks now, on
`feat/menu-bar-app`: 122 commits, **879 tests**, zero build warnings on
both targets. Nothing is merged and nothing is pushed.

The three waves, so the shape is readable: wave 1 built the app and its anecdote
connector; wave 2 made the weather ambient furniture with animated icons and a
feels-like colour, moved it off the panel, and cut the clock's polling; wave 3
was driven entirely by defects the user saw on live hardware — the History's
first press, a discharge the app could not see, a quiet window the signing
experiment silently disabled, and a battery that forgot itself on every launch.

Under heavy load the suite is a different animal — 21 red in 25 runs against ten
saturating processes — and always in the same four tests, all wall-clock budgets
rather than logic: `theProducersPacingIsObeyedPerClipNotAveraged`,
`theModelKnowsWhenTheNextRunIsDue`,
`theDueTimeFollowsABackoffRatherThanTheNominalInterval`,
`theShippedPlayerWaitsOutRealAudioForAsLongAsItLasts`. Read a red run against
what else the machine was doing before treating it as a defect.

The app is installed at `~/Applications/PixelClockTiles.app` (until the first
install of the renamed build, the old `~/Applications/AwtrixConnectors.app`).
Rebuild it with `./Scripts/bundle.sh debug` and it lands in
`build/PixelClockTiles.app`. The package is `PixelClockTiles`: the kit is
`PixelClockKit`, the executable target `PixelClockTilesApp`, and their tests
`PixelClockKitTests` and `PixelClockTilesAppTests`.

What it does now: prepares ten anecdotes ahead, refreshed daily and played
best-first by feed rank; speaks them in five cloned voices with the female one
reserved; shows a History with replay and copy; pauses when the clock is
unreachable, when macOS reports a Focus, and while a watched microphone is
capturing; warns on battery thresholds with a discharge ETA; mirrors the local
weather onto the clock's own overlay; and finds the device over Bonjour — while
the panel is open and the clock is not answering, and at no other time, because
a browse left running puts multicast on the network for the life of the process.

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

### The battery, measured 2026-08-19 — and the number that was guessed wrong

`bat_raw` is an ADC count. `bat` is derived from it by the firmware as
`map(raw, 475, 665, 0, 100)`, which reproduces both live observations exactly
(648 → 91%, 665 → 100%). So **one percent is about 1.9 raw steps**, not the
seven a comment in this tree used to claim — that figure was `648/91`, a ratio
where a slope was wanted.

Three rates, all from this clock, all needed to tell a discharge from noise:

| state | measured | per ten minutes |
| --- | --- | --- |
| charging | 664 → 669 in two minutes | ~25 steps |
| **discharging** | **646 → 642 over 30 minutes; 90% → 87%** | **~1.33 steps** |
| at rest on mains | 667–669 across ten minutes | ±1 |

The discharge figure is the one that matters and the one that was got wrong
twice. A brief written from it said "a few hours" of range; the measurement says
**about 16.7 hours** at brightness 3. A threshold sized against the guess was
twice the real signal, so the app reported a charging clock throughout an entire
discharge — plug shown, no estimate, and every low-battery warning silently
ungated, because the direction gates those too.

**The series is not monotonic**, and that is the crux: raw held 644 for nine
consecutive samples, fell to 641, rebounded to 643. The wander is ±2 — LARGER
than the 1.33 of signal over ten minutes. No threshold on a short window can
separate them; only a longer baseline can, which is why the fall window is an
hour and the rise window is ten minutes. The asymmetry is 20:1 in the signals,
not in the noise.

**A clock that has just booted answers `bat_raw = 0`**, measured 2026-08-20
through a power-on: `uptime=25` gave `bat=0, bat_raw=0`, `uptime=42` gave
`bat=98, bat_raw=662`, `uptime=50` gave `bat=97, bat_raw=661`. Nothing crosses
98 points in seventeen seconds — the firmware answers before it has read the
converter. The window is roughly the first twenty to forty seconds of uptime
against a poll every sixty, so about one reboot in two lands a poll inside it.
Both fields are wrong in that reply and only the raw one is diagnostic, `bat`
being derived from it and clamped, so `record(_:at:)` drops any reading whose raw
figure falls below `rawAtEmpty` before it can become a sample or a percentage.
475 itself is kept: that is where the map puts 0%, and a battery genuinely run
down to nothing is the last thing the app gets to warn about. Untreated, the zero
costs twice — the lowest threshold fires without waiting for a direction, so it
is a false red warning on the first poll after a reboot, and the +662 that
follows it is an instant confident "charging".

Anyone re-tuning these numbers: take a fresh series first. The clock's rate
depends on its brightness, and `BRI` was 2–3 for every measurement above.

**The readings survive the app.** Those windows are the cost of a signal smaller
than its own noise, and nothing shortens them — but they only have to be paid
once. The samples are written to `UserDefaults` under `batteryHistory` on every
poll and the trajectory is rebuilt from them at launch, so a relaunch resumes
the trend instead of spending twenty minutes earning it again. The restored
series goes through the same three discard rules a live reading does — a
different `uid`, uptime going backwards, a gap longer than the 90-minute window
— so a series that no longer describes the clock in front of the app is thrown
away and the launch starts cold, which is the honest answer. What is NOT stored
is the verdict: it is recomputed from the samples, because a stored one could
only be trusted or dropped.

## The icon

AWTRIX 3 publishes **no square logo**. Its repository holds one wide AI-rendered
cover banner (1792x1024) whose wordmark is illegible below roughly 64pt, under
CC BY-NC-SA; the firmware itself serves an **empty** `/favicon.ico` — HTTP 200,
zero bytes — and 404s every other asset path. Both were checked, not assumed.

So the mark is the user's own pixel-art clock: `Scripts/MakeIcon.swift` sets the
approved `UserClock` map — the menu bar glyph's single home, compiled into the
app target AND into the generator, so the shipped art and the tested map cannot
drift apart — on the dark circular badge its source art sits on, the badge
having been dropped only for the tiny bar. Everything is generated at bundle
time into git-ignored `build/`, which keeps binary art out of the repository
and makes the design reviewable as code. Run it with
`swiftc Sources/PixelClockTilesApp/MenuBarUserclock.swift Scripts/MakeIcon.swift
-o build/icon-maker && build/icon-maker` and look at
`build/icon/preview-appicon-*.png`.

Rules inside it, each of which was arrived at by rendering and looking:

- One master at 1024, resampled down for every other size. Drawing simplified
  art per size was tried first and lost: the resampled clock still reads at
  32px, the directly-drawn one aliases into noise. The comparison sheet stays
  in the generator's previews as the record.
- Clock pixels stay pixels: the map rides on the badge at a whole art-pixel
  scale, centred on whole device pixels, so the icon itself never resamples
  the art — only the badge, its sheen and its halo are smooth. The dark
  palette is the source of truth; Finder and the Dock put the icon on light
  ground, where the light frame carries the silhouette.
- The menu bar glyph is the bare clock in colour, NOT a template — a template
  is macOS DISCARDING the colour, and the four approved palettes are what the
  glyph is. One art pixel is one point on a 21x18 canvas (the bar caps an
  item's height, not its width); `@2x` and `@3x` are emitted and macOS picks
  by display scale, so a larger file does not buy a larger glyph.
- Online and offline are two palettes, not one drawing plus a badge: offline
  dims the sliders to grey and takes the sparkles out.

The alternative treatments of the candidates stay in
`icons-candidates/menubar/MakeMenuBarCandidates.swift`, because the comparison
sheet is what settled the choice and re-deciding should mean rendering them
again, not arguing.

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

**Also open, with no owner yet:** `public enum PixelClockKit` (`AwtrixKit` before
the rename) shadows the module name,
which is why `IconRef` had to be renamed `IconReference` (LaunchServices declares
its own `IconRef`). Pre-1.0, compile-time only, fails loudly. Its own task.

**PixelClockTiles, left by phase 1** (plan
`docs/superpowers/plans/2026-09-18-pixelclocktiles-phase1-domain-persistence.md`):

- The migration is a series of steps, each with its own marker, written last.
  Phase 1 ran `migration.clocks` and `migration.tiles`. A later step reads the
  old keys when it lands — they are never removed — and moves a row in the
  same commit that stops the app writing its source key.
- Phase 4 owes the step for the quiet hours, `weatherLocation` and the VPN
  lamps. It extends `TilePolicyRecord` with optional keys for the Focus and the
  hours; a tile without them has not been through that step.
- Whichever phase keys custody and health by clock owes the steps for
  `borrowedOverlay` and `batteryHistory`, in the commit that re-keys them.
- `TileSettingsStore.save` keeps the stored seconds while the slider position
  they snap to has not moved. It retires with the adapter when the scheduler
  reads `TileRecord` directly; until then nothing may write seconds that the
  old scale cannot show except through a moved slider.
- `ClockStore.firstClock(orCreatingAt:)` creates a clock when none is stored.
  Phase 5 removes that branch once "No clocks yet" is a state the user can
  reach, and decides what `ClockMigration` does on a fresh install.

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

### Added by the resizable border

The ↔ glyph these items used to be about is gone. It was one spot to reach for,
and what was asked for is the gesture every other window has: put the pointer on
an edge and pull. There is nothing to see now — the grips are six points of the
surface's own padding — so the cursor is the entire affordance, and item 14 is
as much about whether it can be FOUND as about whether it works.

14. Bring the pointer slowly onto the right-hand edge of the panel. Within a few
    points of the edge it becomes a horizontal resize cursor. Drag right: the
    panel widens as you drag, the rows lay out at the new width, and nothing
    runs off the edge. Then the same on the LEFT edge, pulled left — the same
    widening, because outward is outward on both sides.
15. Let go, click somewhere else, click the menu bar item again — it opens at
    the width you left. Then quit and relaunch: still that width.
16. Drag inwards, hard, past where you started. It stops at 320 and will not go
    narrower, so there is always a border left to grab. A panel dragged to
    nothing would be recoverable only from the command line.
17. **The three surfaces are one width now.** Widen the panel, then press the
    gear, then Back and History. All three open at what you left, and the window
    stops resizing itself when you change surface. (It still changes HEIGHT
    between them, by 400 points or so between the panel and the settings, since
    each is as tall as its content.)
18. Where the menu bar item sits changes which way the panel grows. With the
    item near the RIGHT of the bar the window is right-anchored and grows
    leftwards, so the edge you are dragging stays put while the pointer moves
    away from it. Dragging outward still widens it — that is measured off the
    pointer's screen position, not off the window — but say whether the edge
    failing to follow reads as broken.
19. With something in the History, bring the pointer onto its BOTTOM edge: an
    up-and-down resize cursor. Drag down and the list gets taller. Scroll it —
    the entries below the fold are still reachable, so the height is a viewport
    and not a pair of scissors.
20. Drag the History's bottom edge up, hard. It stops with about two entries
    showing, so there is always a bottom edge left to pull back down.
21. The History's TOP edge is the counter-intuitive one, and it is worth a look
    rather than a fix. The surface hangs from the menu bar, so the top boundary
    cannot move: pulling the top edge UP makes the surface taller by moving its
    BOTTOM down. The size changes in the direction the gesture asks for; the
    boundary that moves is the other one. Say whether that reads as broken —
    the same question as 18, on the other axis.
22. The four corners move both axes at once, on the History. On macOS 14 they
    show a horizontal cursor rather than a diagonal one, because AppKit had no
    public diagonal resize cursor until 15; on this machine they should show the
    real corner cursor. Worth confirming which you get.
23. Open the History with **nothing played yet**. The top and bottom edges do
    nothing there and offer no cursor — there is no list to resize — while the
    left and right edges still work. Confirm the sides still resize it.
24. If a surface ever opens at a size you cannot work with:

    ```sh
    defaults write dev.artk0re.pixelclocktiles panelWidth -int 320
    defaults write dev.artk0re.pixelclocktiles historyHeight -int 280
    ```

    then relaunch. Deleting either key does the same. Both are read back through
    their clamp, so a value typed outside the range is corrected rather than
    honoured — and `historyHeight` is clamped against the screen it is READ on,
    which is what makes a height saved on a big display safe on a laptop.

### Added by wave 3

24. **The cadence survives a relaunch.** Quit the app part-way through an
    interval and reopen it: the panel must name the REMAINDER, not a fresh full
    interval. This is the defect that was reported — five relaunches inside an
    hour meant the hourly anecdote never arrived, because each launch started
    the hour again.
25. **A long absence owes one delivery, not a queue.** Leave the app closed for
    several intervals and reopen: exactly one anecdote, then the normal cadence.
    A burst here would be the app punishing the user for having shut the laptop.
26. **A connector that has never run still waits a full interval.** On a fresh
    install nothing is owed, so the first anecdote is one interval away and not
    immediate. Deliberate — verify it did not become eager.

### Added by wave 4

27. **The battery trend survives a relaunch.** Watch the panel until the row
    carries a glyph, quit the app, reopen it: the glyph must be there on the
    FIRST reading. This is the defect that was reported — 81 seconds after a
    launch the row was still a bare percentage, because the samples lived in
    memory and the window had to be earned again.
28. **A true first launch marks the row rather than leaving a bare number.**
    `defaults delete <bundle-id> batteryHistory`, or point the app at a clock
    this Mac has never seen, then reopen: the row reads ⏳ and the percentage
    until the trend lands. The hourglass is the one mark that claims nothing
    about where the power is coming from.
29. **The Focus caption says what the app actually does.** With Full Disk Access
    granted the settings line under the hour pickers must name Do Not Disturb
    and Sleep; revoke it and the same line must go back to naming any Focus.
    The sentence describes the RULE, so turning a Work Focus on must not change
    it — what changes is that the app keeps talking.

### Added by PixelClockTiles phase 1

30. **An upgrade keeps what the user had.** Install the phase 1 build over the
    previous one and open the panel: the clock at the same address, the
    anecdote interval and switch as they were, and the next anecdote due at the
    remainder of the interval rather than a fresh one. Then let the clock drop
    off the network and come back at a new address: the app follows it, which
    is the migrated `deviceUID` at work.

## The panel's width belongs to the content, not to the window

Route one — make the real window resizable — was probed on the running app
before the handle was written, and it does not hold. The measurement, from a
launch with the schedules skipped so nothing reached TCC:

- `MenuBarExtra` in `.window` style puts the panel on a `MenuBarExtraWindow`,
  style mask 32896: borderless, non-activating, full-size content view. Not
  resizable.
- `.resizable` goes into the mask without complaint — `AppDelegate` has held the
  panel's `NSWindow` since `ee2c7c1`, so this is one line — and the window then
  accepts `setContentSize(500 x 198)`. Its frame reads 500 wide immediately
  afterwards.
- **Half a second later it reads 320 again.** SwiftUI keeps that window at its
  content's fitting size, pins `contentMinSize` there as well, and re-imposes
  both on the next layout pass. With the content at a fixed `.frame(width:)`
  there is nowhere for a dragged size to survive, style mask or no style mask.

The same run showed why the handle works. Opening the gear took the window from
320x198 to 320x615 unasked, and moved it to stay under its menu bar item. The
window follows the CONTENT and does its own anchoring — so a width the content
carries is a width the window adopts, which is what `.frame(width:)` off a
stored value now does.

Confirmed on the shipped build rather than argued: with `panelWidth` written to
480, the panel opened at **480x198 and stayed there** — `contentMinSize` moved
to 480 with it, where route one's hand-set 500 had collapsed back to 320 inside
half a second. Same window class, same style mask; the difference is entirely
which side of SwiftUI's layout the number is on.

Both literals are gone. `SettingsSheet` and `HistoryMenu` carry the shared width
themselves, through the one `panelWidth(from:)` modifier all three surfaces use,
so there is one place that reads the key and one that writes it.

Wrapping the two from outside was tried first and does not substitute: an outer
`.frame(width: 500)` around `SettingsSheet` gives a 500-wide host with the
sheet's 320 of content centred in it — measured, the fields sit at x=104 with
90 points of nothing on each side. A child's fixed frame cannot be overridden by
its parent, which is why the literal had to go rather than be wrapped, and why
the width arrives on each surface rather than round all three.

### The height, and why only one surface has one

The same measurement decides it. The panel and the settings are their content's
fitting height — 198 and 615 — and SwiftUI re-imposes that every layout pass, so
a stored height there would clip a form that does not scroll or pad it with
nothing. The History is different because it has a `ScrollView` in it: a height
given to a scroll view is a viewport, and the entries under the fold are a
scroll away rather than gone. So `HistoryHeight` exists and no equivalent for
the other two does.

Its ceiling is the screen's rather than a constant, which is where it parts
company with the width. The width grows sideways off a menu bar item and 1200
points fits inside the narrowest display macOS 14 runs on. A height hangs
DOWNWARDS from the menu bar, so how much room there is depends entirely on what
is under it — and a History grown past the bottom of the display has taken the
edge that would shrink it off the screen too, with scrolling no help because it
is the viewport that has gone. The chrome allowance is measured rather than
guessed: 69 points for the padding, header, divider and spacing, about 115 once
a failed replay has put its two-line answer under the title, rounded up to 120.

## Signing — and the three APIs that turned out not to be dead

**This section replaces an earlier one that was wrong.** It said this machine
has no signing identity and that three Apple authorization APIs refuse here.
The first half is still true of what the toolchain produces; the conclusion drawn
from it was not.

`./Scripts/bundle.sh` leaves the linker's **ad-hoc** signature, and an ad-hoc
signature has no stable identity — it changes with every build, so TCC has
nothing to remember a grant against. That, not the absence of an Apple
certificate, is what the three refusals were measuring.

A **self-signed** code-signing certificate is enough to fix it, costs nothing,
and needs no Apple ID. One was created in the login keychain as
`AwtrixConnectors Local Signing`. macOS does not report it under
`security find-identity -p codesigning`, because that lists TRUSTED identities
and this one is not trusted — trust is needed to VERIFY a signature, not to make
one. Sign by its SHA-1 instead:

```bash
codesign --force --deep --sign 6417A281BC7E103BB9B4A4EA69F831F5211A89A5 build/PixelClockTiles.app
```

### Probed again, signed, 2026-08-19 — all three answer

Each was a separate minimal bundle, signed with that identity and launched
through LaunchServices, writing its result to a file.

| API | Ad-hoc, as first measured | Signed |
| --- | --- | --- |
| `CLLocationManager` | `requestLocation` fails `kCLErrorDenied` | authorization goes notDetermined → authorized; **fix returned to 55 m** |
| `UNUserNotificationCenter` | refused, `UNErrorDomain` 1 | `granted=true`, status `authorized` |
| `INFocusStatusCenter` | handler never called, stays `notDetermined` for ever | handler called, status `authorized`, `isFocused` readable |

The location result is the one that changes a product decision. Its 55 metres
beat both alternatives on the only axis that matters here: IP geolocation put
this machine in **Amsterdam**, 2,000 km out, because of a VPN — corroborated
across three services — and the Open-Meteo geocoder knows settlements but not
districts, which cannot tell one side of a 40 km city from the other.

`NSLocationWhenInUseUsageDescription` is required for any of that and is now in
`Scripts/bundle.sh`. Without the key CoreLocation refuses whatever the signature
says.

### What this does NOT change

- `bundle.sh` still does not sign. Signing is a machine-local step with a
  machine-local certificate hash; baking one developer's identity into the
  script would break every other checkout.
- The fallbacks stay. The user-set quiet window, the dialog, and typed
  coordinates all still work and are still what an unsigned build uses. Nothing
  was rewired to depend on a signature.
- `SMAppService` was probed alongside them and is **not** in this family: it
  registers a login item under an ad-hoc signature just as happily. Four
  variants, all identical, verified against `sfltool dumpbtm`.
- Running the binary **directly** rather than through the bundle still aborts on
  a TCC privacy violation — LaunchServices, not the path on disk, is what
  attributes `Info.plist`. And `open` forwards the calling shell's environment,
  so launching from a terminal is not a faithful reproduction of a Finder
  launch.

## The rename to PixelClockTiles

Phase 0 of the multi-clock design. The bundle is `PixelClockTiles.app`, its
identifier `dev.artk0re.pixelclocktiles`; 1010 tests, zero build warnings.

**Settings are carried over, once.** A defaults domain is keyed by bundle
identifier, so `DefaultsCarryOver` runs first in `AppDelegate.init()` and
copies every key of `dev.artk0re.awtrix-connectors` that the new domain lacks.
It never overwrites a key the new domain already holds, and it writes its
marker, `carriedOverFromAwtrixConnectors`, last. The old domain is only read,
so going back to the old build finds everything where it was. Presence is
judged on the new domain's own record, not through the search list, which
also answers from the registration domain and `NSGlobalDomain`.

Where else the old name lives, and what was decided:

| Where | Decision |
| --- | --- |
| `~/Library/Application Support/AwtrixConnectors/anecdotes.json` | Kept. Not keyed by bundle id, so the rename does not move it, and moving it would put the played set at risk for the sake of a name |
| `$TMPDIR/awtrix-speech` | Kept. The store records clip paths under it and the reaper reclaims nothing outside it |
| `DispatchQueue` labels | Renamed to `dev.artk0re.pixelclocktiles.*`; nothing persisted |
| Logger subsystems, Caches | None exist |
| Keychain | Nothing of ours; the app reads Claude Code's `Claude Code-credentials` |
| Signing identity `AwtrixConnectors Local Signing` | Kept; it is chosen by SHA-1 and its name is read by nothing |
| The app icon's wordmark, `AWTRIX` in `Scripts/MakeIcon.swift` | Kept. A new mark is a design question, not part of a rename |

**Paid once by the user**, because TCC grants are bound to the bundle id and
the signature: location, notifications, Focus, Local Network and Full Disk
Access are asked for again (Full Disk Access means adding
`PixelClockTiles.app` in System Settings by hand); the login item is turned on
again from the settings; the first read of the Claude token raises the
keychain prompt again. Remove `~/Applications/AwtrixConnectors.app` once the
new build runs, which also retires its login item.

To check at the desk, on the first launch of the renamed build: the panel talks
to the same clock and names the remainder of the interval the old build was
in, not a fresh one; and the battery row carries its trend glyph on the first
reading rather than ⏳.

**The installed app no longer depends on `.build`.** Until now `Bundle.module`
found the bundled GIFs through the absolute build path compiled into the
binary, and `fatalError`ed once that directory was gone, so a build installed
from a worktree died with the worktree. This predated the rename, and is now
fixed. `Scripts/bundle.sh` copies `PixelClockTiles_PixelClockKit.bundle` into
`Contents/Resources` (not the `.app` root, which codesign refuses), and
`KitResources.bundle` reads that copy first, touching `Bundle.module` only when
there is none, which is the case under `swift test` and `swift run`. Any new
kit resource goes through `KitResources.bundle`, never `Bundle.module`
directly. Phase 3's TC002 images included.

## Deferred findings

The ledger carries roughly forty deferred minor findings from the task reviews,
each with the reason it was deferred. The final whole-branch review triages them.

## PixelClockTiles Phase 2 — what it leaves for later phases

Phase 2 (`docs/superpowers/plans/2026-09-18-pixelclocktiles-phase2-ports-awtrix-parity.md`)
changed no behaviour. What it deliberately did not do, so the next phases do not
look for it:

- `ConnectorRunning` is still the app's name for a session; the kit type is
  `AwtrixClockSession`. Phase 4 renames the protocol when `AppModel` holds a
  session per clock.
- `DeliveryChain` is keyed by `String`. Phase 4 makes it generic over `TileKey`.
- Health — `DeviceMonitor`, `BatteryTrajectory`, relocation — is still in
  `AppModel`. It moves into the session in Phase 4.
- `AwtrixScene` is a struct with a `surface`, not the spec's enum. `.indicator`
  joins it in Phase 4 with the VPN tile's face, and indicator writes must stay
  off the delivery chain there too.
- `awtrixFace` is non-optional. Phase 3b adds `ulanziFace` as optional with a
  `nil` default in a protocol extension.
- No `Config` on `Connector`. It lands in Phase 4 with the weather tile's
  location, its first reader.
- `produce()` is the AWTRIX program. Phase 3b names the TC002 counterpart.
- The drawing tests stayed in their connector test files; Phase 3b moves them
  when TC002 face tests land beside them.
- `VPNLampDisplayTests` still pins lamp custody through the app's two corners.
  When Phase 4 deletes `VPNLampDisplay`, `IndicatorCustodyTests` carries the
  rules, and the generic "put out every lit lamp on quit" is Phase 4's to add.

Owed at the hardware (the desk clock is now a TC002, so this waits for a TC001
on the network): the weather app, the Claude app and an anecdote banner look as
they did before Phase 2; the VPN corners follow a Focus switch; a clean quit
removes the apps, restores the overlay and darkens both corners.

Found while running the suite, and not changed by Phase 2:
`nothingButTheAnecdotesEverPutsSoundInTheRoom` produces every connector
`live()` registers, so it read the real login keychain through
`KeychainClaudeCredentials` — a reader lane C has since deleted, so the test no
longer touches the keychain. Once, with the machine under heavy load, it sat in
`SecItemCopyMatching` for more than ten minutes and held a serial run with it;
alone, later, it passed in five seconds. A serial run that stops printing is
worth sampling for that frame before anything else is suspected.

## Claude usage from Claude Code's status line — lane C

The Claude figure no longer comes from `/api/oauth/usage` with a token taken
from the keychain. Connect Claude Code (in the settings) sets Claude Code's
`statusLine` to `/bin/sh '<Application Support>/PixelClockTiles/claude-statusline.sh'`,
followed by the previous command as a quoted argument when there was one. After
each reply the hook stores the document, if it carries `rate_limits`, as
`claude-status.json` beside itself, then runs the previous command. The
replaced value is kept in the defaults key `claudeStatusLine.previous`, and
Disconnect puts it back, removes the hook and removes the document.
`StatusLineClaudeUsageReporter` reads the document on every Claude refresh.

Known limits, which are not defects:

- A project's own `.claude/settings.json` with a `statusLine` overrides the
  user's in that project, so sessions there never run the hook.
- `CLAUDE_CONFIG_DIR` moves Claude Code's settings. The app edits
  `~/.claude/settings.json` only.
- Two sessions signed in to different accounts: the last one to reply wins.
- A `refreshInterval` carried over from a previous status line runs the hook on
  that timer too, and Claude Code re-runs it when a window resets. The
  document's time can move without a reply.
- Rewriting `settings.json` keeps every value, but not its formatting or key
  order.
- A bare `swift run` build cannot connect. Without a bundle id there is no
  link, and that guard is what keeps `swift test` off the real settings.

### What only a person at the hardware can settle — added by lane C

C1. **Connect.** Copy `~/.claude/settings.json` aside, open the settings, press
    Connect Claude Code…, read the confirmation, press Connect. Diff the file
    against the copy: `statusLine` is the only key that changed.
C2. **The figure arrives.** Run an interactive `claude` session and send one
    message. `claude-status.json` appears beside the hook, the settings line
    shows its time when the settings are reopened, and within one Claude
    refresh (five minutes at most) the clock shows the same weekly percentage
    that `/usage` reports.
C3. **An empty status row.** With nothing chained, the hook prints nothing. The
    documentation says an empty output blanks the row. Look at what Claude Code
    actually draws there, and confirm that `esc to interrupt` is gone, as the
    confirmation says.
C4. **Disconnect.** `statusLine` is back to what the copy from C1 holds, or
    absent if it was absent. The hook and the document are gone. The figure
    leaves the clock within its lifetime (fifteen minutes).
C5. **Launch refresh.** While connected, overwrite the hook with any text and
    relaunch the app. The hook is back to the shipped script, with mode 0700.
C6. **No keychain prompt.** From this build on, no dialog ever asks for the
    "Claude Code-credentials" keychain item.

## PixelClockTiles Phase 3b — TC002 wiring: what it leaves for the hardware

The phase-3b lane wired the TC002 adapter into the delivery chain and the app.
`UlanziTileBoard` holds what each tile's page shows (nothing ticks — the knob
belongs to the user, D1). `UlanziClockSession` pushes on events only: a
delivery, an idle mark, a removal, and one blunt recovery rule — after any
failed device call, the first successful call re-pushes every registered page
except the one whose push just ended the outage (D4). `live()` routes per
`ClockRecord.model`: the AWTRIX branch is unchanged, a TC002 record builds the
Ulanzi session over `UlanziCustody` and the durable `UserDefaultsAppRecord`
(D9), and `UlanziConnectorRunning` is the app's view of it. A connector
switched off on a TC002 marks its tile idle — paused, never deleted — and the
TC002 panel row draws no battery line: the stock firmware reads no level over
its API, the cell is there, the API does not answer it.

Two stopgaps phase 4 replaces, named so nobody mistakes them for decisions:
`NoClockHost` answers the AWTRIX-shaped app shell without wire traffic, and
`start()` keeps the device loops off a TC002. What drives the Ulanzi session
on a cadence — the sweep at startup and the per-tile deliveries — lands with
phase 4's multi-clock work, not here.

### Audit results at close

- `switchDiyApp`: no matches in `Sources/` (D3).
- `URLSession()` constructed in tests: no matches (D13). Every test drives an
  injected `Transport`.
- `Sources/PixelClockKit/Awtrix/`: byte-identical to the phase-3b base
  (`eeb87fd`).
- Test functions: 835 at the base, 879 at close. The full suite runs 795 tests
  with the anecdote-sound test skipped (796 total in the tree, that one run
  alone).
- One new unstructured `Task` spawn, the disable-edge `markIdle` in
  `AppModel.commit` — a one-shot push, not a tick.

### What only a person at the hardware can settle

1. **E9 — reboot persistence — MEASURED 2026-09-20: custom apps die with
   power.** The TC002 was power-cycled; `getBase` answered with the same
   device identity and `/api/customList` returned `{"apps":[],"count":0}` —
   the `pct-e9` marker is gone. Custom apps live in RAM, so the session's
   re-push-all on offline→online is mandatory; implemented in
   `UlanziClockSession`.
2. **`pct-` name acceptance — PASSED 2026-09-20.** `pct-` names were pushed by
   hand and appeared as DIY pages at index 100+; delete = POST with an EMPTY
   body re-confirmed live (`{}` does not delete).
3. **E4 — deleted-page effect.** With the knob parked on a page, delete that
   page's app and record what the panel shows — black, previous page, crash?
   This is what `tileRemoved` and `shutdown` expose a user to.
4. **Legibility.** The 3×5 font at scale 2 on the 52×16 panel from normal
   viewing distance: confirm `-12°` and `87%` read cleanly; adjust ink colours
   if the panel washes out.
5. **Idle marker.** Confirm the single dim dot reads as "paused" from the
   couch.
6. **`customList` exact schema — SETTLED 2026-09-20.** Live reads show
   `{"apps":[],"count":0}` when empty and the pushed app inside `apps` once
   pushed; the Task 4 decode shape matches the device.
7. **`image[]` element spelling — MEASURED 2026-09-21.** The element is an
   object: `{"data": "data:image/gif;base64,…", "position": [x, y]}` — a bare
   base64 payload, string or data URL, renders nothing on appVer 1.1.1.
   `text[]` entries turned out to be objects too (`content`, `fontHeight`,
   `x`, `y`, `color`); a string entry renders a black page. The encoder emits
   the measured spelling; see the phase-6 section at the end.

## Added by PixelClockTiles phase 4

Several clocks, one policy per tile. Every tile — including the two VPN tiles
— is held by its own `TilePolicy` (paused, then its hours, then its Focus
rule); the app-wide `FocusGate` and the quiet-hours pickers are gone. Health
is one `ClockHealth` per clock, so a clock that stops answering is counted and
looked for on its own and holds only its own tiles. Custody, battery history
and the schedule are per clock. Five migration steps moved the old app-wide
rows onto the records they belong to (`migration.weatherLocation`,
`migration.batteryHistory`, `migration.borrowedOverlay`, `migration.quietHours`,
`migration.vpnTiles`), each marker written last and each old key left in place.

What only a person at the hardware can settle:

1. **Two VPN tiles sharing a lamp.** Move Amnezia onto the top lamp, working
   in Personal only. Switching Work → Personal goes green → purple with no
   dark frame in between — the lamp handover is resolved per clock before
   anything is written.
2. **Focus naming.** With Full Disk Access on a signed build, Work and
   Personal are told apart by `com.apple.focus.work` and
   `com.apple.focus.personal`: the migrated Pritunl lamp lights in Work only.
   Every tile's Focus rule depends on this read now.
3. **Upgrade from Phase 3.** The weather place, the quiet hours (on the
   audible tiles now) and both VPN corners survive the upgrade. On the desk's
   TC002, no VPN tiles appear and no old overlay is restored.
4. **Two AWTRIX clocks, one unplugged.** The first keeps delivering on its
   own cadence, and the glyph stays online while the first clock is selected.

What later tasks owe:

- Phase 5 owes the UI named in the contact-points table: the clock switcher,
  tile rows, the Add tile menu (over `AppModel.availability(of:on:)`),
  the tile detail (over `saveTile`/`removeTile`) and the Clocks section.
- A VPN tile's recheck below 60 s needs a loop of its own; phase 4 reads it as
  the poll's minute.
- The uploaded-icon record (`UserDefaultsUploadedIconStore`, one key) does not
  say which clock an icon went to, and "Remove installed icons" acts on one
  device. With two AWTRIX clocks it needs keying per clock, like the overlay
  loan. No phase owns it yet.
- `ClaudeUsageConnector.showsNow` and `Failure.outOfFocus` were removed in
  phase 4 (lane C had already landed), so nothing is owed there.

## PixelClockTiles Phase 5 — the UI: what it leaves for the hardware

The panel learned about clocks. `MenuPanel` is assembled from its parts now —
the `ClockSwitcher` (hidden while one clock is configured), a
`ClockStatusBlock` over the SELECTED clock, one `TileRow` per tile stored on
it, the `AddTileMenu` rendering the reasons `TileCatalogue.availability`
answers with, and the last row — and the surface switch gained the detail
branch, which carries the `TileKey` it was opened for: the shared
`TilePolicyEditor` beside the tile's own block. `selectedClockId` is a stored
defaults key, remembered across launches, and the glyph's mirror re-reads the
selection the moment the selection moves, so the mark answers for the selected
clock alone (D7). The launch fallback is retired: `ClockStore.firstClock()`
keeps the first clock and invents none, the migration writes nothing on a
fresh install, and a launch with nothing stored shows "No clocks yet" with
"Add clock…" opening the Clocks section (D6). The settings sheet gained the
Clocks section where the address field was — add by address over the dual
probe, add from discovery, rename, remove — and lost the weather section,
whose place and switch live on the weather tile (D8). Tile actions are named
by tile now: pausing a TC002 tile marks its page idle and never deletes it
(D4), removing one posts the empty-body delete the knob answers to (phase-3
A9), and removal of a whole clock releases its TC002 pages through the
session's teardown.

Audit results at close: `switchDiyApp` — no matches (D3 still holds). The only
wire deletes are the two empty-body posts (`AwtrixDevice`, `UlanziDevice`);
no `{}` JSON body anywhere. Full suite green with the phase's tests counted,
zero warnings, and no commit in this phase touched `MenuPanel.swift` or
`SettingsSheet.swift` before the switch-over's own.

What only a person at the hardware can settle:

1. **Both clocks on the desk.** The switcher moves between them, each clock's
   rows are its own, and the battery line appears on the AWTRIX and never on
   the TC002 — whose status says Checking… because no `ClockHealth` exists for
   it yet.
2. **Removing a TC002 tile with the knob parked on its page.** The deleted-
   page effect (E4) is now reachable from the panel: the row's confirmation is
   the last thing in front of the empty-body POST.
3. **The policy editor against the real Focus modes.** With Full Disk Access
   on a signed build, entering and leaving Work flips the row's held-by-Focus
   badge on the tiles whose rule keeps them out of Work.
4. **The empty state and the upgrade.** A fresh defaults domain boots to "No
   clocks yet" and stores nothing; an install upgraded across the phase — the
   old `deviceHost` key present — still migrates into its one clock, marker
   written last.

What later tasks owe:

- The Clocks section's "Found on the network" list is wired but unfed: the
  model does not yet publish the merged Bonjour browse + UDP broadcast list
  the plan's architecture names. `addClock(from:)` and the
  `UlanziBroadcastListener` are ready; the publisher is the missing piece.
- The place search lost its surface with `WeatherSettings` (D8). Its home is
  beside the weather tile's own block in the detail; until it lands, the
  place is typed as a pair.
- The VPN tile's detail draws the shared policy editor but no `VPNTileBlock`:
  which VPN, which lamp, which colour have no UI surface yet. The block and
  the palette are built and tested; the wiring is what is owed.
- The due-time label left the panel with the connector row: a row carries its
  result and its hold badge, and "when" has no surface. Say so if it is
  missed.
- The panel observes ONE monitor and one browser, injected at launch; the
  status VALUES read the selected clock through the model. If battery
  staleness on a selection switch matters, the app shell owes the observed
  monitor swapping with the selection.

## PixelClockTiles Phase 6f — what the live clock answered, 2026-09-21

The envelope probe on the TC002 (appVer 1.1.1) settled the wire spellings the
phase-3b checklist carried open:

- `text[]` entries are objects — `{"content", "fontHeight", "x", "y", "color"}`
  (+ optional `align`, `valign`, `rect`, `charSpacing`). A plain string entry
  renders nothing: the page goes black. The encoder's defaults are the doc's:
  `fontHeight: 10`, `color: "#FFFFFF"`, `x`/`y` at −1000 so `align`/`valign`
  place the text.
- `image[]` entries are objects — `{"data": "data:image/gif;base64,…",
  "position": [x, y]}`. Bare base64 (string or data URL) renders nothing.
  Phase-3b checklist item 7 is closed by this.
- A GIF carries its own timing: two frames with a `DelayTime` of 5.0 each
  alternate on the panel by themselves (#27, verified live). That is the
  sanctioned time-multiplexing for one page — no Mac-side rotation — and a
  scrolling marquee is the same trick with a pre-rendered scrolling GIF, not a
  re-push loop.

What later tasks owe:

- The bundled weather art in `Sources/PixelClockKit/Resources` is 8×8
  AWTRIX-era GIFs; the TC002 weather face wants 16×16 art. The new art is owed
  before that face ships — drawn by a person, not generated in passing.

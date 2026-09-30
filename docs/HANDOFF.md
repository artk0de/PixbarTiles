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

The app is installed at `~/Applications/PixbarTiles.app` (until the first
install of the renamed build, the old `~/Applications/PixelClockTiles.app`).
Rebuild it with `./Scripts/bundle.sh debug` and it lands in
`build/PixbarTiles.app`. The package is `PixbarTiles`: the kit is
`PixbarKit`, the executable target `PixbarTilesApp`, and their tests
`PixbarKitTests` and `PixbarTilesAppTests`.

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

So the mark is the PixbarTiles brand approved on 2026-09-24
(`docs/superpowers/specs/2026-09-24-pixbar-brand-design.md`, with its two
oracle pages): a pixel P on a screen. The geometry lives in
`Sources/PixbarTilesApp/MenuBarGlyph.swift` (the glyph and the shared P) and
`AppIconArt.swift` (the icon), compiled into the app target AND into the
generator, so the shipped art and the tested geometry cannot drift apart.
Everything is generated at bundle time into git-ignored `build/`, which keeps
binary art out of the repository and makes the design reviewable as code. Run
it with `swiftc Sources/PixbarTilesApp/MenuBarGlyph.swift
Sources/PixbarTilesApp/AppIconArt.swift Scripts/MakeIcon.swift -o
build/icon-maker && build/icon-maker` and look at `build/icon/preview-*.png`.

Rules inside it:

- The app icon is the P lit in three bands (blue, white, purple) and a cyan
  open-plus sparkle on a 17 x 17 LED grid, on a near-black rounded plate. One
  master at 1024, resampled down for every other size — a grid redrawn at
  32px rounds its cell to a pixel and loses the dots. The comparison sheet
  stays in the generator's previews as the record.
- The menu bar glyph is drawn per appearance, NOT as a template — white ink
  on a dark bar, black on a light one, because a template would tint the
  offline red with the ink. The canvas is 28x18 pt (the bar caps an item's
  height, not its width); `@2x` and `@3x` come from the same vector geometry,
  rasterized as exact area per device pixel, and macOS picks by display scale.
- Online fills the case and knocks the P and a half-point bezel out of it;
  offline strokes the case, traces the P as a half-point contour and puts a
  red square in a clear moat on the corner; empty (no clock configured) is the
  stroked case alone.
- The user's old pixel-art clock (`UserClock`) no longer marks the app; it
  stays as the panel's header clock and its palettes colour the panel's
  device drawings.

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

**Also open, with no owner yet:** `public enum PixbarKit` (`AwtrixKit` before
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
python3 demo_anecdote.py              # first dialogue in today's feed
python3 demo_anecdote.py 2            # the third dialogue in today's feed
python3 demo_anecdote.py <word>       # the first anecdote containing <word>
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
    defaults write dev.artk0re.pixbartiles panelWidth -int 320
    defaults write dev.artk0re.pixbartiles historyHeight -int 280
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
codesign --force --deep --sign 6417A281BC7E103BB9B4A4EA69F831F5211A89A5 build/PixbarTiles.app
```

**Since 2026-09-23 `bundle.sh` runs this step itself** whenever the identity is
in the keychain (override the SHA-1 with `PIXBAR_SIGN_ID`; the older
`PIXELCLOCK_SIGN_ID` is still honoured), and warns when
it is not. The manual step was skipped often enough to cost: a worktree build
left ad-hoc saved the z.ai key, the key's ACL pinned that build's cdhash, and
every other build — the properly signed one included — met a keychain prompt
for `PixelClockTiles tile keys`. One "Always Allow" from a signed build repairs
an item created that way; after that the certificate carries the grant.

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
fixed. `Scripts/bundle.sh` copies `PixbarTiles_PixbarKit.bundle` into
`Contents/Resources` (not the `.app` root, which codesign refuses), and
`KitResources.bundle` reads that copy first, touching `Bundle.module` only when
there is none, which is the case under `swift test` and `swift run`. Any new
kit resource goes through `KitResources.bundle`, never `Bundle.module`
directly. Phase 3's TC002 images included.

## The rename to PixbarTiles

The bundle is `PixbarTiles.app`, its identifier `dev.artk0re.pixbartiles`; the
package is `PixbarTiles`, the kit `PixbarKit`, the executable
`PixbarTilesApp`. Four things an existing installation would lose are carried
over by the app itself, each pinned by tests:

| What | How |
| --- | --- |
| Defaults (`dev.artk0re.pixelclocktiles`) | `DefaultsCarryOver.chain`, newest first: the PixelClockTiles domain (marker `carriedOverFromPixelClockTiles`), then AwtrixConnectors (unchanged step). The PixelClockTiles domain brings its own AwtrixConnectors marker, so the oldest domain is not read twice; a user who never ran PixelClockTiles still arrives from AwtrixConnectors. Gaps only, once per step, marker last |
| `Application Support/PixelClockTiles` | `SupportFolder.carryOver()` in `AppDelegate.init()`, before `.live()` opens the secret store: renamed to `PixbarTiles` when that folder does not exist yet; both left alone when it does |
| Claude Code's `statusLine` command | `ClaudeCodeStatusLine.legacyDirectories`: a command running the hook under `PixelClockTiles` is still ours; the launch's `refreshHookIfConnected()` (and Connect) swaps its base for the new hook's and keeps the chained previous command as text |
| TC002 pages `pct-<tile>` | `UlanziCustody.legacyPagePrefixes`: the startup sweep deletes every listed `pct-` page no live tile uses, with or without a record; the tiles' next deliveries push `pbt-<tile>`. Foreign pages are untouched |

Kept under the old name on purpose:

| Where | Why |
| --- | --- |
| `EncryptedFileSecretStore.info`, `"PixelClockTiles secrets v1"` | HKDF input: a new string derives a new key and `secrets.enc` stops opening |
| `LoginKeychainStore.service`, `"PixelClockTiles tile keys"` | Where `SecretsMigration` finds the legacy keychain items |
| The `"PCTS"` magic of `secrets.enc` | File format, not a name |
| `Application Support/AwtrixConnectors/anecdotes.json` | Unchanged since the first rename |

Renamed with nothing persisted: dispatch queue labels, the log subsystem
fallback, the GitHub `User-Agent` and token name, the TC002 battery helper
(`pbt-batt`, `/tmp/pbt-req`, `/tmp/pbt-out`; the device's `/tmp` is RAM, so
old `pct-*` helper files go at its next reboot). AWTRIX needs nothing: its app
names carry no prefix and live in RAM.

**Paid once by the user**, because TCC and login items are bound to the bundle
id: location, notifications, Focus and Local Network are asked for again (Full
Disk Access, if granted, is re-added by hand for `PixbarTiles.app`); "Open at
login" is turned on again from the settings. Quit and remove
`~/Applications/PixelClockTiles.app` once the new build runs — it retires its
login item, and two apps pushing to one clock would fight over its pages.

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
`statusLine` to `/bin/sh '<Application Support>/PixbarTiles/claude-statusline.sh'`,
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
- `Sources/PixbarKit/Awtrix/`: byte-identical to the phase-3b base
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
- The GIF the panel plays must carry **full frames**. ImageIO's writer crops
  each frame to the changed region and relies on the decoder holding the
  previous frame; the stock decoder paints those sub-rects over the
  accumulated picture instead, and crossing marquees smear within seconds.
  A hand-assembled full-frame GIF89a (one global palette, no local tables)
  renders pixel-stable. The demo kit that proved it lives in `Scripts/`:
  `MakeTimedGif.py` — byte-level GIF89a writer, own LZW, stdlib-only, ALSO
  decodes the animated icon; validated pixel-exact against ImageIO (44/44
  frames) — plus `font5x7-cyrillic.bdf`, the X11 Fixed 5×7 (Sony,
  ISO10646-1) trimmed to ASCII + Cyrillic, its «Т» patched symmetric. The
  panel-confirmed layout: 5×7 glyphs at a 6 px advance, two text bands
  (rows 0–6 and 9–15), an 8 px icon column, marquee rows clipped at x ≥ 8.
  Vector-font-to-grid rasterization is dead — the user rejected it twice.
- `switchDiyApp` answers POST only; GET is 404. Upsert is
  `POST /api/custom?name=<name>` with the envelope as the body; the list read
  is `GET /api/customList`. — **measured** 2026-09-21

What later tasks owe:

- The bundled weather art in `Sources/PixbarKit/Resources` is 8×8
  AWTRIX-era GIFs; the TC002 weather face wants 16×16 art. The new art is owed
  before that face ships — drawn by a person, not generated in passing.
- The TC002 banner face (anecdotes, z.ai rows) builds on the full-frame
  writer and the vendored 5×7 font from `Scripts/` — the pipeline the panel
  accepted live on 2026-09-21. Porting it into the kit means: BDF parse →
  RGB canvas → the same full-frame GIF assembly; keep the ImageIO
  pixel-exact check as the test oracle.

## The modern UI redesign — what it leaves, 2026-09-21

The spec `docs/superpowers/specs/2026-09-21-pixelclocktiles-modern-ui-design.md`,
phases 1–5, landed in one working pass. The panel is grouped now: every clock a
section under its own status dot — green while its last push was delivered,
yellow while it is reachable with nothing yet delivered or a push in flight,
red when it is unreachable or its last push failed — and its own gear (add,
reorder, settings), each item aimed at ITS clock. The projection the panel
draws is `PanelModel`, the first of the facades: `@Observable` types that read
`AppModel` and hold what only presentation knows. `SettingsModel` (which tab,
which clock the Clocks tab names), `TileSettingsModel` (the draft, the debounced
off-main render) and `StoreModel` (the shelves, the cards) followed, and the
model's own panel sections, menu-item builders and settings-open bookkeeping
were deleted as each facade took them — never left beside them.

The surfaces moved out of the panel into the app's own windows. Settings is a
real Settings scene now — Clocks (add/rename/remove/reorder, the discovery
list), Defaults (the new-tile interval), General (microphone gate, the FDI
sentence, login item, icon removal) — opened with the system action. The tile's
detail is a `Window(id:)` whose content swaps as rows ask: the policy editor
beside the tile's own block on the left, the live preview on the right. The
store is a third window: categories on the sidebar, cards on the grid, each
card saying in one glance whether the clock it is aimed at can take the tile —
`.notListed` draws as a disabled "Added" card rather than a hole, because a
grid with gaps reads as a bug — and a successful add opens the tile's settings
on it (the two-step commit: a tile is never added and forgotten). What the
menu deleted the window keeps.

Two infrastructure pieces landed with the surfaces. `FullFrameGif` is the
Scripts/ Python writer ported into the kit — full-frame GIF89a, own LZW,
Poskanzer growth — byte-identical to `MakeTimedGif.py`'s output, with ImageIO
as the decode oracle; it is why the preview can promise the same settings give
the same bytes. `WeatherTileConfig` grew the settings the Better Weather
controls flip — scale, humidity, felt temperature, each wired through to the
canvas and the TC002 face, whose temperature now names its scale (`-12°C`) and
rides the small band when the tile asks for humidity or feels. Records written
before the settings existed decode as the shipped defaults; nothing rewrites
them.

Removed by design, so nobody "restores" them: the battery line left the panel
(battery stays on the Clocks tab's rows), the ClockSwitcher and the panel's
ClockStatusBlock are gone with the grouped panel, the AddTileMenu and the
settings sheet are gone with the windows, and `AppModel` holds no panel
projection anymore.

What later tasks owe:

- The Defaults tab carries the new-tile interval and nothing else. A
  brightness or quiet-hours policy belongs there, but none was invented in
  passing — the tab waits for the policy to be designed.
- The discovery status line's next home is the Clocks tab; it has no surface
  on the grouped panel.
- The BDF 5×7 font (ASCII + Cyrillic) is still a Scripts/ artifact. The
  canvas's `drawText` speaks its own built-in face; porting the BDF parser is
  the door to Cyrillic on the TC002, and the full-frame GIF assembly it needs
  is already in the kit.
- The GIF carries one delay per FILE (`FullFrameGif.encode(frames:delay:)`).
  Per-frame delays (a marquee that scrolls and then dwells) are a signature
  widening away, wanted the day a tile needs it.

Measured at close: 1542 tests (587 app + 955 kit), serial run green to the
last, zero build warnings. The app bundle's waitUntil budget (5 s) is
sensitive to Swift Testing's parallel workers when the machine is loaded — a
full parallel run can time out a wave of network-shaped tests (the two
UlanziClockSlot upsert pins were the first known specimens; under load the wave
widens). A serial run — `swift test --no-parallel` — is the arbiter: green
throughout. tea-rags has the project indexed (alias `pixelclocktiles`, 4783
chunks; Swift support arrived with the tool) — reached through the `tea-rags`
CLI, since the MCP server is not attached to this repo's sessions.

### The first run's corrections, same day

The launch against the real desktop caught three things the suite could not:

- **The detail window opened itself.** The panel carried an opener whose
  `.onAppear` called `openWindow` — and a `MenuBarExtra` panel's content
  appears EVERY open, so while a tile's key stood set, opening the menu bar
  yanked the key off the panel onto the settings window, the panel resigned
  and closed itself, and the settings window kept fronting over everything.
  To the hand it read as "windows do not click, do not close". The opener is
  gone; the ⋯ row button opens the window at the click (`onOpenDetailWindow`,
  a view question the facade cannot answer), and the store's add already did.
- **Liquid Glass was missing.** `.glassEffect` is scene-layer material: the
  panel takes it from the `MenuBarExtra` content in `App.swift`, the store
  sidebar on its own column. The view stays content, drawable in tests
  without the glass — a pixel pin that includes the material flattens to
  uniform noise under offscreen `cacheDisplay` and the dot test fails on the
  equality it exists to make.
- **The preview is every tile's.** Requirement 6 said so and the first pass
  shipped weather only. `PixelCanvas` now carries its own dimensions (the
  statics keep spelling the 52×16 TC002 panel), `FullFrameGif` encodes at the
  first frame's size, `PixelCanvas.apply(_:)` paints the TC002 draw
  vocabulary, and `AwtrixScene.canvas()` draws the AWTRIX panel's 32×16 —
  words centred in the kit's font (the BDF port widens the glyph set later),
  the scene's colour, the progress bar over the bottom band. The weather
  keeps answering its draft; every other tile renders its own face.

The quit button read as broken for the same family of reasons: against a
clock that cannot answer, the budget spends up to fifteen seconds on the
held banner's dismiss with the panel showing an unchanged Quit button. The
row now says `Quitting…` for exactly that stretch — the wait itself is
measured design (see QuitBudget), the silence was the defect.

### The corrected requirements, same evening

The first live session produced a set of corrections that redrew the panel
and added a surface. All are the user's calls, made against the running app:

- **The panel is statistics only.** No tile rows: the panel answers "what are
  my clocks doing" — the dot, the connection in words, the battery beside it
  (`Connected · 🔋 77%`), per clock, and nothing else. A TC002 draws the
  connection alone, which is the truth about a clock with no cell. The spec's
  requirement 1 and the panel section were rewritten to match.
- **The clock's gear opens the clock's own window** (`Clock Settings`,
  `id: "clock-settings"`, re-aimed like every other window): a Tiles tab
  laying the clock's tiles out as a GRID of cards — mark, name, last result,
  settings / move earlier–later / remove, and a dashed Add card at the end —
  and a General tab that names the clock and says its model, address and
  status. The grid reuses `TileRowLine` for its result line, so the
  thrown-error wording pin moved with it; `TileRow`/`TileRowValue` are
  deleted outright, and `TileRowIcon` moved to `TileRowLine.swift`.
- **Every window opened from the panel is activated**: `openAndFocus` wraps
  each `openWindow`/`openSettings` call with `NSApp.activate()`, because an
  accessory app's window opens without the key otherwise and sat behind the
  user's attention. This was the "focus does not move to the opened window"
  report.
- **The store's cards carry previews**: the connector's own face rendered
  once per connector per session (`StoreModel.previews`), shown at 3×
  nearest-neighbour over black. The render spends one reading — the same
  reading the tile's first delivery would have spent; the anecdotes pop what
  they pop and restock behind it.
- **"Weather" is "Better Weather"** — the connector's `displayName`, the
  spec's own name, everywhere a surface says it.
- **Nothing clips**: the Settings window is a floor (`minWidth`/`minHeight`)
  with scrolling tabs, not a fixed box; the store window is resizable too.
  The Clocks tab's rows carry explicit up/down chevrons beside the drag.
- **A render that cannot happen says why**: the tile-settings preview grew
  `previewNote` — "The sky could not be read…", "This connector draws no
  face for a TC002." — instead of a blank a reader reads as breakage.

On Liquid Glass, measured: the machine runs dark appearance, and Apple's dark
glass is dense — the panel's `glassEffect` renders as a dark rounded slab
whose translucency is easy to miss. The material is in (panel, store
sidebar); what carries the modern look in dark mode is the structure — grids,
cards, segmented tabs, a scrolling settings window. A light-appearance launch
shows the glass unmistakably.

### The second live pass, same evening

- **Gear opens the window, not a menu.** The per-clock gear's context menu
  asked a question the click had already answered; the gear is a button now.
- **Liquid Glass, the recipe that actually renders.** `glassEffect` behind
  an opaque window background refracts nothing — it drew a dark slab. Every
  window now clears its own background through a `WindowBackgroundClearer`
  view (`.glassWindow(cornerRadius:)`), and the panel's window is cleared
  by `panelMoved` the moment the reader hands it over. Measured with a
  standalone probe before wiring: clear window + glass effect is the pair
  that renders. Dark appearance keeps the material dense; light shows it
  fully.
- **Store previews removed.** The preview belongs to the tile settings —
  before adding, the store card says what the tile IS (mark, name, blurb,
  availability), not what it draws. The black thumbnails read as broken
  screenshots and are gone with the code that drew them.
- **The clock's tiles stack vertically**, full-width, the whole card a door
  to the tile's settings; drag & drop between cards moves a tile (the key
  rides a `dragPayload` string, round-trip pinned), chevrons stay for the
  hand that wants buttons.
- **The battery survives an outage**: the panel says the last KNOWN charge
  (`DeviceMonitor.lastKnownBattery`) — a figure that vanished every time the
  Wi-Fi blipped was a figure nobody planned around. A clock that never
  answered still says nothing, and the status line says "last push failed"
  beside a red dot instead of a bare "Connected" that contradicted it.
- **Already-configured clocks stay out of "Found on the network"** — the
  address is the identity both sides speak.
- **The Clocks tab is a `Form`** — grouped sections, the platform's own
  settings idiom — and every tab reads from the top.

### The third live pass, same evening

- **Drag to reorder the clock's tiles is `List.onMove`.** Two gesture
  reimplementations (`.draggable` payloads, then `onDrag` providers) lost
  the drag to the buttons living on the card; the platform's own move drag
  does not. The rows still draw the colour cards; the chrome is stripped.
- **The status dot is the CONNECTION only.** Red = unreachable. A failed
  push belongs to the failed TILE: its card wears the red
  `exclamationmark.triangle.fill`, the words on hover (`.help`), and the
  card's line reads failures through `TileRowLine.failureWords` — no
  NSError dictionaries on the glass. The panel's words come off the same
  table the dot reads, so they cannot disagree again.
- **The battery is drawn, not emoji'd** — SF battery symbols by charge,
  bolt for charging, hourglass while the trend is unestablished —
  percentage and ETA unchanged, urgency colours unchanged, and the LAST
  KNOWN charge survives an outage (`DeviceMonitor.lastKnownBattery`).
- **A removed tile's settings wait for its return**: `removeTile` stashes
  the config in defaults, `addTile` restores it when the same connector
  returns to the same clock. Reset-to-defaults sits beside Save settings in
  the tile's Tile tab (the place is kept; it is where the clock stands).
- **Windows are chromeless glass**: `hiddenTitleBar` everywhere, traffic
  lights over the content, the content keeping clear of their corner.
- **Already-configured clocks stay out of "Found on the network"**, the
  Settings tabs read from the top, the general Settings surface is a
  labelled button in the panel's corner (a third gear was one too many).

## The shared TC002 usage face, and why every TC002 page was black — 2026-09-23

**`db` was the black page.** `UlanziDraw.bitmap` encoded `{"db": [w, h, p0,
p1, …]}` and a comment called that spelling "pinned against a real exchange".
It never was. Measured on the TC002 (appVer 1.1.1) on 2026-09-23 by pushing
the same 52×16 frame both ways: the flat spelling is answered
`{"code":200,"message":"ok"}` and draws a black page; `{"db": [x, y, w, h,
[p0, p1, …]]}` — position first, the pixels a NESTED array — renders. Every
TC002 face that shipped through the encoder (the weather's, the old usage
rows) was black on the panel for that reason alone. The encoder now writes the
measured spelling and encodes the `at` point it used to drop. A 200 from this
clock proves nothing about the pixels; `Sources/PixbarKit/Ulanzi/CLAUDE.md`
carries that rule for whoever edits the adapter next.

**The usage face.** Claude and z.ai share one TC002 face, `UsageFace`
(`Sources/PixbarKit/Usage/`): the vendor's mark in the corner, a session
row (`s`, the five-hour window) and a weekly row (`w`), each a figure over a
one-pixel bar in the shared `UsageBand` colours — each vendor below 80 % in its
own brand colour, the three warnings common to both. It replaces the
three-row `UsageRows` face on both connectors; `UsageRows` is deleted. The
AWTRIX pages are untouched. The design was approved in the browser and on the
clock through the `tc002-face-mockup` skill, and its `gen.py` is the pixel
oracle: `Scripts/make_usage_face_oracle.py` records gen.py's timelines for
fourteen cases (steady, one row hot, both hot, spent past 100 %, 0 % and 3 %,
no data, partial data, the threshold at 60/70/80/100) into
`Tests/PixbarKitTests/Fixtures/usage_face_oracle.json`, and
`UsageFaceOracleTests` holds the Swift face to it frame for frame and delay for
delay. A design change starts in gen.py, then the fixture, then Swift — never
the fixture by hand.

The page is one timeline the panel plays by itself — one full-frame GIF at the
origin (§6f's `image[]` envelope), each frame with its own delay, which is why
`FullFrameGif` grew `encode(frames:delays:)` (the one-delay spelling is that
with the figure repeated, byte-identical). Frame A, the percentages, stands for
the tile's **Show reset every**; a row at or past **Show reset after** flips to
its reset — the session's `rst 14:30` still, five seconds when it is the only
flip; the week's `rst 1 oct 09:00` an edge marquee through its value area, a
second at the left edge, 100 ms a pixel, a second and a half at the tail. Reset
times are instants formatted in `TimeZone.current` at draw time — z.ai's
`nextResetTime` is epoch milliseconds and stays absolute; nothing is ever said
in Asia/Shanghai's hour. The glyphs are gen.py's own five-row proportional
table, `PixelFont.proportional`; `PixelFontFace` learnt per-glyph widths, and
the fixed faces measure and draw exactly as before.

The two settings live on both tiles' records (`UsageFaceConfig`, fields
`showResetEvery` / `showResetAfter`; 5 s–5 min, default 10 s; 50–100 % in
fives, default 80 %). While they are the defaults the configs write exactly
what they wrote before — the Claude tile its bare metric word, the z.ai tile
its bare key handle — so records from before the settings decode as the
defaults and nothing rewrites them. The pickers sit under the Claude and z.ai
blocks in the tile's window; the metric picker and a pasted key keep them. The
connectors read them off the record at every draw. The TC002 preview of a page
that ships as one GIF is that GIF's own bytes, and `PixelPreview` now holds
each frame for its own delay.

Where the Swift face departs from gen.py, deliberately:

- A row past the threshold whose source dated no reset does not flip — gen.py
  never meets a hot row without a reset string, and inventing one is worse.
- `PixelFont.proportional` carries a `?` (the tiny face's) that gen.py does
  not: the substitute rule needs a shape to draw. The face never spells one.
- The envelope's `duration` stays the kit's constant 5; the demo pushed 10.

What only a person at the hardware can settle:

1. **The weather face, un-blackened.** With the `db` fix, the TC002 weather
   page should draw. Nobody has looked at it through the app yet.
2. **The usage face through the app.** The oracle proves the Swift frames
   equal gen.py's; gen.py's frames were approved live via `tc002_demo.py`,
   not via this app's push. Confirm the app's page on the panel matches the
   demo — in particular that the per-frame delays (10 s, 5 s, 1 s, 100 ms,
   1.5 s) play as timed, and that a five-minute first frame (30 000
   centiseconds) is honoured.
3. **A pasted z.ai key and the settings.** Tune the z.ai tile, then paste a
   key; the pickers keep their values.

What later tasks owe:

- `Sources/PixbarKit/Ulanzi/CLAUDE.md` and the `.claude/skills/tc002-face-mockup/`
  skill (gen.py, template.html, tc002_demo.py, SKILL.md) were left untracked in
  this worktree — they are the oracle's source and the adapter's navigator,
  and belong in the repository. Until the CLAUDE.md is tracked or excluded,
  SwiftPM warns about one unhandled file in the kit target.
- `UlanziHandoffTests` read one heap byte past its payload and failed in a full
  serial run whenever the allocator handed back a dirty block; the test buffer
  is zeroed now. The parallel-run timeouts in `UlanziClockSlotTests` named in
  the redesign section are unchanged — `swift test --no-parallel` stays the
  arbiter.

Measured at close: 1622 tests (613 app + 1009 kit), serial run green; 1587
(603 + 984) at the base, `1b068f4`.

## The TC002 weather face — 2026-09-23

Spec: `docs/superpowers/specs/2026-09-23-tc002-weather-face-design.md`.
Plan: `docs/superpowers/plans/2026-09-23-tc002-weather-face.md`.

The TC002 weather page is no longer a still raster. `WeatherFace`
(`Sources/PixbarKit/Weather/`) draws a 16×16 animated icon (46 approved
animations plus `nodata`), the temperature in the 5×9 digits, and a rotating
detail line — feels-like, humidity, wind, hi/lo, rain chance, UV,
sunrise/sunset, an hourly chart — in one of three layouts: **Anchor** (two
GIFs, the icon looping on its own beside a fixed temperature), **Pages** and
**Hybrid** (one 52×16 GIF each, because there the icon changes with the text).
Why the deliveries differ, and the measured GIF ceilings behind them, are
stated once in `Sources/PixbarKit/Ulanzi/CLAUDE.md`; `UlanziScene` now
enforces 480 frames / 136 000 bytes of base64.

The pixels come from the `tc002-face-mockup` skill's `weather/wgen.py` and
`weather/icons.py`. `Scripts/make_weather_face_oracle.py` records them into
`Tests/PixbarKitTests/Fixtures/weather_icons_oracle.json` and
`weather_face_oracle.json`, and the Swift face is tested against those
fixtures pixel for pixel and delay for delay. A design change starts in the
Python, then the fixtures are re-recorded, then Swift changes. The skill's
SKILL.md has the demo flags.

The tile's settings (`WeatherTileConfig`: layout, change interval, wind unit,
feels-like colour, one switch per detail line) decode from records written
before them as the shipped defaults. The tile window has a control for each,
and its TC002 preview plays `WeatherFace.preview` at the face's own frame
delays. `WeatherConnector.canvas(for:config:)`, the old still raster, has no
caller left in the app; only the tests that pin its raster still use it.

What only a person at the hardware can settle: Anchor, Pages and Hybrid on a
live reading, °F, and the no-data face (the place field emptied or the
network off), pushed by the app rather than by `weather_demo.py`.

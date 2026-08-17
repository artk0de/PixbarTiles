# Handoff — 2026-08-17

Everything needed to resume this project without the conversation that produced
it. Read this, the spec, and the SDD ledger; the rest is in git.

- Spec: `docs/superpowers/specs/2026-08-17-awtrix-connectors-design.md`
- Plan: `docs/superpowers/plans/2026-08-17-awtrix-connectors.md` (16 tasks)
- Ledger: `.superpowers/sdd/2026-08-17-awtrix-connectors/progress.md` (git-ignored,
  local only — every ruling and deferred finding lives there)

## What this is

A native macOS menu bar app that runs pluggable connectors and pushes their
output to a Ulanzi TC001 clock running AWTRIX 3. The first connector reads the
day's popular anecdotes, voices them with cloned game-character voices, and
shows them on the clock on a user-set interval.

## State

Branch `feat/menu-bar-app`, nothing merged, nothing pushed.

| Tasks 1-7 | complete, reviewed |
| Task 8 | implemented (`a14e4ba`), review was in flight at handoff |
| Tasks 9-16 | planned, not started |

`swift test` passes 82 tests with zero warnings.

## Hardware, measured not assumed

Device at `192.168.1.72`, AWTRIX 0.98, `type: 0` (stock TC001). Found by mDNS:
it advertises `_http._tcp` as `awtrix_a07f9c`, and `awtrix.local` does NOT
resolve — the instance name is not a hostname.

- The buzzer plays RTTTL only. An uploaded `.mp3` sits on the flash and never
  reaches the sound path: `/api/sound` answers 404 for a name backed by `.mp3`
  and 200 for the same name once a `.txt` exists. Speech therefore plays on the
  Mac, never on the clock.
- The font renders Cyrillic. Confirmed by reading the matrix buffer back.
- `/api/screen` returns 256 packed `0xRRGGBB` values, so what the clock shows can
  be rendered and inspected rather than trusted.
- The LaMetric icon search endpoint needs ALL five query parameters
  (`page`, `category`, `search`, `count`, `guest_icons`); omitting one returns a
  framework error page that reads like a block. The CDN serves any icon by id
  with no auth.
- The catalogue's "animated" flag is unreliable — it marks single-frame icons
  animated. Count frames instead. The chosen laughing icon is `66558`, 55 frames.

## Voices

Five, all Russian, at `~/.local/share/tts-voices/voices/`. Median F0 in brackets:
`acolyte` (92 Hz), `arthas` (134), `peon` (262), `crystal` (296), `batrak` (329).
`crystal` is the only female voice and the only one not from Warcraft — there is
no Russian female pack in the peon-ping registry, so she comes from the Dota 2
Russian wiki.

Two traps when building a reference, both paid for once already:

1. **Do not pick clips by length.** It selects for declamation: the three most
   steeply falling contours in the Arthas pack all landed in his reference and
   every rising, question-like line was excluded, so the clone read questions
   with a falling pitch. Measure each clip's contour and keep a mix.
2. **Normalise every clip to one format before concatenating.** Packs are not
   internally consistent. ffmpeg's concat demuxer applies the first file's
   parameters to the rest; one reference came out 59% too long with its pitch
   dragged from 211 Hz to 108 Hz, and looked like a valid file. The F0 number is
   what exposed it.

## Speech

Synthesis is stock XTTS-v2 through `~/.local/share/tts-voices/speak.py`, driven
as a long-lived `--serve` process speaking JSON Lines. **Do not modify that
script** — Swift code is written against its contract.

Loading the model is the entire cost of synthesis: a cold demo run takes 70
seconds, a fully cached one 0.28 s of CPU. That single measurement is why the
connector never synthesizes on demand and a preparer fills a queue in batches.

The spec holds the full findings: the four text-normalisation rules and the
defect each one fixes, why stress marking is impossible (the marks are absent
from the XTTS vocabulary and encode to `[UNK]`), and why F5-TTS, VibeVoice,
cross-lingual cloning and the Russian fine-tuned checkpoints were all rejected.
Read that section before proposing a TTS change; every one of those was tested.

## Requirements settled with the user during the session

- Anecdotes must not repeat. Played `<guid>`s persist; when the primary feed is
  exhausted the source widens (`export_top` → `export_bestday` → `export_j`)
  rather than resetting.
- The clock shows a short `ВНИМАНИЕ, АНЕКДОТ!` banner, held until the speech
  ends — not the joke, which is heard rather than read.
- The announcement is spoken, not merely scrolled.
- Each audio clip carries its own `leadIn`, so the connector sets the rhythm and
  the player never learns what a punchline is.
- The laugh scales with the joke's length; short jokes draw at random from three
  variants.
- Marked speakers (`О: - привет`) should be recognised so a dialogue can carry
  more than two actors, and a female line — detectable from Russian past-tense
  verb endings — should use the female voice.

## Not yet planned

The marked-speaker rule and female-voice selection have no task. They extend
Tasks 5 and 6, which are already closed, so they need a new task written.

The detection rule was designed and validated against the live corpus but not
implemented. Two forms count: `<label>: <dash> <text>` always, and
`<label>: <text>` only when the same anecdote carries two or more distinct
labels. The paired requirement is what rejects ordinary prose — `Идея для
свидания:` and `Верховный суд РФ:` both appear in the real feed and would
otherwise be read as speaker names. Zero false positives on the measured corpus.

## Running the demonstration

The Python prototype does end to end what the Swift app will do, against the
real device:

```bash
cd ~/Dev/Personal/awtrix-connectors/prototype
python3 demo_anecdote.py колобок      # a pinned anecdote, always available
python3 demo_anecdote.py              # first dialogue in today's feed
python3 demo_anecdote.py вертолёт     # the other pinned one
```

Clips are cached by voice and text under `prototype/cache/`, so a repeat never
starts the synthesis model at all.

## Deferred findings

The ledger carries roughly thirty deferred minor findings from the task reviews,
each with the reason it was deferred. The final whole-branch review is supposed
to triage them. Two are worth knowing early because they affect work not yet
done:

- Task 8's sidecar process is never terminated on teardown, and `synthesize`
  blocks a cooperative-pool thread for the duration of a batch.
- Empty host and a pasted `http://10.0.0.5` both parse, skip `.invalidHost`, and
  the second aims the request at a host literally named `http`. Input
  normalisation belongs in Task 14, where the address becomes user-typable.

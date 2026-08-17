#!/usr/bin/env python3
"""End-to-end demonstration of the anecdote connector, before the app exists.

Fetches a real anecdote from the vote-ranked feed, splits it into speaker turns,
voices each turn with a cloned character voice, then plays the audio on this Mac
while the clock scrolls the text behind a laughing icon and a Nokia jingle.

This mirrors what AnecdoteConnector will do in Swift. It is a demonstration, not
the product.
"""

from __future__ import annotations

import hashlib
import html
import json
import os
import random
import re
import subprocess
import sys
import time
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from awtrix import AwtrixClient  # noqa: E402
from awtrix import lametric  # noqa: E402

DEVICE = "192.168.1.72"
FEED = "https://www.anekdot.ru/rss/export_top.xml"
TTS_DIR = "/Users/artk0re/.local/share/tts-voices"
PYTHON = f"{TTS_DIR}/.venv/bin/python"
CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "cache")

# A grinning open-mouthed face that cycles colour across 55 frames. Chosen by
# counting frames, not by trusting the catalogue: its `type` field marks icons
# animated that turn out to be a single frame (9612), and the previous pick
# (9039) had only two.
LAUGH_ICON = 66558
NOKIA = "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"
BANNER = "ВНИМАНИЕ, АНЕКДОТ!"
ANNOUNCEMENT = "Внимание! Анекдот!"

# Short anecdotes get one of these, picked at random so a run of quick jokes
# does not laugh identically every time.
SHORT_LAUGHS = ["АХАХАХА", "АХАХАХАХА", "АХАХАХАХАХ ХАХА"]
SHORT_JOKE_WORDS = 12
MAX_HA = 14

# Silence before a clip, in seconds. The producer sets the pacing; the player
# just obeys. The beat before the laughter is a punchline pause, not a separator.
LEAD_ANNOUNCEMENT = 0.0
LEAD_FIRST_LINE = 0.7
LEAD_BETWEEN_LINES = 0.25
LEAD_LAUGHTER = 0.7

# Anecdotes worth replaying on demand. The feed rotates, so a search argument
# that stops matching falls back to these instead of failing.
PINNED = {
    "колобок": (
        "pinned:kolobok",
        "- Сеть быстрого питания «Вкусно — и точка» открыла кафе прямо в библиотеке"
        " - Теперь книги будут читать с кетчупом?",
    ),
    "вертолёт": (
        "pinned:helicopter",
        "— Ты спишь?\n— Неее, я просто закрыла глаза и слушаю дождь...\n"
        "— Но дождя нет!!!\n— Я его слушаю по памяти.",
    ),
}

DASHES = "-—–"
ENTITIES = [("&quot;", '"'), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&amp;", "&")]


QUOTES = "«»“”„‟\"‘’`´"


def speech_text(line: str) -> str:
    """Prepare one line for the synthesizer. Every rule here was settled by ear.

    - Quotation marks are removed. XTTS vocalises them: `точка»` came out as
      "точкала", the closing quote becoming a syllable of the word.
    - A dash between spaces is dropped rather than kept or turned into a comma.
      Kept, it produced a pause long enough to sound like a fault.
    - A trailing full stop is removed. It provoked the decoder into appending an
      audible fragment after the sentence — a spurious "по" separated from the
      real speech by true silence. Raising the repetition penalty did not fix
      that; deleting the full stop did.
    - A trailing `?` or `!` is KEPT, because it carries the intonation, and a
      space is added after it. Without the space the final consonant was
      swallowed: "Анекдот!" lost its Т.
    """
    text = "".join(" " if ch in QUOTES else ch for ch in line)
    text = re.sub(r"\s+[—–]\s+", " ", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s+([,.!?;:…])", r"\1", text).strip()

    if text.endswith("."):
        return text.rstrip(".").rstrip()
    if text and text[-1] in "?!":
        return text + " "
    return text


def laughter_for(text: str) -> str:
    """The longer the anecdote, the longer the laugh.

    A one-liner does not earn a fifteen-syllable cackle, and a long build-up
    deserves more than three. Short jokes draw from a small set at random so
    consecutive quick ones do not laugh identically.
    """
    words = len(text.split())
    if words <= SHORT_JOKE_WORDS:
        return random.choice(SHORT_LAUGHS)

    repeats = min(4 + words // 8, MAX_HA)
    # Past a certain length the laugh needs somewhere to breathe.
    if repeats >= 9:
        head = repeats - 3
        return "А" + "ХА" * head + " " + "ХА" * 3
    return "А" + "ХА" * repeats


def rtttl_duration(melody: str) -> float:
    """Total play time of an RTTTL string, in seconds.

    Computed rather than guessed so the speech lands the moment the jingle ends,
    and keeps landing there if the jingle is ever changed.
    """
    _, defaults, notes = melody.split(":", 2)
    spec = dict(part.split("=") for part in defaults.split(","))
    default_len = int(spec.get("d", 4))
    bpm = int(spec.get("b", 63))
    whole = 4 * (60.0 / bpm)

    total = 0.0
    for note in notes.split(","):
        note = note.strip()
        if not note:
            continue
        digits = re.match(r"^\d+", note)
        length = int(digits.group()) if digits else default_len
        seconds = whole / length
        if "." in note:  # dotted note is half again as long
            seconds *= 1.5
        total += seconds
    return total


def fetch_anecdotes() -> list[tuple[str, str]]:
    req = urllib.request.Request(FEED, headers={"User-Agent": "Mozilla/5.0"})
    raw = urllib.request.urlopen(req, timeout=20).read().decode("utf-8", "replace")
    out = []
    for item in re.findall(r"<item>(.*?)</item>", raw, re.S):
        guid = re.search(r"<guid>(.*?)</guid>", item, re.S)
        desc = re.search(r"<description>(?:<!\[CDATA\[)?(.*?)(?:\]\]>)?</description>", item, re.S)
        if not (guid and desc):
            continue
        text = re.sub(r"<br\s*/?>", "\n", desc.group(1), flags=re.I)
        for entity, char in ENTITIES:
            text = text.replace(entity, char)
        lines = [l.strip() for l in text.split("\n")]
        text = "\n".join(l for l in lines if l)
        if text:
            out.append((guid.group(1), text))
    return out


def parse_turns(text: str) -> list[tuple[str, str]]:
    """(speaker, line) where speaker is 'narrator' or 'actor0'/'actor1'."""
    turns, next_actor = [], 0
    for line in (l.strip() for l in text.split("\n")):
        if not line:
            continue
        if line[0] in DASHES:
            body = line[1:].strip()
            if not body:
                continue
            turns.append((f"actor{next_actor}", body))
            next_actor = (next_actor + 1) % 2
        else:
            turns.append(("narrator", line))
    return turns


def cast(turns: list[tuple[str, str]], pool: list[str]) -> list[tuple[str, str]]:
    assigned, cursor, out = {}, 0, []
    for speaker, line in turns:
        if speaker == "narrator":
            out.append((pool[0], line))
            continue
        if speaker not in assigned:
            assigned[speaker] = pool[cursor % len(pool)]
            cursor += 1
        out.append((assigned[speaker], line))
    return out


def cache_path(voice: str, line: str) -> str:
    key = hashlib.sha1(f"{voice}|{line}".encode()).hexdigest()[:16]
    return os.path.join(CACHE_DIR, f"{voice}-{key}.wav")


def synthesize(voiced: list[tuple[str, str]]) -> list[str]:
    """Return one audio file per turn, synthesizing only what is not cached.

    Loading the XTTS model costs most of a run — minutes, against seconds for the
    synthesis itself. Caching by voice and text means a repeat of the same
    anecdote never starts the sidecar at all.
    """
    os.makedirs(CACHE_DIR, exist_ok=True)
    # The synthesizer gets normalized text; the clock and the log keep the
    # original. Normalization is part of the cache key, so changing a rule
    # invalidates the clips it affected.
    spoken = [(voice, speech_text(line)) for voice, line in voiced]
    files = [cache_path(voice, line) for voice, line in spoken]
    missing = [i for i, path in enumerate(files) if not os.path.exists(path)]

    if not missing:
        print("   all clips cached — the synthesis model is not loaded at all")
        return files

    print(f"   {len(files) - len(missing)} cached, {len(missing)} to synthesize"
          f" (loading the model takes a while on a cold run)")
    proc = subprocess.Popen(
        [PYTHON, "speak.py", "--serve"],
        cwd=TTS_DIR, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    try:
        for index in missing:
            voice, line = spoken[index]
            proc.stdin.write(
                json.dumps({"voice": voice, "text": line, "out": files[index]}) + "\n"
            )
            proc.stdin.flush()
            reply = json.loads(proc.stdout.readline())
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error", "synthesis failed"))
            print(f"   voiced [{voice:8}] {reply['duration']:5.2f}s  {line[:56]}")
    finally:
        proc.stdin.close()
        proc.wait(timeout=60)
    return files


def main() -> None:
    print("=== fetching the vote-ranked feed ===")
    anecdotes = fetch_anecdotes()
    dialogues = [(g, t) for g, t in anecdotes
                 if sum(1 for l in t.split("\n") if l[:1] in DASHES) >= 2]
    print(f"{len(anecdotes)} anecdotes, {len(dialogues)} with dialogue")

    # An argument selects one anecdote: a number is an index into the dialogue
    # list, anything else is matched against the text. Matching by content
    # survives the feed reordering, which an index does not.
    choice = sys.argv[1] if len(sys.argv) > 1 else None
    if choice is None:
        guid, text = dialogues[0]
    elif choice.isdigit():
        guid, text = dialogues[int(choice)]
    else:
        # A pinned name wins over a feed search: it was curated on purpose, and
        # the same word can match something else in today's feed.
        needle = choice.lower()
        found = [(g, t) for g, t in anecdotes if needle in t.lower()]
        if needle in PINNED:
            guid, text = PINNED[needle]
        elif found:
            guid, text = found[0]
        else:
            print(f"nothing in the feed or the pinned set matches {choice!r}")
            print(f"pinned: {', '.join(PINNED)}")
            print("dialogues in today's feed:")
            for index, (_, t) in enumerate(dialogues):
                print(f"  {index}: {t.splitlines()[0][:70]}")
            raise SystemExit(1)
    print(f"\n=== chosen {guid} ===")
    for line in text.split("\n"):
        print("   |", line)

    # The announcement is spoken first, then the anecdote, then the laughter.
    # All three are narration, so all three are the narrator's voice.
    body = parse_turns(text)
    laughter = laughter_for(text)
    print(f"\n=== laughter scaled to {len(text.split())} words: {laughter} ===")
    turns = [("narrator", ANNOUNCEMENT)] + body + [("narrator", laughter)]
    leads = ([LEAD_ANNOUNCEMENT, LEAD_FIRST_LINE]
             + [LEAD_BETWEEN_LINES] * (len(body) - 1)
             + [LEAD_LAUGHTER])

    pool = [v[:-4] for v in sorted(os.listdir(f"{TTS_DIR}/voices")) if v.endswith(".wav")]
    pool = ["arthas"] + [v for v in pool if v != "arthas"]
    print(f"\n=== voice pool: {pool} ===")
    voiced = cast(turns, pool)

    print("\n=== synthesizing ===")
    files = synthesize(voiced)

    client = AwtrixClient(DEVICE)
    print("\n=== installing the laughing icon ===")
    if not any(f.name == f"{LAUGH_ICON}.gif" for f in client.list_icons()):
        client.upload_bytes(lametric.download(LAUGH_ICON), f"/ICONS/{LAUGH_ICON}.gif")
    print(f"icons on device: {[f.name for f in client.list_icons()]}")

    # The clock shows a short banner, not the joke — the joke is heard, not read.
    # `hold` keeps it up until we dismiss it, so the banner lasts exactly as long
    # as the speech instead of us guessing a scroll count.
    print("\n=== jingle + held banner on the clock, speech on the Mac ===")
    jingle = rtttl_duration(NOKIA)
    started = time.monotonic()
    client.notify(BANNER, icon=str(LAUGH_ICON), hold=True,
                  color="#FFD200", rtttl=NOKIA, push_icon=2)
    # Wait out exactly the jingle, minus the time the request itself took — the
    # device starts playing when it receives the call, not when we return.
    remaining = jingle - (time.monotonic() - started)
    print(f"jingle {jingle:.2f}s, request took {time.monotonic() - started:.2f}s, "
          f"waiting {max(remaining, 0):.2f}s")
    if remaining > 0:
        time.sleep(remaining)

    for (voice, line), path, lead in zip(voiced, files, leads):
        if lead:
            time.sleep(lead)
        print(f"   [{voice:8}] {line[:60]}")
        subprocess.run(["afplay", path], check=False)

    # The banner was held, so it stays until told otherwise — dismiss it now
    # that the last line has finished.
    client.dismiss_notification()
    print("\n=== done; banner dismissed, icon left installed for the connector ===")


if __name__ == "__main__":
    main()

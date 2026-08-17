#!/usr/bin/env python3
"""End-to-end demonstration of the anecdote connector, before the app exists.

Fetches a real anecdote from the vote-ranked feed, splits it into speaker turns,
voices each turn with a cloned character voice, then plays the audio on this Mac
while the clock scrolls the text behind a laughing icon and a Nokia jingle.

This mirrors what AnecdoteConnector will do in Swift. It is a demonstration, not
the product.
"""

from __future__ import annotations

import html
import json
import os
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

LAUGH_ICON = 9039
NOKIA = "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"
PREFIX = "ВНИМАНИЕ, АНЕКДОТ: "
ANNOUNCEMENT = "Внимание! Анекдот!"
LAUGHTER = "АХАХАХАХАХА"

# Silence before a clip, in seconds. The producer sets the pacing; the player
# just obeys. The beat before the laughter is a punchline pause, not a separator.
LEAD_ANNOUNCEMENT = 0.0
LEAD_FIRST_LINE = 0.7
LEAD_BETWEEN_LINES = 0.25
LEAD_LAUGHTER = 0.7

DASHES = "-—–"
ENTITIES = [("&quot;", '"'), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"),
            ("&nbsp;", " "), ("&mdash;", "—"), ("&ndash;", "–"), ("&amp;", "&")]


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


def synthesize(voiced: list[tuple[str, str]]) -> list[str]:
    """Drive speak.py --serve once for the whole dialogue, JSONL in and out."""
    proc = subprocess.Popen(
        [PYTHON, "speak.py", "--serve"],
        cwd=TTS_DIR, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    files = []
    try:
        for index, (voice, line) in enumerate(voiced):
            out = f"/tmp/demo-turn-{index}.wav"
            proc.stdin.write(json.dumps({"voice": voice, "text": line, "out": out}) + "\n")
            proc.stdin.flush()
            reply = json.loads(proc.stdout.readline())
            if not reply.get("ok"):
                raise RuntimeError(reply.get("error", "synthesis failed"))
            print(f"   voiced [{voice:8}] {reply['duration']:5.2f}s  {line[:56]}")
            files.append(out)
    finally:
        proc.stdin.close()
        proc.wait(timeout=30)
    return files


def main() -> None:
    print("=== fetching the vote-ranked feed ===")
    anecdotes = fetch_anecdotes()
    dialogues = [(g, t) for g, t in anecdotes
                 if sum(1 for l in t.split("\n") if l[:1] in DASHES) >= 2]
    print(f"{len(anecdotes)} anecdotes, {len(dialogues)} with dialogue")

    guid, text = dialogues[int(sys.argv[1]) if len(sys.argv) > 1 else 0]
    print(f"\n=== chosen {guid} ===")
    for line in text.split("\n"):
        print("   |", line)

    # The announcement is spoken first, then the anecdote, then the laughter.
    # All three are narration, so all three are the narrator's voice.
    body = parse_turns(text)
    turns = [("narrator", ANNOUNCEMENT)] + body + [("narrator", LAUGHTER)]
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

    scroll = PREFIX + text.replace("\n", " ") + " " + LAUGHTER
    print("\n=== jingle + scroll on the clock, speech on the Mac ===")
    jingle = rtttl_duration(NOKIA)
    started = time.monotonic()
    client.notify(scroll, icon=str(LAUGH_ICON), duration=25,
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

    print("\n=== done; leaving the icon installed for the connector ===")


if __name__ == "__main__":
    main()

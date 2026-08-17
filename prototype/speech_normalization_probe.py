#!/usr/bin/env python3
"""Compare text normalizations for speech, by ear.

XTTS vocalises typographic punctuation — quotation marks come out as an audible
token rather than as nothing. This synthesizes the same sentence under several
normalizations in ONE sidecar session, so the model loads once, then plays them
back to back for a listener to judge.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time

TTS_DIR = "/Users/artk0re/.local/share/tts-voices"
PYTHON = f"{TTS_DIR}/.venv/bin/python"
VOICE = "arthas"

SAMPLE = (
    'Сеть быстрого питания «Вкусно — и точка» открыла кафе прямо в библиотеке '
    'специальной акцией.'
)

QUOTES = "«»“”„‟\"'‘’`´"


def strip_quotes(text: str) -> str:
    return "".join(" " if ch in QUOTES else ch for ch in text)


def collapse_spaces(text: str) -> str:
    """Whitespace runs become one space, and no space precedes punctuation."""
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r"\s+([,.!?;:…])", r"\1", text)
    return text.strip()


VARIANTS = {
    "A_raw": lambda t: t,
    "B_no_quotes": lambda t: collapse_spaces(strip_quotes(t)),
    "C_no_quotes_dash_comma": lambda t: collapse_spaces(
        re.sub(r"\s+[—–]\s+", ", ", strip_quotes(t))
    ),
    "D_no_quotes_no_dash": lambda t: collapse_spaces(
        re.sub(r"\s+[—–]\s+", " ", strip_quotes(t))
    ),
}


def main() -> None:
    text = sys.argv[1] if len(sys.argv) > 1 else SAMPLE
    prepared = {name: fn(text) for name, fn in VARIANTS.items()}

    print("=== variants ===")
    for name, value in prepared.items():
        print(f"{name:24} {value}")

    print("\n=== synthesizing, one model load ===")
    proc = subprocess.Popen(
        [PYTHON, "speak.py", "--serve"],
        cwd=TTS_DIR, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True, bufsize=1,
    )
    files: dict[str, str] = {}
    try:
        for name, value in prepared.items():
            out = f"/tmp/norm-{name}.wav"
            proc.stdin.write(
                json.dumps({"voice": VOICE, "text": value, "out": out}) + "\n"
            )
            proc.stdin.flush()
            reply = json.loads(proc.stdout.readline())
            if not reply.get("ok"):
                print(f"{name}: FAILED {reply.get('error')}")
                continue
            print(f"{name:24} {reply['duration']:5.2f}s")
            files[name] = out
    finally:
        proc.stdin.close()
        proc.wait(timeout=60)

    print("\n=== listen ===")
    for name, path in files.items():
        print(f">>> {name}: {prepared[name][:70]}")
        subprocess.run(["afplay", path], check=False)
        time.sleep(0.8)


if __name__ == "__main__":
    main()

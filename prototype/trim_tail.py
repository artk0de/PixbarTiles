#!/usr/bin/env python3
"""Cut the spurious syllable XTTS sometimes appends to an utterance.

The model occasionally fails to stop cleanly and emits an extra fragment after
the sentence has ended. Punctuation does not prevent it, but the fragment is
separated from the real speech by genuine digital silence — around -90 dB, well
below anything speech produces — so it can be cut deterministically instead of
being worked around in the prompt.

Rule: find the last silent gap; if what follows is short enough to be an
artifact rather than a clause, drop everything from that gap onward.
"""

from __future__ import annotations

import math
import struct
import subprocess
import sys

SAMPLE_RATE = 24000
WINDOW = 0.02          # envelope resolution, seconds
SILENCE_DB = -60.0     # speech never sits this low; the gap measured -90 dB
MIN_GAP = 0.08         # shorter dips are stops inside speech, not an end
MAX_ARTIFACT = 0.9     # a longer tail is a real clause, so leave it alone


def envelope(samples: list[int], rate: int) -> list[tuple[float, float]]:
    step = int(rate * WINDOW)
    out = []
    for start in range(0, len(samples) - step, step):
        chunk = samples[start:start + step]
        rms = math.sqrt(sum(s * s for s in chunk) / len(chunk)) or 1
        out.append((start / rate, 20 * math.log10(rms / 32768)))
    return out


def decode(path: str) -> list[int]:
    raw = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-f", "s16le",
         "-ac", "1", "-ar", str(SAMPLE_RATE), "-"],
        capture_output=True, check=True,
    ).stdout
    count = len(raw) // 2
    return list(struct.unpack(f"<{count}h", raw[:count * 2]))


def artifact_start(path: str) -> float | None:
    """Seconds at which a trailing artifact begins, or None if the tail is clean."""
    samples = decode(path)
    frames = envelope(samples, SAMPLE_RATE)
    if not frames:
        return None
    duration = len(samples) / SAMPLE_RATE

    # Walk backwards over the trailing silence, then over the candidate
    # fragment, then look for the gap that separates it from the real speech.
    index = len(frames) - 1
    while index >= 0 and frames[index][1] < SILENCE_DB:
        index -= 1                      # skip silence at the very end
    fragment_end = index
    while index >= 0 and frames[index][1] >= SILENCE_DB:
        index -= 1                      # skip the fragment itself
    gap_end = index
    while index >= 0 and frames[index][1] < SILENCE_DB:
        index -= 1                      # skip the gap before it
    gap_start = index

    if gap_end < 0 or gap_start < 0:
        return None
    gap = frames[gap_end][0] - frames[gap_start][0]
    fragment = frames[fragment_end][0] - frames[gap_end][0]
    if gap < MIN_GAP or fragment > MAX_ARTIFACT:
        return None
    print(f"   gap {gap:.2f}s at {frames[gap_start][0]:.2f}s, "
          f"fragment {fragment:.2f}s, file {duration:.2f}s")
    return frames[gap_start][0]


def trim(path: str, out: str) -> bool:
    cut = artifact_start(path)
    if cut is None:
        subprocess.run(["cp", path, out], check=True)
        return False
    subprocess.run(
        ["ffmpeg", "-y", "-v", "error", "-i", path, "-t", f"{cut:.3f}",
         "-c:a", "pcm_s16le", "-ar", str(SAMPLE_RATE), "-ac", "1", out],
        check=True,
    )
    return True


if __name__ == "__main__":
    source = sys.argv[1]
    target = sys.argv[2] if len(sys.argv) > 2 else source.replace(".wav", "-trimmed.wav")
    print(f"{source} -> {target}")
    print("trimmed" if trim(source, target) else "tail already clean, copied as is")

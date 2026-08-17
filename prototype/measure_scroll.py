#!/usr/bin/env python3
"""Measure what scrollSpeed actually does, instead of guessing its direction.

The API documents scrollSpeed as "a percentage of the original scroll speed",
which does not say whether a larger number scrolls faster or slower. This holds
a notification on screen, samples the matrix, and reports how far the pixels
travel per second at each setting.
"""

from __future__ import annotations

import sys
import time

from awtrix import AwtrixClient
from awtrix.screen import HEIGHT, WIDTH, unpack

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.72"
TEXT = "ABCDEFGHIJKLMNOPQRSTUVWXYZ ABCDEFGHIJKLMNOPQRSTUVWXYZ"
SAMPLES = 10
INTERVAL = 0.35


def columns(buffer: list[int]) -> list[bool]:
    """Which columns have any lit pixel — enough signal to track motion."""
    px = unpack(buffer)
    return [any(sum(px[y * WIDTH + x]) > 90 for y in range(HEIGHT)) for x in range(WIDTH)]


def best_shift(a: list[bool], b: list[bool]) -> int:
    """Horizontal offset that best aligns b onto a, searching leftward motion."""
    best, best_score = 0, -1
    for shift in range(0, WIDTH // 2):
        overlap = WIDTH - shift
        score = sum(1 for i in range(overlap) if a[i + shift] == b[i])
        if score > best_score:
            best, best_score = shift, score
    return best


def measure(client: AwtrixClient, speed: int) -> float:
    client.dismiss_notification()
    time.sleep(0.6)
    client.notify(TEXT, duration=30, hold=True, scroll_speed=speed, color="#FFFFFF")
    time.sleep(1.5)

    prev = columns(client.screen())
    shifts: list[int] = []
    for _ in range(SAMPLES):
        time.sleep(INTERVAL)
        cur = columns(client.screen())
        shifts.append(best_shift(prev, cur))
        prev = cur

    moving = [s for s in shifts if s > 0]
    px_per_sample = sum(moving) / len(moving) if moving else 0.0
    return px_per_sample / INTERVAL


def main() -> None:
    client = AwtrixClient(HOST)
    for speed in (50, 100, 200, 400):
        rate = measure(client, speed)
        print(f"scrollSpeed={speed:>4} -> ~{rate:5.1f} px/s", flush=True)
    client.dismiss_notification()


if __name__ == "__main__":
    main()

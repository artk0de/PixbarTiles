#!/usr/bin/env python3
"""End-to-end check of the three device capabilities, against real hardware.

Run: python3 smoke.py [host]

Each step prints what it did and leaves the device as it found it. Screen
captures land in captures/ so the result can be inspected rather than assumed.
"""

from __future__ import annotations

import os
import sys
import time

from awtrix import AwtrixClient
from awtrix import lametric, screen

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.72"
CAPTURES = "captures"

LAUGH_ICON_ID = 9039
NOKIA = "nokia:d=4,o=5,b=225:8e6,8d6,f#,g#,8c#6,8b,d,e,8b,8a,c#,e,2a"

JOKE_RU = (
    "Звонок от курьера: - Здравствуйте! Я подъехал... "
    "- Здравствуйте! Но я вас не вижу... "
    "- Такое бывает. Я у соседнего подъезда!"
)
JOKE_LATIN = "ATTENTION JOKE: a courier calls. I have arrived. I cannot see you. I am at the next entrance!"


def step(title: str) -> None:
    print(f"\n=== {title} ===", flush=True)


def capture(client: AwtrixClient, name: str) -> str:
    path = os.path.join(CAPTURES, f"{name}.png")
    buffer = client.screen()
    screen.render(buffer, path)
    print(screen.to_text(buffer))
    print(f"-> {path}")
    return path


def main() -> None:
    os.makedirs(CAPTURES, exist_ok=True)
    client = AwtrixClient(HOST)

    step("device")
    stats = client.stats()
    print({k: stats[k] for k in ("version", "uid", "bat", "ram", "type", "ip_address")})

    step("files: melody round-trip")
    client.upload_melody("smoke", NOKIA)
    print("melodies:", [f.name for f in client.list_melodies()])
    print("play by name:", client.play_melody("smoke"))
    time.sleep(3)

    step("icons: fetch from catalogue and install")
    blob = lametric.download(LAUGH_ICON_ID)
    print(f"downloaded icon {LAUGH_ICON_ID}: {len(blob)} bytes, animated={blob[:6]!r}")
    client.upload_bytes(blob, f"/ICONS/{LAUGH_ICON_ID}.gif")
    print("icons:", [f.name for f in client.list_icons()])

    step("send: cyrillic joke with icon and jingle")
    client.notify(
        JOKE_RU,
        icon=str(LAUGH_ICON_ID),
        duration=12,
        color="#FFD200",
        rtttl=NOKIA,
        push_icon=2,
    )
    time.sleep(2.5)
    capture(client, "cyrillic")

    step("send: latin control text")
    client.dismiss_notification()
    time.sleep(1)
    client.notify(JOKE_LATIN, icon=str(LAUGH_ICON_ID), duration=10, color="#00FF88", push_icon=2)
    time.sleep(2.5)
    capture(client, "latin")

    step("cleanup")
    client.dismiss_notification()
    print("melody deleted:", client.delete_melody("smoke"))
    print("icon deleted:", client.delete(f"/ICONS/{LAUGH_ICON_ID}.gif"))
    print("melodies left:", [f.name for f in client.list_melodies()])
    print("icons left:", [f.name for f in client.list_icons()])


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Rebuilds octicons.py: GitHub's 16px octicons as 16x16 coverage.

Needs network, rsvg-convert and ImageMagick (`magick`) — only here; the face
generator reads the baked table and needs neither.
"""
import os, subprocess, tempfile, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
ICONS = {"mark": "mark-github", "star": "star-fill", "fork": "repo-forked", "pr": "git-pull-request",
         "ci": "x-circle-fill"}
URL = "https://raw.githubusercontent.com/primer/octicons/main/icons/{}-16.svg"


def coverage(name, tmp):
    svg, big, raw = (os.path.join(tmp, f"{name}.{ext}") for ext in ("svg", "png", "raw"))
    with open(svg, "wb") as f:
        f.write(urllib.request.urlopen(URL.format(name), timeout=20).read())
    subprocess.run(["rsvg-convert", "-w", "160", "-h", "160", svg, "-o", big], check=True)
    subprocess.run(["magick", big, "-alpha", "extract", "-filter", "box", "-resize", "16x16",
                    "-depth", "8", f"gray:{raw}"], check=True)
    b = open(raw, "rb").read()
    return [b[y * 16:(y + 1) * 16].hex() for y in range(16)]


def main():
    with tempfile.TemporaryDirectory() as tmp:
        table = {key: coverage(name, tmp) for key, name in ICONS.items()}
    path = os.path.join(HERE, "octicons.py")
    head = open(path, encoding="utf-8").read().split("OCTICONS = {")[0]
    body = "".join(f'    "{k}": {rows},\n' for k, rows in table.items())
    with open(path, "w", encoding="utf-8") as f:
        f.write(head + "OCTICONS = {\n" + body + "}\n")
    print(path)


if __name__ == "__main__":
    main()

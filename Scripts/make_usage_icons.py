#!/usr/bin/env python3
"""Draw each coding-subscription vendor's AWTRIX icon from its OWN mark.

The mark a vendor is known by exists once, as the `logo` on its
`CodeUsage.Vendor` — the rows the TC002 panel draws. The AWTRIX page shows the
same mark as 8x8 art on the clock's flash, and that art must not be a second
drawing of it: a hand-made GIF and a bitmap in Swift drift, and the clock ends
up showing a mark the panel does not.

So the GIF is GENERATED from the Swift table. This script reads the vendor
declarations out of `CodeUsage.swift` — the rows and the colour — and writes one
8x8 GIF per vendor into the kit's resources, where `BundledIcon` finds it by
basename.

    python3 Scripts/make_usage_icons.py

Rerun it when a mark or a mark's colour changes in `CodeUsage.swift`.
`UsageIconTests` holds the shipped art to that table, so a mark edited without
rerunning this fails the suite rather than the clock.
"""

from __future__ import annotations

import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENDORS = os.path.join(
    ROOT, "Sources", "PixelClockKit", "TileTemplates", "CodeUsage", "CodeUsage.swift"
)
RESOURCES = os.path.join(ROOT, "Sources", "PixelClockKit", "Resources")
SIZE = 8

# The one vendor whose mark is drawn here. Claude's `ClaudeStar` is art that
# predates the substrate and is not a rendering of its `logo`, so it is left
# alone rather than silently replaced by a crab-shaped approximation.
GENERATED = {"zai": "ZaiZ"}


def vendors(source: str) -> dict[str, dict]:
    """The `logo` rows and the mark's colour, per vendor, out of the Swift."""
    found = {}
    for name, body in re.findall(
        r"public static let (\w+) = Vendor\((.*?)\n        \)", source, re.S
    ):
        rows = re.findall(r'"([#.]+)"', body)
        hex_match = re.search(r"UlanziColour\(value: 0x([0-9A-Fa-f_]+)\)", body)
        brand = re.search(r'brand: (\w+)\.brandColour', body)
        found[name] = {
            "rows": rows,
            # A mark given as a literal uses that; one given as the brand's own
            # colour is looked up where the brand lives.
            "value": int(hex_match.group(1).replace("_", ""), 16) if hex_match else None,
            "brand": brand.group(1) if brand else None,
        }
    return found


def brand_colour(module: str) -> int:
    path = os.path.join(ROOT, "Sources", "PixelClockKit", module[:-5] if False else "", "")
    # `ClaudeUsage` lives in Claude/, `ZaiUsage` in Zai/ — the directory is the
    # type's prefix.
    folder = "Claude" if module.startswith("Claude") else "Zai"
    text = open(os.path.join(ROOT, "Sources", "PixelClockKit", folder, f"{module}.swift")).read()
    return int(re.search(r'brandColour = "#([0-9A-Fa-f]{6})"', text).group(1), 16)


def canvas(rows: list[str], colour: int) -> list[list[int | None]]:
    """The mark centred on the 8x8 the clock draws an icon at."""
    height = len(rows)
    width = max(len(row) for row in rows)
    left = (SIZE - width) // 2
    top = (SIZE - height) // 2
    px: list[list[int | None]] = [[None] * SIZE for _ in range(SIZE)]
    for y, row in enumerate(rows):
        for x, cell in enumerate(row):
            if cell == "#":
                px[top + y][left + x] = colour
    return px


def gif(px) -> bytes:
    """A one-frame GIF87a with a two-colour table: the mark, and black."""
    colours = [0x000000]
    indices = []
    for row in px:
        for cell in row:
            if cell is None:
                indices.append(0)
                continue
            if cell not in colours:
                colours.append(cell)
            indices.append(colours.index(cell))
    table = b"".join(struct.pack(">I", c)[1:] for c in colours)
    table += b"\x00\x00\x00" * (2 - len(colours))

    out = b"GIF87a" + struct.pack("<HH", SIZE, SIZE) + bytes([0xF0, 0, 0]) + table
    out += b"," + struct.pack("<HHHH", 0, 0, SIZE, SIZE) + b"\x00"

    # LZW at the smallest code size the format allows, written uncompressed:
    # every pixel its own code, with a clear code before each run so the
    # dictionary never fills. Sixty-four pixels needs no better.
    minimum = 2
    clear, end = 1 << minimum, (1 << minimum) + 1
    bits, acc, data = minimum + 1, 0, []
    stream, width = [], 0

    def emit(code):
        nonlocal acc, width
        acc |= code << width
        width += bits
        while width >= 8:
            stream.append(acc & 0xFF)
            acc >>= 8
            width -= 8

    emit(clear)
    for index in indices:
        emit(index)
        emit(clear)
    emit(end)
    if width:
        stream.append(acc & 0xFF)

    out += bytes([minimum])
    data = bytes(stream)
    for start in range(0, len(data), 255):
        block = data[start : start + 255]
        out += bytes([len(block)]) + block
    out += b"\x00" + b";"
    return out


def main() -> int:
    table = vendors(open(VENDORS).read())
    for vendor, basename in GENERATED.items():
        spec = table.get(vendor)
        if spec is None or not spec["rows"]:
            print(f"no mark for {vendor} in CodeUsage.swift", file=sys.stderr)
            return 1
        colour = spec["value"]
        if colour is None:
            colour = brand_colour(spec["brand"])
        path = os.path.join(RESOURCES, f"{basename}.gif")
        with open(path, "wb") as handle:
            handle.write(gif(canvas(spec["rows"], colour)))
        print(f"{vendor}: {len(spec['rows'])} rows -> {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Render the device's 32x8 matrix buffer to a PNG.

Lets the prototype verify what actually reached the display instead of trusting
a 200 response. The PNG encoder is hand-rolled so the package stays stdlib-only.
"""

from __future__ import annotations

import struct
import zlib

WIDTH = 32
HEIGHT = 8


def unpack(buffer: list[int]) -> list[tuple[int, int, int]]:
    """Split packed 0xRRGGBB values into RGB triples."""
    if len(buffer) != WIDTH * HEIGHT:
        raise ValueError(f"expected {WIDTH * HEIGHT} pixels, got {len(buffer)}")
    return [((v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF) for v in buffer]


def _chunk(tag: bytes, payload: bytes) -> bytes:
    return (
        struct.pack(">I", len(payload))
        + tag
        + payload
        + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF)
    )


def encode_png(pixels: list[tuple[int, int, int]], width: int, height: int) -> bytes:
    raw = bytearray()
    for y in range(height):
        raw.append(0)  # filter type: none
        for x in range(width):
            raw.extend(pixels[y * width + x])
    return b"".join(
        [
            b"\x89PNG\r\n\x1a\n",
            _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)),
            _chunk(b"IDAT", zlib.compress(bytes(raw), 9)),
            _chunk(b"IEND", b""),
        ]
    )


def render(buffer: list[int], path: str, scale: int = 16, grid: bool = True) -> str:
    """Write the buffer to `path`, upscaled so individual LEDs stay readable."""
    pixels = unpack(buffer)
    out_w, out_h = WIDTH * scale, HEIGHT * scale
    scaled: list[tuple[int, int, int]] = []
    for y in range(out_h):
        for x in range(out_w):
            sx, sy = x // scale, y // scale
            if grid and scale >= 4 and (x % scale == 0 or y % scale == 0):
                scaled.append((24, 24, 24))
            else:
                scaled.append(pixels[sy * WIDTH + sx])
    with open(path, "wb") as fh:
        fh.write(encode_png(scaled, out_w, out_h))
    return path


def to_text(buffer: list[int]) -> str:
    """Coarse terminal preview: filled block where a LED is lit."""
    pixels = unpack(buffer)
    rows = []
    for y in range(HEIGHT):
        row = "".join(
            "#" if sum(pixels[y * WIDTH + x]) > 90 else "." for x in range(WIDTH)
        )
        rows.append(row)
    return "\n".join(rows)

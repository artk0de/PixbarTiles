#!/usr/bin/env python3
# Scripts/MakeTimedGif.py — demo GIF generator for the TC002 custom-app
# pages. Text uses the X11 Fixed 5×7 font (font5x7-cyrillic.bdf, ASCII +
# Cyrillic). The GIF is assembled byte by byte — FULL 52×16 frames, one
# global palette, no per-frame cropping: ImageIO crops frames to the changed
# region and the FlyThings decoder paints those sub-rects over the
# accumulated picture, smearing everything (measured live 2026-09-21).
#
#   timed:   MakeTimedGif.py out.gif TEXT1 COLOR1 TEXT2 COLOR2   — 2 frames, 5 s each
#   marquee: MakeTimedGif.py out.gif marquee TEXT COLOR          — scroll, 2 px/0.1 s
#   duo5:    MakeTimedGif.py out.gif duo5 ICON ROW1 ROW2 COLOR  — icon + two static rows
#   duom:    MakeTimedGif.py out.gif duom ICON ROW1 ROW2 COLOR  — icon + two marquees
#            clipped to x ≥ 8 so they never cover the icon

import os
import sys

W, H = 52, 16


def here(name):
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), name)


# ───────────────────────── font ─────────────────────────

def load_font(path=here("font5x7-cyrillic.bdf")):
    font, ascent = {}, 6
    lines = open(path).read().splitlines()
    i = 0
    while i < len(lines):
        parts = lines[i].split()
        if not parts:
            i += 1
            continue
        if parts[0] == "FONT_ASCENT":
            ascent = int(parts[1])
        elif parts[0] == "STARTCHAR":
            encoding, w, h, by, rows = 0, 0, 0, 0, []
            i += 1
            while lines[i] != "ENDCHAR":
                p = lines[i].split()
                if not p:
                    i += 1
                    continue
                if p[0] == "ENCODING":
                    encoding = int(p[1])
                elif p[0] == "BBX":
                    w, h, by = int(p[1]), int(p[2]), int(p[4])
                elif p[0] != "BITMAP":
                    try:
                        int(p[0], 16)
                        rows.append(p[0])
                    except ValueError:
                        pass
                i += 1
            cells = []
            for r, row in enumerate(rows):
                bits = int(row, 16)
                for x in range(w):
                    if (bits >> (7 - x)) & 1:
                        cells.append((x, ascent - (by + h) + r))
            font[encoding] = cells
        i += 1
    return font


FONT = load_font()


# ───────────────────────── canvases ─────────────────────────

def new_canvas():
    return [[(0, 0, 0)] * W for _ in range(H)]


def parse_colour(text):
    return int(text[1:3], 16), int(text[3:5], 16), int(text[5:7], 16)


def glyph_run(canvas, text, x, y_top, colour, clip=0):
    pen = x
    for scalar in text:
        if scalar == " ":
            pen += 6
            continue
        for gx, gy in FONT.get(ord(scalar), []):
            # Glyphs like "/" run below the baseline; marquee rows start past
            # the right edge — clip both dimensions to the canvas.
            if clip <= pen + gx < W and 0 <= y_top + gy < H:
                canvas[y_top + gy][pen + gx] = colour
        pen += 6


def text_width(text):
    return 6 * len(text) - 1


# ───────────────────────── icon decoding (pure stdlib) ─────────────────────────

def lzw_decode(min_size, raw, expected):
    clear, end = 1 << min_size, (1 << min_size) + 1
    table = [bytes([i]) for i in range(clear)] + [b"", b""]
    size = min_size + 1
    out = bytearray()
    prev = None  # previous emitted entry
    bitpos = 0
    while True:
        code = 0
        for k in range(size):
            code |= ((raw[bitpos >> 3] >> (bitpos & 7)) & 1) << k
            bitpos += 1
        if code == end:
            break
        if code == clear:
            table = [bytes([i]) for i in range(clear)] + [b"", b""]
            size = min_size + 1
            prev = None
            continue
        if prev is None:
            entry = table[code]
        elif code < len(table):
            entry = table[code]
            table.append(prev + entry[:1])
        else:
            entry = prev + prev[:1]
            table.append(entry)
        out += entry
        prev = entry
        if len(table) == 1 << size and size < 12:
            size += 1
    return list(out[:expected]) + [0] * max(0, expected - len(out))


def icon_frames(path):
    """Decodes a small animated GIF into a list of RGB frames (stdlib only)."""
    data = open(path, "rb").read()
    flags = data[10]
    pos = 13
    table = None
    if flags & 0x80:
        n = 2 << (flags & 7)
        table = [(data[13 + 3 * i], data[14 + 3 * i], data[15 + 3 * i]) for i in range(n)]
        pos = 13 + 3 * n
    frames, canvas = [], None
    transparent, pending_disposal, frame_disposal = None, 1, 1
    while pos < len(data) and data[pos] != 0x3B:
        block = data[pos]
        if block == 0x21:
            if data[pos + 1] == 0xF9:
                packed = data[pos + 2]
                transparent = data[pos + 6] if packed & 1 else None
                frame_disposal = (packed >> 2) & 7
            pos += 2
            while data[pos] != 0:
                pos += 1 + data[pos]
            pos += 1
        elif block == 0x2C:
            if canvas is None or pending_disposal == 2:
                canvas = [[(0, 0, 0)] * 8 for _ in range(8)]
            left = data[pos + 1] | data[pos + 2] << 8
            top = data[pos + 3] | data[pos + 4] << 8
            w = data[pos + 5] | data[pos + 6] << 8
            h = data[pos + 7] | data[pos + 8] << 8
            img_flags = data[pos + 9]
            pos += 10
            local = table
            if img_flags & 0x80:
                n = 2 << (img_flags & 7)
                local = [(data[pos + 3 * i], data[pos + 1 + 3 * i], data[pos + 2 + 3 * i]) for i in range(n)]
                pos += 3 * n
            min_size = data[pos]
            pos += 1
            raw = bytearray()
            while data[pos] != 0:
                raw += data[pos + 1:pos + 1 + data[pos]]
                pos += 1 + data[pos]
            pos += 1
            indices = lzw_decode(min_size, raw, w * h)
            for row in range(h):
                for col in range(w):
                    idx = indices[row * w + col]
                    if idx != transparent:
                        canvas[top + row][left + col] = local[idx]
            frames.append([r[:] for r in canvas])
            pending_disposal = frame_disposal
        else:
            raise ValueError(f"unexpected block {block:#x} at {pos}")
    return frames


# ───────────────────────── GIF assembly ─────────────────────────

def lzw_encode(pixels):
    out, bit_buffer, bit_count = [], 0, 0

    def emit(code, width):
        nonlocal bit_buffer, bit_count
        bit_buffer |= code << bit_count
        bit_count += width
        while bit_count >= 8:
            out.append(bit_buffer & 0xFF)
            bit_buffer >>= 8
            bit_count -= 8

    width = 9
    table = {bytes([i]): i for i in range(256)}
    emit(256, width)
    phrase = b""
    for p in pixels:
        nxt = phrase + bytes([p])
        if nxt in table:
            phrase = nxt
            continue
        emit(table[phrase], width)
        code = len(table) + 2  # literals + clear + EOI already exist; first new code is 258
        table[nxt] = code
        # Classic (Poskanzer) convention: the encoder grows one code LATER
        # than the decoder adds the same entry — grow only after entry
        # 1 << width itself exists.
        if code == 1 << width and width < 12:
            width += 1
        phrase = bytes([p])
    if phrase:
        emit(table[phrase], width)
    emit(257, width)
    if bit_count > 0:
        out.append(bit_buffer & 0xFF)
    return bytes(out)


def write_gif(path, frames, delay_cs):
    palette = {(0, 0, 0): 0}
    indexed = []
    for canvas in frames:
        row = []
        for y in range(H):
            for x in range(W):
                c = canvas[y][x]
                if c not in palette:
                    if len(palette) >= 256:
                        raise ValueError("palette overflow — coarsen the colours")
                    palette[c] = len(palette)
                row.append(palette[c])
        indexed.append(bytes(row))
    colours = list(palette)

    gif = bytearray(b"GIF89a")
    # Logical screen descriptor: width/height are little-endian 16-bit.
    gif += bytes([W & 0xFF, W >> 8, H & 0xFF, H >> 8, 0xF7, 0, 0])
    for i in range(256):
        gif += bytes(colours[i]) if i < len(colours) else b"\0\0\0"
    gif += bytes([0x21, 0xFF, 11]) + b"NETSCAPE2.0" + bytes([3, 1, 0, 0, 0])
    for frame in indexed:
        # GCE: packed=0x04 (do-not-dispose), delay, transparent index 0 —
        # then the block terminator.
        gif += bytes([0x21, 0xF9, 4, 0x04, delay_cs & 0xFF, (delay_cs >> 8) & 0xFF, 0, 0])
        # Image descriptor: FULL frame at (0,0), no local table — width and
        # height as little-endian 16-bit.
        gif += bytes([0x2C, 0, 0, 0, 0, W & 0xFF, W >> 8, H & 0xFF, H >> 8, 0])
        gif.append(8)  # LZW min code size
        blob = lzw_encode(frame)
        for i in range(0, len(blob), 255):
            chunk = blob[i:i + 255]
            gif += bytes([len(chunk)]) + chunk
        gif.append(0)
    gif.append(0x3B)
    open(path, "wb").write(gif)
    print(f"wrote {path}: {len(gif)} bytes, {len(frames)} full frames, {len(colours)} palette entries")


# ───────────────────────── modes ─────────────────────────

out, mode = sys.argv[1], sys.argv[2]
frames, delay = [], 500

if mode in ("duo5", "duom"):
    colour = parse_colour(sys.argv[6])
    icon = icon_frames(sys.argv[3])
    top, bottom = sys.argv[4], sys.argv[5]

    def compose(icon_index, painter):
        canvas = new_canvas()
        if icon:
            ic = icon[icon_index % len(icon)]
            for y in range(8):
                for x in range(8):
                    canvas[4 + y][x] = ic[y][x]
        painter(canvas)
        return canvas

    if mode == "duom":
        # Rows cross the 44 px zone (x 8–51) in opposite directions, clipped
        # at the icon column.
        delay = 10
        count = (44 + text_width(top) + 3) // 2
        frames = [
            compose(i, lambda c, i=i: (
                glyph_run(c, top, W - i * 2, 0, colour, clip=8),
                glyph_run(c, bottom, 8 - text_width(bottom) - 1 + i * 2, 9, colour, clip=8)))
            for i in range(count)
        ]
    else:
        delay = 12
        frames = [
            compose(i, lambda c: (
                glyph_run(c, top, 10, 0, colour),
                glyph_run(c, bottom, 9, 9, colour)))
            for i in range(12)
        ]
elif mode == "marquee":
    colour, text = parse_colour(sys.argv[4]), sys.argv[3]
    delay = 10
    frames = []
    for i in range((W + text_width(text)) // 2 + 2):
        canvas = new_canvas()
        glyph_run(canvas, text, W - i * 2, 3, colour)
        frames.append(canvas)
else:  # timed: TEXT1 COLOR1 TEXT2 COLOR2
    frames = []
    for text, col in ((sys.argv[2], sys.argv[3]), (sys.argv[4], sys.argv[5])):
        canvas = new_canvas()
        glyph_run(canvas, text, 0, 3, parse_colour(col))
        frames.append(canvas)

write_gif(out, frames, delay)

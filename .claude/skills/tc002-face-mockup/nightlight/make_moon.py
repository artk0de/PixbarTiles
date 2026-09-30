"""Offline helper: the Red Moon crescent as a character mask.

An outer disc minus an inner disc whose centre is pushed along the crescent's
axis, the axis rotated by `deg`; each pixel sampled 8×8 in integer 1/16-px
units and quantised by coverage into the inks of `redmoon.MOON_INK`:
M full body, B the full pixels lining the inner limb, T edge pixels, g the
faint rim. Prints the mask to paste into `redmoon.py` as a literal.

  python3 make_moon.py            # the chosen crescent
  python3 make_moon.py 20 25 30   # candidates at these angles
"""
import math, sys

SS = 8                    # subsamples per axis; positions in 1/16 px
FULL = SS * SS
BOX_X, BOX_Y, BOX_W, BOX_H = 3, 1, 11, 11

# outer centre, outer radius, inner radius, offset of the inner centre — in 1/16 px
CX, CY, R, RI, D = 9.0, 6.0, 5.0, 4.5, 3.25
LEVELS = ((48, "M"), (20, "T"), (6, "g"))      # coverage ≥ n of 64 → ink


def px16(v):
    return int(round(v * 16))


def crescent(deg):
    cx, cy, r, ri = px16(CX), px16(CY), px16(R), px16(RI)
    ix = cx + px16(D * math.cos(math.radians(deg)))
    iy = cy - px16(D * math.sin(math.radians(deg)))       # screen y grows downwards
    rows = []
    for y in range(BOX_Y, BOX_Y + BOX_H):
        row = []
        for x in range(BOX_X, BOX_X + BOX_W):
            cover, near = 0, 0
            for j in range(SS):
                sy = 16 * y + 2 * j + 1
                for i in range(SS):
                    sx = 16 * x + 2 * i + 1
                    outer = (sx - cx) ** 2 + (sy - cy) ** 2 <= r * r
                    inner = (sx - ix) ** 2 + (sy - iy) ** 2 <= ri * ri
                    if outer and not inner:
                        cover += 1
                        if (sx - ix) ** 2 + (sy - iy) ** 2 <= (ri + 16) ** 2:
                            near += 1
            ink = "."
            for level, name in LEVELS:
                if cover >= level:
                    ink = name
                    break
            if ink == "M" and cover >= 56 and (16 * x + 8 - ix) ** 2 + (16 * y + 8 - iy) ** 2 <= (ri + 21) ** 2:
                ink = "B"
            row.append(ink)
        rows.append("".join(row))
    return rows


HALO_LEVELS = {1: "H", 2: "h"}      # squared distance to the nearest lit pixel → ink


def halo(rows, x0, y0, lit="BMT"):
    """The glow round the crescent: the ring of pixels touching the lit silhouette
    (and into the concave side), H beside them, h diagonal."""
    cells = {(x0 + dx, y0 + dy) for dy, row in enumerate(rows) for dx, ch in enumerate(row) if ch in lit}
    bx0, by0 = x0 - 2, max(0, y0 - 2)
    bx1, by1 = x0 + len(rows[0]) + 1, y0 + len(rows) + 1
    out = []
    for y in range(by0, by1 + 1):
        line = ""
        for x in range(bx0, bx1 + 1):
            d2 = min(((x - cx) ** 2 + (y - cy) ** 2 for cx, cy in cells), default=99)
            line += "." if (x, y) in cells else HALO_LEVELS.get(d2, ".")
        out.append(line)
    return (bx0, by0), out


if __name__ == "__main__":
    for deg in [int(a) for a in sys.argv[1:]] or [25]:
        rows = crescent(deg)
        print(f"# {deg}°  box x {BOX_X}…{BOX_X + BOX_W - 1}, y {BOX_Y}…{BOX_Y + BOX_H - 1}")
        for r in rows:
            print(f'    "{r}",')
        print("#", sum(r.count(c) for r in rows for c in "BMTg"), "px lit")
        (hx, hy), hrows = halo(rows, BOX_X, BOX_Y)
        print(f"# halo  HALO_X, HALO_Y = {hx}, {hy}")
        for r in hrows:
            print(f'    "{r}",')
        print("#", sum(r.count(c) for r in hrows for c in "Hhl"), "px halo")

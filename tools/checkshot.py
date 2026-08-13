#!/usr/bin/env python3
"""checkshot.py — assert that a VICE screenshot contains a rendered frame.

    checkshot.py build/shot.png [--min-coverage 0.30] [--min-colors 3]

The regression this catches is the black-screen class of bug: the engine
assembles, runs, `make debug` stays clean, and the display shows nothing.
`make debug` cannot see that — it only proves nobody wrote outside their
buffers — so the screenshot needs an assertion of its own.

Two cheap properties separate "a frame" from "not a frame", inside the 320x144
3D viewport (text rows 2-19; rows 0-1 and 20-21 are the two letterbox bands and
rows 22-24 the HUD -- IMPLEMENTATION_PLAN.md §14a.1 then §12, 176 -> 160 -> 144
rows, the last cut split evenly off the top and the bottom):

  coverage  fraction of pixels that are not the black background. A wall/floor/
            ceiling view fills most of the viewport; the known-good E1M1-less
            test-map frame measures 0.64.
  colors    number of distinct colours. Guards the other direction: a viewport
            flooded with one solid colour scores 1.0 coverage but is not a
            render.

Exits 0 when both hold, 1 when either fails, 2 if the PNG is missing or
unreadable. Prints the measured numbers either way, so a threshold that starts
tripping can be judged rather than merely raised.
"""

import argparse
import sys
from collections import Counter

try:
    from PIL import Image
except ImportError:
    sys.exit("checkshot: needs Pillow (pip install pillow)")

# VICE writes the full PAL frame including borders; the 320x200 VIC display
# area is centred in it. Derive the offset rather than hardcoding 32/36, so a
# different -exitscreenshot geometry still lines up.
DISPLAY_W, DISPLAY_H = 320, 200
# The 3D view is 144 rows centred on the old 176-row window: 16 blank rows above
# it, 16 below, then the HUD at 176. Cropping from row 0 would have measured the
# top letterbox as "the renderer drew nothing there", which is true and useless.
VIEWPORT_Y = 16
VIEWPORT_H = 144                 # rows 16-159. Outside it: letterbox + HUD.


def measure(path):
    im = Image.open(path).convert("RGB")
    w, h = im.size
    if w < DISPLAY_W or h < VIEWPORT_H:
        raise ValueError(f"{path} is {w}x{h}, too small to hold a C64 display")
    x0 = (w - DISPLAY_W) // 2
    y0 = (h - DISPLAY_H) // 2
    view = im.crop((x0, y0 + VIEWPORT_Y,
                    x0 + DISPLAY_W, y0 + VIEWPORT_Y + VIEWPORT_H))
    # getcolors returns [(count, rgb), ...]; the limit is well above the 16
    # colours a VIC-II frame can contain, so it never falls back to None.
    hist = Counter({rgb: n for n, rgb in view.getcolors(maxcolors=1 << 16)})
    total = DISPLAY_W * VIEWPORT_H
    black = hist.get((0, 0, 0), 0)
    return (total - black) / total, len(hist), hist


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("png", nargs="?", default="build/shot.png")
    ap.add_argument("--min-coverage", type=float, default=0.30,
                    help="minimum non-black fraction of the viewport (default 0.30)")
    ap.add_argument("--min-colors", type=int, default=3,
                    help="minimum distinct colours in the viewport (default 3)")
    a = ap.parse_args()
    path, min_cov, min_colors = a.png, a.min_coverage, a.min_colors

    try:
        cov, ncolors, hist = measure(path)
    except (OSError, ValueError) as e:
        print(f"checkshot: FAIL — {e}")
        return 2

    print(f"checkshot: {path}")
    print(f"  coverage {cov:6.1%}  (min {min_cov:.1%})")
    print(f"  colours  {ncolors:6d}  (min {min_colors})")
    for rgb, n in hist.most_common(5):
        print(f"    rgb{rgb} {n:6d} px  {n / (DISPLAY_W * VIEWPORT_H):5.1%}")

    fail = []
    if cov < min_cov:
        fail.append(f"coverage {cov:.1%} < {min_cov:.1%} — viewport is mostly black")
    if ncolors < min_colors:
        fail.append(f"only {ncolors} distinct colour(s) — flat fill, not a render")
    if fail:
        for f in fail:
            print(f"  FAIL: {f}")
        return 1
    print("  ok -- the frame has content")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Grab the engine's chunky framebuffer off real hardware and save a PNG.

    python3 tools/u64shot.py 192.168.1.65 build/hwshot.png

This is the hardware counterpart of `make shot`. It DMA-reads the live
25600 bytes of the MATRIX buffer over the REST API (176 -> 160 rows,
IMPLEMENTATION_PLAN.md §14a.1 -- the rest of MATRIX's 28160 bytes is
unused past the first frame) and renders it the way the C64
would, so a hardware frame can be looked at -- and diffed against the
emulator's -- without a capture card or the U64 video stream.

What it renders is the *chunky* buffer, i.e. the renderer's output
before chunky2mc packs it into a multicolor bitmap. So it shows what the
3D code drew, at full 16-shades-per-ramp precision, not what the VIC
finally displays. Attribute-level artefacts will not show up here; wrong
geometry will.

Optionally sets the camera first (--cam X,Y,A), which makes it usable as
a scripted turntable: dump a frame, nudge the angle, dump another.
"""

from __future__ import annotations

import argparse
import struct
import sys
import zlib

from u64 import Ultimate, U64Error, add_host_args

MATRIX = 0x1000
WIDTH, HEIGHT = 160, 160          # 176 -> 160 rows, IMPLEMENTATION_PLAN.md §14a.1
CELL_ROWS = HEIGHT // 8          # 20
CAMX = 0x50                      # camX, camY, camZ, camA, camSec -- see defs.asm

CHUNK = 0x1000                   # bytes per readmem request

# Pepto's C64 palette.
C64 = [
    (0x00, 0x00, 0x00), (0xFF, 0xFF, 0xFF), (0x68, 0x37, 0x2B), (0x70, 0xA4, 0xB2),
    (0x6F, 0x3D, 0x86), (0x58, 0x8D, 0x43), (0x35, 0x28, 0x79), (0xB8, 0xC7, 0x6F),
    (0x6F, 0x4F, 0x25), (0x43, 0x39, 0x00), (0x9A, 0x67, 0x59), (0x44, 0x44, 0x44),
    (0x6C, 0x6C, 0x6C), (0x9A, 0xD2, 0x84), (0x6C, 0x5E, 0xB5), (0x95, 0x95, 0x95),
]

# Must match `ramps` in src/render/chunky2mc.asm.
RAMPS = [
    (0xb, 0xc, 0xf),  # 0 stone
    (0x9, 0x8, 0x7),  # 1 wood
    (0x2, 0xa, 0x7),  # 2 flesh
    (0x6, 0xe, 0x3),  # 3 sky
    (0x9, 0x5, 0xd),  # 4 moss
    (0x6, 0x4, 0xa),  # 5 violet
    (0xb, 0xc, 0x1),  # 6 metal
    (0x2, 0x8, 0x7),  # 7 fire
] + [(0xb, 0xc, 0xf)] * 8


def build_lut() -> list[tuple[int, int, int]]:
    """matrix byte -> RGB.

    The hardware dithers between the two ramp entries that bracket the
    intensity; here that is done as a straight linear blend, which is
    what the dither averages to and is easier to read on a still.
    """
    lut = []
    for byte in range(256):
        stops = [(0, 0, 0)] + [C64[c] for c in RAMPS[byte >> 4]]
        pos = (byte & 0x0F) / 5.0           # 0..3 across the four stops
        lo = min(int(pos), 2)
        frac = pos - lo
        a, b = stops[lo], stops[lo + 1]
        lut.append(tuple(round(a[i] + (b[i] - a[i]) * frac) for i in range(3)))
    return lut


def write_png(path: str, width: int, height: int, rows: list[bytes]) -> None:
    """Minimal truecolor PNG writer -- no Pillow dependency."""
    raw = b"".join(b"\x00" + row for row in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as fh:
        fh.write(b"\x89PNG\r\n\x1a\n")
        fh.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)))
        fh.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        fh.write(chunk(b"IEND", b""))


def read_matrix(u: Ultimate) -> bytes:
    size = CELL_ROWS * 1280
    out = bytearray()
    while len(out) < size:
        n = min(CHUNK, size - len(out))
        block = u.readmem(MATRIX + len(out), n)
        if len(block) != n:
            raise U64Error(f"readmem at ${MATRIX + len(out):04X} returned "
                           f"{len(block)} bytes, expected {n}")
        out += block
    return bytes(out)


def render(matrix: bytes, scale: int) -> list[bytes]:
    lut = build_lut()
    rows = []
    for y in range(HEIGHT):
        # cell-major: (y>>3)*1280 + (x>>2)*32 + (y&7)*4 + (x&3)
        base = (y >> 3) * 1280 + (y & 7) * 4
        px = bytearray()
        for x in range(WIDTH):
            r, g, b = lut[matrix[base + (x >> 2) * 32 + (x & 3)]]
            # multicolor pixels are twice as wide as they are tall
            px += bytes((r, g, b)) * (2 * scale)
        rows.extend([bytes(px)] * scale)
    return rows


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("output", help="PNG to write")
    ap.add_argument("--cam", metavar="X,Y,A",
                    help="place the camera here before grabbing, e.g. 512,512,0")
    ap.add_argument("--settle", type=float, default=0.2,
                    help="seconds to wait after moving the camera "
                         "(default: %(default)s)")
    ap.add_argument("--scale", type=int, default=1,
                    help="integer upscale (default: %(default)s)")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password, timeout=60)
    try:
        if args.cam:
            import time
            try:
                x, y, a = (int(v) for v in args.cam.split(","))
            except ValueError:
                print("error: --cam wants X,Y,A", file=sys.stderr)
                return 2
            u.writemem(CAMX, struct.pack("<hh", x, y))
            u.writemem(CAMX + 6, bytes([a & 0xFF]))
            time.sleep(args.settle)

        matrix = read_matrix(u)
        write_png(args.output, WIDTH * 2 * args.scale, HEIGHT * args.scale,
                  render(matrix, args.scale))
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    nonblack = sum(1 for b in matrix if b & 0x0F)
    print(f"{args.output}: {len(matrix)} bytes read, "
          f"{100.0 * nonblack / len(matrix):.1f}% non-black")
    return 0


if __name__ == "__main__":
    sys.exit(main())

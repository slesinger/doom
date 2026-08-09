#!/usr/bin/env python3
"""Probes for a running x64sc, over the VICE binary monitor.

    # terminal 1
    xvfb-run -a x64sc -warp +sound +confirmonexit -autostartprgmode 1 \
        -binarymonitor -binarymonitoraddress ip4://127.0.0.1:6510 \
        -autostart build/doom.prg

    # terminal 2
    python3 tools/vicedbg/probe.py dump build/doom.prg   # memory occupancy + PC
    python3 tools/vicedbg/probe.py diff build/doom.prg   # live RAM vs PRG image

`diff` is the regression test for the spanFill out-of-bounds bug: it reports any
byte that differs from the loaded image outside the regions the engine is allowed
to write at runtime. A clean run prints zero unexpected differences.
"""
import struct
import sys
import time
from collections import Counter

from vicemon import Mon

# regions the engine legitimately writes while running
ALLOWED = [
    (0x0200, 0x02FF, "colTop"),
    (0x0300, 0x03FF, "colBot"),
    (0x0400, 0x07FF, "COLBUF"),
    (0x0B20, 0x0B5F, "portal-stack/visitedSec"),
    (0x1000, 0x7DFF, "MATRIX"),
    (0x8000, 0x83FF, "SCREEN0"),
    (0xA000, 0xBF3F, "BITMAP0"),
    (0xC000, 0xC3FF, "SCREEN1"),
    (0x9900, 0x9AFF, "converter code (self-mod)"),
    (0x9B60, 0x9D5F, "math code (self-mod mul8)"),
]


def region(addr):
    for lo, hi, name in ALLOWED:
        if lo <= addr <= hi:
            return name
    return "*** UNEXPECTED ***"


def load_prg(path):
    raw = open(path, "rb").read()
    return raw[0] | (raw[1] << 8), raw[2:]


def reg_names(m):
    _, _, b = m.cmd(0x83, b"\x00")
    n = struct.unpack("<H", b[:2])[0]
    off, names = 2, {}
    for _ in range(n):
        size = b[off]
        names[b[off + 1]] = b[off + 4:off + 4 + b[off + 3]].decode()
        off += size + 1
    return names


def cmd_dump(m, prg_path, settle):
    names = reg_names(m)
    m.exit_mon()
    time.sleep(settle)

    pcs = []
    for _ in range(8):
        pcs.append({names[k]: v for k, v in m.regs().items()}.get("PC"))
        m.exit_mon()
        time.sleep(0.2)
    print("PC samples:", " ".join(f"${p:04x}" for p in pcs))
    if len(set(pcs)) == 1:
        print("  !! PC is frozen -- the CPU is wedged or JAMmed")

    ranges = {
        "matrix":  (0x1000, 0x7DFF),
        "screen0": (0x8000, 0x83FF),
        "screen1": (0xC000, 0xC3FF),
        "bitmap0": (0xA000, 0xBF3F),
        "bitmap1": (0xE000, 0xFF3F),
        "colbuf":  (0x0400, 0x077F),
        "clip":    (0x0200, 0x03FF),
    }
    for name, (a, b) in ranges.items():
        # bank 1 = ram, so reads under BASIC/KERNAL ROM see the RAM beneath
        data = m.mem_get(a, b, bank=1)
        nz = sum(1 for x in data if x)
        print(f"{name:8s} ${a:04x}-${b:04x} {len(data):6d}B "
              f"nonzero={nz:6d} ({100.0 * nz / max(1, len(data)):5.1f}%)")

    zp = m.mem_get(0x0000, 0x00FF, bank=1)
    print(f"camX={zp[0x50] | zp[0x51] << 8} camY={zp[0x52] | zp[0x53] << 8} "
          f"camA={zp[0x56]} camSec={zp[0x57]} backBuf={zp[0x4A]} stackN={zp[0x5C]}")
    if zp[0x4A] == 0:
        print("  !! backBuf still 0 -- flip() has never completed a frame")


def cmd_diff(m, prg_path, settle):
    load, img = load_prg(prg_path)
    m.exit_mon()
    time.sleep(settle)

    diffs = []
    for a in range(load, load + len(img), 0x1000):
        b = min(a + 0xFFF, load + len(img) - 1)
        live = m.mem_get(a, b, bank=1)
        for i, v in enumerate(live):
            addr = a + i
            if v != img[addr - load]:
                diffs.append((addr, img[addr - load], v))
        m.exit_mon()

    counts = Counter(region(a) for a, _, _ in diffs)
    print("live-vs-PRG differences by region:")
    for name, n in counts.most_common():
        print(f"  {n:7d}  {name}")

    bad = [d for d in diffs if region(d[0]).startswith("***")]
    print(f"\nunexpected differences: {len(bad)}")
    if not bad:
        print("  clean -- no writes outside the engine's own buffers")
        return 0

    runs = []
    for addr, was, now in bad:
        if runs and addr - runs[-1][1] <= 8 and now == runs[-1][2]:
            runs[-1][1] = addr
        else:
            runs.append([addr, addr, now])
    for start, end, val in runs[:40]:
        print(f"  ${start:04x}-${end:04x}  value=${val:02x}  ({end - start + 1} bytes)")
    return 1


def connect(port, wait=30.0):
    """Wait for the monitor socket to come up, then connect.

    x64sc opens the binary-monitor port some way into its startup, and how long
    that takes varies with the machine, whether xvfb is in the way, and whether
    the ROMs load on the first try. A fixed `sleep` in the Makefile therefore
    either raced (ConnectionRefused) or wasted seconds on every run.
    """
    deadline = time.time() + wait
    while True:
        try:
            return Mon(port=port)
        except (ConnectionRefusedError, OSError):
            if time.time() >= deadline:
                raise
            time.sleep(0.25)


def main():
    if len(sys.argv) < 2 or sys.argv[1] not in ("dump", "diff"):
        print(__doc__)
        return 2
    action = sys.argv[1]
    prg = sys.argv[2] if len(sys.argv) > 2 else "build/doom.prg"
    port = int(sys.argv[3]) if len(sys.argv) > 3 else 6510
    settle = float(sys.argv[4]) if len(sys.argv) > 4 else 8.0

    try:
        m = connect(port)
    except OSError as e:
        print(f"probe: no VICE binary monitor on port {port} ({e})")
        return 2
    try:
        return cmd_dump(m, prg, settle) if action == "dump" else cmd_diff(m, prg, settle)
    finally:
        m.quit()


if __name__ == "__main__":
    sys.exit(main() or 0)

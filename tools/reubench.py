#!/usr/bin/env python3
"""Run src/reubench.asm on a C64 Ultimate and print the DMA throughput table.

    python3 tools/reubench.py 192.168.1.65 build/reubench.prg

The benchmark leaves its results in C64 RAM; this reads them out over
DMA and does the arithmetic. See src/reubench.asm for the method.

The question it exists to answer: does REU DMA throughput scale with
the CPU turbo clock, or is it fixed? If the 1 MHz and 64 MHz columns
agree, DMA is independent of the CPU clock, and IMPLEMENTATION_PLAN.md
§4's per-subsector streaming costs whatever the table says it costs
regardless of how fast the engine runs.
"""

from __future__ import annotations

import argparse
import sys
import time

from u64 import Ultimate, U64Error, add_host_args

RESULTS = 0x0C00        # must match `.const RESULTS` in src/reubench.asm
SIZES = (32, 256, 4096)
REPS = (128, 32, 4)
PASSES = ("1 MHz", "64 MHz")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("prg", nargs="?", default="build/reubench.prg")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="seconds to wait for the benchmark to finish")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password, timeout=60)
    try:
        with open(args.prg, "rb") as fh:
            u.run_prg(fh.read())

        end = time.monotonic() + args.timeout
        while True:
            head = u.readmem(RESULTS, 64)
            if head[0:3] == b"RB\x01" and head[5] == 0xFF:
                break
            if time.monotonic() > end:
                print(f"error: benchmark did not finish in {args.timeout:.0f} s "
                      f"(magic={head[0:3]!r} progress={head[4]} done={head[5]:#04x})",
                      file=sys.stderr)
                return 2
            time.sleep(0.5)
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    if head[3] != 1:
        print("error: the machine reports no REU -- check that "
              "'RAM Expansion Unit' is Enabled in the Ultimate's "
              "C64 and Cartridge Settings", file=sys.stderr)
        return 2

    vals = [head[8 + 2 * i] | (head[9 + 2 * i] << 8) for i in range(12)]

    print("REU DMA throughput (CIA timer A, 1 us ticks; loop overhead "
          "measured and subtracted)\n")
    print(f"{'size':>6} {'reps':>5} {'pass':>7} {'gross us':>9} "
          f"{'ovh us':>7} {'net us':>7} {'us/xfer':>8} {'MB/s':>6}")
    net = {}
    for p, pname in enumerate(PASSES):
        for s, (size, reps) in enumerate(zip(SIZES, REPS)):
            gross = vals[p * 6 + s * 2]
            ovh = vals[p * 6 + s * 2 + 1]
            n = max(gross - ovh, 0)
            net[(pname, size)] = n
            per = n / reps
            rate = (size * reps) / n * 1e6 / 1e6 if n else 0.0   # bytes/us
            print(f"{size:>6} {reps:>5} {pname:>7} {gross:>9} {ovh:>7} "
                  f"{n:>7} {per:>8.1f} {rate:>6.2f}")

    print()
    for size in SIZES:
        a, b = net[("1 MHz", size)], net[("64 MHz", size)]
        if not a or not b:
            continue
        print(f"  {size:>5} B: 64 MHz is {a / b:.2f}x the 1 MHz rate")
    print("\n  ~1.00x across the board means DMA does not scale with the "
          "CPU clock.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

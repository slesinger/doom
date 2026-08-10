#!/usr/bin/env python3
"""Run src/geobench.asm on a C64 Ultimate and print the I/O access-cost table.

    python3 tools/geobench.py 192.168.1.65 build/geobench.prg

The question it exists to answer is docs/georam-vs-reu.md §9.1: does an
access to I/O space run at the CPU turbo clock, or is it synchronised
down to the 1 MHz bus? A GeoRAM migration is worth ~2.4 ms/frame if the
former and nothing at all if the latter.

Read the table bottom-up:

  * the two RAM rows are the control. They must show close to a 64x
    spread between the passes. If they do not, the turbo switch did not
    take and no other row means anything.
  * the `lda $de00,x` row is the answer. Tracking the RAM control means
    the window runs at CPU speed; ~1.0 us/access means it is bus-locked
    and the REU is as good as GeoRAM will ever be.

See src/geobench.asm for the method.
"""

from __future__ import annotations

import argparse
import sys
import time

from u64 import Ultimate, U64Error, add_host_args

RESULTS = 0x0C00        # must match `.const RESULTS` in src/geobench.asm
REPS = 8                # must match `.const REPS`
ITERS = REPS * 256      # accesses per timed loop

# Must match the call order in runPass.
LOOPS = (
    ("empty loop", "control"),
    ("lda $c000,x", "RAM read"),
    ("sta $c000,x", "RAM write"),
    ("lda $de00,x", "GeoRAM window read"),
    ("sta $de00,x", "GeoRAM window write"),
    ("sta $dffe", "GeoRAM page select"),
)
PASSES = ("1 MHz", "64 MHz")

PROBE = {
    0: "no window at $de00 -- reads came back as open bus ($ff)",
    1: "ok",
    2: "something answers at $de00 but $dffe does not select between "
       "pages -- another cartridge or the Ultimate command interface "
       "may own I/O1",
}


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("prg", nargs="?", default="build/geobench.prg")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="seconds to wait for the benchmark to finish")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password, timeout=60)
    try:
        # run_prg_basic, not run_prg: the latter starts the program with
        # the cartridge disabled and the GeoRAM window reads as open bus.
        with open(args.prg, "rb") as fh:
            u.run_prg_basic(fh.read())

        end = time.monotonic() + args.timeout
        while True:
            head = u.readmem(RESULTS, 64)
            if head[0:3] == b"GB\x01" and (head[5] == 0xFF or head[3] != 1):
                break
            if time.monotonic() > end:
                print(f"error: benchmark did not finish in {args.timeout:.0f} s "
                      f"(magic={head[0:3]!r} probe={head[3]} "
                      f"progress={head[4]} done={head[5]:#04x})",
                      file=sys.stderr)
                return 2
            time.sleep(0.5)
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    probe = head[3]
    print(f"GeoRAM window probe: {PROBE.get(probe, f'unknown code {probe}')}\n")
    if probe != 1:
        print("Check that 'RAM Expansion Unit' is 'GeoRAM Mode' in the "
              "Ultimate's C64 and Cartridge Settings.", file=sys.stderr)
        return 2

    vals = [head[8 + 2 * i] | (head[9 + 2 * i] << 8)
            for i in range(2 * len(LOOPS))]

    print(f"I/O access cost ({ITERS} accesses per loop, CIA 2 timer A, "
          f"1 us ticks;\nthe empty loop is measured and subtracted, so "
          f"each row is one instruction)\n")
    print(f"{'loop':>12} {'what':<20} {'pass':>7} {'gross us':>9} "
          f"{'net us':>8} {'ns/access':>10} {'cycles@64':>10}")

    net = {}
    for p, pname in enumerate(PASSES):
        base = vals[p * len(LOOPS) + 0]
        for i, (loop, what) in enumerate(LOOPS):
            gross = vals[p * len(LOOPS) + i]
            n = max(gross - base, 0) if i else gross
            net[(pname, loop)] = n
            per_ns = n * 1000.0 / ITERS
            # 64 MHz -> 15.6 ns a cycle; meaningless for the 1 MHz pass,
            # so only shown where it means something.
            cyc = f"{per_ns / 15.625:>10.1f}" if pname == "64 MHz" and i else " " * 10
            print(f"{loop:>12} {what:<20} {pname:>7} {gross:>9} "
                  f"{n:>8} {per_ns:>10.1f} {cyc}")

    print()
    print(f"{'loop':>12} {'1 MHz ns':>10} {'64 MHz ns':>10} {'speedup':>9}")
    for loop, _ in LOOPS[1:]:
        a, b = net[("1 MHz", loop)], net[("64 MHz", loop)]
        if not b:
            print(f"{loop:>12} {'-':>10} {'-':>10} {'n/a':>9}")
            continue
        print(f"{loop:>12} {a * 1000.0 / ITERS:>10.1f} "
              f"{b * 1000.0 / ITERS:>10.1f} {a / b:>8.1f}x")

    ram = net[("64 MHz", "lda $c000,x")]
    win = net[("64 MHz", "lda $de00,x")]
    print()
    if not ram or not win:
        print("  inconclusive: a net time came out at zero, so the loops are "
              "too short to resolve. Raise REPS in src/geobench.asm.")
        return 0
    ratio = win / ram
    print(f"  A window read costs {ratio:.1f}x a RAM read at 64 MHz.")
    if ratio < 2.0:
        print("  => I/O runs at the turbo clock. docs/georam-vs-reu.md §4 "
              "holds; the migration is worth costing out.")
    elif win * 1000.0 / ITERS > 500:
        print("  => I/O is synchronised to the 1 MHz bus (~1 us/access, "
              "REU DMA's own rate).\n     docs/georam-vs-reu.md §10: stay "
              "on the REU.")
    else:
        print("  => in between: neither the fast nor the slow case the "
              "document assumed. Worth a look\n     before anything is "
              "migrated.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

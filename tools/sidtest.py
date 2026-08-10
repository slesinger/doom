#!/usr/bin/env python3
"""Run src/sidtest.asm on a C64 Ultimate and say whether SID writes survive turbo.

    python3 tools/sidtest.py 192.168.1.65 build/sidtest.prg

The question: the engine drives the bus at 64 MHz and the SID is a 1 MHz
device. A music player writes ~25 registers back to back, which at speed
index 15 is under half a microsecond of bus time. If the Ultimate does not
stretch or queue those writes, some are lost -- and a lost write does not
raise anything, it just makes the tune subtly wrong.

The PRG measures voice 3's oscillator through $d41b, which is readable while
bit 7 of $d418 keeps voice 3 out of the audio path, so the whole measurement
is silent and needs no ears. See src/sidtest.asm for the method.

DO NOT RUN THIS UNDER VICE. $d031 is inert there, so both passes would be
1 MHz passes and the question would go unasked -- and worse, VICE's $d41b
does not track the frequency register at all (it reads as a counter
advancing one unit per cycle whatever is written), so the run would look
like a catastrophic failure that is purely an emulation artefact. The raw
trace this prints is what makes that visible; check it first.
"""

from __future__ import annotations

import argparse
import sys
import time

from u64 import Ultimate, U64Error, add_host_args

RESULTS = 0x0C00        # must match `.const RESULTS` in src/sidtest.asm
TRACE = 0x0D00
NSAMPLE = 8
SLOT_BASE = (16, 24, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104)
TICK_LOG = 128          # the elapsed-tick log sits this far above each sample

# variant index -> (label, frequency written)
VARIANTS = (("spaced", 0x0400), ("tight", 0x0400), ("burst25", 0x0400),
            ("hammer8", 0x0400), ("spaced", 0x0200), ("spaced", 0x0800))
SPEEDS = ("1 MHz", "64 MHz")

# $d41b advances freq/65536 per phi2 cycle and a CIA tick is MS_TICKS = 1000
# of them, so the per-tick step is freq/65.536. Both sides are fed from phi2,
# so this holds whatever PAL's exact clock is -- see src/sidtest.asm.
def predicted(freq: float) -> float:
    return freq * 1000.0 / 65536.0


TOL = 1.5               # units of $d41b per tick
RATIO_TOL = 0.08        # fractional, for the half/double controls


def mean_step(samples):
    """Per-tick advance, unwrapped. Each step is well under 256."""
    steps = [(samples[i + 1] - samples[i]) % 256 for i in range(len(samples) - 1)]
    return sum(steps) / len(steps), steps


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("prg", nargs="?", default="build/sidtest.prg")
    ap.add_argument("--timeout", type=float, default=60.0,
                    help="seconds to wait for the measurement to finish")
    ap.add_argument("--trace", action="store_true",
                    help="print the raw $d41b trace as well")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password, timeout=60)
    try:
        with open(args.prg, "rb") as fh:
            u.run_prg(fh.read())

        end = time.monotonic() + args.timeout
        while True:
            res = u.readmem(RESULTS, 256)
            if res[0:3] == b"ST\x01" and res[3] == 0xFF:
                break
            if time.monotonic() > end:
                print(f"error: sidtest did not finish in {args.timeout:.0f} s "
                      f"(magic={res[0:3]!r} done={res[3]:#04x})",
                      file=sys.stderr)
                return 2
            time.sleep(0.3)
        trace = u.readmem(TRACE, 192)
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    # -- the sanity check that has to come first --------------------------
    # A trace whose three frequencies look alike means the frequency register
    # never reached the chip, and every table below it is meaningless.
    tr_steps = []
    for off in (0, 64, 128):
        v = list(trace[off:off + 64])
        tr_steps.append(mean_step(v)[0])
    print("raw $d41b trace at 1 MHz -- the oscillator must track the "
          "frequency written:")
    for (lbl, off, st) in zip(("$0200", "$0400", "$0800"), (64, 0, 128),
                              (tr_steps[1], tr_steps[0], tr_steps[2])):
        print(f"  freq {lbl}: {st:6.2f} units/sample   "
              f"{list(trace[off:off + 10])} ...")
    if tr_steps[0] <= 0 or not (
            0.35 < tr_steps[1] / tr_steps[0] < 0.65 and
            1.6 < tr_steps[2] / tr_steps[0] < 2.4):
        print()
        print("  The three traces are not in a 1 : 2 : 4 ratio, so $d41b is "
              "not following")
        print("  the frequency register. Either no SID is mapped at $d400 or "
              "this machine")
        print("  does not implement the readback. Nothing below can be "
              "believed. (VICE fails")
        print("  exactly this way -- run it on hardware.)")
        return 2
    print("  ratio 1 : "
          f"{tr_steps[0] / tr_steps[1]:.2f} : "
          f"{tr_steps[2] / tr_steps[1]:.2f} -- the readback is real.\n")

    # -- the measurement --------------------------------------------------
    rows = []
    for s in range(12):
        base = SLOT_BASE[s]
        samples = list(res[base:base + NSAMPLE])
        ticks = list(res[base + TICK_LOG:base + TICK_LOG + NSAMPLE])
        step, steps = mean_step(samples)
        rows.append((SPEEDS[s // 6], VARIANTS[s % 6], step, steps, ticks))

    print(f"{'speed':>7} {'writes':>8} {'freq':>6} {'step/tick':>10} "
          f"{'predicted':>10} {'ticks':>12}")
    ok = True
    for speed, (label, freq), step, steps, ticks in rows:
        pred = predicted(freq)
        good = abs(step - pred) <= TOL
        timing_ok = ticks == list(range(1, NSAMPLE + 1))
        ok &= good and timing_ok
        print(f"{speed:>7} {label:>8} {freq:>#6x} {step:>10.2f} "
              f"{pred:>10.2f} "
              f"{'1..8' if timing_ok else str(ticks):>12}"
              f"{'' if good else '   MISMATCH'}"
              f"{'' if timing_ok else '   BAD TIMING'}")

    print()
    base_1mhz = rows[0][2]
    base_64 = rows[6][2]
    for speed, idx, want, what in (("1 MHz", 4, 0.5, "half"),
                                   ("1 MHz", 5, 2.0, "double"),
                                   ("64 MHz", 10, 0.5, "half"),
                                   ("64 MHz", 11, 2.0, "double")):
        ref = base_1mhz if speed == "1 MHz" else base_64
        got = rows[idx][2] / ref if ref else 0
        good = abs(got - want) <= want * RATIO_TOL
        ok &= good
        print(f"  control {speed:>6}: {what} frequency reads "
              f"{got:.3f}x the reference (want {want:.1f}) "
              f"{'ok' if good else 'FAILED'}")

    print()
    spread_1 = max(r[2] for r in rows[0:4]) - min(r[2] for r in rows[0:4])
    spread_64 = max(r[2] for r in rows[6:10]) - min(r[2] for r in rows[6:10])
    print(f"  spread across the four write patterns: "
          f"{spread_1:.2f} at 1 MHz, {spread_64:.2f} at 64 MHz "
          f"(units/tick; anything under {TOL} is measurement noise)")

    print()
    if ok:
        print("  Every write pattern delivers the same frequency, at 1 MHz and "
              "at 64 MHz alike --")
        print("  including 25 registers back to back and eight of those bursts "
              "in a row. A player")
        print("  may write the SID at full turbo with no pacing.")
        return 0
    print("  At least one row disagrees. Compare 'tight' against 'burst25' "
          "against 'hammer8'")
    print("  at 64 MHz: the first pattern that fails says how tightly writes "
          "have to be paced.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Run src/irqtest.asm on a C64 Ultimate: can the engine take interrupts?

    python3 tools/irqtest.py 192.168.1.65 build/irqtest.prg

A music player has to tick at 50 Hz while the main loop runs at 25 fps, so it
belongs in an interrupt -- and the engine has never taken one. `main.asm`
opens with `sei` and the BSP walk flips $01 between $35 and $34 to read the
tables under the I/O space, so an interrupt landing inside one of those
windows returns to code whose banking assumption is wrong.

This drives the PRG through four modes and reports what each one measured:

  0  correct handler        mismatches must stay at 0
  1  handler restores $35   mismatches must CLIMB -- the positive control,
                            without which a zero in mode 0 proves nothing
  2  interrupts off         the loop rate that makes mode 0's rate mean
                            something
  3  correct handler + a 25-register SID burst -- what a player call costs,
     and whether the Ultimate stalls a 64 MHz CPU on a 1 MHz device

See src/irqtest.asm for the method.
"""

from __future__ import annotations

import argparse
import sys
import time

from u64 import Ultimate, U64Error, add_host_args

RESULTS = 0x0C00        # must match `.const RESULTS` in src/irqtest.asm
OFF_MODE = 3
OFF_IRQ = 4
OFF_LOOP = 8
OFF_BAD = 12
OFF_BADVAL = 16
OFF_BADIDX = 17
OFF_INWIN = 20
OFF_CURMODE = 24
OFF_READY = 25

CPU_HZ = 64_000_000     # speed index 15 on a C64 Ultimate
FRAME_MS = 39.9         # the engine's frame: two PAL frames (defs.asm)
PLAYS_PER_FRAME = 2     # a 50 Hz player against a 25 fps frame


class Sample:
    def __init__(self, raw: bytes, t: float):
        self.t = t
        self.irq = u24(raw, OFF_IRQ)
        self.loop = u24(raw, OFF_LOOP)
        self.bad = u24(raw, OFF_BAD)
        self.inwin = u24(raw, OFF_INWIN)
        self.badval = raw[OFF_BADVAL]
        self.badidx = raw[OFF_BADIDX]


def u24(raw: bytes, off: int) -> int:
    return raw[off] | (raw[off + 1] << 8) | (raw[off + 2] << 16)


def run_mode(u: Ultimate, mode: int, seconds: float, settle: float = 0.4):
    """Apply a mode, wait for the machine to confirm it, then measure."""
    u.writemem(RESULTS + OFF_MODE, bytes([mode]))
    deadline = time.monotonic() + 5.0
    while True:
        raw = u.readmem(RESULTS, 32)
        if raw[OFF_CURMODE] == mode:
            break
        if time.monotonic() > deadline:
            raise U64Error(f"the machine never applied mode {mode} "
                           f"(it reports {raw[OFF_CURMODE]})")
        time.sleep(0.1)
    time.sleep(settle)
    a = Sample(u.readmem(RESULTS, 32), time.monotonic())
    time.sleep(seconds)
    b = Sample(u.readmem(RESULTS, 32), time.monotonic())
    return a, b


def rates(a: Sample, b: Sample):
    dt = b.t - a.t
    return ((b.irq - a.irq) / dt, (b.loop - a.loop) / dt,
            b.bad - a.bad, b.inwin - a.inwin, dt)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("prg", nargs="?", default="build/irqtest.prg")
    ap.add_argument("--seconds", type=float, default=5.0,
                    help="measurement window per mode (default 5)")
    ap.add_argument("--control-seconds", type=float, default=2.0,
                    help="window for the mode-1 positive control (default 2)")
    ap.add_argument("--warmup", type=float, default=3.0,
                    help="seconds to discard after run_prg (default 3)")
    ap.add_argument("--recheck", action="store_true",
                    help="measure mode 0 again at the end; the two readings "
                         "must agree or the run drifted")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password, timeout=60)
    try:
        with open(args.prg, "rb") as fh:
            u.run_prg(fh.read())

        deadline = time.monotonic() + 30.0
        while True:
            raw = u.readmem(RESULTS, 32)
            if raw[0:3] == b"IQ\x01" and raw[OFF_READY] == 0xFF:
                break
            if time.monotonic() > deadline:
                print(f"error: irqtest never came up "
                      f"(magic={raw[0:3]!r} ready={raw[OFF_READY]:#04x}). "
                      f"A machine that wedged here has failed the test: it "
                      f"took an interrupt through a vector that was not there.",
                      file=sys.stderr)
                return 2
            time.sleep(0.3)

        # Discard the first seconds after run_prg. The Ultimate is still
        # finishing its own post-reset housekeeping and the loop rate reads
        # low -- the same transient u64push.py drops when measuring frames
        # (IMPLEMENTATION_PLAN.md §9). Measured here first: without this the
        # first mode sampled came out 40% slower than every later one, which
        # made an interrupt look like it cost 216 us instead of 9.
        print(f"settling for {args.warmup:.0f} s (post-reset transient)")
        u.writemem(RESULTS + OFF_MODE, bytes([0]))
        time.sleep(args.warmup)

        print("mode 0: correct handler, interrupts on")
        m0 = rates(*run_mode(u, 0, args.seconds))
        print("mode 2: interrupts off")
        m2 = rates(*run_mode(u, 2, args.seconds))
        print("mode 3: correct handler + a 25-register SID burst")
        m3 = rates(*run_mode(u, 3, args.seconds))
        print("mode 1: handler restores the wrong bank (positive control)")
        m1 = rates(*run_mode(u, 1, args.control_seconds))
        m0b = None
        if args.recheck:
            print("mode 0 again: the two readings must agree")
            m0b = rates(*run_mode(u, 0, args.seconds))
        u.writemem(RESULTS + OFF_MODE, bytes([0]))
        final = u.readmem(RESULTS, 32)
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    print()
    print(f"{'mode':>26} {'irq/s':>9} {'loops/s':>10} {'in-window':>10} "
          f"{'mismatches':>11}")
    rows = [("0  correct handler", m0),
            ("2  interrupts off", m2),
            ("3  correct + SID burst", m3),
            ("1  wrong bank restored", m1)]
    if m0b is not None:
        rows.append(("0  correct handler (again)", m0b))
    for name, m in rows:
        irq, loop, bad, inwin, dt = m
        frac = f"{inwin / (irq * dt) * 100:.0f}%" if irq * dt else "-"
        print(f"{name:>26} {irq:>9.0f} {loop:>10.0f} {frac:>10} {bad:>11}")

    irq0, loop0, bad0, inwin0, dt0 = m0
    irq2, loop2, bad2, _, _ = m2
    irq3, loop3, bad3, _, _ = m3
    irq1, _, bad1, _, _ = m1

    print()
    ok = True

    if bad0 != 0:
        ok = False
        print(f"  FAIL  mode 0 saw {bad0} canary mismatches. A handler that "
              f"saves and restores $01")
        print(f"        is NOT sufficient -- last bad byte {final[OFF_BADVAL]:#04x} "
              f"at index {final[OFF_BADIDX]}.")
    else:
        print(f"  pass  mode 0: {inwin0} of {int(irq0 * dt0)} interrupts landed "
              f"inside a BANK_RAM window,")
        print(f"        and not one of them corrupted a read. Saving $01 in the "
              f"handler is enough.")

    if bad1 <= 0:
        ok = False
        print(f"  FAIL  mode 1 saw no mismatches either, so this test cannot "
              f"see the failure")
        print(f"        it is looking for and mode 0's zero means nothing. "
              f"Do not trust the pass above.")
    else:
        print(f"  pass  mode 1: {bad1} mismatches when the handler restores the "
              f"wrong bank, so the")
        print(f"        test does detect the failure mode 0 did not have.")

    if loop2 <= 0:
        ok = False
        print("  FAIL  mode 2 completed no loops; the interrupt-off baseline "
              "is missing.")
    else:
        cost = 1.0 / loop2                      # seconds per loop pass
        for label, irq, loop in (("interrupt alone", irq0, loop0),
                                 ("interrupt + SID burst", irq3, loop3)):
            if irq <= 0:
                continue
            busy = 1.0 - loop * cost            # fraction of a second lost
            per = busy / irq                    # seconds per interrupt
            print(f"  cost  {label}: {per * 1e6:.1f} us "
                  f"({per * CPU_HZ:.0f} cycles at 64 MHz)")
            print(f"        {PLAYS_PER_FRAME} of these per {FRAME_MS:.0f} ms "
                  f"frame = {per * 1e3 * PLAYS_PER_FRAME:.3f} ms, "
                  f"{per * PLAYS_PER_FRAME * 1e3 / FRAME_MS * 100:.2f}% of "
                  f"the frame")

    print()
    if ok:
        print("  Interrupts are safe in the engine's banking scheme, the RAM "
              "vector at $fffe")
        print("  works with the KERNAL banked out, and the cost is measured "
              "rather than assumed.")
        return 0
    print("  At least one assertion failed -- read the FAIL lines above before "
          "designing around this.")
    return 1


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""Cross-check `tools/cpu6502.py` against an independent 6502 core.

    python3 tools/cputest.py assets/DooM_Medley.sid

Why: `sidstream.py`'s whole output is decided by an emulator written for this
project, and a wrong emulator does not fail -- it produces music that is
subtly wrong, or silence, and neither is distinguishable from a bad player
without a second opinion. This is that second opinion.

The method is the one this project keeps coming back to (IMPLEMENTATION_PLAN
§11, §14): run the same workload through two implementations and diff, and
include a positive control so a pass cannot be the result of the test being
blind. The control here is `--break-it`, which perturbs one flag in our core
and must make the comparison fail.

Requires `py65` (`pip install py65`). It is a dev-only check: neither the
build nor `make check` depends on it, because neither may assume a network.
Both tunes in `assets/` use only documented opcodes -- `cpu6502.py`'s
undocumented set is therefore *not* covered here, and is not exercised by
them either.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from cpu6502 import Cpu6502                                    # noqa: E402
from sidstream import C64Bus, SidFile, FRAME_SIZE, SENTINEL    # noqa: E402


class Py65Memory:
    """Adapts a C64Bus to py65's list-like memory protocol."""

    def __init__(self, bus):
        self.bus = bus

    def __getitem__(self, addr):
        if isinstance(addr, slice):
            return [self.bus.read(a) for a in range(addr.start, addr.stop)]
        return self.bus.read(addr)

    def __setitem__(self, addr, val):
        if isinstance(addr, slice):
            for i, a in enumerate(range(addr.start, addr.stop)):
                self.bus.write(a, val[i])
        else:
            self.bus.write(addr, val)

    def __len__(self):
        return 0x10000


def trace_ours(sid, ticks, break_it=False):
    bus = C64Bus()
    cpu = Cpu6502(bus)
    bus.cpu = cpu
    bus.ram[sid.load:sid.load + len(sid.data)] = sid.data
    if break_it:
        # positive control: make ADC forget the carry in
        cpu._adc = lambda v, c=cpu: Cpu6502._adc(c, v & 0xFE)

    def call(addr, acc=0):
        cpu.a, cpu.x, cpu.y, cpu.sp, cpu.p = acc, 0, 0, 0xFD, 0x24
        cpu.pc = addr
        cpu.push((SENTINEL - 1) >> 8)
        cpu.push((SENTINEL - 1) & 0xFF)
        cpu.run_until(SENTINEL)

    call(sid.init, max(0, sid.start_song - 1))
    out = []
    for _ in range(ticks):
        call(sid.play)
        out.append(bytes(bus.sid[:FRAME_SIZE]))
    return out


def trace_py65(sid, ticks):
    from py65.devices.mpu6502 import MPU

    bus = C64Bus()
    bus.ram[sid.load:sid.load + len(sid.data)] = sid.data
    mpu = MPU(memory=Py65Memory(bus))
    bus.cpu = mpu                       # exposes .cycles, which py65 also has

    def call(addr, acc=0):
        mpu.a, mpu.x, mpu.y, mpu.sp, mpu.p = acc, 0, 0, 0xFD, 0x24
        mpu.pc = addr
        ret = SENTINEL - 1
        bus.write(0x0100 | mpu.sp, ret >> 8)
        mpu.sp -= 1
        bus.write(0x0100 | mpu.sp, ret & 0xFF)
        mpu.sp -= 1
        steps = 0
        while mpu.pc != SENTINEL:
            mpu.step()
            steps += 1
            if steps > 2_000_000:
                raise RuntimeError("py65 ran away")

    call(sid.init, max(0, sid.start_song - 1))
    out = []
    for _ in range(ticks):
        call(sid.play)
        out.append(bytes(bus.sid[:FRAME_SIZE]))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sid", nargs="?", default="assets/DooM_Medley.sid")
    ap.add_argument("--ticks", type=int, default=2000)
    ap.add_argument("--break-it", action="store_true",
                    help="the positive control: perturb our core; must FAIL")
    args = ap.parse_args(argv)

    try:
        import py65                                            # noqa: F401
    except ImportError:
        print("cputest: py65 is not installed (pip install py65); skipping",
              file=sys.stderr)
        return 77

    sid = SidFile(args.sid)
    ours = trace_ours(sid, args.ticks, args.break_it)
    theirs = trace_py65(sid, args.ticks)

    bad = [i for i, (a, b) in enumerate(zip(ours, theirs)) if a != b]
    print(f"cputest: {os.path.basename(args.sid)}  {args.ticks} ticks x "
          f"{FRAME_SIZE} registers")
    if not bad:
        print("  identical to py65" + ("  -- BUT --break-it was set, so this "
                                       "is a FAILED control" if args.break_it
                                       else ""))
        return 1 if args.break_it else 0

    i = bad[0]
    print(f"  {len(bad)} of {len(ours)} ticks differ; first at tick {i}")
    print(f"    ours   {ours[i].hex(' ')}")
    print(f"    py65   {theirs[i].hex(' ')}")
    if args.break_it:
        print("  control passed: a broken core is detected")
        return 0
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

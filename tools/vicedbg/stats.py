#!/usr/bin/env python3
"""Frame-time and renderer-workload statistics from a running x64sc.

    python3 tools/vicedbg/stats.py [port] [sample_seconds]

Reports milliseconds per frame, and -- if the build has INSTRUMENT = 1 in
src/instrument.asm -- what the traversal touched to produce each of those
frames.

Two things make this work under `-warp`, where wall-clock seconds mean
nothing:

  * The clock is the emulated one. src/clock.asm runs CIA2 Timer B as a
    millisecond counter, and this reads it over the monitor, so a 3-second
    wall-clock sample in warp reports the emulated milliseconds that actually
    elapsed -- at 1 MHz that is the real cost of the frame on a 1 MHz machine.

  * The counters never reset. They are free-running 24-bit accumulators, so
    two readings divided by the frameCnt delta between them give per-frame
    averages without having to catch a frame boundary.

Attaching the binary monitor halts the CPU, and a halted CPU stops the CIA
too, so the pause between the two readings does not pollute the measurement.
"""
import sys
import time

FRAME_CNT = 0x0F40          # `.const frameCnt` in src/defs.asm
CIA2_TBLO = 0xDD06          # `.const CIA2_TBLO`, the millisecond clock
BANK_RAM = 1
BANK_IO = 3

# `.const cnt*` in src/instrument.asm -- name, address, and what it is per what.
COUNTERS = [
    ("nodes descended",       0x98E4),
    ("subsectors drawn",      0x98E7),
    ("segs considered",       0x98EA),
    ("  rejected: near plane", 0x98ED),
    ("  rejected: off screen", 0x98F0),
    ("  skipped: backfacing",  0x98F3),
    ("subtrees sphere-culled", 0x98F6),
    ("subsectors sphere-culled", 0x98F9),
    ("span pixels",           0x98FC),
]


def sample(m):
    """One (frames, ms, counters) reading. Leaves the machine running."""
    frames = int.from_bytes(m.mem_get(FRAME_CNT, FRAME_CNT + 1, bank=BANK_RAM), "little")
    ms = int.from_bytes(m.mem_get(CIA2_TBLO, CIA2_TBLO + 1, bank=BANK_IO), "little")
    lo, hi = COUNTERS[0][1], COUNTERS[-1][1] + 2
    raw = m.mem_get(lo, hi, bank=BANK_RAM)
    counts = [int.from_bytes(raw[a - lo:a - lo + 3], "little") for _, a in COUNTERS]
    m.exit_mon()
    return frames, ms, counts


# Every quantity read here is a modulo counter -- 16 bits for the frame count
# and the clock, 24 for the workload counters -- so the run is sampled in short
# steps and the wrapped differences are summed. One step must stay well inside
# the narrowest range, which is the clock's 65.5 s of emulated time. Under warp
# that is only a few seconds of wall clock at E1M1's ~4 s/frame, which is how
# the first version of this silently reported 119 ms/frame for a 3.9 s one.
POLL = 2.0


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6510
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 20.0
    settle = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0

    from probe import connect
    m = connect(port)
    frames = elapsed = 0
    totals = [0] * len(COUNTERS)
    try:
        m.exit_mon()
        time.sleep(settle)              # let boot and the first frames pass
        f0, ms0, c0 = sample(m)
        deadline = time.time() + seconds
        while time.time() < deadline:
            time.sleep(POLL)
            f1, ms1, c1 = sample(m)
            frames += (f1 - f0) & 0xFFFF
            elapsed += (ms0 - ms1) & 0xFFFF     # Timer B counts down
            totals = [t + ((b - a) & 0xFFFFFF) for t, a, b in zip(totals, c0, c1)]
            f0, ms0, c0 = f1, ms1, c1
    finally:
        m.quit()

    if frames == 0:
        print(f"stats: no frames completed in {elapsed} ms -- the engine is "
              f"stuck, or `settle` was too short")
        return 1

    print(f"frames {frames}   emulated {elapsed} ms   "
          f"{elapsed / frames:.0f} ms/frame   {1000.0 * frames / elapsed:.2f} fps")

    if not any(totals):
        print("counters: all zero -- build with INSTRUMENT = 1 in src/instrument.asm")
        return 0
    print("\nper frame:")
    for (name, _), total in zip(COUNTERS, totals):
        print(f"  {name:22s} {total / frames:10.1f}")
    return 0


if __name__ == "__main__":
    sys.exit(main() or 0)

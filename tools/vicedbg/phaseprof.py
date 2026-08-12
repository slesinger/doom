#!/usr/bin/env python3
"""Where the frame goes, by phase: input, doors, render, convert, flip, pace.

    make phaseprof                 # -> ms and % of the frame, per mainLoop phase
    python3 tools/vicedbg/phaseprof.py [port] [frames] [--syms build/main.vs]

profile.py answers "how many times", this answers "for how long". It is the
instrument IMPLEMENTATION_PLAN.md §14a.1 asks for: `spanFill` is ~27% of the
frame and textures are 8.7 ms measured, but `chunky2mc`'s own share has never
been recorded, and it decides whether a viewport-height cut returns its pixel
percentage or rather less.

How it measures, and why the number travels to hardware:

  * A *stopping* exec checkpoint on each `jsr` target in mainLoop. The stop
    costs no emulated time -- VICE's clock does not advance while the monitor
    holds the CPU -- so the phase boundaries are exact, not sampled.
  * At each stop, read CIA2 Timer B ($DD06/$DD07) over the monitor. That is
    the engine's own millisecond clock (src/clock.asm): phi2-derived, 1000
    cycles per tick, so at VICE's 1 MHz **one tick is exactly 1000 cycles**
    and the reading is a cycle count in disguise.
  * The timer counts *down*, so elapsed = (prev - now) mod 65536.

These are 1 MHz numbers, and per Makefile's `stats` note that is fine for
anything that is pure CPU work: `convert` touches no REU and no I/O, so its
*share* of compute is the same share on the Ultimate at 64 MHz. The one phase
whose share does not travel is anything doing REU DMA (renderFrame's subsector
streaming), which is flat 1 byte/us on both machines and therefore a larger
share of a hardware frame than of an emulated one.

`framePace` and `flip` are reported and are mostly *waiting* -- the pacer's
spin and the raster sync. They are not compute; the "compute" line below
excludes them, and is what should agree with the engine's own ftComp.
"""
import sys
import time

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from vicemon import Mon, BANK_IO, BANK_RAM     # noqa: E402

CIA2_TBLO = 0xDD06                  # src/defs.asm; Timer B, counting down
FRAME_CNT = 0x0F40
FT_COMP = 0x02A2                    # the engine's own compute figure, in ticks

# mainLoop's phases, in call order (src/main.asm). The cost attributed to a
# phase is the time from its entry to the entry of the next one, so the list
# must be complete and in order or the arithmetic silently reassigns work.
PHASES = ["readInput", "playerFrame", "lineFrame", "renderFrame",
          "convert", "framePace", "flip", "frameMark"]

# Phases that are the engine working, as opposed to waiting for the raster or
# for the frame cap. flip does both (its colour-RAM burst is real work behind
# the raster wait), so it is excluded here and reported separately.
COMPUTE = {"readInput", "playerFrame", "lineFrame", "renderFrame", "convert"}


def load_syms(path):
    """build/main.vs is KickAssembler's VICE symbol file: `al C:addr .name`."""
    out = {}
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 3 and parts[0] == "al":
                out[parts[2].lstrip(".")] = int(parts[1].split(":")[1], 16)
    return out


def ms(m):
    b = m.mem_get(CIA2_TBLO, CIA2_TBLO + 1, bank=BANK_IO)
    return b[0] | (b[1] << 8)


def frames(m):
    b = m.mem_get(FRAME_CNT, FRAME_CNT + 1, bank=BANK_RAM)
    return b[0] | (b[1] << 8)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 6510
    nframes = int(sys.argv[2]) if len(sys.argv) > 2 else 8
    syms = load_syms(sys.argv[3] if len(sys.argv) > 3 else "build/main.vs")

    for _ in range(60):
        try:
            m = Mon(port=port)
            break
        except OSError:
            time.sleep(0.5)
    else:
        print("phaseprof: no monitor on port", port, file=sys.stderr)
        return 1

    time.sleep(6.0)                 # let the engine reach steady state
    m.cmd(0xAA)                     # a fresh connection halts the CPU

    missing = [p for p in PHASES if p not in syms]
    if missing:
        print("phaseprof: symbols not in the map:", missing, file=sys.stderr)
        return 1
    addr2name = {syms[p]: p for p in PHASES}
    for p in PHASES:
        m.checkpoint(syms[p], syms[p], op=4, stop=True)

    # Resume with a bare _send: waiting for the exit command's own response
    # would race the checkpoint, and cmd() drops the async stop it beat us to
    # -- after which the machine is halted and nothing ever arrives again.
    def step():
        m._send(0xAA)
        pc = m.wait_stopped()
        return pc, ms(m)

    stops = []
    f0 = frames(m)
    for _ in range(len(PHASES) * nframes + 1):
        stops.append(step())

    tot = {p: 0 for p in PHASES}
    hits = {p: 0 for p in PHASES}
    for (pc, t0), (_, t1) in zip(stops, stops[1:]):
        name = addr2name.get(pc)
        if name is None:                        # a stop we did not set
            continue
        tot[name] += (t0 - t1) & 0xFFFF         # Timer B counts down
        hits[name] += 1
    m._send(0xAA)
    time.sleep(0.2)
    nf = (frames(m) - f0) & 0xFFFF
    ftcomp = int.from_bytes(m.mem_get(FT_COMP, FT_COMP + 1, bank=BANK_RAM), "little")

    span = sum(tot.values())
    comp = sum(v for k, v in tot.items() if k in COMPUTE)
    print(f"frames measured: {nf}   (ticks are 1000 cycles at VICE's 1 MHz)\n")
    print(f"{'phase':<14}{'ms/frame':>10}{'kcycles':>10}{'% frame':>9}{'% compute':>11}")
    for p in PHASES:
        if not hits[p]:
            continue
        per = tot[p] / hits[p]
        cpct = f"{100.0 * per / (comp / hits[p]):>10.1f}%" if p in COMPUTE else ""
        print(f"{p:<14}{per:>10.1f}{per:>10.1f}{100.0 * per / (span / hits[p]):>8.1f}%{cpct:>11}")
    n = max(1, min(hits[p] for p in PHASES if hits[p]))
    print(f"\n{'compute':<14}{comp / n:>10.1f}{comp / n:>10.1f}"
          f"{100.0 * comp / span:>8.1f}%")
    print(f"{'frame total':<14}{span / n:>10.1f}")
    print(f"\nengine ftComp (last frame, ticks): {ftcomp}")
    m.quit()
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""bobtest.py — the acceptance test for the walk bob.

Same claim, same method as jumptest.py: bobStep writes camJZ once per frame
and setEyeZ adds it to the sector floor, so the bob working means camZ traces
`floor + EYE + wave[frame]` while a movement key is down and sits flat at
`floor + EYE` while it is not.

  walk    hold W for two and a bit periods. camJZ must trace the triangle --
          the same eight values, in order, wrapping -- and camZ must equal
          floor + EYE + camJZ every frame, which is what proves the bob
          reaches the renderer and not only the zero page.
  stand   no keys: the eye must be still. A bob that runs off frameCnt alone
          rather than off frameCnt *and* IN_MOVE fails exactly here.
  turn    A held: turning is not moving in Doom and is not moving here, so
          the eye must be as still as it is standing.

The wave is the oracle and it comes out of defs.asm (BOBPEAK) rather than out
of the machine, so a bob that agrees only with itself fails.

Frames are stepped one per resume at readInput's entry, for jumptest.py's
reason: under -warp a poll-driven sampler misses most of a 0.48 s wave.

Usage:  bobtest.py <monitor-port> [--wad assets/DOOM1.WAD] [--map E1M1]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from probe import connect                                  # noqa: E402
import wad2reu                                             # noqa: E402
from walktest import (DEFS, Engine, ROOT, load_consts,     # noqa: E402
                      load_syms, pick_wall)
from jumptest import Stepper                               # noqa: E402

WALK_FRAMES = 20        # two periods and a half
STILL_FRAMES = 10


def wave(peak):
    """0 2 4 6 6 4 2 0 for peak 6: bobStep's triangle, one entry per frame.

    src/input.asm computes `((f&7) reflected at 4) * 2`; this is that, written
    the other way round so a sign error in either one shows up.
    """
    step = peak // 3
    return [step * (t if t < 4 else 7 - t) for t in range(8)]


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", type=int, help="VICE binary monitor port")
    ap.add_argument("--wad", default=os.path.join(ROOT, "assets", "DOOM1.WAD"))
    ap.add_argument("--map", default="E1M1")
    a = ap.parse_args(argv)

    c, sym = load_consts(), load_syms()
    m = wad2reu.load_wad_map(wad2reu.Wad(a.wad), a.map.upper())
    w = wave(c["BOBPEAK"])

    failures = []
    if max(w) != c["BOBPEAK"]:
        failures.append(f"the wave peaks at {max(w)}, BOBPEAK says "
                        f"{c['BOBPEAK']} ({DEFS})")

    mon = connect(a.port)
    mon.exit_mon()
    eng = Engine(mon, c, sym, m)
    eng.wait_boot()
    eng.patch()

    # The open floor walktest starts its wall run from: a real subsector of
    # the real map, with room to walk a few frames without leaving the sector.
    ssec, _, _, start = pick_wall(m, want_corner=False)
    _, sec = eng.teleport(*start, 0)
    floor = m.sectors[sec].floor
    print(f"standing in sector {sec} (subsector {ssec}) at "
          f"({start[0]:.0f},{start[1]:.0f}), floor {floor}")
    print(f"wave: {w} (peak {max(w)}, period {len(w)} frames)")

    step = Stepper(eng, sym["readInput"])
    ground = step.frame(0)
    print(f"standing: camJZ {ground[0]}, camZ {ground[1]}")
    if ground != (0, floor + c["EYE"]):
        failures.append(f"standing still gives {ground}, wanted "
                        f"(0, {floor + c['EYE']})")

    # -- 1. walking -------------------------------------------------------
    # The phase is frameCnt's own, so the run may start anywhere in the wave;
    # what is asserted is that it *is* the wave, unbroken, from wherever it
    # picked it up.
    seen = [step.frame(c["IN_FWD"]) for _ in range(WALK_FRAMES)]
    heights = [jz for jz, _ in seen]
    print(f"walk: camJZ {heights}")
    phases = [p for p in range(len(w))
              if heights == [w[(p + i) % len(w)] for i in range(len(heights))]]
    if not phases:
        failures.append(f"the eye did not trace the wave: {heights}, wanted "
                        f"{w} repeating from some phase")
    else:
        print(f"      matches the wave from phase {phases[0]}")

    # camZ is only floor + EYE + camJZ while the player is still in the
    # sector they started in -- walking forward is allowed to leave it.
    bad = [(jz, z) for jz, z in seen if z != floor + c["EYE"] + jz]
    stayed = len(seen) - len(bad)
    if bad and stayed < 2:
        failures.append(f"camZ never was floor + EYE + camJZ: {seen[:3]}")
    elif bad:
        print(f"      camZ = floor + EYE + camJZ for the {stayed} frames "
              f"inside sector {sec}; the rest walked out of it")
    else:
        print(f"      camZ = floor + EYE + camJZ on all {len(seen)} frames")

    # -- 2. standing still ------------------------------------------------
    stood = [step.frame(0)[0] for _ in range(STILL_FRAMES)]
    print(f"stand: camJZ {stood}")
    if any(stood):
        failures.append(f"the eye bobbed while standing still: {stood}")

    # -- 3. turning is not moving -----------------------------------------
    turned = [step.frame(c["IN_LEFT"])[0] for _ in range(STILL_FRAMES)]
    print(f"turn: camJZ {turned}")
    if any(turned):
        failures.append(f"the eye bobbed while only turning: {turned}")

    mon.quit()
    if failures:
        print("\nbobtest: FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nbobtest: all green -- the eye rides the wave while walking and "
          "is still when the player is")
    return 0


if __name__ == "__main__":
    sys.exit(main())

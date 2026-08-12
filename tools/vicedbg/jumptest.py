#!/usr/bin/env python3
"""jumptest.py — the acceptance test for jumping (SPACE).

Drives the *running engine* in VICE and judges the eye against the arc table
the image itself carries. That is the whole claim of the feature: camJZ walks
jumpTab once per frame and setEyeZ adds it to the sector floor, so a jump
working means exactly that camZ traces `floor + EYE + jumpTab[i]` and comes
back to `floor + EYE`.

  tap     press SPACE for exactly one frame. The eye must rise through the
          table's entries in order, peak at JUMPPEAK, and land -- and camZ
          must equal floor + EYE + camJZ at every frame, which is what proves
          the arc reaches the renderer and not only the zero page.
  ceiling the same run, checked against the sector's own ceiling. Nothing in
          the engine stops the eye rising through one, so the peak is the only
          thing that keeps it below: this asserts the margin exists here.
  hold    hold SPACE through two arcs. The take-off test is a level and not an
          edge, so this must bunny-hop: back to the floor between arcs, and
          never above JUMPPEAK. A press taken in mid-air would restart the arc
          and show up as a peak that never comes down.

WHY THIS ONE STEPS THE ENGINE AND walktest DOES NOT

walktest samples once per frame by polling frameCnt, and misses frames when it
does -- it counts them and calls them `skipped`, because a path with a gap in
it is still a path. That does not survive here. Under -warp the emulator can
run *dozens* of frames between two monitor round trips, and the whole arc is
seven: a poll-driven tap released the key after an entire jump had come and
gone, and read zero every time. So this test stops the CPU at readInput's own
entry, one frame per resume, and writes the key while it is halted. Every
frame of the arc is then observed by construction.

The other patches are walktest.py's, unchanged.

Usage:  jumptest.py <monitor-port> [--wad assets/DOOM1.WAD] [--map E1M1]
"""
import argparse
import os
import re
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from probe import connect                                  # noqa: E402
import wad2reu                                             # noqa: E402
from walktest import (DEFS, Engine, ROOT, load_consts,     # noqa: E402
                      load_syms, pick_wall)

TAIL_FRAMES = 6         # frames watched after the arc's last entry
HOLD_FRAMES = 20        # two arcs and a little


def arc_from_source():
    """The jump table as src/input.asm writes it -- the test's oracle.

    Read out of the source rather than out of the machine, so that a wrong
    table in RAM fails instead of agreeing with itself. jumpStep stops at the
    first negative entry, so $ff ends it here too.
    """
    src = open(os.path.join(ROOT, "src", "input.asm")).read()
    m = re.search(r"^jumpTab:\s*\n\s*\.byte\s+([^\n]+)$", src, re.M)
    if not m:
        raise SystemExit("jumptest: no jumpTab in src/input.asm")
    out = []
    for tok in m.group(1).split("//")[0].split(","):
        tok = tok.strip()
        v = int(tok[1:], 16) if tok.startswith("$") else int(tok)
        if v > 127:
            break
        out.append(v)
    return out


class Stepper:
    """One frame per resume, halted at readInput's entry in between.

    The checkpoint is on *readInput* and not on playerFrame, and that is the
    whole reason this test sees anything: readInput copies the patched
    immediate into zInput at the top of the frame, so a key written while the
    CPU sits inside playerFrame is already a frame too late. Stopped here, the
    key written now is the key this frame runs on.

    Everything talks to the monitor directly rather than through Engine.rd/wr:
    those end in exit_mon, which is exactly what this class exists to control.
    """

    def __init__(self, eng, addr):
        self.eng, self.mon = eng, eng.mon
        self.mon.checkpoint(addr, addr, op=4, stop=True)

    def _wait(self, timeout=30):
        """Resume, and block until VICE reports the stop (response type 0x11).

        The resume is sent raw rather than through Mon.exit_mon(): that one
        waits for its own response id and *drops* everything else on the way,
        which on a fast resume can swallow the stop event this is waiting for
        and hang the run (profile.py's notification-vs-query race). Here every
        response is looked at, and the first stop wins whichever order they
        arrive in.
        """
        self.mon._send(0xAA)
        deadline = time.time() + timeout
        while time.time() < deadline:
            _, _, blen, rtype, _, _ = struct.unpack("<BBIBBI",
                                                    self.mon._recvn(12))
            payload = self.mon._recvn(blen)
            if rtype == 0x11:
                return payload
        raise SystemExit("jumptest: the engine never came back to readInput")

    def frame(self, keys):
        """Run one frame with `keys` held. Returns (camJZ, camZ) after it.

        The CPU is stopped before readInput has run, so the key goes in now
        and what comes back is the state that frame left behind.
        """
        c = self.eng.c
        self.mon.mem_set(self.eng.input_imm, bytes([keys]))
        self._wait()
        jz = self.mon.mem_get(c["camJZ"], c["camJZ"])[0]
        z = self.mon.mem_get(c["camZ"], c["camZ"] + 1)
        z = z[0] | z[1] << 8
        return jz, (z - 65536 if z >= 32768 else z)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", type=int, help="VICE binary monitor port")
    ap.add_argument("--wad", default=os.path.join(ROOT, "assets", "DOOM1.WAD"))
    ap.add_argument("--map", default="E1M1")
    a = ap.parse_args(argv)

    c, sym = load_consts(), load_syms()
    m = wad2reu.load_wad_map(wad2reu.Wad(a.wad), a.map.upper())
    arc = arc_from_source()

    failures = []
    if max(arc) != c["JUMPPEAK"]:
        failures.append(f"jumpTab peaks at {max(arc)}, JUMPPEAK says "
                        f"{c['JUMPPEAK']} ({DEFS})")
    if len(arc) != c["JUMPFRAMES"]:
        failures.append(f"jumpTab has {len(arc)} entries, JUMPFRAMES says "
                        f"{c['JUMPFRAMES']}")

    mon = connect(a.port)
    mon.exit_mon()
    eng = Engine(mon, c, sym, m)
    eng.wait_boot()
    eng.patch()

    # Somewhere with room: the open floor walktest starts its wall run from,
    # which is a real subsector of the real map rather than the spawn point.
    ssec, _, _, start = pick_wall(m, want_corner=False)
    _, sec = eng.teleport(*start, 0)
    floor = m.sectors[sec].floor
    ceil = m.sectors[sec].ceil
    print(f"standing in sector {sec} (subsector {ssec}) at "
          f"({start[0]:.0f},{start[1]:.0f}), floor {floor}, ceiling {ceil}")
    print(f"arc: {arc} (peak {max(arc)}, {len(arc)} frames)")

    step = Stepper(eng, sym["readInput"])
    ground = step.frame(0)
    print(f"standing: camJZ {ground[0]}, camZ {ground[1]}")
    if ground != (0, floor + c["EYE"]):
        failures.append(f"standing still gives {ground}, wanted "
                        f"(0, {floor + c['EYE']})")

    # -- 1. one press -----------------------------------------------------
    seen = [step.frame(c["IN_USE"])]                    # the press, one frame
    for _ in range(len(arc) + TAIL_FRAMES - 1):
        seen.append(step.frame(0))
    heights = [jz for jz, _ in seen]
    want = arc + [0] * TAIL_FRAMES
    print(f"tap:  camJZ {heights}")
    print(f"want: camJZ {want}")
    if heights != want:
        failures.append(f"the eye did not walk the table: {heights}, wanted "
                        f"{want}")
    bad = [(jz, z) for jz, z in seen if z != floor + c["EYE"] + jz]
    if bad:
        failures.append(f"camZ is not floor + EYE + camJZ: {bad[:3]}")

    # -- 2. the ceiling ---------------------------------------------------
    top = max(z for _, z in seen)
    print(f"ceiling: eye reached {top}, ceiling {ceil} "
          f"({ceil - top} units of clearance)")
    if top >= ceil:
        failures.append(f"the eye reached {top} in a sector whose ceiling is "
                        f"{ceil}")

    # -- 3. the key held --------------------------------------------------
    held = [step.frame(c["IN_USE"])[0] for _ in range(HOLD_FRAMES)]
    print(f"hold: camJZ {held}")
    if max(held) > max(arc):
        failures.append(f"a held key pushed the eye to {max(held)}, above the "
                        f"table's {max(arc)}")
    if 0 not in held[1:]:
        failures.append("a held key never brought the player back to the "
                        "floor: the arc is being restarted in mid-air")
    if max(held) == 0:
        failures.append("a held key never left the floor at all")

    mon.quit()
    if failures:
        print("\njumptest: FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\njumptest: all green -- the eye walks the arc, clears the "
          "ceiling, and lands")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""doortest.py — the acceptance test for doors and moving sectors (§11).

Drives the *running engine* in VICE and judges it against SECTAB, the sector
height table the renderer and the collision test both read. That is the whole
claim of §11: nothing in render/ knows what a door is, so a door working means
exactly that two bytes in SECTAB moved and came back.

  door    stand in front of an E1M1 door, facing it, and hold the use key.
          Its ceiling must rise to the target the image carries, hold there,
          and come back down to where it started.
  ignore  hold the key in another room. The door must not move -- lnUse only
          looks at the segs of the subsector the player is standing in.

          Note what is *not* asserted: that turning away closes it off. The
          use scan tests which side of the seg the player is on, not where
          they are looking, so a door sharing their subsector opens whichever
          way they face. That is §11.2a's sector-based activation, and M3's
          geometric test is what would tighten it.
  walkover  step into a trigger sector of a walkover line and stand still.
          Its floor must move without a key ever being pressed. It runs first,
          because the door case teleports across sectors and a lift fires on
          the first one of those that lands in its trigger.

The patches are walktest.py's, for the same reasons and with one addition:
this test cannot NOP `jsr lineFrame`, since that is the code under test.

Usage:  doortest.py <monitor-port> [--wad assets/DOOM1.WAD] [--map E1M1]
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from probe import connect                                  # noqa: E402
import wad2reu                                             # noqa: E402
from walktest import (Engine, ROOT, angle_byte, inward_normal,  # noqa: E402
                      load_consts, load_syms, seg_dir)

# A door takes (target - closed) / DOOR_SPEED frames to open. E1M1's are ~72
# units of travel at 4 units a frame, and the wait is 71 frames on top.
OPEN_FRAMES = 40
HOLD_FRAMES = 30
CLOSE_FRAMES = 130
STAND_OFF = 48          # how far in front of the door the player stands


def find_seg(m, sector):
    """A two-sided seg with `sector` behind it, and the subsector it is in.

    This is the geometry lnUse is looking at from the other end: it walks the
    segs of the subsector the player stands in and asks which has a special
    sector behind it.
    """
    for ssec, segs in enumerate(m.subsectors):
        for s in segs:
            if s.back == sector:
                return ssec, s
    return None, None


def height(eng, c, sec, ceiling):
    """One sector height out of SECTAB, signed.

    Read with bank=1 ("ram"), not through the CPU's view: SECTAB is at $DC00,
    where the CPU sees CIA 2. A default read here returns timer values, which
    look exactly like a door thrashing at random.
    """
    base = c["SECTAB"] + (2 if ceiling else 0) * c["MAXSEC"]
    lo = eng.mon.mem_get(base + sec, base + sec, bank=1)[0]
    eng.mon.exit_mon()
    hi_a = base + c["MAXSEC"] + sec
    hi = eng.mon.mem_get(hi_a, hi_a, bank=1)[0]
    eng.mon.exit_mon()
    v = lo | hi << 8
    return v - 65536 if v >= 32768 else v


def sample(eng, c, sec, ceiling, frames, keys):
    """Hold `keys` for `frames` frames, sampling one height once per frame."""
    eng.wr(eng.input_imm, bytes([keys]))
    start = last = eng.frame()
    seen = [height(eng, c, sec, ceiling)]
    while last - start < frames:
        now = eng.frame()
        if now == last:
            continue
        last = now
        seen.append(height(eng, c, sec, ceiling))
    eng.wr(eng.input_imm, b"\x00")
    return seen


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", type=int, help="VICE binary monitor port")
    ap.add_argument("--wad", default=os.path.join(ROOT, "assets", "DOOM1.WAD"))
    ap.add_argument("--map", default="E1M1")
    a = ap.parse_args(argv)

    c, sym = load_consts(), load_syms()
    m = wad2reu.load_wad_map(wad2reu.Wad(a.wad), a.map.upper())

    # Line.kind carries the LF_ flags in its high nibble, the way the engine
    # stores it (wad2reu.pack_linedefs, and LK_MASK in src/defs.asm).
    doors = [ln for ln in m.lines if ln.kind & 0x0F == wad2reu.LK_DOOR]
    walkovers = [ln for ln in m.lines if ln.kind & wad2reu.LF_WALKOVER]
    if not doors:
        print("doortest: the map carries no doors -- nothing to test")
        return 0

    mon = connect(a.port)
    mon.exit_mon()
    eng = Engine(mon, c, sym, m)
    eng.wait_boot()
    eng.patch()

    failures = []

    # -- 1. a walkover trigger ------------------------------------------
    # First, because everything below teleports across sectors and a walkover
    # fires on whichever of those lands in its trigger.
    for ln in walkovers:
        ssec = next((i for i, s in enumerate(m.ssec_sector) if s == ln.trig),
                    None)
        if ssec is None:
            continue
        segs = m.subsectors[ssec]
        cx = sum((s.x0 + s.x1) / 2 for s in segs) / len(segs)
        cy = sum((s.y0 + s.y1) / 2 for s in segs) / len(segs)
        kind = {wad2reu.LK_LIFT: "lift", wad2reu.LK_FLOOR: "floor"}.get(
            ln.kind & 0x0F, ln.kind & 0x0F)
        print(f"walkover: {kind}, sector {ln.sector} floor "
              f"{m.sectors[ln.sector].floor} -> {ln.target}, entering trigger "
              f"sector {ln.trig} at ({cx:.0f},{cy:.0f})")
        before = height(eng, c, ln.sector, ceiling=False)
        eng.teleport(cx, cy, 0)
        moved = sample(eng, c, ln.sector, False, OPEN_FRAMES, 0)
        print(f"  floor: {before} -> {moved[-1]} (target {ln.target})")
        if moved[-1] != ln.target:
            failures.append(f"walking into sector {ln.trig} left the floor at "
                            f"{moved[-1]}, wanted {ln.target}")
        break
    else:
        print("walkover: no trigger sector has a subsector -- skipped")

    # -- 2. open a door, hold it, close it ------------------------------
    door = None
    for ln in doors:
        ssec, seg = find_seg(m, ln.sector)
        if seg is not None:
            door = (ln, ssec, seg)
            break
    if door is None:
        print("doortest: no door sector is behind a seg -- cannot reach one")
        return 1
    ln, ssec, seg = door
    tx, ty, _ = seg_dir(seg)
    nx, ny = inward_normal(seg)
    mx, my = (seg.x0 + seg.x1) / 2, (seg.y0 + seg.y1) / 2
    px, py = mx + nx * STAND_OFF, my + ny * STAND_OFF
    facing = angle_byte(-nx, -ny)

    closed = m.sectors[ln.sector].ceil
    print(f"door: sector {ln.sector}, ceiling {closed} -> {ln.target}, "
          f"seg ({seg.x0},{seg.y0})->({seg.x1},{seg.y1})")
    print(f"  player at ({px:.0f},{py:.0f}) facing {facing}")
    eng.teleport(px, py, facing)

    live = height(eng, c, ln.sector, ceiling=True)
    if live != closed:
        failures.append(f"door sector {ln.sector} starts at {live}, "
                        f"the image says {closed}")

    rising = sample(eng, c, ln.sector, True, OPEN_FRAMES, c["IN_USE"])
    print(f"  opening: {rising[0]} -> {rising[-1]} "
          f"(target {ln.target}) over {len(rising) - 1} frames")
    if rising[-1] != ln.target:
        failures.append(f"door reached {rising[-1]}, wanted {ln.target}")
    if any(b < a_ for a_, b in zip(rising, rising[1:])):
        failures.append("door ceiling went down while opening")

    holding = sample(eng, c, ln.sector, True, HOLD_FRAMES, 0)
    if set(holding) != {ln.target}:
        failures.append(f"door did not hold open: {sorted(set(holding))}")
    else:
        print(f"  holding at {ln.target} for {HOLD_FRAMES} frames")

    closing = sample(eng, c, ln.sector, True, CLOSE_FRAMES, 0)
    print(f"  closing: {closing[0]} -> {closing[-1]} (home {closed})")
    if closing[-1] != closed:
        failures.append(f"door came back to {closing[-1]}, wanted {closed}")

    # -- 3. the use key, pressed in another room ------------------------
    # The player's own subsector is the whole of what lnUse looks at, so a
    # press anywhere that does not border this door must leave it alone. This
    # is the assertion that the scan is bounded; the one it replaces -- turn
    # around and it stays shut -- is not true of sector-based activation and
    # was never segFacing's job (see the module docstring).
    sx, sy, _ = m.spawn
    eng.teleport(sx, sy, 0)
    elsewhere = sample(eng, c, ln.sector, True, OPEN_FRAMES, c["IN_USE"])
    print(f"  use at the spawn point: ceiling {elsewhere[0]} -> "
          f"{elsewhere[-1]}")
    if set(elsewhere) != {closed}:
        failures.append("a door in another room opened -- the use scan is not "
                        "bounded by the player's subsector")

    print()
    if failures:
        for f in failures:
            print(f"FAIL: {f}")
        return 1
    print("doortest: all green")
    return 0


if __name__ == "__main__":
    sys.exit(main())

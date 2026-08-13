#!/usr/bin/env python3
"""walktest.py — the acceptance test for sliding collision (§9.2).

Drives the *running engine* in VICE along two scripted paths and judges the
result against the map's own geometry:

  wall    walk into a long one-sided wall at 20 degrees and hold forward.
          Sliding must carry the player along the wall; M1's undo-the-move
          collision stopped dead here, which is the defect §9.2 exists to fix.
  corner  the same approach on a wall that ends in an inside corner, held
          until the player wedges. It must reach the corner (not stop at
          first contact) and must not end up on the far side of either wall.

The oracle is `tools/wad2reu.py`'s own map reader, so "did the player leak
through a wall" is answered against E1M1's linedefs rather than against a
screenshot: every frame-to-frame step is intersected with every one-sided seg
in the map, and any crossing fails the run.

Three patches go into the running machine over the binary monitor, all of them
to code and none to the collision path under test:

  * readInput becomes `lda #imm / sta zInput / rts`, so the host writes the
    key state directly into the immediate operand -- the engine has no other
    input path a host can reach (the keyboard matrix is read from $DC00/$DC01,
    and the monitor's keyboard feed only fills the KERNAL buffer, which the
    engine never looks at).
  * `jsr renderFrame` and `jsr convert` in mainLoop become NOPs. A rendered
    frame costs ~2.4 emulated seconds at 1 MHz, and this test does not look at
    a single pixel; without them a frame is framePace's 49 ms and the whole run
    takes seconds. movePlayer runs *before* renderFrame and streams its own
    segs, so nothing it depends on is being skipped.

Usage:  walktest.py <monitor-port> [--wad assets/DOOM1.WAD] [--map E1M1]
"""
import argparse
import math
import os
import re
import struct
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

from vicemon import Mon                                    # noqa: E402
from probe import connect                                  # noqa: E402
import wad2reu                                             # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEFS = os.path.join(ROOT, "src", "defs.asm")
SYMS = os.path.join(ROOT, "build", "main.vs")

APPROACH_DEG = 20.0         # how shallow the run into the wall is
WALL_FRAMES = 24
CORNER_FRAMES = 40
BOOT_TIMEOUT = 120.0


# ---------------------------------------------------------------- symbols
def load_consts():
    """The .const values from src/defs.asm -- the zero-page map is there and
    nowhere else, so this test cannot drift from the engine's own addresses."""
    out = {}
    pat = re.compile(r"^\.const\s+(\w+)\s*=\s*(\$[0-9a-fA-F]+|%[01]+|\d+)\s*(?://.*)?$")
    for line in open(DEFS):
        m = pat.match(line.strip())
        if m:
            v = m.group(2)
            if v.startswith("$"):
                out[m.group(1)] = int(v[1:], 16)
            elif v.startswith("%"):
                out[m.group(1)] = int(v[1:], 2)
            else:
                out[m.group(1)] = int(v)
    return out


def load_syms():
    out = {}
    for line in open(SYMS):
        m = re.match(r"al C:([0-9a-f]+)\s+\.(\S+)", line.strip())
        if m:
            out[m.group(2)] = int(m.group(1), 16)
    return out


# ---------------------------------------------------------------- geometry
def solid_segs(m):
    return [s for grp in m.subsectors for s in grp if s.back is None]


def seg_dir(s):
    dx, dy = s.x1 - s.x0, s.y1 - s.y0
    L = math.hypot(dx, dy)
    return dx / L, dy / L, L


def inward_normal(s):
    """Inside a subsector is cross < 0 (the front sector is on the right of a
    directed seg), which puts the interior on (ty, -tx)."""
    tx, ty, _ = seg_dir(s)
    return ty, -tx


def angle_byte(dx, dy):
    """The engine's 8-bit angle: 0 = east, counter-clockwise, forward =
    (cos a, sin a)."""
    return int(round(math.atan2(dy, dx) * 128.0 / math.pi)) & 0xFF


def crosses(p, q, s):
    """Does the step p->q cross seg s? Proper intersection only: touching an
    endpoint is what walking along a wall does."""
    def cr(ax, ay, bx, by, cx, cy):
        return (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    d1 = cr(p[0], p[1], q[0], q[1], s.x0, s.y0)
    d2 = cr(p[0], p[1], q[0], q[1], s.x1, s.y1)
    d3 = cr(s.x0, s.y0, s.x1, s.y1, p[0], p[1])
    d4 = cr(s.x0, s.y0, s.x1, s.y1, q[0], q[1])
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))


def pick_wall(m, want_corner):
    """The longest one-sided seg with room in front of it.

    With want_corner, it must also end in a corner that can actually wedge the
    player: the next one-sided seg of the same subsector must turn *into* the
    room (cross < 0, the same sign convention the collision test uses) and turn
    by at least 90 degrees (dot <= 0). A shallower corner is not a trap -- the
    slide carries straight on around it, which is correct behaviour and would
    make "did it reach the corner" the wrong question.
    """
    best = None
    for si, grp in enumerate(m.subsectors):
        for seg in grp:
            if seg.back is not None:
                continue
            tx, ty, L = seg_dir(seg)
            if L < 400:
                continue
            corner = None
            for o in grp:
                if o is seg or o.back is not None:
                    continue
                if (o.x0, o.y0) != (seg.x1, seg.y1):
                    continue
                ox, oy, _ = seg_dir(o)
                if tx * oy - ty * ox < 0 and tx * ox + ty * oy <= 0:
                    corner = o
                    break
            if want_corner and corner is None:
                continue
            nx, ny = inward_normal(seg)
            # stand a third of the way along, a little off the wall
            sx = seg.x0 + tx * L / 3.0 + nx * 40.0
            sy = seg.y0 + ty * L / 3.0 + ny * 40.0
            if wad2reu.descend(m, int(round(sx)), int(round(sy))) != si:
                continue
            if best is None or L > best[0]:
                best = (L, si, seg, corner, (sx, sy))
    if best is None:
        raise SystemExit("walktest: no suitable wall found in this map")
    return best[1], best[2], best[3], best[4]


# ---------------------------------------------------------------- machine
class Engine:
    def __init__(self, mon, c, sym, m):
        self.mon, self.c, self.sym, self.m = mon, c, sym, m
        self.cp = None              # the frame checkpoint, once run() sets it

    # Every monitor command halts the emulated CPU, and it stays halted until
    # the next exit_mon -- so each access here ends with one. Without it the
    # machine freezes on the first read and no frame ever completes.
    #
    # Once run() has installed the frame checkpoint the machine is *meant* to
    # stay halted between frames, and resuming here would run a frame nobody
    # asked for -- and queue a stop event that the next _wait would mistake
    # for its own. So from that point on these are plain reads and writes.
    def rd(self, addr, n=1):
        b = self.mon.mem_get(addr, addr + n - 1)
        if self.cp is None:
            self.mon.exit_mon()
        return b

    def word(self, addr):
        b = self.rd(addr, 2)
        v = b[0] | (b[1] << 8)
        return v - 0x10000 if v & 0x8000 else v

    def wr(self, addr, data):
        self.mon.mem_set(addr, data)
        if self.cp is None:
            self.mon.exit_mon()

    def wword(self, addr, v):
        v &= 0xFFFF
        self.wr(addr, bytes([v & 0xFF, v >> 8]))

    def frame(self):
        b = self.rd(self.c["frameCnt"], 2)
        return b[0] | (b[1] << 8)

    def wait_boot(self):
        t0 = time.time()
        while time.time() - t0 < BOOT_TIMEOUT:
            if self.rd(self.c["mapOK"])[0] == 1 and self.frame() > 1:
                return
            time.sleep(0.2)
        raise SystemExit("walktest: the engine never reported a loaded map")

    def patch(self):
        """readInput -> `lda #0 / sta zInput / rts`, and drop the two frame
        costs this test does not use. Verified against the symbols rather than
        assumed: the jsr operands must name renderFrame and convert."""
        self.input_imm = self.sym["readInput"] + 1
        self.wr(self.sym["readInput"],
                bytes([0xA9, 0x00, 0x85, self.c["zInput"], 0x60]))
        base = self.sym["mainLoop"]
        code = self.rd(base, 24)
        dropped = 0
        for off in range(0, 21, 3):
            if code[off] != 0x20:
                break
            target = code[off + 1] | (code[off + 2] << 8)
            if target in (self.sym["renderFrame"], self.sym["convert"]):
                self.wr(base + off, b"\xea\xea\xea")
                dropped += 1
        if dropped != 2:
            raise SystemExit(f"walktest: patched {dropped} of 2 frame costs -- "
                             "mainLoop is not the shape this test expects")

    def teleport(self, x, y, ang):
        """Place the player, subsector and sector together. The engine only
        re-locates itself inside a completed move, so a poked position with a
        stale camSsec would be tested against the wrong subsector's segs."""
        ssec = wad2reu.descend(self.m, int(round(x)), int(round(y)))
        sec = self.m.ssec_sector[ssec]
        self.wword(self.c["camX"], int(round(x)))
        self.wword(self.c["camY"], int(round(y)))
        self.wr(self.c["camA"], bytes([ang & 0xFF]))
        self.wr(self.c["camSec"], bytes([sec]))
        self.wword(self.c["camSsec"], ssec)
        self.wword(self.c["camZ"], self.m.sectors[sec].floor + self.c["EYE"])
        return ssec, sec

    def _wait(self, timeout=30):
        """Resume, and block until VICE reports the checkpoint stop (0x11).

        The resume is sent raw rather than through Mon.exit_mon(), which waits
        for its own response id and drops everything else on the way -- on a
        fast resume that swallows the stop event and hangs the run. This is
        jumptest.py's Stepper._wait, for the same reason.
        """
        self.mon._send(0xAA)
        deadline = time.time() + timeout
        while time.time() < deadline:
            _, _, blen, rtype, _, _ = struct.unpack("<BBIBBI",
                                                    self.mon._recvn(12))
            self.mon._recvn(blen)
            if rtype == 0x11:
                return
        raise SystemExit("walktest: the engine never came back to readInput")

    def pos(self):
        """camX/camY, both words in one read. They are adjacent ($50-$53)."""
        b = self.rd(self.c["camX"], 4)
        p = (b[0] | b[1] << 8, b[2] | b[3] << 8)
        return tuple(v - 0x10000 if v & 0x8000 else v for v in p)

    def run(self, frames, keys):
        """Hold `keys` for `frames` frames, sampling the position once per
        frame. Returns the path, starting at the position before the run.

        The sample is taken with the CPU stopped at the top of readInput, and
        that is not a detail: camX/camY are written *speculatively*. checkMove
        applies a move and then slides or undoes it if it crossed a wall, and
        §9.3's substepping does that four times a frame -- so a free-running
        sample can catch a position the player never actually stood at, a unit
        or two inside a wall, and the leak test below then reports a walk
        through solid geometry that never happened. Stopping the machine at
        one fixed point in the loop makes every sample a settled position and
        makes consecutive samples exactly one frame apart.
        """
        if self.cp is None:
            self.cp = self.mon.checkpoint(self.sym["readInput"],
                                          self.sym["readInput"], op=4,
                                          stop=True)
            self._wait()                        # arrive at the first stop
        path = [self.pos()]
        for _ in range(frames):
            self.wr(self.input_imm, bytes([keys]))
            self._wait()
            path.append(self.pos())
        self.wr(self.input_imm, b"\x00")
        return path, 0


# ---------------------------------------------------------------- scenarios
def leaks(path, solids):
    for p, q in zip(path, path[1:]):
        for s in solids:
            if crosses(p, q, s):
                return (p, q, s)
    return None


def report(name, path, skipped):
    moved = math.dist(path[0], path[-1])
    print(f"  {name}: {len(path) - 1} samples ({skipped} frames not sampled), "
          f"start {path[0]} end {path[-1]}, displacement {moved:.0f} units")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("port", type=int, help="VICE binary monitor port")
    ap.add_argument("--wad", default=os.path.join(ROOT, "assets", "DOOM1.WAD"))
    ap.add_argument("--map", default="E1M1")
    a = ap.parse_args(argv)

    c, sym = load_consts(), load_syms()
    m = wad2reu.load_wad_map(wad2reu.Wad(a.wad), a.map.upper())
    solids = solid_segs(m)
    speed = c["MOVE_SPEED"]

    mon = connect(a.port)
    mon.exit_mon()
    eng = Engine(mon, c, sym, m)
    eng.wait_boot()
    eng.patch()

    failures = []

    # -- 1. the shallow run along a wall --------------------------------
    _, seg, _, start = pick_wall(m, want_corner=False)
    tx, ty, L = seg_dir(seg)
    heading = (angle_byte(tx, ty) + round(APPROACH_DEG * 256 / 360)) & 0xFF
    print(f"wall run: seg ({seg.x0},{seg.y0})->({seg.x1},{seg.y1}), "
          f"{L:.0f} units, heading {heading} "
          f"({APPROACH_DEG:.0f} deg into it)")
    eng.teleport(*start, heading)
    path, skipped = eng.run(WALL_FRAMES, c["IN_FWD"])
    report("wall", path, skipped)

    along = (path[-1][0] - path[0][0]) * tx + (path[-1][1] - path[0][1]) * ty
    ideal = WALL_FRAMES * speed * math.cos(math.radians(APPROACH_DEG))
    print(f"  along the wall: {along:.0f} of an unobstructed {ideal:.0f} "
          f"({100 * along / ideal:.0f}%)")
    if along < 0.6 * ideal:
        failures.append(f"wall run slid {along:.0f} units, wanted "
                        f"{0.6 * ideal:.0f}+ (M1 would score ~0)")
    hit = leaks(path, solids)
    if hit:
        failures.append(f"wall run leaked: {hit[0]} -> {hit[1]} crosses {hit[2]}")

    # -- 2. the same, held into an inside corner ------------------------
    _, seg, corner, start = pick_wall(m, want_corner=True)
    tx, ty, L = seg_dir(seg)
    heading = (angle_byte(tx, ty) + round(APPROACH_DEG * 256 / 360)) & 0xFF
    cx, cy = seg.x1, seg.y1
    print(f"corner run: into ({cx},{cy}), where "
          f"({seg.x0},{seg.y0})->({cx},{cy}) meets "
          f"({corner.x0},{corner.y0})->({corner.x1},{corner.y1})")
    eng.teleport(*start, heading)
    path, skipped = eng.run(CORNER_FRAMES, c["IN_FWD"])
    report("corner", path, skipped)

    reach = math.dist(path[-1], (cx, cy))
    print(f"  ended {reach:.0f} units from the corner")
    if reach > 2 * speed + c["PLRAD"]:
        failures.append(f"corner run stuck {reach:.0f} units short of the "
                        f"corner (a wedged player stops within "
                        f"{2 * speed + c['PLRAD']})")
    hit = leaks(path, solids)
    if hit:
        failures.append(f"corner run leaked: {hit[0]} -> {hit[1]} crosses {hit[2]}")

    mon.quit()
    if failures:
        print("\nwalktest: FAILED")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("\nwalktest: all green -- slides along walls, wedges in corners, "
          "crosses nothing")
    return 0


if __name__ == "__main__":
    sys.exit(main())

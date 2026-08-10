#!/usr/bin/env python3
"""wad2reu.py — pack a Doom map into the engine's REU image.

    python3 tools/wad2reu.py assets/DOOM1.WAD -o build/assets.reu
    python3 tools/wad2reu.py --map TEST      -o build/testmap.reu
    python3 tools/wad2reu.py assets/DOOM1.WAD -o build/assets.reu --png build/assets-map.png

The output format is frozen in `docs/reu-format.md`; that document is the
contract and this file is one half of its implementation (`src/mapload.asm`
and `src/render/bsp.asm` are the other). If you change a layout here, change
it there first.

Two maps go through the same packers:

  E1M1  from DOOM1.WAD, using the WAD's own NODES/SSECTORS/SEGS. The BSP is
        id Software's; nothing here builds one.
  TEST  the three convex sectors of src/testmap.asm, run through a BSP builder
        in this file (§ build_bsp).

The test map exists because it separates "the converter is wrong" from "the
traversal is wrong". E1M1 is 732 segs across 237 subsectors; when the first
frame comes out garbled there is no way to tell which half did it. The test
map is 14 linedefs and its expected frame is already drawn, traced and
documented in `pipeline.md` §11.

Validation (on by default, --no-validate to skip) re-parses the finished image
with an independent reader and checks it against the structures that produced
it — see `docs/reu-format.md` §8 for the list. --png writes a top-down render
of the *decoded* blocks, which is the only check that catches geometry that
survived packing as valid-but-wrong.
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import sys
from collections import Counter

# ----------------------------------------------------------------------------
# Format constants. These MUST match src/defs.asm and docs/reu-format.md.
# ----------------------------------------------------------------------------

MAGIC = b"D64U"
VERSION = 2                     # 2 added the bounding spheres (SSEC_HDR, block 4)

HEADER_SIZE = 64
BLOCK_ALIGN = 256

MAXNODES = 240                  # capacity of the resident node arrays
MAXSEC = 96                     # capacity of the resident sector arrays
SSEC_STRIDE_SHIFT = 7           # 128-byte subsector slot
SSEC_STRIDE = 1 << SSEC_STRIDE_SHIFT
SEG_RECORD = 10

# The subsector slot header carries the subsector's bounding sphere as well as
# its seg count and sector, so that the engine can reject the whole subsector
# before the second DMA fetches any segs (docs/reu-format.md §5). Eight bytes
# leaves exactly twelve seg records in a 128-byte slot: 8 + 12*10 = 128.
SSEC_HDR = 8
MAX_SEGS_PER_SSEC = (SSEC_STRIDE - SSEC_HDR) // SEG_RECORD      # 12

# One bounding sphere per node, streamed: centre x, centre y, radius, each
# signed 16-bit, padded to a power-of-two stride so the engine's address
# arithmetic is three shifts and no multiply.
SPHERE_RECORD = 6
NODESPH_STRIDE = 8
NODESPH_SHIFT = 3

BLK_MAPINFO, BLK_NODES, BLK_SECTORS, BLK_SSECDATA, BLK_NODESPH = 0, 1, 2, 3, 4

# reuProbe (src/reu.asm) round-trips a 4-byte signature through REU RAM at boot,
# before the loader runs. The image's used region must not reach that address,
# or the probe destroys the header it is about to verify -- which it did, the
# first time this was wired up, with the probe still at REU offset 0.
# Matches REU_PROBE_ADDR/REU_PROBE_BANK in src/defs.asm: bank 0, $f000.
REU_PROBE_OFFSET = 0x00F000

# The image is padded to exactly this size, and it is not optional.
#
# VICE's -reuimage loads the file with util_file_load(), which fails unless the
# file is *exactly* the emulated REU size -- it prints "Reading REU image ...
# failed" to stderr, boots anyway with a zeroed REU, and the engine then reads
# a header full of nothing. That is the same silent-failure shape as `-default`
# switching the REU off (IMPLEMENTATION_PLAN.md §10), and it is caught the same
# way: mapload.asm verifies the magic and `make check` asserts mapOK.
#
# 128 KB is VICE's smallest REU and the smallest real 1750, so the Makefile
# runs -reusize 128 and one artifact serves both VICE and the Ultimate (whose
# REU Preload does not care about the size). It leaves the probe scratch at
# 64 KB comfortably inside. Raise both together if the image ever outgrows it.
REU_IMAGE_SIZE = 128 * 1024

LOAD_MAPINFO = 0x0E00
LOAD_NODES = 0xD000
LOAD_SECTORS = 0xDC00

MAPINFO_SIZE = 32
NO_BACK_SECTOR = 0xFF           # matches testmap.asm's wBack sentinel

MAPID_TEST, MAPID_E1M1 = 0, 1

# ----------------------------------------------------------------------------
# Ramp assignment — the M1 art-direction knob.
#
# chunky2mc.asm defines 16 ramps of 3 colours each; ramps 8-15 are currently
# duplicates of stone, so only 0-7 carry information. Filling the spares is an
# asm change and is out of scope for Milestone 1.
#
# Matching is by prefix, longest first, so STARTAN3 beats STAR*. Anything
# unmatched falls back to DEFAULT_RAMP and is reported by --report so a texture
# that quietly landed on the default can be spotted.
# ----------------------------------------------------------------------------

STONE, WOOD, FLESH, SKY, MOSS, VIOLET, METAL, FIRE = range(8)

RAMP_NAMES = ["stone", "wood", "flesh", "sky", "moss",
              "violet", "metal", "fire"] + [f"spare{i}" for i in range(8, 16)]

DEFAULT_RAMP = STONE

# Wall textures. E1M1 uses 32 distinct names; every one of them is covered here.
WALL_RAMPS = {
    # brown/tan structural — the bulk of E1M1's corridors
    "BROWN1": WOOD, "BROWN144": WOOD, "BROWN96": WOOD,
    "BRNBIGL": WOOD, "BRNBIGR": WOOD, "BRNBIGC": WOOD,
    "STARTAN": WOOD,                     # STARTAN1, STARTAN3
    # brown-green: split off from plain brown so the two read apart
    "BROWNGRN": MOSS,
    "SLADWALL": MOSS, "NUKE24": MOSS,    # slime and nukage surrounds
    # grey structural
    "STARG": STONE, "STARGR": STONE,
    "SUPPORT2": METAL, "DOORSTOP": METAL, "DOORTRAK": METAL,
    "STEP1": METAL, "STEP6": METAL,
    "BIGDOOR": METAL, "DOOR3": METAL, "EXITDOOR": METAL, "SW1STRTN": METAL,
    # computers and tech panels — blue, and the strongest landmark in E1M1
    "TEKWALL": SKY, "COMPTILE": SKY, "COMPUTE2": SKY, "COMPTALL": SKY,
    "COMPSPAN": SKY, "PLANET1": SKY,
    # lit things
    "LITE3": FIRE, "EXITSIGN": FIRE,
}

# Flats (floors and ceilings).
FLAT_RAMPS = {
    "FLOOR4_8": STONE, "FLOOR5_1": STONE, "FLOOR5_2": STONE,
    "FLOOR7_1": STONE, "FLOOR7_2": STONE, "FLOOR6_2": STONE, "FLOOR1_1": STONE,
    "CEIL3_5": STONE, "CEIL5_1": STONE, "CEIL5_2": STONE,
    "FLAT18": STONE, "FLAT23": STONE,
    "FLAT14": WOOD, "FLAT5_5": WOOD,
    "FLAT20": METAL, "STEP2": METAL,
    "NUKAGE3": MOSS,
    "F_SKY1": SKY,
    "TLITE6": FIRE,                      # TLITE6_1/4/5/6
}


def pick_ramp(name: str, table: dict, misses: Counter) -> int:
    """Longest-prefix match of a Doom texture/flat name onto a ramp id."""
    name = name.upper()
    best = None
    for key in table:
        if name.startswith(key) and (best is None or len(key) > len(best)):
            best = key
    if best is None:
        misses[name] += 1
        return DEFAULT_RAMP
    return table[best]


def light_to_intensity(light: int) -> int:
    """WAD sector light level (0-255) -> the matrix byte's intensity nibble.

    Clamped to 2..15 rather than 0..15 for the same reason `pipeline.md` §8.6
    clamps wall shading: intensity 0 and 1 dissolve into the black background,
    and a floor that vanishes reads as a hole in the world rather than as a
    dark room.
    """
    return 2 + int(round(max(0, min(255, light)) / 255.0 * 13))


# How many intensity steps a ceiling sits below its sector's floor. See where
# it is applied for why this exists at all.
CEIL_DARKEN = 4


# ----------------------------------------------------------------------------
# WAD reading
# ----------------------------------------------------------------------------

MAP_LUMPS = ("THINGS", "LINEDEFS", "SIDEDEFS", "VERTEXES", "SEGS",
             "SSECTORS", "NODES", "SECTORS", "REJECT", "BLOCKMAP")


class Wad:
    def __init__(self, path: str):
        self.data = open(path, "rb").read()
        magic, count, dirofs = struct.unpack_from("<4sii", self.data, 0)
        if magic not in (b"IWAD", b"PWAD"):
            raise ValueError(f"{path}: not a WAD (magic {magic!r})")
        self.dir = []
        for i in range(count):
            ofs, size, raw = struct.unpack_from("<ii8s", self.data, dirofs + i * 16)
            self.dir.append((raw.rstrip(b"\0").decode("ascii", "replace"), ofs, size))

    def map_lumps(self, mapname: str) -> dict:
        try:
            start = next(i for i, e in enumerate(self.dir) if e[0] == mapname)
        except StopIteration:
            raise ValueError(f"no map lump {mapname!r} in WAD")
        out = {}
        for name, ofs, size in self.dir[start + 1: start + 11]:
            if name in MAP_LUMPS:
                out[name] = (ofs, size)
            elif out:
                break
        return out

    def records(self, lumps: dict, name: str, fmt: str) -> list:
        ofs, size = lumps[name]
        step = struct.calcsize(fmt)
        if size % step:
            raise ValueError(f"{name}: {size} bytes is not a multiple of {step}")
        return [struct.unpack_from(fmt, self.data, ofs + i * step)
                for i in range(size // step)]


# ----------------------------------------------------------------------------
# The in-memory map, in the form the packers want. Both the WAD path and the
# test-map path produce one of these, and nothing downstream can tell which.
# ----------------------------------------------------------------------------

class Seg:
    __slots__ = ("x0", "y0", "x1", "y1", "front", "back", "ramp")

    def __init__(self, x0, y0, x1, y1, front, back, ramp):
        self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.front = front              # sector id
        self.back = back                # sector id, or None if one-sided
        self.ramp = ramp

    def __repr__(self):
        return (f"Seg(({self.x0},{self.y0})->({self.x1},{self.y1}) "
                f"f={self.front} b={self.back} r={self.ramp})")


class Node:
    __slots__ = ("px", "py", "dx", "dy", "right", "left")

    def __init__(self, px, py, dx, dy, right, left):
        self.px, self.py, self.dx, self.dy = px, py, dx, dy
        self.right, self.left = right, left     # raw Doom child words


class Sector:
    __slots__ = ("floor", "ceil", "fbyte", "cbyte")

    def __init__(self, floor, ceil, fbyte, cbyte):
        self.floor, self.ceil = floor, ceil
        self.fbyte, self.cbyte = fbyte, cbyte


class MapData:
    def __init__(self, name, mapid):
        self.name = name
        self.mapid = mapid
        self.sectors: list[Sector] = []
        self.subsectors: list[list[Seg]] = []
        self.ssec_sector: list[int] = []
        self.nodes: list[Node] = []
        self.root = 0
        self.spawn = (0, 0, 0)          # x, y, camA
        self.ramp_misses = Counter()

    @property
    def numsegs(self):
        return sum(len(s) for s in self.subsectors)


CHILD_IS_SSEC = 0x8000


def point_on_side(x: int, y: int, nd: Node) -> int:
    """0 = right/front child, 1 = left/back child.

    This is Doom's R_PointOnSide, and it is the *same* cross product the engine
    already computes in `checkSector` (`pipeline.md` §5.1):

        cross = dx*(y - py) - dy*(x - px)      cross < 0  =>  right/front

    which matters more than it looks: the 6502 `pointOnSide` is not new code,
    it is `checkSector`'s sign-only subtract chain with the wall delta replaced
    by the node delta. Getting this sign backwards mirrors the whole world, so
    MAPINFO carries a precomputed spawn subsector for the engine to check its
    own descent against (`docs/reu-format.md` §4.1).
    """
    cross = nd.dx * (y - nd.py) - nd.dy * (x - nd.px)
    return 0 if cross < 0 else 1


def descend(m: MapData, x: int, y: int) -> int:
    """Walk the packed BSP to the subsector containing (x, y)."""
    child = m.root
    guard = 0
    while not (child & CHILD_IS_SSEC):
        nd = m.nodes[child]
        child = nd.left if point_on_side(x, y, nd) else nd.right
        guard += 1
        if guard > 64:
            raise ValueError("BSP descent did not terminate — cyclic children?")
    return child & ~CHILD_IS_SSEC


# ----------------------------------------------------------------------------
# E1M1 (and any other WAD map) — read the shipped BSP, repack it
# ----------------------------------------------------------------------------

def load_wad_map(wad: Wad, mapname: str) -> MapData:
    L = wad.map_lumps(mapname)
    verts = wad.records(L, "VERTEXES", "<hh")
    lines = wad.records(L, "LINEDEFS", "<HHHHHHH")
    sides = wad.records(L, "SIDEDEFS", "<hh8s8s8sH")
    wsecs = wad.records(L, "SECTORS", "<hh8s8shHH")
    wsegs = wad.records(L, "SEGS", "<HHhHHh")
    wssec = wad.records(L, "SSECTORS", "<HH")
    wnodes = wad.records(L, "NODES", "<hhhh" + "hhhh" * 2 + "HH")
    things = wad.records(L, "THINGS", "<hhHHH")

    m = MapData(mapname, MAPID_E1M1)

    def txt(b):
        return b.rstrip(b"\0").decode("ascii", "replace")

    for floor, ceil, ftex, ctex, light, _special, _tag in wsecs:
        inten = light_to_intensity(light)
        fr = pick_ramp(txt(ftex), FLAT_RAMPS, m.ramp_misses)
        cr = pick_ramp(txt(ctex), FLAT_RAMPS, m.ramp_misses)
        # Ceilings are darkened a fixed step below floors. Not a lighting
        # model -- it is what keeps a room readable when both flats land on
        # the same ramp, which the E1M1 start room does (both STONE at
        # intensity 9), and which renders as one undifferentiated grey field
        # with the walls floating in it. This is the M1 art knob
        # IMPLEMENTATION_PLAN.md risk #5 points at, and it costs nothing at
        # runtime because the nibble had to hold something either way.
        m.sectors.append(Sector(floor, ceil, (fr << 4) | inten,
                                (cr << 4) | max(2, inten - CEIL_DARKEN)))

    def side_sector(idx):
        return None if idx == 0xFFFF else sides[idx][5]

    def side_ramp(idx):
        """Ramp from a sidedef's textures: middle, else upper, else lower."""
        if idx == 0xFFFF:
            return DEFAULT_RAMP
        _xo, _yo, upper, lower, middle, _sec = sides[idx]
        for tex in (middle, upper, lower):
            name = txt(tex)
            if name and name != "-":
                return pick_ramp(name, WALL_RAMPS, m.ramp_misses)
        return DEFAULT_RAMP

    segs = []
    for v1, v2, _angle, linedef, side, _offset in wsegs:
        right, left = lines[linedef][5], lines[linedef][6]
        front_sd, back_sd = (right, left) if side == 0 else (left, right)
        x0, y0 = verts[v1]
        x1, y1 = verts[v2]
        segs.append(Seg(x0, y0, x1, y1,
                        side_sector(front_sd), side_sector(back_sd),
                        side_ramp(front_sd)))

    for count, first in wssec:
        group = segs[first:first + count]
        if not group:
            raise ValueError(f"{mapname}: subsector with no segs")
        m.subsectors.append(group)
        m.ssec_sector.append(group[0].front)

    for nd in wnodes:
        px, py, dx, dy = nd[0:4]
        m.nodes.append(Node(px, py, dx, dy, right=nd[12], left=nd[13]))
    m.root = len(m.nodes) - 1

    start = next((t for t in things if t[3] == 1), None)
    if start is None:
        raise ValueError(f"{mapname}: no player-1 start in THINGS")
    sx, sy, sdeg = start[0], start[1], start[2]
    m.spawn = (sx, sy, int(round(sdeg * 256.0 / 360.0)) & 0xFF)
    return m


# ----------------------------------------------------------------------------
# The test map — src/testmap.asm's three convex sectors, as linedefs
#
# testmap.asm lists 16 directed walls, but walls 3/6 and 8/11 are the two sides
# of one physical boundary. Expressed as linedefs (front sector on the RIGHT of
# v0 -> v1, exactly as the WAD does it) that is 14 lines. Sector heights,
# shading bytes and ramps are copied from testmap.asm unchanged so the frame
# traced in `pipeline.md` §11 stays the expected output.
# ----------------------------------------------------------------------------

TEST_SECTORS = [
    # floor, ceil, fbyte, cbyte
    (0, 256, 0x45, 0x02),               # A  moss floor, dark stone ceiling
    (24, 152, 0x13, 0x12),              # B  wood corridor, lower and narrower
    (-32, 320, 0x23, 0x52),             # C  flesh floor, violet ceiling
]

# (x0, y0, x1, y1, frontSector, backSector, frontRamp, backRamp)
TEST_LINEDEFS = [
    (0, 0, 0, 1024, 0, None, 0x0, None),
    (0, 1024, 1024, 1024, 0, None, 0x0, None),
    (1024, 1024, 1024, 640, 0, None, 0x6, None),
    (1024, 640, 1024, 384, 0, 1, 0x6, 0x1),         # A <-> B
    (1024, 384, 1024, 0, 0, None, 0x6, None),
    (1024, 0, 0, 0, 0, None, 0x0, None),
    (1024, 640, 1536, 640, 1, None, 0x1, None),
    (1536, 640, 1536, 384, 1, 2, 0x1, 0x2),         # B <-> C
    (1536, 384, 1024, 384, 1, None, 0x1, None),
    (1536, 128, 1536, 384, 2, None, 0x2, None),
    (1536, 640, 1536, 896, 2, None, 0x2, None),
    (1536, 896, 2304, 896, 2, None, 0x5, None),
    (2304, 896, 2304, 128, 2, None, 0x2, None),
    (2304, 128, 1536, 128, 2, None, 0x5, None),
]

TEST_SPAWN = (512, 512, 0)              # matches START_X/START_Y/START_A


def build_test_map() -> MapData:
    m = MapData("TEST", MAPID_TEST)
    for floor, ceil, fb, cb in TEST_SECTORS:
        m.sectors.append(Sector(floor, ceil, fb, cb))

    segs = []
    for x0, y0, x1, y1, front, back, framp, bramp in TEST_LINEDEFS:
        segs.append(Seg(x0, y0, x1, y1, front, back, framp))
        if back is not None:
            # The reverse side of a two-sided line is its own seg, wound the
            # other way so that its front sector is again on the right.
            segs.append(Seg(x1, y1, x0, y0, back, front, bramp))

    build_bsp(m, segs)
    m.spawn = TEST_SPAWN
    return m


# ----------------------------------------------------------------------------
# BSP builder (test map only — E1M1 uses the BSP id Software shipped)
# ----------------------------------------------------------------------------

ON_EPS = 1e-9


def _side_of(px, py, dx, dy, x, y) -> int:
    """-1 front/right, +1 back/left, 0 on the line. Same sign rule as
    point_on_side, but three-valued so splitting can see collinearity."""
    cross = dx * (y - py) - dy * (x - px)
    if cross < 0:
        return -1
    if cross > 0:
        return +1
    return 0


def _split_seg(seg: Seg, px, py, dx, dy):
    """Split `seg` against the partition line. Returns (front_part, back_part),
    either of which may be None."""
    a = _side_of(px, py, dx, dy, seg.x0, seg.y0)
    b = _side_of(px, py, dx, dy, seg.x1, seg.y1)

    if a == 0 and b == 0:
        # Collinear: it belongs to whichever side it faces.
        same = (seg.x1 - seg.x0) * dx + (seg.y1 - seg.y0) * dy > 0
        return (seg, None) if same else (None, seg)
    if a <= 0 and b <= 0:
        return seg, None
    if a >= 0 and b >= 0:
        return None, seg

    # Genuinely straddling: solve for the crossing parameter.
    sdx, sdy = seg.x1 - seg.x0, seg.y1 - seg.y0
    den = dx * sdy - dy * sdx
    if den == 0:                                    # parallel; cannot straddle
        return (seg, None) if a <= 0 else (None, seg)
    t = (dx * (seg.y0 - py) - dy * (seg.x0 - px)) / -den
    mx = int(round(seg.x0 + sdx * t))
    my = int(round(seg.y0 + sdy * t))

    head = Seg(seg.x0, seg.y0, mx, my, seg.front, seg.back, seg.ramp)
    tail = Seg(mx, my, seg.x1, seg.y1, seg.front, seg.back, seg.ramp)
    return (head, tail) if a < 0 else (tail, head)


def _is_convex(segs: list[Seg]) -> bool:
    """A leaf is acceptable when every seg sees every other seg entirely on its
    front side, and all segs share a front sector (a Doom subsector lies in
    exactly one sector, and the engine reads floor/ceiling heights per
    subsector, so a mixed leaf would render one sector's flats over another's).
    """
    if len({s.front for s in segs}) > 1:
        return False
    for a in segs:
        dx, dy = a.x1 - a.x0, a.y1 - a.y0
        for b in segs:
            if b is a:
                continue
            for (x, y) in ((b.x0, b.y0), (b.x1, b.y1)):
                if _side_of(a.x0, a.y0, dx, dy, x, y) > 0:
                    return False
    return True


def _pick_partition(segs: list[Seg]) -> Seg:
    """Fewest splits wins; ties go to the seg that balances the two sides best.

    A full node builder would also weigh axis-alignment and seg length. This
    one runs on 14 linedefs, so the exhaustive O(n^2) scan is free and the
    simple metric is enough.
    """
    best, best_key = None, None
    for cand in segs:
        dx, dy = cand.x1 - cand.x0, cand.y1 - cand.y0
        if dx == 0 and dy == 0:
            continue
        splits = front = back = 0
        for s in segs:
            f, b = _split_seg(s, cand.x0, cand.y0, dx, dy)
            if f and b:
                splits += 1
            if f:
                front += 1
            if b:
                back += 1
        if front == 0 or back == 0:
            # A partition with nothing behind it makes no progress unless it is
            # the only thing separating a still-non-convex set; allow it, but
            # rank it last.
            key = (splits + len(segs), abs(front - back) + len(segs))
        else:
            key = (splits, abs(front - back))
        if best_key is None or key < best_key:
            best, best_key = cand, key
    if best is None:
        raise ValueError("no usable partition candidate (all segs degenerate)")
    return best


def build_bsp(m: MapData, segs: list[Seg]) -> None:
    """Recursively partition `segs`, filling m.nodes / m.subsectors / m.root."""

    def leaf(group: list[Seg]) -> int:
        idx = len(m.subsectors)
        m.subsectors.append(group)
        m.ssec_sector.append(group[0].front if group else 0)
        if idx >= CHILD_IS_SSEC:
            raise ValueError("too many subsectors for Doom's child encoding")
        return idx | CHILD_IS_SSEC

    def recurse(group: list[Seg], depth: int) -> int:
        if depth > 32:
            raise ValueError("BSP build did not converge — check seg winding")
        if not group or _is_convex(group):
            return leaf(group)

        part = _pick_partition(group)
        dx, dy = part.x1 - part.x0, part.y1 - part.y0
        front, back = [], []
        for s in group:
            f, b = _split_seg(s, part.x0, part.y0, dx, dy)
            if f:
                front.append(f)
            if b:
                back.append(b)
        if not front:
            raise ValueError("partition put every seg behind it")

        right = recurse(front, depth + 1)
        # An empty back side is solid space. Doom's own builder produces these
        # too; the engine renders a zero-seg subsector by doing nothing.
        left = recurse(back, depth + 1)

        idx = len(m.nodes)
        m.nodes.append(Node(part.x0, part.y0, dx, dy, right, left))
        return idx

    m.root = recurse(segs, 0)
    if m.root & CHILD_IS_SSEC:
        raise ValueError("degenerate map: the whole thing is one subsector")


# ----------------------------------------------------------------------------
# Packing
# ----------------------------------------------------------------------------

def _s16(v: int, what: str) -> int:
    if not -32768 <= v <= 32767:
        raise ValueError(f"{what}: {v} does not fit in signed 16 bits")
    return v & 0xFFFF


def pack_nodes(m: MapData) -> bytes:
    if len(m.nodes) > MAXNODES:
        raise ValueError(f"{len(m.nodes)} nodes exceeds MAXNODES={MAXNODES}")
    cols = [bytearray(MAXNODES) for _ in range(12)]
    for i, nd in enumerate(m.nodes):
        vals = [_s16(nd.px, "node px"), _s16(nd.py, "node py"),
                _s16(nd.dx, "node dx"), _s16(nd.dy, "node dy"),
                nd.right & 0xFFFF, nd.left & 0xFFFF]
        for k, v in enumerate(vals):
            cols[k * 2][i] = v & 0xFF
            cols[k * 2 + 1][i] = v >> 8
    return b"".join(bytes(c) for c in cols)


def pack_sectors(m: MapData) -> bytes:
    if len(m.sectors) > MAXSEC:
        raise ValueError(f"{len(m.sectors)} sectors exceeds MAXSEC={MAXSEC}")
    cols = [bytearray(MAXSEC) for _ in range(6)]
    for i, s in enumerate(m.sectors):
        f, c = _s16(s.floor, "floor"), _s16(s.ceil, "ceil")
        cols[0][i], cols[1][i] = f & 0xFF, f >> 8
        cols[2][i], cols[3][i] = c & 0xFF, c >> 8
        cols[4][i], cols[5][i] = s.fbyte & 0xFF, s.cbyte & 0xFF
    return b"".join(bytes(c) for c in cols)


def _sphere(points) -> tuple:
    """A bounding circle for `points`, as (cx, cy, r) in whole map units.

    Not the minimal enclosing circle — the circumcircle of the axis-aligned
    bounding box, which is at most 1.41x its radius. The looser circle costs
    a few rejections; solving the minimal-circle problem here would buy them
    back and change nothing else, because the engine's cost is the same three
    numbers either way.

    The radius is rounded *up* and the centre to whole units, so the packed
    sphere always contains every point. That direction matters: a sphere that
    is too small makes the engine cull geometry that is on screen, which shows
    up as walls flickering out of existence at the edge of the view, and a
    sphere that is too large only makes it cull less.
    """
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    cx = (min(xs) + max(xs)) // 2
    cy = (min(ys) + max(ys)) // 2
    r = 0
    for x, y in points:
        r = max(r, (x - cx) ** 2 + (y - cy) ** 2)
    r = math.isqrt(r)
    while r * r < max((x - cx) ** 2 + (y - cy) ** 2 for x, y in points):
        r += 1                          # isqrt floors; the sphere must contain
    return cx, cy, r


def _seg_points(group) -> list:
    return [(s.x0, s.y0) for s in group] + [(s.x1, s.y1) for s in group]


def ssec_spheres(m: MapData) -> list:
    """One bounding sphere per subsector, over its own segs' endpoints.

    Segs are the only thing a subsector draws. Its true convex cell can be
    larger — the edges that run along BSP partition lines carry no seg
    (docs/reu-format.md §5) — but nothing is ever rasterised out there, so
    bounding the segs is bounding the output.
    """
    return [_sphere(_seg_points(g)) if g else (0, 0, 0) for g in m.subsectors]


def node_spheres(m: MapData) -> list:
    """One bounding sphere per node, over every seg endpoint in its subtree.

    Computed from the packed tree rather than from the WAD's own per-child
    bounding boxes, so the test map — whose BSP this tool builds itself, and
    which has no WAD boxes to read — goes through the identical path. That is
    the same argument as Phase 4.4's: bring it up on three hand-checkable
    sectors before 236 nodes can hide a sign error.
    """
    spheres = [None] * len(m.nodes)
    points = [None] * len(m.nodes)

    def child_points(child):
        if child & CHILD_IS_SSEC:
            return _seg_points(m.subsectors[child & ~CHILD_IS_SSEC])
        return walk(child)

    def walk(i):
        if points[i] is not None:
            return points[i]
        nd = m.nodes[i]
        pts = child_points(nd.right) + child_points(nd.left)
        if not pts:
            pts = [(nd.px, nd.py)]      # a subtree with no segs at all
        points[i] = pts
        spheres[i] = _sphere(pts)
        return pts

    for i in range(len(m.nodes)):
        walk(i)
    return spheres


def pack_nodesph(m: MapData) -> bytes:
    out = bytearray(MAXNODES * NODESPH_STRIDE)
    for i, (cx, cy, r) in enumerate(node_spheres(m)):
        # The engine adds the radius to a camera-space coordinate and compares
        # the sum against another one, in signed 16 bits. Map coordinates reach
        # +/-4864 and the trig rotation can add ~41%, so a radius over 8000
        # would be the first thing to overflow that. E1M1's largest is 2686.
        if r > 8000:
            raise ValueError(f"node {i} bounding sphere radius {r} is too "
                             "large for the engine's 16-bit compare")
        _s16(cx, f"node {i} sphere cx")      # range check; "<h" packs it
        _s16(cy, f"node {i} sphere cy")
        struct.pack_into("<hhH", out, i * NODESPH_STRIDE, cx, cy, r)
    return bytes(out)


def pack_ssecdata(m: MapData) -> bytes:
    out = bytearray(len(m.subsectors) * SSEC_STRIDE)
    spheres = ssec_spheres(m)
    for i, group in enumerate(m.subsectors):
        if len(group) > MAX_SEGS_PER_SSEC:
            raise ValueError(f"subsector {i} has {len(group)} segs, "
                             f"slot holds {MAX_SEGS_PER_SSEC}")
        base = i * SSEC_STRIDE
        out[base] = len(group)
        out[base + 1] = m.ssec_sector[i] & 0xFF
        cx, cy, r = spheres[i]
        struct.pack_into("<hhH", out, base + 2, cx, cy, r)
        p = base + SSEC_HDR
        for s in group:
            back = NO_BACK_SECTOR if s.back is None else s.back
            if back != NO_BACK_SECTOR and back >= len(m.sectors):
                raise ValueError(f"seg back sector {back} out of range")
            struct.pack_into("<hhhhBB", out, p,
                             s.x0, s.y0, s.x1, s.y1, back, (s.ramp & 0x0F) << 4)
            p += SEG_RECORD
    return bytes(out)


def pack_mapinfo(m: MapData, ssec_reu_base: int, spawn_ssec: int,
                 sph_reu_base: int) -> bytes:
    b = bytearray(MAPINFO_SIZE)
    struct.pack_into("<HHBB", b, 0,
                     len(m.nodes), len(m.subsectors), len(m.sectors),
                     SSEC_STRIDE_SHIFT)
    b[6] = ssec_reu_base & 0xFF
    b[7] = (ssec_reu_base >> 8) & 0xFF
    b[8] = (ssec_reu_base >> 16) & 0xFF
    sx, sy, sa = m.spawn
    struct.pack_into("<HhhBHBHB", b, 9,
                     m.root & 0xFFFF, sx, sy, sa,
                     spawn_ssec, m.ssec_sector[spawn_ssec] & 0xFF,
                     m.numsegs, m.mapid)
    b[22] = sph_reu_base & 0xFF                 # NODESPH, streamed 6 B/node
    b[23] = (sph_reu_base >> 8) & 0xFF
    b[24] = (sph_reu_base >> 16) & 0xFF
    return bytes(b)


def build_image(m: MapData) -> bytes:
    """Assemble the whole .reu image. Blocks follow the header in id order,
    each padded up to a 256-byte boundary (docs/reu-format.md §3)."""
    nodes = pack_nodes(m)
    sectors = pack_sectors(m)
    ssecdata = pack_ssecdata(m)
    nodesph = pack_nodesph(m)

    # MAPINFO needs SSECDATA's offset, and SSECDATA's offset depends only on
    # the fixed sizes ahead of it, so the layout is computed before packing it.
    def align(n):
        return (n + BLOCK_ALIGN - 1) // BLOCK_ALIGN * BLOCK_ALIGN

    ofs_mapinfo = align(HEADER_SIZE)
    ofs_nodes = ofs_mapinfo + align(MAPINFO_SIZE)
    ofs_sectors = ofs_nodes + align(len(nodes))
    ofs_ssecdata = ofs_sectors + align(len(sectors))
    ofs_nodesph = ofs_ssecdata + align(len(ssecdata))

    sx, sy, _ = m.spawn
    spawn_ssec = descend(m, sx, sy)
    mapinfo = pack_mapinfo(m, ofs_ssecdata, spawn_ssec, ofs_nodesph)

    blocks = [
        (BLK_MAPINFO, 1, ofs_mapinfo, mapinfo, LOAD_MAPINFO >> 8),
        (BLK_NODES, 1, ofs_nodes, nodes, LOAD_NODES >> 8),
        (BLK_SECTORS, 1, ofs_sectors, sectors, LOAD_SECTORS >> 8),
        (BLK_SSECDATA, 0, ofs_ssecdata, ssecdata, 0),
        (BLK_NODESPH, 0, ofs_nodesph, nodesph, 0),
    ]

    used = align(ofs_nodesph + len(nodesph))
    if used > REU_PROBE_OFFSET:
        raise ValueError(
            f"image is {used} B and would reach REU ${REU_PROBE_OFFSET:06X}, "
            "where reuProbe round-trips its signature at boot (src/defs.asm "
            "REU_PROBE_ADDR/BANK). Move the probe scratch before growing "
            "the image past that.")
    if used > REU_IMAGE_SIZE:
        raise ValueError(f"image is {used} B, past REU_IMAGE_SIZE "
                         f"({REU_IMAGE_SIZE} B); raise it and -reusize together")
    img = bytearray(REU_IMAGE_SIZE)
    img[0:4] = MAGIC
    img[4] = VERSION
    img[5] = len(blocks)
    for i, (bid, flags, ofs, payload, loadhi) in enumerate(blocks):
        if len(payload) > 0xFFFF:
            raise ValueError(f"block {bid} is {len(payload)} B, length field is 16-bit")
        struct.pack_into("<BBBBBHB", img, 8 + i * 8,
                         bid, flags,
                         ofs & 0xFF, (ofs >> 8) & 0xFF, (ofs >> 16) & 0xFF,
                         len(payload), loadhi)
        img[ofs:ofs + len(payload)] = payload
    return bytes(img)


# ----------------------------------------------------------------------------
# Validation — an independent reader, deliberately not sharing code with the
# packers above. A round-trip through the same helper functions would agree
# with itself no matter how wrong both halves were.
# ----------------------------------------------------------------------------

def parse_image(img: bytes) -> dict:
    if img[0:4] != MAGIC:
        raise ValueError(f"bad magic {img[0:4]!r}")
    if img[4] != VERSION:
        raise ValueError(f"version {img[4]}, expected {VERSION}")
    n = img[5]
    blocks = {}
    for i in range(n):
        bid, flags, o0, o1, o2, length, loadhi = struct.unpack_from(
            "<BBBBBHB", img, 8 + i * 8)
        ofs = o0 | (o1 << 8) | (o2 << 16)
        if ofs + length > len(img):
            raise ValueError(f"block {bid} runs past the end of the image")
        blocks[bid] = dict(flags=flags, ofs=ofs, length=length,
                           load=loadhi << 8, data=img[ofs:ofs + length])

    mi = blocks[BLK_MAPINFO]["data"]
    numnodes, numssec, numsec, shift = struct.unpack_from("<HHBB", mi, 0)
    ssec_base = mi[6] | (mi[7] << 8) | (mi[8] << 16)
    sph_base = mi[22] | (mi[23] << 8) | (mi[24] << 16)
    root, sx, sy, sa, spawn_ssec, spawn_sec, numsegs, mapid = \
        struct.unpack_from("<HhhBHBHB", mi, 9)

    info = dict(numnodes=numnodes, numssec=numssec, numsec=numsec,
                shift=shift, ssec_base=ssec_base, sph_base=sph_base, root=root,
                spawn=(sx, sy, sa), spawn_ssec=spawn_ssec,
                spawn_sec=spawn_sec, numsegs=numsegs, mapid=mapid)

    nd = blocks[BLK_NODES]["data"]
    nodes = []
    for i in range(numnodes):
        vals = [nd[k * 2 * MAXNODES + i] | (nd[(k * 2 + 1) * MAXNODES + i] << 8)
                for k in range(6)]
        px, py, dx, dy = [v - 0x10000 if v & 0x8000 else v for v in vals[:4]]
        nodes.append(Node(px, py, dx, dy, vals[4], vals[5]))

    sc = blocks[BLK_SECTORS]["data"]
    sectors = []
    for i in range(numsec):
        floor = sc[i] | (sc[MAXSEC + i] << 8)
        ceil = sc[2 * MAXSEC + i] | (sc[3 * MAXSEC + i] << 8)
        sectors.append(Sector(floor - 0x10000 if floor & 0x8000 else floor,
                              ceil - 0x10000 if ceil & 0x8000 else ceil,
                              sc[4 * MAXSEC + i], sc[5 * MAXSEC + i]))

    subs, ssec_sector, ssec_sph = [], [], []
    stride = 1 << shift
    for i in range(numssec):
        base = ssec_base + (i << shift)
        count, secid = img[base], img[base + 1]
        ssec_sph.append(struct.unpack_from("<hhH", img, base + 2))
        group = []
        for k in range(count):
            x0, y0, x1, y1, back, ramp = struct.unpack_from(
                "<hhhhBB", img, base + SSEC_HDR + k * SEG_RECORD)
            group.append(Seg(x0, y0, x1, y1, secid,
                             None if back == NO_BACK_SECTOR else back,
                             ramp >> 4))
        subs.append(group)
        ssec_sector.append(secid)

    sp = blocks[BLK_NODESPH]["data"]
    node_sph = [struct.unpack_from("<hhH", sp, i * NODESPH_STRIDE)
                for i in range(numnodes)]

    return dict(info=info, blocks=blocks, nodes=nodes, sectors=sectors,
                subsectors=subs, ssec_sector=ssec_sector, stride=stride,
                ssec_sph=ssec_sph, node_sph=node_sph)


def validate(m: MapData, img: bytes) -> list[str]:
    """Returns a list of complaints; empty means the image is good."""
    bad = []
    p = parse_image(img)
    info = p["info"]

    def check(cond, msg):
        if not cond:
            bad.append(msg)

    check(info["numnodes"] == len(m.nodes), "node count round-trip")
    check(info["numssec"] == len(m.subsectors), "subsector count round-trip")
    check(info["numsec"] == len(m.sectors), "sector count round-trip")
    check(info["numsegs"] == m.numsegs, "seg count round-trip")
    check(info["root"] == (m.root & 0xFFFF), "root node round-trip")
    check(info["spawn"] == m.spawn, f"spawn round-trip {info['spawn']} vs {m.spawn}")
    check(info["mapid"] == m.mapid, "map id round-trip")

    for bid, blk in p["blocks"].items():
        check(blk["ofs"] % BLOCK_ALIGN == 0 or bid == BLK_MAPINFO,
              f"block {bid} is not page-aligned in the image")
    check(p["blocks"][BLK_NODES]["load"] == LOAD_NODES, "NODES load address")
    check(p["blocks"][BLK_SECTORS]["load"] == LOAD_SECTORS, "SECTORS load address")
    check(p["blocks"][BLK_MAPINFO]["load"] == LOAD_MAPINFO, "MAPINFO load address")
    check(p["blocks"][BLK_SSECDATA]["flags"] & 1 == 0, "SSECDATA must not be resident")
    check(p["blocks"][BLK_NODESPH]["flags"] & 1 == 0, "NODESPH must not be resident")
    check(info["sph_base"] == p["blocks"][BLK_NODESPH]["ofs"],
          "MAPINFO's sphere base does not point at the NODESPH block")

    # 2. every child resolves
    for i, nd in enumerate(p["nodes"]):
        for name, child in (("right", nd.right), ("left", nd.left)):
            if child & CHILD_IS_SSEC:
                check((child & ~CHILD_IS_SSEC) < info["numssec"],
                      f"node {i} {name} child -> subsector {child & ~CHILD_IS_SSEC} out of range")
            else:
                check(child < info["numnodes"],
                      f"node {i} {name} child -> node {child} out of range")

    # 3/4/5. subsector and seg sanity
    for i, group in enumerate(p["subsectors"]):
        check(len(group) <= MAX_SEGS_PER_SSEC, f"subsector {i} overflows its slot")
        check(p["ssec_sector"][i] < info["numsec"],
              f"subsector {i} sector id out of range")
        for s in group:
            check(s.back is None or s.back < info["numsec"],
                  f"subsector {i}: back sector out of range")
        # front sector agreement, against the source structures
        for s in m.subsectors[i]:
            check(s.front == m.ssec_sector[i],
                  f"subsector {i}: seg front sector {s.front} != {m.ssec_sector[i]}")

    # 6. geometry round-trip, seg by seg
    for i, (want, got) in enumerate(zip(m.subsectors, p["subsectors"])):
        if len(want) != len(got):
            bad.append(f"subsector {i}: {len(want)} segs in, {len(got)} out")
            continue
        for k, (a, b) in enumerate(zip(want, got)):
            if (a.x0, a.y0, a.x1, a.y1) != (b.x0, b.y0, b.x1, b.y1):
                bad.append(f"subsector {i} seg {k}: coordinates changed")
            if (a.back if a.back is not None else NO_BACK_SECTOR) != \
               (b.back if b.back is not None else NO_BACK_SECTOR):
                bad.append(f"subsector {i} seg {k}: back sector changed")
            if a.ramp != b.ramp:
                bad.append(f"subsector {i} seg {k}: ramp changed")
    for i, (a, b) in enumerate(zip(m.sectors, p["sectors"])):
        if (a.floor, a.ceil, a.fbyte, a.cbyte) != (b.floor, b.ceil, b.fbyte, b.cbyte):
            bad.append(f"sector {i}: round-trip mismatch")
    for i, (a, b) in enumerate(zip(m.nodes, p["nodes"])):
        if (a.px, a.py, a.dx, a.dy, a.right, a.left) != \
           (b.px, b.py, b.dx, b.dy, b.right, b.left):
            bad.append(f"node {i}: round-trip mismatch")

    # 8. every bounding sphere must actually bound.
    #
    # This is the check that matters most about the spheres, and it is checked
    # against the *decoded* image rather than against the packer's own output:
    # a sphere that is too small does not corrupt anything, it makes the engine
    # cull geometry that is on screen, and the symptom -- a wall that vanishes
    # when you turn until it is near the edge of the view -- is exactly the kind
    # of thing that survives a whole session being blamed on the renderer.
    def contains(sph, pts, what):
        cx, cy, r = sph
        for x, y in pts:
            if (x - cx) ** 2 + (y - cy) ** 2 > r * r:
                bad.append(f"{what}: sphere ({cx},{cy}) r={r} does not contain "
                           f"({x},{y})")
                return

    for i, group in enumerate(p["subsectors"]):
        if group:
            contains(p["ssec_sph"][i], _seg_points(group), f"subsector {i}")

    def subtree_points(child):
        if child & CHILD_IS_SSEC:
            return _seg_points(p["subsectors"][child & ~CHILD_IS_SSEC])
        nd = p["nodes"][child]
        return subtree_points(nd.right) + subtree_points(nd.left)

    for i, nd in enumerate(p["nodes"]):
        pts = subtree_points(i)
        if pts:
            contains(p["node_sph"][i], pts, f"node {i} subtree")

    # 7. the descent the engine will perform, done against the decoded blocks
    decoded = MapData(m.name, m.mapid)
    decoded.nodes = p["nodes"]
    decoded.root = info["root"]
    sx, sy, _ = m.spawn
    try:
        got_ssec = descend(decoded, sx, sy)
        check(got_ssec == info["spawn_ssec"],
              f"spawn subsector: decoded descent gives {got_ssec}, "
              f"MAPINFO says {info['spawn_ssec']}")
        check(got_ssec == descend(m, sx, sy),
              "spawn subsector: descending the packed nodes disagrees with "
              "descending the source nodes")
        check(p["ssec_sector"][got_ssec] == info["spawn_sec"],
              "spawn sector disagrees with the spawn subsector")
    except ValueError as e:
        bad.append(f"spawn descent: {e}")

    # The descent above proves the tree is self-consistent, not that it points
    # at the right place. Confirm geometrically: the spawn must be on the
    # interior side of every one-sided seg of the subsector it landed in.
    for s in p["subsectors"][info["spawn_ssec"]]:
        if s.back is None:
            dx, dy = s.x1 - s.x0, s.y1 - s.y0
            check(_side_of(s.x0, s.y0, dx, dy, sx, sy) <= 0,
                  f"spawn ({sx},{sy}) is outside solid seg "
                  f"({s.x0},{s.y0})->({s.x1},{s.y1}) of its own subsector")

    return bad


# ----------------------------------------------------------------------------
# Top-down render of the decoded blocks
# ----------------------------------------------------------------------------

# C64 palette, for the middle colour of each ramp in chunky2mc.asm.
C64 = [(0, 0, 0), (255, 255, 255), (136, 57, 50), (103, 182, 189),
       (139, 63, 150), (85, 160, 73), (64, 49, 141), (191, 206, 114),
       (139, 84, 41), (87, 66, 0), (184, 105, 98), (80, 80, 80),
       (120, 120, 120), (148, 224, 137), (120, 105, 196), (159, 159, 159)]
RAMP_MID = [0xc, 0x8, 0xa, 0xe, 0x5, 0x4, 0xc, 0x8] + [0xc] * 8


def render_png(img: bytes, path: str, size: int = 1000) -> None:
    try:
        from PIL import Image, ImageDraw
    except ImportError:
        print("wad2reu: --png needs Pillow (pip install pillow); skipping",
              file=sys.stderr)
        return

    p = parse_image(img)
    segs = [s for group in p["subsectors"] for s in group]
    if not segs:
        return
    xs = [v for s in segs for v in (s.x0, s.x1)]
    ys = [v for s in segs for v in (s.y0, s.y1)]
    pad = 32
    minx, maxx, miny, maxy = min(xs), max(xs), min(ys), max(ys)
    scale = (size - 2 * pad) / max(maxx - minx, maxy - miny, 1)

    def to_px(x, y):
        # y flips: Doom's +y is north, the image's +y is down.
        return (pad + (x - minx) * scale, pad + (maxy - y) * scale)

    im = Image.new("RGB", (size, size), (16, 16, 20))
    d = ImageDraw.Draw(im)

    for s in segs:
        col = C64[RAMP_MID[s.ramp & 15]]
        if s.back is not None:
            col = tuple(c // 3 for c in col)        # portals drawn dim
        d.line([to_px(s.x0, s.y0), to_px(s.x1, s.y1)],
               fill=col, width=1 if s.back is not None else 2)

    sx, sy, sa = p["info"]["spawn"]
    px, py = to_px(sx, sy)
    d.ellipse([px - 6, py - 6, px + 6, py + 6], outline=(255, 80, 80), width=2)
    ang = sa * 2 * math.pi / 256.0
    d.line([(px, py), (px + 22 * math.cos(ang), py - 22 * math.sin(ang))],
           fill=(255, 80, 80), width=2)

    info = p["info"]
    d.text((8, 8), f"{info['numsegs']} segs  {info['numssec']} subsectors  "
                   f"{info['numnodes']} nodes  {info['numsec']} sectors  "
                   f"spawn ssec {info['spawn_ssec']}", fill=(200, 200, 200))
    im.save(path)


# ----------------------------------------------------------------------------

def report(m: MapData, img: bytes) -> None:
    p = parse_image(img)
    counts = Counter(len(g) for g in m.subsectors)
    used = Counter()
    for group in m.subsectors:
        for s in group:
            used[RAMP_NAMES[s.ramp]] += 1
    print(f"  map            {m.name} (id {m.mapid})")
    print(f"  nodes          {len(m.nodes)} / {MAXNODES}   root {m.root & 0xFFFF}")
    print(f"  sectors        {len(m.sectors)} / {MAXSEC}")
    print(f"  subsectors     {len(m.subsectors)}   segs {m.numsegs} "
          f"(mean {m.numsegs / max(1, len(m.subsectors)):.2f}, "
          f"max {max(counts) if counts else 0} / {MAX_SEGS_PER_SSEC})")
    print(f"  spawn          ({m.spawn[0]}, {m.spawn[1]}) angle {m.spawn[2]} "
          f"-> subsector {p['info']['spawn_ssec']} sector {p['info']['spawn_sec']}")
    print("  wall ramps     " + "  ".join(f"{k}:{v}" for k, v in used.most_common()))
    sph = p["node_sph"]
    print(f"  node spheres   max radius {max((r for _, _, r in sph), default=0)}"
          f"  mean {sum(r for _, _, r in sph) / max(1, len(sph)):.0f}")
    for bid, name in ((BLK_MAPINFO, "MAPINFO"), (BLK_NODES, "NODES"),
                      (BLK_SECTORS, "SECTORS"), (BLK_SSECDATA, "SSECDATA"),
                      (BLK_NODESPH, "NODESPH")):
        b = p["blocks"][bid]
        where = f"-> ${b['load']:04X}" if b["flags"] & 1 else "streamed"
        print(f"  block {bid} {name:<9}${b['ofs']:06X} +{b['length']:<6} {where}")
    if m.ramp_misses:
        print("  UNMAPPED textures (fell back to "
              f"{RAMP_NAMES[DEFAULT_RAMP]}): "
              + ", ".join(f"{k}x{v}" for k, v in m.ramp_misses.most_common()))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wad", nargs="?", help="path to DOOM1.WAD (not needed for --map TEST)")
    ap.add_argument("-o", "--out", required=True, help="output .reu image")
    ap.add_argument("--map", default="E1M1",
                    help="map lump name, or TEST for the built-in test map")
    ap.add_argument("--png", help="write a top-down render of the decoded image")
    ap.add_argument("--no-validate", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args(argv)

    try:
        if a.map.upper() == "TEST":
            m = build_test_map()
        else:
            if not a.wad:
                ap.error("a WAD path is required unless --map TEST")
            m = load_wad_map(Wad(a.wad), a.map.upper())
        img = build_image(m)
    except ValueError as e:
        print(f"wad2reu: {e}", file=sys.stderr)
        return 2

    if not a.no_validate:
        problems = validate(m, img)
        if problems:
            print(f"wad2reu: {len(problems)} validation failure(s):", file=sys.stderr)
            for msg in problems[:20]:
                print(f"  - {msg}", file=sys.stderr)
            return 1

    os.makedirs(os.path.dirname(os.path.abspath(a.out)) or ".", exist_ok=True)
    with open(a.out, "wb") as f:
        f.write(img)

    png = a.png
    if png is None and not a.quiet:
        png = os.path.splitext(a.out)[0] + "-map.png"
    if png:
        render_png(img, png)

    if not a.quiet:
        print(f"wad2reu: {a.out}  {len(img)} bytes (padded)"
              + (f"  ({png})" if png else ""))
        report(m, img)
    return 0


if __name__ == "__main__":
    sys.exit(main())

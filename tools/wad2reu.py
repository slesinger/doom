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
from collections import Counter, defaultdict

# ----------------------------------------------------------------------------
# Format constants. These MUST match src/defs.asm and docs/reu-format.md.
# ----------------------------------------------------------------------------

MAGIC = b"D64U"
VERSION = 7                     # 2 added the bounding spheres (SSEC_HDR, block 4)
                                # 3 added the music stream (block 5) and the
                                #   page-unit length flag it needs
                                # 4 added the wall texture tiles (block 6) and
                                #   the texture family id in the seg's low nibble
                                # 5 added the special linedefs (block 7): doors,
                                #   lifts and walkover triggers, with tags and
                                #   target heights resolved here rather than
                                #   searched for at runtime
                                # 6 took the wall tiles from 8x8 to 16x16
                                #   (block 6, 512 -> 2048 B). The engine loads
                                #   them resident now, so an image of the old
                                #   size is not merely finer or coarser, it is
                                #   the wrong length for texLoad's one transfer
                                # 7 added the weapon view (block 10). The
                                #   engine keeps this block's REU offset and
                                #   streams from it every frame, so an image
                                #   without it leaves wpnReuBase at zero and
                                #   the gun simply is not drawn -- but the
                                #   version still moves, because block 10's
                                #   descriptor is what carries the offset

HEADER_SIZE = 128               # 15 descriptors. 64 through version 4, which
                                # held 7 and the eighth block outgrew; the
                                # first block starts at $000100 either way
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
BLK_MUSIC = 5
BLK_WALLTEX = 6
BLK_LINEDEFS = 7

# Wall texture tiles -- IMPLEMENTATION_PLAN.md §10.2 Stage A.
#
# Sixteen families, one 16x16 intensity tile each, nibble-packed column-major:
# 8 bytes per u column (v = 0,1 in byte 0, v = 2,3 in byte 1, ...), 128 bytes per
# family, 2048 bytes for the block. Family i is at texReuBase + (i << 7).
#
# 8x8 through format 5 (IMPLEMENTATION_PLAN.md §10.2 Stage A). 16x16 is §10.6,
# and it is a resident block in the engine now rather than a per-seg DMA: at
# 128 B a tile, re-fetching one per seg would be 8.7 KB/frame.
#
# Sixteen and not more because the family id rides in the low nibble of the seg
# record's rampByte, which was reserved and zero (docs/reu-format.md §5.1). That
# is what makes this a format version bump and not a seg-record widening -- the
# 6-byte seg experiment in IMPLEMENTATION_PLAN.md §4 is the standing warning
# against growing the hottest record in the engine for a feature this size.
TEX_FAMILIES = 16
TEX_TILE_W = 16
TEX_TILE_H = 16
TEX_TILE_TEXELS = TEX_TILE_W * TEX_TILE_H         # 256
TEX_TILE_BYTES = TEX_TILE_TEXELS // 2            # 128, nibble-packed
TEX_BLOCK_BYTES = TEX_FAMILIES * TEX_TILE_BYTES  # 2048

# The intensity a texel of mean brightness gets. The engine adds the tile's
# texel to the wall's depth-shaded intensity and subtracts this, so a mean texel
# leaves the M1 shading exactly as it was and the tile is a pure modulation:
#
#     final = clamp(depthIntensity + texel - TEX_MID, 2, 15)
#
# Keeping the depth term as the base rather than the texture's own brightness is
# what stops a dark texture from going black at distance, which is the failure
# mode M1 risk #5 already found once with two flats on one ramp.
TEX_MID = 8

# How far a texel may swing either side of TEX_MID, and how much luma buys a
# step. TEX_SWING = 4 of 14 usable intensity steps is clearly visible without
# swamping the depth cue; TEX_GAIN saturates that swing at +-25 luma units,
# which is about the contrast of a Doom panel texture. Textures flatter than
# that (BROWNGRN's range is 22 luma) modulate less, which is the honest
# result -- normalising every tile to full swing makes a flat wall look noisy.
TEX_SWING = 4
TEX_GAIN = TEX_SWING / 25.0

# World units per texel, both axes. The engine maps u and v from *world*
# coordinates rather than from a per-seg texture offset -- u = axisCoord >> 3,
# v = z >> 3 -- so the mapping is continuous across a BSP seg split and no
# offset has to ride in the seg record. 8 units per texel over a 16-texel tile
# is the same 128-unit repeat Stage A's 16 units over 8 texels gave, which is
# what a 128x128 Doom texture spans at 1 pixel per unit and the size most of
# E1M1's wall textures actually are: the tile got finer, the world scale did
# not move. The engine's constants are texUpd's mask and texVSet's shift and
# ry/5 (src/render/tex.asm); this is documentation of them, not their source.
TEX_UNITS_SHIFT = 3

# ----------------------------------------------------------------------------
# Special linedefs -- IMPLEMENTATION_PLAN.md §11, docs/reu-format.md §4.8.
#
# M1 dropped LINEDEFS entirely: the engine renders segs and collides against
# segs, and a linedef is neither. What comes back is only the lines that *do*
# something -- special != 0 -- which in E1M1 is 19 of 475, and of those 19 the
# eight scrollers are not sector motion. So the resident table is eleven
# records, and that is what changes the design the plan sketched.
#
# §11.2 asked for a seg -> linedef reference, and worried about which of two
# bad ways to carry it (an 11th byte on the hottest record in the engine, or a
# geometry search at use time). Neither is needed, and neither is the geometry:
# activation is by *sector*, decided in IMPLEMENTATION_PLAN.md §11.2a because
# Doom's own segment-crossing test needs ~660 B of code against the 640 B of
# RAM under I/O that is the whole budget for this phase.
#
# So a record carries no endpoints. It carries the sector that moves, and the
# sector whose entry (or whose presence in front of the eye) fires it. A
# walkover line emits *two* records, one per side, because Doom's W1 and WR
# fire from either direction and a single trigger sector only sees one.
#
# Three things are resolved here that Doom resolves at runtime, because doing
# them offline costs nothing and saves the engine a search it has no data for:
#
#   - **the tag.** Doom scans every sector for a matching tag. The engine has
#     no tag array and SECTAB has no room for one, so a tag is resolved to a
#     sector id here. A tag matching several sectors emits one record each.
#   - **the target height.** "Lower to the lowest neighbouring floor" needs the
#     sector adjacency the engine also does not have. The height is computed
#     here from the WAD's own linedefs and stored. This is exact for M2, where
#     nothing else moves a floor; it stops being exact the day two thinkers can
#     act on neighbouring sectors, which is an M3 problem and is noted in
#     docs/reu-format.md §4.8.
#
# Record, 5 bytes, SoA (src/defs.asm LINESPEC):
#
#   kind      LK_* below, plus LF_* flags                        1 B
#   sector    the sector this line moves                         1 B
#   trig      the sector whose entry, or whose presence ahead
#             of the eye, fires it                               1 B
#   target    signed 16-bit height the sector moves to           2 B
MAXLINES = 16                   # capacity of the resident arrays; E1M1 uses 13
LINE_ARRAYS = 5
LINEDEF_BYTES = MAXLINES * LINE_ARRAYS          # 80

LK_NONE, LK_DOOR, LK_LIFT, LK_FLOOR, LK_EXIT = 0, 1, 2, 3, 4

# ----------------------------------------------------------------------------
# The HUD -- IMPLEMENTATION_PLAN.md §13.
#
# Boot-only: the engine paints the status bar exactly once, from these two
# blocks, straight into BITMAP0/1 + SCREEN0/1 + $D800 -- real VIC multicolor
# bitmap format (background shared and black, two screen-RAM nibble colours
# and one colour-RAM colour per cell), not WALLTEX's nibble-packed format and
# not the ramp/intensity chunky format the 3D renderer's dither chain uses.
# There is no runtime patching: code RAM has nothing left to spend on a
# dirty-flag mechanism (see the M2 state notes), so the bar is fixed at boot
# with plausible placeholder values and wired to variables only so M3 does
# not have to touch the pipeline.
#
# The art itself comes from a hand-painted Koala Painter image
# (assets/hud.kla) rather than the WAD's own STBAR/STTNUM lumps: those are
# authored for a much larger palette and downsampling them through the
# engine's dither chain (the previous approach) crushed them to a washed-out
# blur. A real C64 multicolor editor already enforces the exact per-cell
# colour limits the hardware has, so what gets painted there is what lands
# on screen -- a crop, not a conversion.
#
# A cell is one multicolor cell -- 4 px wide, 8 tall: 8 bitmap bytes, 1
# screen-RAM byte, 1 colour-RAM byte, 10 bytes total, cropped directly out of
# the Koala file's own layout (see KOALA_* below, matching src/intro/intro.asm's
# import offsets for doom-title.kla) -- so a HUD block is simply a strip of
# these cells, row-major (cell index = row*width+col).
#
# Neither block gets a MAPINFO field. Like LINEDEFS (block 7), they are
# streamed and read exactly once, by their own loader triggered off the block
# id during mapLoad's descriptor walk -- there is nothing to be resident
# *of*, since nothing reads this data again after boot.
BLK_HUDBG, BLK_HUDFONT = 8, 9
BLK_WEAPON = 10                 # IMPLEMENTATION_PLAN.md §12a, streamed per frame

HUD_CELL_BYTES = 10                 # 8 bitmap bytes + 1 screen byte + 1 colour byte

# The status bar is the four rows reserved below the viewport (main.asm's
# clearHudRows) -- 40 cells wide, 4 tall.
HUD_BG_CELLS_W = 40
HUD_BG_CELLS_H = 4
HUD_BG_BYTES = HUD_BG_CELLS_W * HUD_BG_CELLS_H * HUD_CELL_BYTES   # 1600

# The big HUD digit font, still 2x2 cells (8x16 logical px) -- measured
# against STTNUM's own ~14x16 when the art still came from the WAD (§4's
# rule): one cell renders every digit as a near-solid blob, since Doom's HUD
# font reads by outer silhouette and 4 px wide loses it. Kept at this size
# now that the art is hand-painted, so the two artists (background, font)
# share one grid convention.
HUD_FONT_GLYPHS = 10
HUD_FONT_CELLS_W = 2
HUD_FONT_CELLS_H = 2
HUD_FONT_GLYPH_BYTES = HUD_FONT_CELLS_W * HUD_FONT_CELLS_H * HUD_CELL_BYTES  # 40
HUD_FONT_BYTES = HUD_FONT_GLYPHS * HUD_FONT_GLYPH_BYTES            # 400

# assets/hud.kla's own layout -- a standard Koala Painter file, the same one
# src/intro/intro.asm imports raw for doom-title.kla: 2-byte PRG load address,
# 8000 B bitmap, 1000 B screen RAM, 1000 B colour RAM, 1 B background colour.
KOALA_BITMAP_OFS = 2
KOALA_SCREEN_OFS = KOALA_BITMAP_OFS + 8000
KOALA_COLOR_OFS = KOALA_SCREEN_OFS + 1000
KOALA_BG_OFS = KOALA_COLOR_OFS + 1000
KOALA_SIZE = KOALA_BG_OFS + 1

# Where the two hand-painted elements live on hud.kla's 40x25-cell canvas --
# one combined image rather than two files, so the artist can see the bar and
# the font glyphs together while painting. Everything outside these two
# regions is unused and can be left blank.
HUD_BAR_COL0, HUD_BAR_ROW0 = 0, 21      # the bar occupies the bottom 4 rows,
                                         # matching where it lands on screen
HUD_FONT_COL0, HUD_FONT_ROW0 = 0, 0     # digits 0-9, 2 cells each, top-left


def load_koala(path: str) -> bytes:
    """assets/hud.kla -> its raw bytes, checked for size and a black
    background -- the engine's $d021 is fixed to black at boot
    (src/main.asm) and never changed again, so a hud.kla painted against any
    other background colour would show a seam the moment it lands on screen.
    """
    with open(path, "rb") as fh:
        data = fh.read()
    if len(data) != KOALA_SIZE:
        raise ValueError(
            f"{path}: expected a {KOALA_SIZE}-byte Koala Painter file, got "
            f"{len(data)} -- export from Multipaint as C64 Multicolor/Koala")
    bg = data[KOALA_BG_OFS]
    if bg != 0:
        raise ValueError(
            f"{path}: background colour must be black (0) to match the "
            f"engine's fixed $d021, got colour {bg}")
    return data


def _koala_cell(kla: bytes, col: int, row: int) -> bytes:
    """8 bitmap bytes + 1 screen byte + 1 colour byte for the C64 cell at
    (col, row) in hud.kla's 40x25 grid -- exactly the raw multicolor bitmap
    layout BITMAP0/1 + SCREEN0/1 + $D800 already use, so packing this is a
    crop, not a conversion."""
    n = row * HUD_BG_CELLS_W + col
    bitmap = kla[KOALA_BITMAP_OFS + n * 8: KOALA_BITMAP_OFS + n * 8 + 8]
    screen = kla[KOALA_SCREEN_OFS + n]
    color = kla[KOALA_COLOR_OFS + n] & 0x0F
    return bitmap + bytes((screen, color))


def _hud_fallback_cell(pattern: int) -> bytes:
    """A cell for the TEST map, which has no hud.kla to crop from. Not
    trying to look like anything -- just a fixed, checkable raw cell, the
    same role _pattern_tile plays for WALLTEX's test-map path."""
    if pattern & 1:
        return bytes([0b01010101] * 8) + bytes((0x10, 0x02))  # colour 1 fill
    return bytes(8) + bytes((0x00, 0x00))                     # background


def build_hudbg(kla: bytes = None) -> bytes:
    """Block 8: HUD_BG_CELLS_W x HUD_BG_CELLS_H cells, row-major, cropped
    from hud.kla at (HUD_BAR_COL0, HUD_BAR_ROW0).

    Without a hud.kla (the test map) this is a fixed placeholder pattern
    instead, at full size either way -- build_walltex's own reasoning
    applies here too: the two images should differ only in content, not in
    code path.
    """
    if kla is None:
        return b"".join(
            _hud_fallback_cell((cx + cy) & 1)
            for cy in range(HUD_BG_CELLS_H) for cx in range(HUD_BG_CELLS_W))
    return b"".join(
        _koala_cell(kla, HUD_BAR_COL0 + cx, HUD_BAR_ROW0 + cy)
        for cy in range(HUD_BG_CELLS_H) for cx in range(HUD_BG_CELLS_W))


def build_hudfont(kla: bytes = None) -> bytes:
    """Block 9: HUD_FONT_GLYPHS glyphs, each HUD_FONT_CELLS_W x _H cells,
    row-major within the glyph, cropped from hud.kla starting at
    (HUD_FONT_COL0, HUD_FONT_ROW0), digits left to right.
    """
    if kla is None:
        return b"".join(
            _hud_fallback_cell(d + i)
            for d in range(HUD_FONT_GLYPHS)
            for i in range(HUD_FONT_CELLS_W * HUD_FONT_CELLS_H))
    out = bytearray()
    for d in range(HUD_FONT_GLYPHS):
        col0 = HUD_FONT_COL0 + d * HUD_FONT_CELLS_W
        for cy in range(HUD_FONT_CELLS_H):
            for cx in range(HUD_FONT_CELLS_W):
                out += _koala_cell(kla, col0 + cx, HUD_FONT_ROW0 + cy)
    return bytes(out)


# ----------------------------------------------------------------------------
# The weapon view — IMPLEMENTATION_PLAN.md §12a. Block 10.
#
# One static pose, the shotgun, screen-fixed: not a world Thing, so none of
# §12's transform, sort or per-subsector pickup applies to it.
#
# SIZE IS DOOM'S OWN, not §12a's proposed 96x56. SHTGA0 is 79x60 of Doom's
# 320x200, i.e. 24.7% of the screen's width. This viewport is 160 columns of
# 2:1 pixels covering the same 320, so faithful is 79/2 = 40 columns -- and 40
# columns is 1120 packed bytes against 96's 2688, which matters because the
# block is streamed every frame (below) and REU bytes are 1 us each flat.
# §12a's 60%-of-the-width figure would have made the gun more than twice as
# wide as the one in Doom.
#
# Both axes are cell-aligned deliberately (WPN_COL0 = 60 = 15 cells of 4,
# WPN_ROW0 = 88 = 11 cell-rows of 8, WPN_H = 56 = 7 cell-rows). Cell-aligned
# in MATRIX rows is enough: the converter shifts the whole buffer down by a
# whole number of cell-rows (VIEWTOP, src/defs.asm), so alignment survives the
# trip to the bitmap. A VIC
# multicolor cell carries one 3-colour ramp, so a weapon whose edge fell
# mid-cell would drag its ramp into the wall behind it -- M1 risk #5, and the
# one form of attribute clash that is free to avoid.
#
# STREAMED, NOT RESIDENT, and that is a RAM decision rather than a speed one:
# the 2816 B that §12's viewport cut freed is the only contiguous code-capable
# block in the machine, and §12's sprite art plus this phase's code already
# spend it. 1120 B/frame is 1.12 ms of the ~11 ms free (§14a.1's measurement
# plus §13's landing note), and unlike the sprite art it cannot be cached
# anywhere: nothing in MATRIX survives a frame.
WPN_LUMP = "SHTGA0"
WPN_W = 40                      # columns, cell-aligned (4 px/cell)
WPN_H = 56                      # rows, cell-aligned (8 px/cell)
WPN_COL0 = 60                   # leftmost viewport column: (160-40)/2, cell 15
WPN_ROW0 = 144 - WPN_H          # 88 -- MATRIX row, not raster row: the gun
                                # sits on the bottom edge of the view
WPN_ROW_BYTES = WPN_W // 2      # 20, two pixels per byte
WPN_ART_BYTES = WPN_H * WPN_ROW_BYTES           # 1120
WPN_SIL_BYTES = WPN_W                           # 40
WPN_BYTES = WPN_SIL_BYTES + WPN_ART_BYTES       # 1160
WPN_RAMP = 14                   # the first of chunky2mc.asm's two spare slots

# Transparency is intensity 0, the convention §12.2 reserves for all of §12's
# art. It costs nothing: light_to_intensity already clamps opaque pixels to
# 2..15 so that a dark surface does not dissolve into the background, which
# leaves 0 and 1 unused and 0 free to mean "not part of the sprite".
SPR_CLEAR = 0
SPR_MIN, SPR_MAX = 2, 15        # the opaque intensity range, SPR_CLEAR excluded

# A destination cell is opaque only if this fraction of the source texels it
# covers are. Sprite edges are what this number is for: take "any coverage" and
# every sprite grows a one-pixel fringe of half-transparent guesswork, which at
# our scale is a visible halo; take "full coverage" and thin things (a barrel's
# rim, a candle) erode away. Half is the ordinary answer and it is what Doom's
# own low-detail mode effectively does.
SPR_COVER = 0.5

# The weapon's own tone curve. Rank spreading (below) normalises every sprite to
# the same *mean* brightness, which is right for props scattered through a level
# and wrong for the one object permanently in front of the camera: E1M1's walls
# are largely stone and tan, both grey-topped, so a gun normalised to mid-grey
# sits in front of grey and disappears.
#
# Two knobs, and only the second one works. Squeezing the range (1..12, then
# 1..8) darkens by pushing the whole distribution down, but because the spread
# is uniform the top goes with it -- at 1..8 the gun is 88% black-and-brown with
# no third tone at all, i.e. a flat silhouette rather than a dark object.
# Raising the rank to a power darkens the *body* while leaving the top rank at
# 1.0, so the barrel highlight survives at full range. Measured over SHTGA0's
# 1292 opaque cells, as the fraction of subpixels each dither code gets:
#
#   range  gamma   black   brown   dgrey   grey
#    2..15   1.0     5.5%   36.2%   39.3%  19.0%   original -- grey on grey
#    1..12   1.0    14.4%   44.6%   37.5%   3.4%   squeezed: highlight gone
#    1..8    1.0    23.5%   64.4%   12.1%   0.0%   squeezed harder: two tones
#    1..15   3.0    41.4%   35.6%   16.5%   6.5%   curved: dark body, lit barrel
#
# (the last two columns are ramp 14's own colours, which dropped a step at each
# end for the same reason -- see chunky2mc.asm. Brown/dgrey/grey is the darkest
# neutral triple the VIC has; below brown there is nothing but blue and black,
# so past this point darkening can only mean *more black*, not darker colours.)
#
# Floor 1, not 0: intensity 0 is SPR_CLEAR and wpnFrame skips those nibbles, so
# a "black" pixel written as 0 would be a hole the world is forbidden to fill
# (colBotSeed has sealed the column) showing last frame's garbage. The black is
# the dither's, not the intensity's -- which is why a curve darkens at all.
WPN_MIN, WPN_MAX = 1, 15
WPN_GAMMA = 3.0


def _picture_intensity_grid(wad: Wad, lump: str, dst_w: int, dst_h: int,
                            lo: int = SPR_MIN, hi: int = SPR_MAX,
                            gamma: float = 1.0) -> list:
    """A Doom picture lump -> dst_w*dst_h intensity nibbles, u-major (column
    x's rows are grid[x*dst_h : (x+1)*dst_h]), SPR_CLEAR where the sprite is
    transparent.

    Box-average of the covered texels per destination cell, then the sprite's
    own distribution spread across lo..hi **by rank, not by value**, optionally
    bent by `gamma` (rank ** gamma, so > 1 darkens the body and leaves the
    brightest cell alone). Both are parameters because the weapon wants a much
    darker curve than world sprites do -- see WPN_GAMMA.

    A linear min..max stretch is what this did first and it produced a black
    blob: SHTGA0's luminance histogram has half its opaque pixels in the bottom
    quarter of its own range and its maximum in a specular highlight a dozen
    pixels wide, so a linear map put 77% of the gun at intensity <= 5. The
    dither turns intensity 3 into one lit pixel in five, and the result reads
    as a silhouette rather than as an object.

    Ranking fixes that by construction: every intensity gets an equal share of
    the sprite's pixels, so the contrast that survives the 4-bit quantisation
    is the contrast *within the sprite*, which is the only kind a foreground
    object needs. Absolute brightness is not preserved and is not wanted --
    nothing downstream compares one sprite's brightness with another's, and
    the walls behind them already normalise per texture (quantise_tile).

    Equal-luminance cells share a rank, so a flat region stays flat rather
    than being split across two intensities by tie-breaking order.
    """
    luma = palette_luma(wad)
    w, h, px = decode_picture(wad.lump(lump))
    acc = [0.0] * (dst_w * dst_h)
    cnt = [0] * (dst_w * dst_h)
    tot = [0] * (dst_w * dst_h)
    for y in range(h):
        for x in range(w):
            k = (x * dst_w // w) * dst_h + (y * dst_h // h)
            tot[k] += 1
            if (x, y) in px:
                acc[k] += luma[px[(x, y)]]
                cnt[k] += 1
    lit = [acc[k] / cnt[k] for k in range(len(acc))
           if tot[k] and cnt[k] >= tot[k] * SPR_COVER]
    if not lit:
        raise ValueError(f"sprite {lump!r} has no opaque cells at "
                         f"{dst_w}x{dst_h} -- it downsampled to nothing")
    # value -> the mean rank of the cells sharing it, as a 0..1 fraction
    order = sorted(lit)
    rank = {}
    i = 0
    while i < len(order):
        j = i
        while j < len(order) and order[j] == order[i]:
            j += 1
        rank[order[i]] = (i + j - 1) / 2.0 / max(1, len(order) - 1)
        i = j
    out = []
    for k in range(len(acc)):
        if not tot[k] or cnt[k] < tot[k] * SPR_COVER:
            out.append(SPR_CLEAR)
            continue
        v = rank[acc[k] / cnt[k]] ** gamma
        out.append(lo + int(round(v * (hi - lo))))
    return out


def _pack_nibbles(px_row: list) -> bytes:
    """A row of intensity nibbles -> two pixels per byte, EVEN x in the LOW
    nibble. The blit reads a byte, masks the low nibble for the left pixel and
    shifts down for the right one, which is one `and` and four `lsr` against
    any other assignment's extra shift."""
    out = bytearray(len(px_row) // 2)
    for i in range(0, len(px_row), 2):
        out[i // 2] = (px_row[i] & 0x0F) | ((px_row[i + 1] & 0x0F) << 4)
    return bytes(out)


def _solid_from_bottom(cols: list, h: int) -> list:
    """Per column, the topmost row from which the column is opaque
    *continuously to the bottom* -- or h if its bottom pixel is clear.

    This is the occlusion pre-seed §12a wants (set colBot[x] here and the wall
    and floor passes never draw the rows the gun covers, which is what makes a
    big weapon cheaper than a small one), and the continuity requirement is
    what keeps it honest. Seeding from the mere topmost opaque pixel would
    also stop the world drawing in any transparent GAP below it -- between the
    barrel and the stock, say -- and a gap the world is forbidden to draw and
    the gun does not paint comes out as a black hole in the middle of the
    screen. Scanning up from the bottom stops at the first such gap, so every
    row the seed closes is a row the blit definitely fills.
    """
    tops = []
    for col in cols:
        r = h
        while r > 0 and col[r - 1] != SPR_CLEAR:
            r -= 1
        tops.append(r)
    return tops


def build_weapon(wad: Wad = None) -> bytes:
    """Block 10: WPN_SIL_BYTES silhouette bytes then WPN_H rows of
    WPN_ROW_BYTES, row-major.

    The silhouette comes first because the engine reads it exactly once, at
    boot, into a resident 40-byte array -- it never changes, so paying 40 REU
    bytes a frame for it would be pure waste -- while the art after it is
    streamed a row at a time into SEGBUF every frame.
    """
    if wad is None:
        # The test map has no WAD. A plain filled block, like _pattern_tile
        # and _hud_fallback_cell: not trying to look like a gun, just
        # something with a known shape that the checks can find.
        cols = [[8 if 8 <= r < WPN_H else SPR_CLEAR for r in range(WPN_H)]
                for _ in range(WPN_W)]
    else:
        grid = _picture_intensity_grid(wad, WPN_LUMP, WPN_W, WPN_H,
                                       WPN_MIN, WPN_MAX, WPN_GAMMA)
        cols = [[grid[x * WPN_H + y] for y in range(WPN_H)]
                for x in range(WPN_W)]
    sil = _solid_from_bottom(cols, WPN_H)
    out = bytearray(bytes(sil))
    for y in range(WPN_H):
        out += _pack_nibbles([cols[x][y] for x in range(WPN_W)])
    assert len(out) == WPN_BYTES, (len(out), WPN_BYTES)
    return bytes(out)


LF_WALKOVER = 0x10              # crossing the line fires it; else the use key
LF_REPEAT = 0x20                # fires again after it has run; else once only

# Doom line special -> what M2 does with it. `sector` says where the moving
# sector comes from: "back" is the line's own back sidedef (Doom's DR doors),
# "tag" is every sector carrying the line's tag.
#
# Everything not in this table becomes a no-op and --validate reports it by
# number, so a map cannot silently lose a mechanism (§11.2 item 5).
LINE_SPECIALS = {
    1:  (LK_DOOR,  LF_REPEAT, "back"),          # DR door, open wait close
    88: (LK_LIFT,  LF_WALKOVER | LF_REPEAT, "tag"),   # WR lift, lower wait raise
    36: (LK_FLOOR, LF_WALKOVER, "tag"),         # W1 floor lower to 8 above highest
    11: (LK_EXIT,  0, "back"),                  # S1 exit -- drawn, does nothing
}

# Doom's door target: the lowest neighbouring ceiling, four units below it, so
# the door leaves a visible lintel rather than sealing flush.
DOOR_LINTEL = 4
# Doom's "lower floor to 8 above the highest neighbouring floor".
FLOOR_STEP_ABOVE = 8

# Block descriptor flags (docs/reu-format.md §2).
#
# BF_PAGES exists for exactly one reason: the music stream is ~400 KB and the
# descriptor's length field is 16 bits. Resident blocks never set it -- they
# are all under 3 KB and mapload.asm reads their length in bytes -- so the
# 6502 side needs no change, but `u64push.py` sizes the upload from these
# descriptors and does.
BF_RESIDENT = 1
BF_PAGES = 2

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
# It used to be 128 KB, VICE's smallest REU and the smallest real 1750. The
# music stream took it to 512 KB: DooM_Medley is 7:22 of delta-encoded SID
# registers, 405 KB, and it goes above the probe scratch at 64 KB rather than
# below it (MUSIC_OFFSET). The Makefile runs -reusize 512 to match, and one
# artifact still serves both VICE and the Ultimate.
#
# The size is fixed rather than fitted to the content on purpose: VICE demands
# an exact match against -reusize, and a size that moved with the tune would
# put a number in a build artifact that the Makefile has to guess.
REU_IMAGE_SIZE = 512 * 1024

# The music stream starts on a bank boundary above reuProbe's scratch, so the
# map image below it keeps the whole 64 KB it had and nothing has to move when
# a tune changes length.
MUSIC_OFFSET = 0x010000

# The stream's own 16-byte header, written by tools/sidstream.py and read by
# src/music.asm at boot. Frozen in docs/reu-format.md §4.6.
MUSIC_MAGIC = b"MU"
MUSIC_VERSION = 1
MUSIC_HEADER_SIZE = 16

# The DMA window the engine fetches per tick -- MUSWINDOW in src/defs.asm. The
# stream's header says how big a window its longest record needs; this is the
# ceiling the player can actually offer, and a stream asking for more is
# rejected here rather than replayed from a truncated record.
MUSWINDOW = 40

LOAD_MAPINFO = 0x0E00
LOAD_NODES = 0xD000
LOAD_SECTORS = 0xDC00

MAPINFO_SIZE = 32
NO_BACK_SECTOR = 0xFF           # matches testmap.asm's wBack sentinel

MAPID_TEST, MAPID_E1M1 = 0, 1

# ----------------------------------------------------------------------------
# Ramp assignment — the M1 art-direction knob.
#
# chunky2mc.asm defines 16 ramps of 3 colours each. 0-7 came from M1, 8 is the
# HUD's, and 9-13 were filled in M2 (IMPLEMENTATION_PLAN.md §10.7) because a
# texture tile can only modulate intensity -- colour has to come from here.
# 14-15 are still stone duplicates and are free.
#
# Matching is by prefix, longest first, so STARTAN3 beats STAR*. Anything
# unmatched falls back to DEFAULT_RAMP and is reported by --report so a texture
# that quietly landed on the default can be spotted.
# ----------------------------------------------------------------------------

STONE, WOOD, FLESH, SKY, MOSS, VIOLET, METAL, FIRE = range(8)
# 8 is HUD_RAMP. 9-13 were claimed 2026-08-13 -- see chunky2mc.asm's table and
# IMPLEMENTATION_PLAN.md §10.7: a tile modulates intensity only, so material
# colour has to come from the ramp, and six ramps across 32 wall textures is
# what made distinct materials read alike.
TAN, SLIME, TECH, DOOR, LITE = range(9, 14)

RAMP_NAMES = ["stone", "wood", "flesh", "sky", "moss",
              "violet", "metal", "fire", "hud",
              "tan", "slime", "tech", "door", "lite", "spare14", "spare15"]

DEFAULT_RAMP = STONE

# Wall textures. E1M1 uses 32 distinct names; every one of them is covered here.
WALL_RAMPS = {
    # brown/tan structural — the bulk of E1M1's corridors
    "BROWN1": WOOD, "BROWN144": WOOD, "BROWN96": WOOD,
    "BRNBIGL": WOOD, "BRNBIGR": WOOD, "BRNBIGC": WOOD,
    "STARTAN": TAN,                      # STARTAN1, STARTAN3 — tan over grey,
                                         # not the brown BROWN* is
    # brown-green: split off from plain brown so the two read apart
    "BROWNGRN": MOSS,
    "SLADWALL": SLIME, "NUKE24": SLIME,  # slime and nukage surrounds
    # grey structural
    "STARG": STONE, "STARGR": STONE,
    "SUPPORT2": METAL, "DOORSTOP": METAL, "DOORTRAK": METAL,
    "STEP1": METAL, "STEP6": METAL,
    # doors read as their own material, and the jambs stay METAL so the door
    # is visibly a different surface from the frame it sits in
    "BIGDOOR": DOOR, "DOOR3": DOOR, "EXITDOOR": DOOR, "SW1STRTN": DOOR,
    # computers and tech panels — the strongest landmark in E1M1. The flat
    # blue screens stay SKY; the banks with white readouts get TECH
    "TEKWALL": SKY, "COMPTILE": SKY, "PLANET1": SKY,
    "COMPUTE2": TECH, "COMPTALL": TECH, "COMPSPAN": TECH,
    # lit things
    "LITE3": LITE, "EXITSIGN": LITE,
}

# Flats (floors and ceilings).
FLAT_RAMPS = {
    "FLOOR4_8": STONE, "FLOOR5_1": STONE, "FLOOR5_2": STONE,
    "FLOOR7_1": STONE, "FLOOR7_2": STONE, "FLOOR6_2": STONE, "FLOOR1_1": STONE,
    "CEIL3_5": STONE, "CEIL5_1": STONE, "CEIL5_2": STONE,
    "FLAT18": STONE, "FLAT23": STONE,
    "FLAT14": WOOD, "FLAT5_5": WOOD,
    "FLAT20": METAL, "STEP2": METAL,
    "NUKAGE3": SLIME,
    "F_SKY1": SKY,
    "TLITE6": LITE,                      # TLITE6_1/4/5/6
}


# ----------------------------------------------------------------------------
# Texture families — the Stage A texturing knob, and the sibling of the ramp
# table above. A family is a group of E1M1 wall textures that share one 8x8
# intensity tile, and the tile is the downsample of the family's *representative*
# texture, named here rather than derived, so that the art decision is visible.
#
# Sixteen families is the hard cap (the id is a nibble), and E1M1's 30 distinct
# wall texture names fit in fifteen of them with family 0 left for "this surface
# has no texture in the WAD either" — the 177 segs whose front sidedef carries
# none. Family 0's tile is deliberately uniform and the validator exempts it;
# every other tile must have structure or it is a silently untextured wall.
#
# Matching is by longest prefix, exactly like pick_ramp, so STARTAN3 and
# STARTAN1 land together without either being spelled out twice.
# ----------------------------------------------------------------------------

TEX_PLAIN = 0                   # no texture on the sidedef; uniform tile

# A sidedef that *does* name a texture the table below does not know falls back
# to this family rather than to TEX_PLAIN. The two cases are different and only
# one is a miss: "the WAD put no texture here" is a fact about the map and must
# stay untextured, while "this name is not in our table" is our gap, and a
# generic panel tile is a better answer than a flat wall. STARTAN3 is the
# nearest thing E1M1 has to a default surface. --report still counts the miss.
TEX_FALLBACK = 2                # STARTAN3

# family id -> the WAD texture whose 8x8 downsample becomes the tile.
# None means "synthesise a uniform tile" and is only legal for TEX_PLAIN.
FAMILY_TEXTURE = [
    None,                       # 0  plain
    "BROWNGRN",                 # 1  the brown-green that lines E1M1's corridors
    "STARTAN3",                 # 2
    "BROWN1",                   # 3
    "SUPPORT2",                 # 4  metal banding; STEP1 rides along
    "STARG3",                   # 5
    "PLANET1",                  # 6
    "LITE3",                    # 7  the light strips
    "COMPTILE",                 # 8
    "NUKE24",                   # 9  slime surrounds
    "DOORSTOP",                 # 10 door jambs and tracks
    "COMPTALL",                 # 11 the big computer banks
    "TEKWALL4",                 # 12
    "EXITSIGN",                 # 13
    "EXITDOOR",                 # 14 doors proper
    "BRNBIGC",                  # 15
]
assert len(FAMILY_TEXTURE) == TEX_FAMILIES

# Every distinct wall texture name in E1M1, by prefix, onto a family.
WALL_TEX_FAMILY = {
    "BROWNGRN": 1,
    "STARTAN": 2,                                   # STARTAN1, STARTAN3
    "BROWN1": 3, "BROWN144": 3, "BROWN96": 3,
    "SUPPORT2": 4, "STEP1": 4, "STEP6": 4,
    "STARG": 5, "STARGR": 5,
    "PLANET1": 6,
    "LITE3": 7,
    "COMPTILE": 8,
    "NUKE24": 9, "SLADWALL": 9,
    "DOORSTOP": 10, "DOORTRAK": 10,
    "COMPTALL": 11, "COMPUTE2": 11, "COMPSPAN": 11,
    "TEKWALL": 12,
    "EXITSIGN": 13,
    "EXITDOOR": 14, "BIGDOOR": 14, "DOOR3": 14, "SW1STRTN": 14,
    "BRNBIG": 15,                                   # BRNBIGL/C/R
}


def pick_ramp(name: str, table: dict, misses: Counter,
              default: int = DEFAULT_RAMP) -> int:
    """Longest-prefix match of a Doom texture/flat name onto a ramp or family id.

    Both lookups have the same shape -- a prefix table, a fallback, and a counter
    so that --report can name what fell through -- so both use this.
    """
    name = name.upper()
    best = None
    for key in table:
        if name.startswith(key) and (best is None or len(key) > len(best)):
            best = key
    if best is None:
        misses[name] += 1
        return default
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

    def lump(self, name: str) -> bytes:
        """A whole lump by name, first match. Textures are global, not per-map,
        so they come through here rather than through map_lumps."""
        for n, ofs, size in self.dir:
            if n == name:
                return self.data[ofs:ofs + size]
        raise ValueError(f"no lump {name!r} in WAD")

    def records(self, lumps: dict, name: str, fmt: str) -> list:
        ofs, size = lumps[name]
        step = struct.calcsize(fmt)
        if size % step:
            raise ValueError(f"{name}: {size} bytes is not a multiple of {step}")
        return [struct.unpack_from(fmt, self.data, ofs + i * step)
                for i in range(size // step)]


# ----------------------------------------------------------------------------
# Wall textures out of the WAD, down to 8x8 intensity tiles.
#
# A Doom wall texture is a composite: TEXTURE1 gives its size and a list of
# patches with origins, and each patch is a lump in the column-post "picture"
# format. None of that survives into the image — what ships is an 8x8 grid of
# intensity nibbles per family — but the downsample has to be done on the real
# pixels or the tile is a guess. Two sessions of M1 went to things that were
# estimated rather than measured (IMPLEMENTATION_PLAN.md §4); a texture that
# reads as the wrong material is the same mistake in the art direction.
# ----------------------------------------------------------------------------

def palette_luma(wad: Wad) -> list:
    """PLAYPAL entry -> perceptual luminance, 0-255."""
    pal = wad.lump("PLAYPAL")[:768]
    return [0.299 * pal[i * 3] + 0.587 * pal[i * 3 + 1] + 0.114 * pal[i * 3 + 2]
            for i in range(256)]


def read_pnames(wad: Wad) -> list:
    d = wad.lump("PNAMES")
    n = struct.unpack_from("<i", d, 0)[0]
    return [d[4 + i * 8:12 + i * 8].rstrip(b"\0").decode("ascii", "replace").upper()
            for i in range(n)]


def read_texture1(wad: Wad) -> dict:
    """TEXTURE1 -> {name: (width, height, [(originx, originy, patchid), ...])}"""
    d = wad.lump("TEXTURE1")
    n = struct.unpack_from("<i", d, 0)[0]
    out = {}
    for o in struct.unpack_from("<%di" % n, d, 4):
        name = d[o:o + 8].rstrip(b"\0").decode("ascii", "replace").upper()
        _masked, w, h, _cdir, npatch = struct.unpack_from("<ihhih", d, o + 8)
        patches = [struct.unpack_from("<hhhhh", d, o + 22 + i * 10)[0:3]
                   for i in range(npatch)]
        out[name] = (w, h, patches)
    return out


def decode_picture(data: bytes) -> tuple:
    """Doom picture format -> (w, h, {(x, y): palette index}).

    Columns are lists of posts, each `topdelta, length, pad, pixels..., pad`,
    terminated by a topdelta of $FF. Gaps between posts are transparent and are
    simply absent from the dict, which is what makes the downsample below
    average over the covered texels only.
    """
    w, h = struct.unpack_from("<hh", data, 0)
    colofs = struct.unpack_from("<%dI" % w, data, 8)
    px = {}
    for x in range(w):
        p = colofs[x]
        while data[p] != 0xFF:
            top, ln = data[p], data[p + 1]
            p += 3
            for i in range(ln):
                y = top + i
                if 0 <= y < h:
                    px[(x, y)] = data[p + i]
            p += ln + 1
    return w, h, px


def texture_luma_tile(wad: Wad, name: str, tex1: dict, pnames: list,
                      luma: list) -> list:
    """A wall texture -> TEX_TILE_TEXELS mean luminances, column-major."""
    if name not in tex1:
        raise ValueError(f"texture {name!r} is not in TEXTURE1")
    w, h, patches = tex1[name]
    acc = [0.0] * TEX_TILE_TEXELS
    cnt = [0] * TEX_TILE_TEXELS
    for ox, oy, pid in patches:
        _pw, _ph, px = decode_picture(wad.lump(pnames[pid]))
        for (x, y), c in px.items():
            tx, ty = x + ox, y + oy
            if 0 <= tx < w and 0 <= ty < h:
                k = (tx * TEX_TILE_W // w) * TEX_TILE_H + (ty * TEX_TILE_H // h)
                acc[k] += luma[c]
                cnt[k] += 1
    if not any(cnt):
        raise ValueError(f"texture {name!r} has no opaque pixels")
    mean = sum(acc) / sum(cnt)
    return [acc[k] / cnt[k] if cnt[k] else mean for k in range(TEX_TILE_TEXELS)]


def quantise_tile(lum: list) -> list:
    """TEX_TILE_TEXELS luminances -> as many intensity nibbles centred on TEX_MID.

    The centre is the tile's own mid-range rather than its mean: a texture that
    is mostly one shade with a bright stripe (LITE3) should have the stripe read
    as bright and the field as neutral, not the field read as dark because the
    stripe pulled the mean up.
    """
    lo, hi = min(lum), max(lum)
    mid = (lo + hi) / 2.0
    out = []
    for v in lum:
        d = int(round((v - mid) * TEX_GAIN))
        out.append(max(TEX_MID - TEX_SWING, min(TEX_MID + TEX_SWING, TEX_MID + d)))
    return out


def pack_tile(nibbles: list) -> bytes:
    """TEX_TILE_TEXELS nibbles, column-major, -> TEX_TILE_BYTES: v even high.

    Column-major because the engine unpacks one *u column* at a time into an
    16-byte strip and then walks v down the screen inside it — see
    IMPLEMENTATION_PLAN.md §10.3. Even v in the high nibble so that a hex dump
    of the block reads top-to-bottom in the order the wall is drawn.
    """
    out = bytearray(TEX_TILE_BYTES)
    for u in range(TEX_TILE_W):
        for v in range(0, TEX_TILE_H, 2):
            hi = nibbles[u * TEX_TILE_H + v] & 0x0F
            lo = nibbles[u * TEX_TILE_H + v + 1] & 0x0F
            out[u * (TEX_TILE_H // 2) + v // 2] = (hi << 4) | lo
    return bytes(out)


# The test map's tiles, as patterns rather than as textures.
#
# The test map is what a renderer change is brought up on before E1M1's 732 segs
# are involved, and a uniform tile would make it useless for exactly the change
# it now has to serve. Each pattern is chosen so that a specific mapping bug is
# obvious by eye and cannot be confused with another one:
#
#   "vbars"  varies in u only -- any wobble is the perspective u interpolation
#   "hbars"  varies in v only -- any wobble is the v step, i.e. the wall scale
#   "check"  varies in both  -- catches u and v swapped, which the two above
#                              cannot: each looks correct through the other's eye
#   "frame"  a border        -- shows where one tile ends and the next begins,
#                              which is what a seg-to-seg seam looks like
#
# Amplitude is TEX_SWING so the patterns exercise the same clamp the real tiles
# are checked against.
def _pattern_tile(kind: str) -> list:
    lo, hi = TEX_MID - TEX_SWING, TEX_MID + TEX_SWING
    out = []
    for u in range(TEX_TILE_W):
        for v in range(TEX_TILE_H):
            if kind == "vbars":
                out.append(hi if (u & 2) else lo)
            elif kind == "hbars":
                out.append(hi if (v & 2) else lo)
            elif kind == "check":
                out.append(hi if ((u ^ v) & 1) else lo)
            else:                                       # frame
                edge = u in (0, TEX_TILE_W - 1) or v in (0, TEX_TILE_H - 1)
                out.append(hi if edge else lo)
    return out


TEST_PATTERNS = ["vbars", "hbars", "check", "frame"]


def build_walltex(wad: Wad = None) -> bytes:
    """Block 6: TEX_FAMILIES tiles of TEX_TILE_BYTES, in family order.

    Without a WAD (the test map) the families get the patterns above instead of
    downsampled textures. The block is emitted at full size either way, so the
    two images differ only in their contents and the engine has one code path.
    """
    tiles = []
    if wad is not None:
        luma = palette_luma(wad)
        pnames = read_pnames(wad)
        tex1 = read_texture1(wad)
    for fam, name in enumerate(FAMILY_TEXTURE):
        if fam == TEX_PLAIN:
            tiles.append(pack_tile([TEX_MID] * TEX_TILE_TEXELS))
        elif wad is None:
            tiles.append(pack_tile(
                _pattern_tile(TEST_PATTERNS[(fam - 1) % len(TEST_PATTERNS)])))
        else:
            tiles.append(pack_tile(quantise_tile(
                texture_luma_tile(wad, name, tex1, pnames, luma))))
    return b"".join(tiles)


# ----------------------------------------------------------------------------
# The in-memory map, in the form the packers want. Both the WAD path and the
# test-map path produce one of these, and nothing downstream can tell which.
# ----------------------------------------------------------------------------

class Seg:
    __slots__ = ("x0", "y0", "x1", "y1", "front", "back", "ramp", "tex")

    def __init__(self, x0, y0, x1, y1, front, back, ramp, tex=TEX_PLAIN):
        self.x0, self.y0, self.x1, self.y1 = x0, y0, x1, y1
        self.front = front              # sector id
        self.back = back                # sector id, or None if one-sided
        self.ramp = ramp
        self.tex = tex                  # texture family, 0-15 (block 6)

    def __repr__(self):
        return (f"Seg(({self.x0},{self.y0})->({self.x1},{self.y1}) "
                f"f={self.front} b={self.back} r={self.ramp} t={self.tex})")


class Line:
    """A special linedef, with its tag, trigger and target already resolved."""
    __slots__ = ("kind", "sector", "trig", "target", "doom")

    def __init__(self, kind, sector, trig, target, doom):
        self.kind = kind                # LK_* | LF_*
        self.sector = sector            # the sector this line moves
        self.trig = trig                # the sector that fires it
        self.target = target            # height it moves to
        self.doom = doom                # the WAD's own special number, --report

    def __repr__(self):
        return (f"Line(kind=${self.kind:02x} sec={self.sector} "
                f"trig={self.trig} target={self.target} doom={self.doom})")


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
        self.tex_misses = Counter()     # wall textures with no family (Stage A)
        self.tex_used = Counter()       # segs per family, for --report
        self.lines: list[Line] = []     # special linedefs only (block 7)
        self.line_drops = Counter()     # Doom specials M2 does not implement

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

def extract_lines(m: MapData, lines, sides, verts, wsecs) -> None:
    """Fill m.lines with the special linedefs, tags and targets resolved.

    Doom does both of those resolutions at runtime, walking every sector for a
    tag and every neighbour for a height. The engine can do neither -- SECTAB
    carries no tag and there is no adjacency anywhere in the image -- and it
    does not have to, because nothing in M2 changes what the answer would be.
    See the LINE_SPECIALS comment for the one case that stops being exact.
    """
    # Sector adjacency, from the WAD's own two-sided lines. A sector is not its
    # own neighbour: Doom's height searches exclude the moving sector, which is
    # the difference between a door that opens and a door that computes its
    # target as its own closed ceiling and never moves.
    neigh = defaultdict(set)
    for _v1, _v2, _flags, _spec, _tag, right, left in lines:
        if right == 0xFFFF or left == 0xFFFF:
            continue
        a, b = sides[right][5], sides[left][5]
        if a != b:
            neigh[a].add(b)
            neigh[b].add(a)

    def lowest_ceiling(sec):
        return min((wsecs[n][1] for n in neigh[sec]), default=wsecs[sec][1])

    def lowest_floor(sec):
        return min((wsecs[n][0] for n in neigh[sec]), default=wsecs[sec][0])

    def highest_floor(sec):
        return max((wsecs[n][0] for n in neigh[sec]), default=wsecs[sec][0])

    for _idx, (_v1, _v2, _flags, spec, tag, right, left) in enumerate(lines):
        if not spec:
            continue
        if spec not in LINE_SPECIALS:
            m.line_drops[spec] += 1
            continue
        kind, flags, where = LINE_SPECIALS[spec]

        front_sec = sides[right][5] if right != 0xFFFF else None
        back_sec = sides[left][5] if left != 0xFFFF else None

        if where == "back":
            if back_sec is None:
                # A one-sided line has no sector behind it to move. That is
                # normal for LK_EXIT (nothing moves) and a mapping error for a
                # door, which is what the drop counter is for.
                if kind != LK_EXIT:
                    m.line_drops[spec] += 1
                    continue
                targets = [front_sec]
            else:
                targets = [back_sec]
        else:
            targets = [i for i, s in enumerate(wsecs) if s[6] == tag]
            if not targets:
                m.line_drops[spec] += 1
                continue

        # Which sector fires it. A door is opened by facing the door sector
        # itself, so the trigger is the sector that moves. A walkover fires on
        # entering either sector the line divides -- Doom's W1 and WR trigger
        # from both sides, and a trigger sector only sees one, so the line
        # emits a record per side.
        if flags & LF_WALKOVER:
            trigs = [s for s in (front_sec, back_sec) if s is not None]
        else:
            trigs = [None]                      # "the sector that moves"

        for sec in targets:
            if kind == LK_DOOR:
                target = lowest_ceiling(sec) - DOOR_LINTEL
            elif kind == LK_LIFT:
                target = lowest_floor(sec)
            elif kind == LK_FLOOR:
                target = highest_floor(sec) + FLOOR_STEP_ABOVE
            else:
                target = 0
            for trig in trigs:
                m.lines.append(Line(kind | flags, sec,
                                    sec if trig is None else trig,
                                    target, spec))

    if len(m.lines) > MAXLINES:
        raise ValueError(
            f"{m.name}: {len(m.lines)} special lines, MAXLINES is {MAXLINES} "
            "-- raise it here and the LINEGEO/LINESPEC arrays in src/defs.asm "
            "together, and check they still fit the two holes under I/O")
    # A door whose target is at or below its closed ceiling never opens, and it
    # renders and collides exactly like a wall, so nothing on the machine would
    # say so. Doom has the same failure and calls it a mapping error.
    for ln in m.lines:
        if ln.kind & 0x0F == LK_DOOR and ln.target <= wsecs[ln.sector][1]:
            raise ValueError(
                f"{m.name}: door sector {ln.sector} opens to {ln.target} but "
                f"is closed at {wsecs[ln.sector][1]} -- it would never move")


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

    def side_family(idx):
        """Texture family from a sidedef, by the same precedence as side_ramp.

        A sidedef with no texture at all is TEX_PLAIN, not a miss: 177 of E1M1's
        732 segs are two-sided lines the WAD itself leaves untextured, and
        counting those as unmatched would bury a genuine miss in the noise. A
        sidedef that names an unknown texture *is* a miss, and gets
        TEX_FALLBACK — see there.
        """
        if idx == 0xFFFF:
            return TEX_PLAIN
        _xo, _yo, upper, lower, middle, _sec = sides[idx]
        for tex in (middle, upper, lower):
            name = txt(tex)
            if name and name != "-":
                return pick_ramp(name, WALL_TEX_FAMILY, m.tex_misses,
                                 TEX_FALLBACK)
        return TEX_PLAIN

    segs = []
    for v1, v2, _angle, linedef, side, _offset in wsegs:
        right, left = lines[linedef][5], lines[linedef][6]
        front_sd, back_sd = (right, left) if side == 0 else (left, right)
        x0, y0 = verts[v1]
        x1, y1 = verts[v2]
        fam = side_family(front_sd)
        m.tex_used[fam] += 1
        segs.append(Seg(x0, y0, x1, y1,
                        side_sector(front_sd), side_sector(back_sd),
                        side_ramp(front_sd), fam))

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

    extract_lines(m, lines, sides, verts, wsecs)

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
    # The test map has no sidedefs to carry a texture name, so a wall's family
    # is its ramp plus one -- distinct per material, and never TEX_PLAIN, which
    # would leave the map untextured and useless for the change it exists to
    # de-risk. The +1 is why the pattern list is indexed from family 1.
    for x0, y0, x1, y1, front, back, framp, bramp in TEST_LINEDEFS:
        segs.append(Seg(x0, y0, x1, y1, front, back, framp,
                        1 + framp % (TEX_FAMILIES - 1)))
        if back is not None:
            # The reverse side of a two-sided line is its own seg, wound the
            # other way so that its front sector is again on the right.
            segs.append(Seg(x1, y1, x0, y0, back, front, bramp,
                            1 + bramp % (TEX_FAMILIES - 1)))

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


def pack_linedefs(m: MapData) -> bytes:
    """Block 7: the special lines, SoA, MAXLINES bytes per field.

    Streamed rather than resident, and copied into place at $DB40 by lineLoad:
    a resident block's home is a *page* in its descriptor (docs/reu-format.md
    §2) and the free RAM under I/O does not start on one.
    """
    cols = [bytearray(MAXLINES) for _ in range(LINE_ARRAYS)]
    for i, ln in enumerate(m.lines):
        t = _s16(ln.target, "line target height")
        cols[0][i] = ln.kind & 0xFF
        cols[1][i] = ln.sector & 0xFF
        cols[2][i] = ln.trig & 0xFF
        cols[3][i], cols[4][i] = t & 0xFF, t >> 8
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
                             s.x0, s.y0, s.x1, s.y1, back,
                             ((s.ramp & 0x0F) << 4) | (s.tex & 0x0F))
            p += SEG_RECORD
    return bytes(out)


def pack_mapinfo(m: MapData, ssec_reu_base: int, spawn_ssec: int,
                 sph_reu_base: int, mus_reu_base: int = 0,
                 tex_reu_base: int = 0) -> bytes:
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
    b[25] = mus_reu_base & 0xFF                 # MUSIC, streamed; 0 = no tune
    b[26] = (mus_reu_base >> 8) & 0xFF
    b[27] = (mus_reu_base >> 16) & 0xFF
    b[28] = tex_reu_base & 0xFF                 # WALLTEX, streamed 32 B/family
    b[29] = (tex_reu_base >> 8) & 0xFF
    b[30] = (tex_reu_base >> 16) & 0xFF
    return bytes(b)


def build_image(m: MapData, music: bytes = b"", walltex: bytes = b"",
                hudbg: bytes = b"", hudfont: bytes = b"",
                weapon: bytes = b"") -> bytes:
    """Assemble the whole .reu image. Blocks follow the header in id order,
    each padded up to a 256-byte boundary (docs/reu-format.md §3).

    `music` is a stream from tools/sidstream.py, or empty for no music. It is
    the one block that does not follow its predecessor: it starts at the fixed
    MUSIC_OFFSET, above reuProbe's scratch, so that the map below it keeps the
    whole first 64 KB and nothing has to move when a tune changes length. An
    empty stream leaves `miMusBase` at zero, which src/music.asm reads as
    "render in silence" rather than as an error.
    """
    nodes = pack_nodes(m)
    sectors = pack_sectors(m)
    ssecdata = pack_ssecdata(m)
    nodesph = pack_nodesph(m)
    linedefs = pack_linedefs(m)

    # MAPINFO needs SSECDATA's offset, and SSECDATA's offset depends only on
    # the fixed sizes ahead of it, so the layout is computed before packing it.
    def align(n):
        return (n + BLOCK_ALIGN - 1) // BLOCK_ALIGN * BLOCK_ALIGN

    ofs_mapinfo = align(HEADER_SIZE)
    ofs_nodes = ofs_mapinfo + align(MAPINFO_SIZE)
    ofs_sectors = ofs_nodes + align(len(nodes))
    ofs_ssecdata = ofs_sectors + align(len(sectors))
    ofs_nodesph = ofs_ssecdata + align(len(ssecdata))
    ofs_walltex = ofs_nodesph + align(len(nodesph))
    ofs_hudbg = ofs_walltex + align(len(walltex))
    ofs_hudfont = ofs_hudbg + align(len(hudbg))
    ofs_lines = ofs_hudfont + align(len(hudfont))
    ofs_weapon = ofs_lines + align(len(linedefs))

    ofs_music = MUSIC_OFFSET if music else 0

    sx, sy, _ = m.spawn
    spawn_ssec = descend(m, sx, sy)
    mapinfo = pack_mapinfo(m, ofs_ssecdata, spawn_ssec, ofs_nodesph, ofs_music,
                           ofs_walltex if walltex else 0)

    blocks = [
        (BLK_MAPINFO, BF_RESIDENT, ofs_mapinfo, mapinfo, LOAD_MAPINFO >> 8),
        (BLK_NODES, BF_RESIDENT, ofs_nodes, nodes, LOAD_NODES >> 8),
        (BLK_SECTORS, BF_RESIDENT, ofs_sectors, sectors, LOAD_SECTORS >> 8),
        (BLK_SSECDATA, 0, ofs_ssecdata, ssecdata, 0),
        (BLK_NODESPH, 0, ofs_nodesph, nodesph, 0),
    ]
    if walltex:
        blocks.append((BLK_WALLTEX, 0, ofs_walltex, walltex, 0))
    # Streamed, and read exactly once, like LINEDEFS below: hudLoad in
    # mapload.asm finds them by block id during the descriptor walk and
    # blits them straight into the bitmap at boot. Neither is resident --
    # nothing reads either block again after that.
    if hudbg:
        blocks.append((BLK_HUDBG, 0, ofs_hudbg, hudbg, 0))
    if hudfont:
        blocks.append((BLK_HUDFONT, 0, ofs_hudfont, hudfont, 0))
    # Streamed, and read exactly once: mapLoad stages it into MATRIX at boot
    # and lineLoad splits it into the two holes under I/O. It is not resident
    # because a resident block's home is a *page* in the descriptor and neither
    # hole starts on one (docs/reu-format.md §4.8).
    blocks.append((BLK_LINEDEFS, 0, ofs_lines, linedefs, 0))
    # Read every frame, not once: weaponBoot keeps the descriptor's REU offset
    # in wpnReuBase and streams the art from it after each renderFrame. It is
    # the first block whose *address* the engine has to remember rather than
    # its contents (docs/reu-format.md §4.9).
    if weapon:
        blocks.append((BLK_WEAPON, 0, ofs_weapon, weapon, 0))
    if music:
        blocks.append((BLK_MUSIC, BF_PAGES, ofs_music, music, 0))

    if 8 + 8 * len(blocks) > HEADER_SIZE:
        raise ValueError(
            f"{len(blocks)} blocks need {8 + 8 * len(blocks)} header bytes and "
            f"the header is {HEADER_SIZE}. Raise it here and HDRSIZE in "
            "src/defs.asm together -- mapload.asm derives MAXDESCS from it and "
            "rejects the image with mapErr=4 (bad block count).")

    used = align(ofs_weapon + len(weapon))
    if used > REU_PROBE_OFFSET:
        raise ValueError(
            f"image is {used} B and would reach REU ${REU_PROBE_OFFSET:06X}, "
            "where reuProbe round-trips its signature at boot (src/defs.asm "
            "REU_PROBE_ADDR/BANK). Move the probe scratch before growing "
            "the image past that.")
    if music and MUSIC_OFFSET < REU_PROBE_OFFSET:
        raise ValueError(
            f"MUSIC_OFFSET ${MUSIC_OFFSET:06X} is below reuProbe's scratch at "
            f"${REU_PROBE_OFFSET:06X}, which would corrupt the stream at boot")
    end = max(used, ofs_music + len(music))
    if end > REU_IMAGE_SIZE:
        raise ValueError(f"image needs {end} B, past REU_IMAGE_SIZE "
                         f"({REU_IMAGE_SIZE} B); raise it and -reusize together")
    img = bytearray(REU_IMAGE_SIZE)
    img[0:4] = MAGIC
    img[4] = VERSION
    img[5] = len(blocks)
    for i, (bid, flags, ofs, payload, loadhi) in enumerate(blocks):
        # The length field is 16 bits. Every block the 6502 reads is well under
        # 64 KB and carries its length in bytes; the music stream is ~400 KB and
        # carries it in pages, flagged BF_PAGES. mapload.asm never sees the
        # difference -- it skips non-resident descriptors before reading a
        # length -- but tools/u64push.py sizes the upload from these and does.
        length = len(payload)
        if flags & BF_PAGES:
            length = (length + BLOCK_ALIGN - 1) // BLOCK_ALIGN
        if length > 0xFFFF:
            raise ValueError(f"block {bid} is {len(payload)} B, too long for "
                             "the 16-bit length field even in pages")
        struct.pack_into("<BBBBBHB", img, 8 + i * 8,
                         bid, flags,
                         ofs & 0xFF, (ofs >> 8) & 0xFF, (ofs >> 16) & 0xFF,
                         length, loadhi)
        img[ofs:ofs + len(payload)] = payload
    return bytes(img)


# ----------------------------------------------------------------------------
# The music stream
# ----------------------------------------------------------------------------

def load_music(path: str) -> bytes:
    """Read a stream from tools/sidstream.py and check its header here.

    The stream is built by a separate tool into build/music.bin because running
    the tune through the 6502 emulator costs seconds and depends on nothing this
    file knows about. What this does check is that the blob is a stream at all
    and that its DMA window fits MUSWINDOW in src/defs.asm -- the engine checks
    that too, at boot, but a build-time failure names the file.
    """
    with open(path, "rb") as fh:
        blob = fh.read()
    if len(blob) < MUSIC_HEADER_SIZE or blob[0:2] != MUSIC_MAGIC:
        raise ValueError(f"{path}: not a music stream (magic {blob[0:2]!r})")
    if blob[2] != MUSIC_VERSION:
        raise ValueError(f"{path}: stream version {blob[2]}, expected "
                         f"{MUSIC_VERSION} -- rebuild it with sidstream.py")
    if not 0 < blob[3] <= MUSWINDOW:
        raise ValueError(f"{path}: DMA window is {blob[3]} B, and src/defs.asm "
                         f"MUSWINDOW is {MUSWINDOW}")
    end = blob[9] | blob[10] << 8 | blob[11] << 16
    if end > len(blob):
        raise ValueError(f"{path}: header says the stream ends at {end}, "
                         f"but the file is {len(blob)} B")
    return blob


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
        if flags & BF_PAGES:
            length *= BLOCK_ALIGN
        if ofs + length > len(img):
            raise ValueError(f"block {bid} runs past the end of the image")
        blocks[bid] = dict(flags=flags, ofs=ofs, length=length,
                           load=loadhi << 8, data=img[ofs:ofs + length])

    mi = blocks[BLK_MAPINFO]["data"]
    numnodes, numssec, numsec, shift = struct.unpack_from("<HHBB", mi, 0)
    ssec_base = mi[6] | (mi[7] << 8) | (mi[8] << 16)
    sph_base = mi[22] | (mi[23] << 8) | (mi[24] << 16)
    mus_base = mi[25] | (mi[26] << 8) | (mi[27] << 16)
    tex_base = mi[28] | (mi[29] << 8) | (mi[30] << 16)
    root, sx, sy, sa, spawn_ssec, spawn_sec, numsegs, mapid = \
        struct.unpack_from("<HhhBHBHB", mi, 9)

    info = dict(numnodes=numnodes, numssec=numssec, numsec=numsec,
                shift=shift, ssec_base=ssec_base, sph_base=sph_base,
                mus_base=mus_base, tex_base=tex_base, root=root,
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
                             ramp >> 4, ramp & 0x0F))
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

    # The special lines (block 7). The failure this is really aimed at is a
    # line that is *present and inert* -- a door whose sector id is wrong moves
    # some other part of the map, and a kind the engine does not know is a wall
    # that never opens. Neither shows up as anything but "the door is broken".
    ld = p["blocks"].get(BLK_LINEDEFS)
    check(ld is not None, "image has no LINEDEFS block")
    if ld is not None:
        check(ld["flags"] & BF_RESIDENT == 0,
              "LINEDEFS must not be resident: its two homes are not page-aligned")
        check(ld["length"] == LINEDEF_BYTES,
              f"LINEDEFS is {ld['length']} B, expected {LINEDEF_BYTES}")
        cols = [ld["data"][i * MAXLINES:(i + 1) * MAXLINES]
                for i in range(LINE_ARRAYS)]
        seen = 0
        for i in range(MAXLINES):
            kind = cols[0][i]
            if kind == 0:
                continue
            seen += 1
            sec = cols[1][i]
            trig = cols[2][i]
            target = cols[3][i] | cols[4][i] << 8
            if target & 0x8000:
                target -= 0x10000
            base = kind & 0x0F
            check(base in (LK_DOOR, LK_LIFT, LK_FLOOR, LK_EXIT),
                  f"line {i} has unknown kind ${kind:02X}")
            check(sec < len(m.sectors),
                  f"line {i} moves sector {sec}, past numsec {len(m.sectors)}")
            check(trig < len(m.sectors),
                  f"line {i} is fired by sector {trig}, past numsec "
                  f"{len(m.sectors)}")
            # A door whose trigger is not the sector it moves cannot be found
            # by the use scan, which walks the segs of the subsector the player
            # is in and matches their back sector.
            check(base != LK_DOOR or trig == sec,
                  f"door line {i} moves sector {sec} but is triggered by "
                  f"{trig}; the use scan only ever finds the moving sector")
            if base == LK_DOOR:
                check(target > m.sectors[sec].ceil,
                      f"door line {i} opens to {target}, at or below its "
                      f"closed ceiling {m.sectors[sec].ceil}")
            if base == LK_LIFT:
                check(target < m.sectors[sec].floor,
                      f"lift line {i} lowers to {target}, at or above its "
                      f"raised floor {m.sectors[sec].floor}")
            check(kind & 0x0F != LK_EXIT or kind & LF_WALKOVER == 0,
                  f"line {i} is a walkover exit, which M2 does not implement")
        check(seen == len(m.lines),
              f"LINEDEFS round-trip: {seen} live records, {len(m.lines)} lines")
        # Two walkover records that share a trigger sector fire together and
        # one of them is redundant; two *different* mechanisms sharing one is
        # a map that plays wrong in a way nothing on the machine reports.
        walk = [(cols[2][i], cols[0][i] & 0x0F) for i in range(MAXLINES)
                if cols[0][i] & LF_WALKOVER]
        check(len(set(walk)) == len(walk),
              f"two walkover records share a trigger sector: {walk}")

    # 10. the music stream, if there is one. miMusBase is what src/music.asm
    # follows, and a zero there means silence -- so the failure this catches is
    # a block that is present and unreachable, which sounds exactly like a
    # build with no tune in it and is not.
    if BLK_MUSIC in p["blocks"]:
        mus = p["blocks"][BLK_MUSIC]
        check(mus["flags"] & BF_RESIDENT == 0, "MUSIC must not be resident")
        check(mus["flags"] & BF_PAGES != 0,
              "MUSIC must set BF_PAGES: its length does not fit 16 bits in bytes")
        check(info["mus_base"] == mus["ofs"],
              "MAPINFO's music base does not point at the MUSIC block")
        check(mus["ofs"] >= REU_PROBE_OFFSET,
              f"MUSIC at ${mus['ofs']:06X} is below reuProbe's scratch")
        head = mus["data"][:MUSIC_HEADER_SIZE]
        check(head[0:2] == MUSIC_MAGIC and head[2] == MUSIC_VERSION,
              "MUSIC block does not start with a v1 stream header")
        check(0 < head[3] <= MUSWINDOW,
              f"MUSIC DMA window {head[3]} exceeds MUSWINDOW {MUSWINDOW}")
        loop = head[6] | head[7] << 8 | head[8] << 16
        end = head[9] | head[10] << 8 | head[11] << 16
        check(MUSIC_HEADER_SIZE <= loop <= end,
              f"MUSIC loop point {loop} is not inside the stream (ends {end})")
        # The player fetches a fixed window and reads the record length out of
        # it, so the last record's fetch runs off the end of the stream by
        # design. sidstream.py pads for that; if it did not, the final tick of
        # every loop would replay whatever follows in the image.
        check(end + head[3] <= len(mus["data"]),
              "MUSIC block has no room for the last record's DMA window")
    else:
        check(info["mus_base"] == 0,
              "MAPINFO points at a music block the image does not contain")

    # 11. the wall texture tiles (IMPLEMENTATION_PLAN.md §10.5).
    #
    # Texturing removes the oracle every M1 optimisation was held to -- "0 of
    # 104448 pixels differ" cannot survive a change that is meant to change
    # every wall pixel. These four checks are what replaces it on the build
    # side: they catch a tile that is missing, a tile that would clip against
    # the intensity range at either end of the depth ramp, a family that no
    # tile backs, and the specific silent failure of a wall that is textured
    # with nothing.
    if BLK_WALLTEX in p["blocks"]:
        tex = p["blocks"][BLK_WALLTEX]
        check(tex["flags"] & BF_RESIDENT == 0, "WALLTEX must not be resident")
        check(tex["length"] == TEX_BLOCK_BYTES,
              f"WALLTEX is {tex['length']} B, expected {TEX_BLOCK_BYTES}")
        check(info["tex_base"] == tex["ofs"],
              "MAPINFO's texture base does not point at the WALLTEX block")
        for fam in range(TEX_FAMILIES):
            tile = tex["data"][fam * TEX_TILE_BYTES:(fam + 1) * TEX_TILE_BYTES]
            nib = [n for b in tile for n in (b >> 4, b & 0x0F)]
            lo, hi = min(nib), max(nib)
            # The engine computes clamp(depth + texel - TEX_MID, 2, 15) with
            # depth in 2..15. Clipping is not a crash, it is a wall that goes
            # flat at one end of its depth range, so it is checked at both.
            check(hi - TEX_MID <= 15 - TEX_MID and TEX_MID - lo <= TEX_MID - 2,
                  f"texture family {fam} swings {lo}..{hi} around {TEX_MID}, "
                  "which clips the intensity nibble at one end of the depth ramp")
            if fam != TEX_PLAIN:
                check(lo != hi,
                      f"texture family {fam} ({FAMILY_TEXTURE[fam]}) is a "
                      "uniform tile -- every seg using it renders untextured")
        # Every family a seg names must have a tile, and the tile block has
        # exactly TEX_FAMILIES of them, so this is a range check on the segs.
        for i, group in enumerate(p["subsectors"]):
            for k, s in enumerate(group):
                check(0 <= s.tex < TEX_FAMILIES,
                      f"subsector {i} seg {k}: texture family {s.tex} has no tile")
    else:
        check(info["tex_base"] == 0,
              "MAPINFO points at a texture block the image does not contain")

    # 12. the HUD blocks (IMPLEMENTATION_PLAN.md §13). No MAPINFO pointer to
    # check -- hudLoad finds them by block id, like LINEDEFS -- so this is
    # presence, size, and the one silent failure worth catching: a glyph or
    # background cell that quantises to uniform intensity, i.e. a blank digit
    # or a blank patch of bar (echoing the WALLTEX check just above).
    hb = p["blocks"].get(BLK_HUDBG)
    check(hb is not None, "image has no HUDBG block")
    if hb is not None:
        check(hb["flags"] & BF_RESIDENT == 0, "HUDBG must not be resident")
        check(hb["length"] == HUD_BG_BYTES,
              f"HUDBG is {hb['length']} B, expected {HUD_BG_BYTES}")
    hf = p["blocks"].get(BLK_HUDFONT)
    check(hf is not None, "image has no HUDFONT block")
    if hf is not None:
        check(hf["flags"] & BF_RESIDENT == 0, "HUDFONT must not be resident")
        check(hf["length"] == HUD_FONT_BYTES,
              f"HUDFONT is {hf['length']} B, expected {HUD_FONT_BYTES}")
        for d in range(HUD_FONT_GLYPHS):
            glyph = hf["data"][d * HUD_FONT_GLYPH_BYTES:
                               (d + 1) * HUD_FONT_GLYPH_BYTES]
            check(len(set(glyph)) > 1,
                  f"digit glyph {d} is uniform -- it will render blank")

    # The weapon: presence, size, and the two properties the blit relies on
    # that a bad downsample would quietly break -- the art must not be blank,
    # and the silhouette must actually agree with the art it claims to
    # describe. The second is the one worth spending cycles on: a silhouette
    # that closes a column the art leaves transparent punches a black hole
    # through the world, and nothing else in the pipeline would notice.
    wp = p["blocks"].get(BLK_WEAPON)
    check(wp is not None, "image has no WEAPON block")
    if wp is not None:
        check(wp["flags"] & BF_RESIDENT == 0, "WEAPON must not be resident")
        check(wp["length"] == WPN_BYTES,
              f"WEAPON is {wp['length']} B, expected {WPN_BYTES}")
        if wp["length"] == WPN_BYTES:
            sil = wp["data"][:WPN_SIL_BYTES]
            art = wp["data"][WPN_SIL_BYTES:]
            check(any(b != 0 for b in art), "the weapon art is entirely clear")
            check(all(t <= WPN_H for t in sil),
                  "a weapon silhouette entry is past the bottom of the art")
            for x in range(WPN_W):
                for y in range(sil[x], WPN_H):
                    byte = art[y * WPN_ROW_BYTES + x // 2]
                    px = (byte >> 4) if (x & 1) else (byte & 0x0F)
                    if px == SPR_CLEAR:
                        bad.append(f"weapon column {x} is sealed from row "
                                   f"{sil[x]} but row {y} is transparent")
                        break

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
            if a.tex != b.tex:
                bad.append(f"subsector {i} seg {k}: texture family changed")
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
RAMP_MID = [0xc, 0x8, 0xa, 0xe, 0x5, 0x4, 0xc, 0x8,   # 0-7
            0x8,                                     # 8  hud
            0xc, 0x7, 0xc, 0x8, 0x7,                 # 9-13 tan slime tech
            0xc, 0xc]                                # door lite, then 14-15


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
    kinds = {LK_DOOR: "door", LK_LIFT: "lift", LK_FLOOR: "floor", LK_EXIT: "exit"}
    live = Counter(kinds[ln.kind & 0x0F] for ln in m.lines)
    print(f"  special lines  {len(m.lines)} / {MAXLINES}   "
          + "  ".join(f"{k}:{v}" for k, v in sorted(live.items())))
    if m.line_drops:
        # Named, not counted: a dropped special is a mechanism the map has and
        # the engine does not, and the plan (§11.2) asks for it by number so
        # that "the map plays wrong" has somewhere to start.
        print("  dropped lines  " + "  ".join(
            f"doom special {k} x{v}" for k, v in sorted(m.line_drops.items())))
    sph = p["node_sph"]
    print(f"  node spheres   max radius {max((r for _, _, r in sph), default=0)}"
          f"  mean {sum(r for _, _, r in sph) / max(1, len(sph)):.0f}")
    for bid, name in ((BLK_MAPINFO, "MAPINFO"), (BLK_NODES, "NODES"),
                      (BLK_SECTORS, "SECTORS"), (BLK_SSECDATA, "SSECDATA"),
                      (BLK_NODESPH, "NODESPH"), (BLK_WALLTEX, "WALLTEX"),
                      (BLK_HUDBG, "HUDBG"), (BLK_HUDFONT, "HUDFONT"),
                      (BLK_LINEDEFS, "LINEDEFS"), (BLK_WEAPON, "WEAPON"),
                      (BLK_MUSIC, "MUSIC")):
        if bid not in p["blocks"]:
            continue
        b = p["blocks"][bid]
        where = f"-> ${b['load']:04X}" if b["flags"] & 1 else "streamed"
        print(f"  block {bid} {name:<9}${b['ofs']:06X} +{b['length']:<6} {where}")
    if BLK_MUSIC in p["blocks"]:
        h = p["blocks"][BLK_MUSIC]["data"][:MUSIC_HEADER_SIZE]
        latch = h[4] | h[5] << 8
        ticks = h[12] | h[13] << 8 | h[14] << 16
        rate = 985248 / (latch + 1)
        print(f"  music          {ticks} ticks at {rate:.2f} Hz "
              f"(CIA latch ${latch:04X}) = {ticks / rate / 60:.0f}:"
              f"{ticks / rate % 60:04.1f}, {h[3]} B DMA window")
    else:
        print("  music          none -- the engine will render in silence")
    if BLK_WALLTEX in p["blocks"]:
        data = p["blocks"][BLK_WALLTEX]["data"]
        segs_per_fam = Counter(s.tex for g in p["subsectors"] for s in g)
        print("  wall textures  " + "  ".join(
            f"{FAMILY_TEXTURE[f] or 'plain'}:{segs_per_fam.get(f, 0)}"
            for f in range(TEX_FAMILIES) if segs_per_fam.get(f)))
        swing = []
        for f in range(TEX_FAMILIES):
            nib = [n for b in data[f * TEX_TILE_BYTES:(f + 1) * TEX_TILE_BYTES]
                   for n in (b >> 4, b & 0x0F)]
            swing.append(max(nib) - min(nib))
        print(f"  tile contrast  min {min(swing)} max {max(swing)} "
              f"(swing around {TEX_MID}, cap {2 * TEX_SWING})")
    if m.ramp_misses:
        print("  UNMAPPED textures (fell back to "
              f"{RAMP_NAMES[DEFAULT_RAMP]}): "
              + ", ".join(f"{k}x{v}" for k, v in m.ramp_misses.most_common()))
    if m.tex_misses:
        print("  UNMAPPED texture families (fell back to "
              f"{FAMILY_TEXTURE[TEX_FALLBACK]}): "
              + ", ".join(f"{k}x{v}" for k, v in m.tex_misses.most_common()))


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("wad", nargs="?", help="path to DOOM1.WAD (not needed for --map TEST)")
    ap.add_argument("-o", "--out", required=True, help="output .reu image")
    ap.add_argument("--map", default="E1M1",
                    help="map lump name, or TEST for the built-in test map")
    ap.add_argument("--hud", default="assets/hud.kla",
                    help="hand-painted Koala Painter image for the status "
                         "bar and digit font (default: %(default)s); if "
                         "missing, a fixed placeholder pattern is used "
                         "instead so a build never hard-fails on it")
    ap.add_argument("--png", help="write a top-down render of the decoded image")
    ap.add_argument("--music", metavar="STREAM",
                    help="a SID register stream from tools/sidstream.py "
                         "(build/music.bin) to embed as block 5; without it "
                         "the engine renders in silence")
    ap.add_argument("--no-validate", action="store_true")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args(argv)

    try:
        kla = load_koala(a.hud) if a.hud and os.path.exists(a.hud) else None
        if a.map.upper() == "TEST":
            m = build_test_map()
            walltex = build_walltex(None)
            hudbg, hudfont = build_hudbg(kla), build_hudfont(kla)
            weapon = build_weapon(None)
        else:
            if not a.wad:
                ap.error("a WAD path is required unless --map TEST")
            wad = Wad(a.wad)
            m = load_wad_map(wad, a.map.upper())
            walltex = build_walltex(wad)
            hudbg, hudfont = build_hudbg(kla), build_hudfont(kla)
            weapon = build_weapon(wad)
        music = load_music(a.music) if a.music else b""
        img = build_image(m, music, walltex, hudbg, hudfont, weapon)
    except (ValueError, OSError) as e:
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

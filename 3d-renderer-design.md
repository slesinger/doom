# C64 Ultimate 3D game — chunky-to-multicolor converter design

Date: 2026-07-03
Target: C64 Ultimate, CPU turbo (budgets computed at 48 MHz — official U64 max; scale down if 64 MHz really available)

> **Status: implemented.** This design is live in
> `src/render/chunky2mc.asm`, and it is the one part of the target architecture
> that Milestone 1 realises in full. This document remains the rationale — the
> byte format, the dithering scheme, the graceful-degradation argument — while
> the source is authoritative for addresses and code.
>
> For how the converter fits into the whole frame, see
> **[`pipeline.md`](pipeline.md)** §10; for the authoritative memory map, §12.2.

## Overview

The 3D pipeline's final stage transforms a 160×176 byte-per-pixel logical framebuffer
("the matrix") into VIC-II multicolor bitmap graphics (bitmap + screen RAM + color RAM),
double-buffered at 25 fps. The design avoids per-cell color quantization entirely by
baking palette discipline into the texture format, so the converter is a pure
table-driven packing loop with ordered dithering at zero runtime cost.

## Matrix byte format

```
bit:  7 6 5 4   3 2 1 0
      ramp id   intensity
      (0-15)    (0-15)
```

- **Ramp (material) id** — one of 16 predefined 3-color luminance ramps. Every ramp
  implicitly starts at **black**, which is the global multicolor background ($D021).
  Examples: stone = black→dk.grey→grey→lt.grey, fire = black→red→orange→yellow.
- **Intensity** — brightness 0..15 along the ramp. Levels 0/5/10/15 are the 4 pure
  colors; in-betweens render as ordered 4×4 Bayer blends of the two neighboring ramp
  colors. 16 perceived shades per material.
- **No depth in the byte.** Visibility is resolved before anything reaches the matrix.
  (This was drafted assuming a back-to-front painter's order; the implemented renderer
  instead walks portals **front-to-back** with per-column clip windows, so each pixel is
  written at most once per sector — see `pipeline.md` §9. Either way the byte carries no
  depth.) If per-pixel flags are ever needed, drop to 8 ramps and free bit 7.

### Why this wins

- **Shading (lit / standard / dark tunnel)** is an intensity transform, pre-baked as
  3 texture variants stored in REU. Zero cycles at rasterization and conversion time.
  Low intensity fades to black → depth cueing / tunnel darkness for free.
- **Texel averaging** (from UV sampling): average the intensity nibbles, keep the ramp.
- **Graceful degradation**: the converter picks ONE ramp per 4×8 cell (sampled from a
  center pixel) and writes its 3 colors to screen/color RAM. Wrong-ramp pixels in the
  cell still map by intensity → right luminance, wrong hue — the error the eye forgives
  most (luminance sensitivity ≫ chroma sensitivity at high spatial frequency).
  No branching, constant time, no attribute garbage.

## Matrix layout (load-bearing decision)

Cell-major, page-aligned: cell n at `MATRIX + n*32`, within a cell `offset = row*4 + px`.
880 cells = exactly 110 pages. This lets the converter use static `ldy MATRIX+ofs,x`
addressing with only 32 operand high-bytes patched per 8 cells.

Rasterizer consequence, as implemented in `spanFill` (`src/math.asm`): spans are
**vertical**, so stepping down a row is `+4` inside a cell and `+1280` ($500) when
crossing to the next cell row — and because $500 has a zero low byte, that crossing
only touches the pointer's high byte. Fills are structured head-pixels /
whole-cells-of-8 / tail-pixels. Pixel address is `rowCellLo/Hi[y>>3] + xOfsLo/Hi[x]`
plus an in-cell `(y&7)*4` offset. (The scanline-major `rowLo`/`rowHi` tables this
document originally specified assumed horizontal spans, were never read, and have
been deleted from `chunky2mc.asm`.) No frame clear needed if the scene overdraws
(floor + ceiling/sky polygons) — the implemented renderer guarantees this, saving
~170k cycles a frame. See `pipeline.md` §9.3.

## Converter mechanics

- 16 lookup tables of 256 bytes (4 pixel positions × 4 Bayer rows) map a raw matrix
  byte directly to a pre-shifted 2-bit pattern — dither, bit position and code
  collapse into one `ldy buf,x : ora tab,y` = 8 cycles/pixel.
- Per-cell attributes: sample pixel at cell offset 13 (row 3, px 1), look up
  screen-RAM byte (`c1<<4|c2`) and color-RAM byte (`c3`) from 256-byte ramp tables.
- Bit codes: %00 = background (black), %01 = screen hi nibble, %10 = screen lo nibble,
  %11 = color RAM.

**Budget: ~415 cycles/cell × 880 ≈ 380k cycles ≈ 8 ms @48 MHz ≈ 20% of a 25 fps frame.**

## Double buffering

Two bitmap+screen pairs in VIC banks 2 and 3, flipped via $DD00/$D018 at vblank.
Color RAM cannot be double-buffered → converter writes a staging buffer (COLBUF)
that is burst-copied to $D800 right after the flip (~7k cycles, fits in vblank).

Memory map (converter's view — the full map is in `pipeline.md` §12.2, and
`src/defs.asm` is authoritative):

```
$0400-$07E7  COLBUF (color-RAM staging, 880 B + 120 B HUD rows)
$1000-$7DFF  MATRIX (28160 B, 110 pages)
$8000-$83FF  SCREEN0            (VIC bank 2)
$8400-$973F  tables (dither 4KB + attr 512B + column helpers)
$9740-$98FF  free (448 B, TABLES_FREE)
$9900-$9B4A  converter code
$A000-$BF3F  BITMAP0            (VIC bank 2)
$C000-$C3FF  SCREEN1            (VIC bank 3)
$E000-$FF3F  BITMAP1 (under Kernal ROM — write-only, fine)
```

**COLBUF moved from `$C400` to `$0400`** when the renderer's math tables (`sqr`,
`sin`, `rowCell`) claimed `$C400-$CA2B`. `$0400` is the default screen page, but
the VIC is banked to 2 or 3 during gameplay, so it is ordinary RAM.

Screens/bitmaps deliberately avoid $9000-$9FFF (char-ROM shadow in VIC bank 2).
Bottom 3 char rows (rows 22-24) of each bitmap/screen are free for a HUD; they
are blanked once at startup by `clearHudRows` in `src/main.asm`.

## REU usage

- Textures stored as 3 pre-shaded variants (lit/standard/dark = intensity remap,
  optionally hue-shifted); DMA in the set for the current zone at load time.
- ~~**Open item:** verify whether U64 REU DMA speed scales with CPU turbo or stays at
  ~1 byte/µs before relying on DMA in any per-frame path.~~
  **Answered 2026-08-09 on a C64 Ultimate** (`make reubench`,
  `IMPLEMENTATION_PLAN.md` §10): **exactly 1 byte/µs, flat across 32 B / 256 B /
  4 KB transfers, and identical at 1 MHz and 64 MHz.** DMA does not scale with
  the CPU clock. Two consequences for anything per-frame:
  - **Cost is linear in bytes with no per-transfer setup penalty**, so small
    fine-grained transfers are as efficient as large ones. Streaming a
    subsector's ~30 bytes of segs on demand is fine.
  - **DMA is ~6× slower than the CPU at moving bytes** once turbo is on
    (0.17 µs/byte for an `sta` at 64 MHz against 1.00 µs/byte for DMA), and it
    halts the CPU while it runs. Use it to reach data that is *only* in REU —
    never as a faster memcpy or memset within main RAM.

## Tuning knobs (assembly-time data, no code changes)

- The 16 ramps (current set is placeholder art direction).
- The Bayer matrix — with 2:1 pixel aspect, a pattern alternating more between
  scanlines than between columns looks smoother.
- Upgrade option: majority-of-4 ramp sampling instead of single-pixel
  (~25 extra cycles/cell, kills edge-cell attribute flicker).

## Implementation

The converter is implemented in **`src/render/chunky2mc.asm`**. It is not
reproduced here: an inline copy drifts from the source the moment either
changes, and this one already had (`COLBUF` at `$C400`, a `flip` that clobbered
the CIA2 serial bits, and its own `.const` block instead of the shared
`src/defs.asm`).

What the source contains, in order:

| Symbol | Role |
|---|---|
| `ditherTabs` | 16 x 256 B — intensity + Bayer position -> pre-shifted 2-bit code |
| `scrTab`, `colTab` | ramp id -> screen-RAM byte (`c1<<4\|c2`) and color-RAM byte (`c3`) |
| `xOfsLo`/`xOfsHi` | MATRIX column-offset helpers (the `rowCell` pair in `math.asm` supplies the row half) |
| `convert` | the 880-cell packing loop, ~411 cy/cell |
| `patchMatrixPage`, `bumpBmpPage`, `initFrame` | self-modifying-code operand patching |
| `flip` | vblank wait, `$DD00`/`$D018` bank swap, COLBUF -> `$D800` burst |

Three notes on reading it:

- **`rowLo`/`rowHi` are gone.** The scanline-major pixel-address helpers from
  this document's original design were never read — the rasterizer settled on
  the cell-major `rowCell` pair in `src/math.asm` — so their 352 bytes have been
  reclaimed. `$9740-$98FF` (448 B, `TABLES_FREE` in `src/defs.asm`) is the free
  space that leaves at the tail of the segment.
- **All `.const`s now live in `src/defs.asm`**, so the memory map is declared
  once for every module.
- **`flip` preserves the CIA2 upper bits** by reading `$DD00`, masking and
  OR-ing, rather than writing a hardcoded byte — the version drafted here
  assumed a fixed value and would have disturbed the serial/RS-232 lines.

The mechanics — the fused `ldy MATRIX,x` / `ora ditherTabs,y` pixel step, the
single-sample per-cell attribute selection, and the self-modified addressing —
are walked through with cycle counts in `pipeline.md` §10.

## Frame flow

As implemented in `mainLoop` (`src/main.asm`):

1. `jsr readInput` / `jsr movePlayer` — intent → camera position, angle, sector.
2. `jsr renderFrame` — portal traversal front-to-back, walls projected to column
   spans, written into MATRIX as pre-shaded `ramp|intensity` bytes.
3. `jsr convert` — fills back bitmap + back screen + COLBUF.
4. `jsr flip` — waits vblank, switches $DD00/$D018, burst-copies COLBUF→$D800, toggles backBuf.

`pipeline.md` traces all four in full.

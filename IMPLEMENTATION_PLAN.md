# Doom C64U — Implementation Plan

**Milestone 1 is closed** on real hardware: E1M1, walkable, flat-shaded, with
music, at a measured **25.05 fps with 100% of frames on the deadline**.

**Milestone 2 is most of the way in**, also on hardware: textured walls, doors
and moving sectors, jumping, walk bob, and a HUD are all shipped at a locked
**16.7 fps / 59.85 ms deadline**, 100% on deadline, ~10 ms of frame budget
still free. **Sprites (§12) are the one phase left**, with a weapon-view
overlay (§12a) recommended to land first as a de-risking step.

This document is compacted: **Part I** is what M1 left binding — architecture,
memory map, lessons that will recur. **Part II** is M2 — closed phases reduced
to their outcome and the decisions that still matter, open phases (§11c, §12,
§12a, §14a, §15) kept in full detail. **Full session-by-session history,
measurements and traps are in this file's git log** — nothing below is stale,
it has just been moved out of the way of the part that is still being read.

---

# Part I — Milestone 1, as built

## 1. What M1 was, and what it delivered

> **Walk around E1M1, flat-shaded, on real Ultimate 64 hardware, at a measured
> frame rate.**

| | Delivered |
|---|---|
| Geometry | Real E1M1 from `DOOM1.WAD` via `tools/wad2reu.py` → `build/assets.reu` |
| Traversal | BSP front-to-back, bounding-sphere culled (§2) |
| Shading | Flat `ramp\|intensity`, WAD light level → intensity, depth falloff |
| Collision | Against the destination subsector's segs; no BLOCKMAP, no linedefs |
| Input | WASD + joystick 2 |
| Audio | A SID register stream replayed from REU — *not* in M1's scope, landed anyway |
| Target | C64 Ultimate at 64 MHz; VICE as the inner loop |

**The final hardware reading**, `make u64-fps`:

```
fps: 502 frames in 20.04 s = 25.05 fps (39.9 ms/frame)
cia: 19706 CIA ms in 20044 host ms = 0.983 x
frame: compute 37.6 ms last, 37.6 min, 38.6 max (deadline 39.90 ms)
frame: raster frames 1x0 2x502 3x0 4+x0 -- 100% made the 25 fps deadline
```

`make u64-map` passes: `mapOK=1`, all three resident blocks verified by checksum
against the image. `make check` is green. The rendered frame hashes
`c5d78e65…` with and without music.

How it got there, in frame time: 56.9 ms → 45.1 → 39.9, via a world-space seg
backface test, streamed bounding spheres, a frame cap, and an arithmetic pass
worth 9.4%. Every step was verified **bit-identical** — 0 of 104448 pixels
differing — which is the standard M2 inherits.

## 2. The architecture, as built

**BSP front-to-back, not portals.** E1M1's 85 sectors are not convex, so the
portal graph the original engine walked does not exist in the WAD; the 237
subsectors *are* convex by construction. `renderFrame` descends `NODES` with an
explicit stack, near child first, and at each leaf DMAs the subsector's segs and
calls `doWall` per seg. There is no `[zXL,zXR]` window: a column is closed when
`colTop[x] >= colBot[x]`, and `openCols` reaching zero ends the frame.

**Three rejection tests, in the order they pay off:**

| Test | Where | What it removes |
|---|---|---|
| Bounding sphere vs frustum | `bspLoop` before descending, `renderSsec` after the 8-byte header | whole subtrees — 234 node descents → 71.7, 235 subsectors → 39.3 |
| World-space backface | `segFacing`, before any projection | 53.6 segs/frame, each of which used to cost two `transformPoint` + two `projSX` |
| Column occlusion | `doWall` | 15-19 segs/frame |

The sphere test is deliberately **not** the exact sphere-plane test: the frustum
planes at 90° are `rx = ±ry`, and `k = r + (r>>1)` is conservative because
`1.5 >= sqrt(2)` while costing one shift instead of a multiply. Accuracy here
is worth more than speed — a coarse transform that needed 128 units of slop cost
6.7% of the frame while saving 4.4%.

**Frame pacing.** `flip` syncs to raster line 251, so frame time is quantised to
`50/n` fps. `framePace` holds every frame to `FPS_CAP_TICKS` so the player moves
at one speed regardless of what is on screen. The clock is CIA2 Timer B cascaded
off Timer A at 1000 phi2 cycles — a millisecond counter that is **turbo-invariant
and absolutely calibrated** (measured 0.983× against the host's wall clock;
PAL phi2 predicts 0.985).

**The engine times itself** (`src/clock.asm`, `ftInt`/`ftComp`/`ftCMin`/`ftCMax`/
`ftHist` at `$02a0`). This exists because an average frame rate cannot
distinguish *many frames slightly over the deadline* from *one frame
catastrophically over* — and those two want opposite responses. It cost ~60
cycles a frame and it overturned a whole session's conclusion the day it landed.

## 3. Memory, and why it is the binding constraint

**Resident blocks** (frozen in `docs/reu-format.md`, which is authoritative):

| Data | Form | Size | Lives at |
|---|---|---|---|
| NODES | 12 SoA arrays of 240 | 2880 B | `$D000`, under I/O |
| SECTORS | 6 SoA arrays of 96 | 576 B | `$DC00`, under I/O |
| MAPINFO | counts, root, spawn, block bases | 32 B | `$0E00` |
| SSECDATA | `[segCount, sectorId, sphere, segs…]` in a 128 B slot per subsector | 30 KB | **REU**, two transfers per visit |
| NODESPH | node bounding spheres, 8 B stride | 2 KB | **REU**, streamed per node visit |
| MUSIC | SID register delta stream | 405 KB | **REU**, streamed per tick |

There is no resident SSECTORS table: each subsector owns a fixed 128-byte REU
slot at `ssecReuBase + (i<<7)`, so the address is one shift and no multiply.
30 KB of REU (free) bought 948 B of RAM (not free). The same trade recurs
throughout — **REU space is abundant, REU bandwidth is 1 byte/µs flat, and RAM
is the thing that runs out.**

**Free RAM, as of the end of M1:**

| Where | Size | Usable for |
|---|---|---|
| `$0cb3-$0cff` | 77 B | code |
| `$0d33-$0d3f` | 13 B | code |
| `$02b0-$02ff` | 80 B | data only (page-aligned tail of `colTop`) |
| `$03a0-$03ff` | 96 B | data only (tail of `colBot`) |
| `$0400-$07ff` | 1024 B | data only — **unclaimed, unverified**, see §8.1 |

**About 90 bytes of code RAM exist.** Everything else is MATRIX, bitmaps,
screens, tables and code. `$ff40-$fff9` was held open for M2's audio for two
sessions and is now `MUSCODE`. Anything below `$0801` cannot hold code — the PRG
loads from there — but is fine for runtime data, which is why `colTop`,
`colBot` and the frame-time block live there.

Two mechanisms bought the RAM that exists: **boot-only code lives inside
MATRIX** (`BOOTCODE = MATRIX + $4100`; `spanFill` overwrites `mapLoad` during
the first frame), and every block is bounded by an `.errorif` against what
follows it, so the next thing that grows fails the build by name rather than by
symptom.

**Banking.** `$01 = $35` is the default; `$34` is entered only to touch the node
and sector tables and always restored. Both keep RAM at `$a000`/`$e000` where the
bitmaps live, so a bank switch never changes what a bitmap write does. Interrupts
are safe inside these windows provided the handler saves and restores `$01` —
measured, with a positive control that produced 3951 corruptions when the handler
restored the wrong bank.

## 4. What M1 taught, and what will bite again

These cost a session each. They are not derivable from the code.

- **Nothing on the REU or hardware path may be believed without an assertion.**
  Three silent failures were found in a row on the delivery path alone, each
  letting every read "succeed" and return wrong bytes: `reuProbe` overwriting
  the header it was about to verify; VICE ignoring a `-reuimage` whose size is
  not exactly the emulated REU size; and the Ultimate's REU Preload not
  delivering at all on firmware 1.1.0. With no REU attached, `$DF00-$DF0A`
  reads back `$00` and every transfer "succeeds" instantly.
- **Build a positive control into every measurement.** A run in which every
  write was silently dropped looks like a clean pass — the SID test's half-
  and double-frequency cases, the sphere test stubbed to `sec/rts`, the IRQ
  test's deliberately-wrong bank restore are what make the corresponding zero
  mean something.
- **VICE and the Ultimate disagree in specific, known ways**: `$d031` turbo is
  inert in VICE but real (and must be toggled) on the Ultimate; `$d41b` tracks
  frequency on hardware but not in VICE; REU DMA is a far larger share of the
  frame on hardware (1 byte/µs is the same absolute cost, but a 1 MHz VICE
  frame is ~2.3 emulated seconds); `-default` resets the REU too and must come
  first on the command line. **A change trading CPU cycles for REU bytes, or
  anything driven by a real-time interrupt, is judged wrongly by `make stats`.**
- **The Ultimate steals the bus for ~2.3 s after reset** — two frames, always,
  cost 2268 ticks each, which read as a plausible regression for half a
  session before `WARMUP_SECONDS` in `u64push.py` was added to sit it out.
- **Price a small change with a profiler hit count, not an estimate.** The
  6-byte seg record was estimated at +0.46 ms/frame and measured +0.06 — wrong
  in the same direction on both the ratio and the cost driver. It shipped,
  measured, and was reverted. `tools/vicedbg/profile.py` is the only way to
  price a change smaller than an instrument's resolution.
- **`make framehash`, not `make shot`, is the acceptance test.** `-limitcycles`
  stops mid-flip often enough that two runs of the same build differ by ~30
  pixels; `framehash` reads the renderer's own buffer at a frame boundary.
- **Anything placed below MATRIX must be checked against `bspStkLo`/`bspStkHi`
  by hand** — a range that reads as free in the memory map can be the BSP
  stack, and will assemble and link clean while rendering garbage.
- **`make debug`'s port is randomised for a reason** — x64sc doesn't set
  `SO_REUSEADDR`, so a stale `TIME-WAIT` socket makes the next VICE fail to
  bind silently, and it boots and runs with no monitor.

## 5. The M1 risk register, closed out

| # | Risk | Outcome |
|---|---|---|
| 1 | REU DMA slow and not turbo-scaled | **Real, and priced.** 1 byte/µs flat, no setup penalty |
| 2 | No way to get a `.reu` onto hardware | **Closed the hard way.** REU Preload doesn't deliver; `src/reuload.asm` + `machine:writemem` does |
| 3 | 40+ visible subsectors blows the frame budget | **Arrived**, at 17.6 fps first light. Answered by spheres + backface test |
| 4 | `$D000` banking breaks the converter or `flip` | **Never seen.** |
| 5 | Flat shading looks like mush | **Arrived twice** — two flats on one ramp, and a depth-falloff bug (`sta` sets no flags) |
| 6 | Projection math has range bugs real geometry exposes | **Never seen.** |

## 6. Session index and what carried into M2

Full logs are in this file's git history (see the note at the top). M1 ran
08-09 to 08-11: turbo/REU setup, `wad2reu.py` and the frozen REU format, the
BSP renderer landing on E1M1, the frame-time work (56.9 → 45.1 → 39.9 ms), the
25 fps lock, and music as a SID register stream replayed from REU.

What M1 left open, and its outcome in M2:

- **Sliding along walls / one boundary per frame** → closed in M2 §9.2.
- **`data_structures.md` never reconciled** → closed in M2 §9.3 (deleted).
- **The uploader sends the whole 470 KB image every run** → closed in M2 §9.1,
  it was the milestone's first blocker.
- **Quality scaling** — the frame-time feedback loop exists, nothing reads it.
  Still not in M2.
- **One unexplained hardware reading**, 24.10 fps / 93%, taken once after a
  470 KB upload, never reproduced.

---

# Part II — Milestone 2

## 8. Scope, and the budget decision that shapes it

> **E1M1 with textured walls, working doors, sprites on screen, and a HUD —
> on hardware, at a locked frame rate.**

| | M2 |
|---|---|
| Wall textures | **In.** Intensity-modulated within the surface's existing ramp (§10) |
| Floor/ceiling textures | **Out.** Flats stay flat — perspective-correct span texturing is a different renderer |
| Doors and moving sectors | **In.** Doors, platforms, switches, walkover triggers (§11) |
| Sprites | **In, rendering only.** Things are drawn, sorted and clipped. **No AI, no combat** (§12) |
| HUD | **In**, and landed — status bar with health/ammo/armour. **Fixed values, not live**: no code RAM for a runtime patch path, see §13 |
| Enemy behaviour, weapons, damage, pickups | **Out.** M3 |
| PVS/REJECT, quality scaling, visplanes | **Out** |

### 8.1 The frame budget triples the room, and that is the whole plan *(landed 2026-08-11)*

**Decision: M2 targets three raster frames — 16.7 fps, a 59.85 ms deadline.**
25 fps with textures and sprites is not reachable on this hardware without
giving up one of them, and 16.7 fps locked is preferable to 25 fps that
judders, which is the trap M1 spent two sessions climbing out of.

| | M1 | M2 |
|---|---:|---:|
| Deadline | 39.90 ms | **59.85 ms** |
| `FPS_CAP_TICKS` | 39 | **49** |
| Measured compute | 37.6 ms | 37.6-38.6 ms |
| **Available** | ~2 ms | **~21 ms** |

`make u64-fps` on hardware: `335 frames in 20.04 s = 16.71 fps`,
`raster frames 3x335 4+x0 -- 100%`, `make framehash` unchanged, `make check`
green.

**`FPS_CAP_TICKS` is 49, not the 58 first predicted**, because `framePace` used
to measure from its own last *release* rather than from the last flip, so a
release-to-release period pinned below the raster grid drifted and beat every
~20th frame (95%, not 100%, at 58). The fix was the reference point:
`framePace` now measures from `msFrame`, re-seeded every raster crossing by
`frameMark`, so the phase resets each frame instead of accumulating. That also
makes the exact cap value uncritical — anything from 41 to 58 selects the same
raster crossing; 49 is just the middle. **Lesson for any future cap/pacing
change: `ftHist`'s bucket histogram is the only instrument that shows this
class of drift — an average frame rate cannot.**

**Three consequences that must land in the same commit as the cap** (all done):

1. Every per-frame motion constant rescaled ×1.5 for the longer frame:
   `MOVE_SPEED` 14 → **21**. `TURN_SPEED` 3 → **4** (67°/s, not the exact 75°;
   a fractional accumulator would give the exact rate at the cost of a
   zero-page byte + 6 cycles/frame — a feel judgement, deliberately deferred).
2. `ftHist`'s target bucket moved 2 → 3 via `TARGET_FRAMES` in `u64push.py`.
   `frameMark`'s own buckets did not move — they count raster frames, a VIC
   property, not the cap.
3. The music tick (CIA-driven, not per-frame) is unaffected — it just fires 6
   times per rendered frame instead of 4.

Do this **first**, before any feature work, so features aren't measured against
the wrong deadline and constants aren't tuned twice.

### 8.2 The budget, allocated

22 ms available, ~2 ms held back as margin — M1 shipped on 2 ms of margin and
that was uncomfortably tight.

| | Estimate | Basis |
|---|---:|---|
| Wall textures | ~~6-9 ms~~ **8.7 ms spent** | §10, measured on hardware 2026-08-12 |
| Doors and moving sectors | < 0.5 ms | §11; the renderer needs no change |
| Sprites | 6-8 ms | §12.4, dominated by REU streaming |
| HUD | **0 ms spent** | §13; measured, painted once at boot, nothing runs per frame |
| Margin | 2 ms | |
| **Total** | **15-20 ms** | against 22 |

It fits, with little room for a surprise. **Every phase reports `ftComp` before
and after** — the frame timer already exists and this is what it is for. A phase
that overruns its estimate stops the milestone rather than eating the next
phase's budget.

### 8.3 RAM is still the binding constraint, and the first job is to find some

M1 ended with **~90 bytes of code RAM**. M2 needs, at minimum, a texture
sampling inner loop, a moving-sector thinker list, a sprite list with a sort, a
per-column depth array for sprite clipping, and a HUD blitter. That is
kilobytes, not bytes, and no amount of clever will fit it into 90.

**The candidate was `$0400-$07ff`, and it is gone.** *(Checked 2026-08-11,
before anything was designed around it — which is the entire reason §9.1 asked
for the check.)* It is **`COLBUF`**, the colour-RAM staging buffer:
`.const COLBUF = $0400` in `defs.asm`, written per cell by `chunky2mc`'s
self-modifying `colSta`, and burst-copied to `$D800` by `flip` every frame.
`probe.py` has always listed it in `ALLOWED`; a `dump` run reads 880 of 896
bytes non-zero. The claim in an earlier draft of this section — "nothing in
`defs.asm` claims it" — was simply false, and a `grep` would have said so.

What is actually there:

| Range | Size | State |
|---|---:|---|
| `$0400-$076f` | 880 B | `COLBUF`, live every frame. **Unavailable.** |
| `$0770-$07e7` | 120 B | written once at boot by `clearHudRows`; `flip` copies only the first 880 B, so nothing reads it back |
| `$07e8-$07ff` | 24 B | genuinely free |

**So M2 has ~90 bytes of code RAM and ~200 bytes of data RAM, not 1 KB**, and
risk #1 in §14 has arrived on day one. Two consequences, both already priced:

- **§12's per-column depth array needs a different home** — and there is a
  better one than any free block. See §12.1.
- **Stage B textures are that much less likely.** A per-frame texel cache
  needs a scratch region; the only one that exists is MATRIX, staged the way
  `mapLoad` stages, which is what §10 already proposed.

For code, the remaining levers are the two M1 already used:

- **More boot-only code into MATRIX.** `mapLoad` went there and returned 411
  bytes. `reuProbe`, `musInit`'s stream validation and the sphere-table setup
  are all boot-only and all currently resident.
- **Accept fragmentation.** M1's sphere test lives in four pieces across three
  holes because that is what existed. M2 should expect the same and design
  routines that split cleanly at a `jsr`.

## 9. Phase 7 — Clear the ground

Nothing here is a feature. All of it makes the rest of the milestone possible or
cheaper, and the first item is a hard blocker.

### 9.1 The uploader must stop sending 470 KB *(blocker — closed 2026-08-11)*

The image went from ~36 KB to ~470 KB when music landed, because `u64push.py`
sent one contiguous region from offset 0 to the last byte any descriptor
claimed — 3 chunks became 29 and `make run-u64` went from seconds to minutes.
Worse, several such uploads in a session made `run_prg` start answering `404`
until a power cycle.

**Fixed**: chunking now covers only the regions descriptors claim (28 chunks,
not 29), and a content-hash skip cache (`build/.reu-upload-cache.json`,
validated by a token written to unclaimed REU space so a stale cache can't be
trusted) skips unchanged chunks — `make run-u64` is back to **8 seconds**,
`0 chunks sent, 28 unchanged and skipped` on a rebuild. `--no-reu-cache` forces
a full send, `--verify-reu` reads every chunk back regardless of skip state.
The 404 did not recur over 12 rapid `run_prg` calls, but risk #6 (§14) stays
open since that's a weaker negative result than the one that motivated the fix.

Also verified here (gates §8.3): **`$0400-$07ff` is `COLBUF`**, not free RAM —
see §8.3 for the numbers.

### 9.2 Sliding along walls, and the two-boundary loop *(closed 2026-08-12)*

M1's worst gameplay defect: a blocked move was undone whole, so walking into a
wall at a shallow angle stopped you dead. **Fixed**: `checkMove` now projects a
blocked move onto the seg it hit and retries, up to `SLIDETRY` = 3 times
(`src/input.asm`, `slideVec`, ~250 bytes, paid for by moving boot-only code
into MATRIX as `BOOTCODE3`). `make walktest` is green: a 20° run along a
704-unit wall covers 96% of the unobstructed distance, an inside-corner run
ends 12 units from the vertex without crossing a linedef.

**Reduced, not fully closed**: the iteration cap resolves an inside corner in
one frame (each retry re-descends the BSP from the new destination), but a
move that legally crosses one subsector boundary and hits a wall in the next
is still tested only against the first boundary — `bspFindSsec` returns the
subsector containing the *destination*, so a true march along the motion
segment would be needed to close it fully. Not written; not observed at 21
units/frame against E1M1's subsector sizes. `pipeline.md` §5.3 notes this.

### 9.3 `data_structures.md` reconciled *(closed 2026-08-12 — deleted)*

The document described a format (`MAPBIN`, PVS, collision grid, LUT taxonomy)
the project never built — everything in it was superseded by `docs/reu-format.md`
(frozen, boot-checked) or by this plan's §12.2. **Deleted**, and references in
`README.md`/`pipeline.md`/`docs/georam-vs-reu.md` repointed to the surviving
authority directly. The memory map still has independent copies in `defs.asm`,
the image header, `probe.py`'s allowed-region table and `docs/reu-format.md`;
only the first two are cross-checked automatically.

### 9.4 `pipeline.md` still described the portal renderer *(closed 2026-08-12)*

Found while closing §9.3: `pipeline.md` still documented the pre-M1 portal
traversal in several places. **Reconciled** — §5 (collision), §7 (BSP descent),
§8.7 (texture line layout), §9 (`spanFillTex`), §12.1-12.3 (measured cost
breakdown) now describe the code as built. **§11 (a worked frame trace against
the deleted test map) is the one section left unreconciled** — it needs a fresh
live-capture session against E1M1, not a documentation-only pass.

## 10. Phase 8 — Textured walls *(closed 2026-08-13)*

The defining feature of M2. **Shipped and measured on hardware**: `16.63 fps
(60.1 ms/frame)`, `compute 46.7-47.7 ms` against the `59.85 ms` deadline,
`raster frames 3x168 4+x0 -- 100%`, `make check` green, `make framehash`
`c1dd1bb3…`. ~12 ms of budget remains for §12's sprites.

**What shipped**, and why, in one pass:

- **A tile modulates the intensity nibble only, never the ramp** — the only
  form of texture a VIC multicolor cell (one 3-colour palette per 4×8 cell)
  can carry without attribute clash. `wad2reu.py`'s ramp table stays the
  colour knob; depth falloff becomes a bias on the texel's intensity.
- **16×16 tiles, resident** (`WALLTILE`, `$7600`, 2 KB — freed by §14a.1's row
  cut). Started as an 8×8 Stage-A tile streamed per seg (+8.7 ms, the top of
  the original 6-9 ms estimate); 16×16 residency cost +5.4% compute
  (`+2.4 ms` CPU) but saved ~1.0 ms of per-seg DMA, netting +1.4 ms — measured,
  not estimated, and the projection held to within a millisecond on hardware.
  **Stage B (64×64 streamed/cached texels) is out of M2** on this budget;
  revisit in M3.
- **8 world units/texel** (128-unit repeat, native WAD scale) — kept over the
  16-unit alternative after re-checking on `make shot` (post-dither VIC
  output) rather than a raw chunky dump, which had wrongly made 8 units look
  like noise in an earlier session. The two tile axes being powers of two on
  the 4×4 Bayer grid means they phase-lock rather than moiré.
- **`u` is `lineSetup`'s existing 5th line** (no new per-column divide); **`v`
  is affine per seg**, anchored exact at mid-`ry`, drifting only toward a
  seg's ends — the deferred subspan divide from the original design was never
  needed at this tile size. **`u` reuses the seg's dominant-axis byte**, no
  texture offset and no 11th seg-record byte (widening the hottest record is
  the standing warning from §4's reverted 6-byte experiment).
- **Five new ramps** (tan/slime/tech/door/lite) claimed from six duplicate
  stone ramps, spreading E1M1's wall segs over ten ramps instead of six — free
  at runtime, pure asset-table work.
- **Floors/ceilings stay flat** — structural, not budgetary: `doWall` fills
  them as vertical constant-byte runs, and a textured flat needs the opposite
  rasterizer (horizontal spans, visplanes), which §8 already put out of M2.
- **653 bytes of code in eleven `.pc` blocks**, three of them below `$0801`
  (in `colTop`/`colBot`/`COLBUF` tails) relocated via `BOOTCODE4`/`texBoot` and
  checked every `make check` by `probe.py`'s `check_texcode` — this class of
  "looks like a free hole, is actually X" mistake is now standard-shaped
  across the codebase (§4, §11, §13) and worth checking for by name in any
  new phase before designing around a hole.

## 11. Phase 9 — Doors and moving sectors *(closed 2026-08-12)*

The cheapest feature in M2. **The renderer needs no change at all**: a door is
just a sector whose ceiling height animates, and `doWall` already draws a
closed door as a two-sided seg's upper step covering the opening — change the
height in RAM and it renders. Bounding spheres are 2D (x/y) so a z-moving
sector needs no re-culling, and `checkMove`'s existing step/headroom tests
already read live sector heights, so collision follows for free too.

**What shipped**, versus what was planned:

- **No seg → linedef reference was needed at all.** E1M1 has only 19 special
  lines (11 that do something: 8 doors, 1 lift, 1 floor, 1 exit) — small
  enough to keep fully resident, with activation running against the *lines*
  directly rather than needing a per-seg pointer. This sidesteps the planned
  format-bump-vs-geometry-lookup decision entirely.
- **Activation is sector-based, not geometric**: the use key fires the door
  whose sector contains the point `USERANGE` ahead of the eye; a walkover
  fires when `camSec` becomes a trigger sector. Doom's exact line-crossing
  test was written but not shipped — it needed ~660 B against the 640 B
  budget below. Cost: a trigger fires on entering the sector rather than on
  the exact line crossing, and `segFacing` (which side of the seg, not which
  way the player looks) means a shared-subsector door opens whichever way the
  player faces. **Logged for M3**, alongside §12.1's per-seg opening list.
- **Tags/target heights resolve in `wad2reu.py` at build time**, not at
  runtime — exact for M2, stops being exact once two thinkers can act on
  neighbouring sectors (M3).
- **A door closing on the player was not built** — E1M1's doors reopen on use,
  which is the escape in practice; play-testing found nothing to fix.
- **The whole feature — thinker list, activation, trimmed `LINEDEFS` — lives
  in the 640 bytes under I/O** (`$DB40-DBFF`, `$DE40-DEFF`, `$DF00-DFFF`),
  the largest free block left, as `.pseudopc` images (`BOOTCODE5`/`lineBoot`).
  Code under I/O must `sei` around the bank switch (the music IRQ writes SID
  registers into the RAM underneath otherwise) and can't call anything that
  itself touches I/O.

**Measured**: `make check`/`walktest`/`doortest` green, `make framehash`
unchanged (the renderer never learned what a door is), `make u64-fps`:
`16.67 fps`, `compute 34.5 ms` (well under §10's 46.7 ms baseline — doors cost
effectively nothing), `raster frames 3x334 4+x1 -- 100%`. ~13 ms of budget
remained for sprites and the HUD, confirming §10's estimate.

**Lesson repeated here** (§4, §13): back-to-back `u64-fps` readings taken
within a minute or two of each other degrade (100% → 88% across three runs)
regardless of the engine — treat close-together readings as noise, don't try
to warm your way out of it, and don't shorten the gap between runs.

## 11a. Jumping *(shipped 2026-08-12, out of scope, built anyway)*

Cheap (42 bytes + 2 zero page) and worth it: everything else that sells depth
(walls, shading, textures) moves when the player turns; nothing moved when the
world stayed still. SPACE (shared with the door-use key, level not edge — door
code keeps its own edge). **The arc is a 7-byte table** (`jumpTab`, eye height
above floor + `$ff` sentinel), not physics — a velocity/gravity model would
cost a second zero-page byte and a rounding-dependent peak. `EYE + JUMPPEAK =
69` against E1M1's lowest opening (72) is the whole safety margin and has to be
exact, since nothing stops the eye rising through a ceiling otherwise.
`setEyeZ`'s `camJZ` read gives ledge-jumping for free (a ledge looks `camJZ`
shorter to the step test) without being implemented on purpose.

Code lives in three fragments squeezed from slack found elsewhere (`TX_SHADE`,
`TX_UADV`, `SSECHDR`'s tail, and `$ffe4` between the music IRQ and the CPU
vectors). **One relocation bug found the hard way**: a routine placed at
`$0f40` (misread as free) silently got overwritten by boot data at that
address and did nothing on a build that was green — `.errorif` only proves no
overlap with the *next* block, never that an address is unowned. Fixed the
same way `LINECODE*`/`MUSCODE` already do it: assemble with `.pseudopc`, copy
up at boot, and let `probe.py`'s relocated-block check compare live RAM every
`make check`. `make jumptest` verifies the eye clears the ceiling and lands.

## 11b. The walk bob *(shipped 2026-08-12, out of scope, built anyway)*

23 bytes, no zero page, no table — same motivation as §11a. `bobStep` computes
a triangle wave from `frameCnt`'s low 3 bits (`0 2 4 6 6 4 2 0`) rather than
looking one up; upward-only because `camJZ` is unsigned. Runs off `IN_MOVE` so
turning in place leaves the eye still. **One real bug, found by its own
test**: `zInput` aliased `zNum+1`, which `checkMove` also writes, so walking
occasionally deposited a cross-product byte into the input register and fired
jumps/doors nobody asked for — moved to `$90`. Same lesson as §11a: a
`.const` proves nothing about ownership; only reading the byte back live
catches a second writer. `make bobtest` checks the triangle traces unbroken
while moving and the eye is still while only turning.

## 11c. A 1351 mouse alongside WASD/joystick 2 *(option, not built)*

Proposed 2026-08-12, evaluated for feasibility, not scheduled. Recorded here so
it isn't re-derived if it's picked up later.


**No port conflict.** Only joystick port 2 is read (`readInput`, `$dc00`);
port 1 is untouched, so a 1351 in proportional mode there costs nothing in
contention. It reads via SID `POTX`/`POTY` (`$d419`/`$d41a`), muxed by the same
`$dc00` bits 6/7 the row strobes already write every frame — sequencable, but
the pot-select write has to be added to that existing sequence deliberately,
not bolted on beside it.

**It doesn't fit `zInput`'s model.** `movePlayer` turns by adding/subtracting a
fixed `TURN_SPEED` gated on a bit in `zInput`; a mouse delta is a variable
signed value, not a flag, so it needs its own path — `camA += scaledDelta`
run alongside the keyboard/joystick turn, not through it. The delta itself is
an 8-bit wraparound subtract against the previous frame's `POTX`, which is
exact as long as per-frame motion stays under ~128 units.

**Cost, if built:**
- Cycles: negligible — one `$dc00` write, two pot reads, one subtract, once a
  frame, against a 59.85 ms deadline that currently has ~13 ms of margin.
- RAM: a couple of zero-page bytes plus an estimated 20-40 bytes of code, the
  same class as §11a's jump (43 B) and §11b's bob (23 B) — except those two
  spent the last free holes below `$d000` that size. This would likely need
  its own `.pseudopc` block relocated at boot, same as `LINECODE*`/`MUSCODE`,
  rather than a hole to drop into.
- A sensitivity constant, tuned by feel — same deferred-judgment shape as
  `TURN_SPEED` in §8.1.

**Not scheduled**: it competes for code RAM that is now more fragmented than
when jump and bob were built, and it changes player feel in a way that wants a
tuning pass, not a one-shot implementation. Pick up if a future session wants
mouselook specifically; nothing here blocks it.

### 11c landing note *(built 2026-08-14, not yet verified on hardware or VICE)*

Built as X-only turning, additive alongside keys/joystick, single button
shared with SPACE's use/jump — decided by conversation, not re-derived here.

**A fresh audit found the machine tighter than this section's own estimate**:
every carved-out hole from §11a onward (`MOVECODE`, `BODYCODE`, `WPNBLIT`,
`SPRCODE`/`2`/`3`, `JUMPBOOT`, `LINECODE*`, `TX_SEED`/`TX_FETCH`) is now sized
flush to its contents, each guarded by its own `.errorif`; the tape buffer and
the classic FP zero page were checked as possible finds and are already spent
(`colBot`/`TX_FETCH` and the engine's own `zA`-`zT` scratch, respectively).
Zero page had exactly three free bytes left (`$e3`, `$f3`, `$f8`), not the
"couple" estimated above — enough regardless, since `mouseTurn` needs only
one persistent byte.

**Where the code went**: `MAXVIS` (§12) dropped 10 → 8 — §12.6's stress pass
never saw more than 6 things in one sightline, so two of the ten slots were
margin nobody had exercised — which frees 16 bytes in `SPRCODE3`, the gap
between the visible-thing list and `SPRIMG`. `mouseTurn` (28 bytes, `src/
render/sprite.asm`) lives there. No new call site was needed anywhere: both
`jumpStep` and `bobStep` already end in `jmp setEyeZ` on `playerFrame`'s
behalf, and both now say `jmp mouseTurn` instead (which itself ends `jmp
setEyeZ`) — changing an existing jmp's operand costs the packed segment
nothing, unlike a new `jsr`.

**Left over, not yet checked:** the `$dc00` bit pattern that selects port 1's
pots onto POTX (`%01000000`) is inferred from `readInput`'s own row-7 keyboard
mask, not confirmed against real 1351 hardware or VICE's mux emulation — per
§4's rule, nothing on an unverified hardware path should be trusted, and this
qualifies. `MOUSE_SHIFT = 2` (defs.asm) is a guess at sensitivity, picked the
same way `TURN_SPEED` was, and wants a feel pass. The terminal was unusable
this session (`Sandbox dependency installation failed`, both plain commands
and package installs), so none of this has been run through `make check` —
verified by code review only, same caveat as the HUD's `.kla` change in
§13's history.

## 11d. The player stops being a point *(shipped 2026-08-13)*

Two play-reported bugs, one cause: collision was a **point** test, sampled once
a frame, against the segs of **one** subsector. Both were reproduced on the
pre-texture build before anything was changed — neither is a texture
regression, which is where the session would otherwise have spent its day.

**Walking through closed doors — the step, not the test, was wrong.**
`checkMove` tests the destination against the segs of the subsector the step
*started* in, so the real limit on a step is not how far the player may travel
but how far they may travel **unchecked**. E1M1's sector-76 door track is 16
units deep with another 16-unit sector in front of it, against `MOVE_SPEED =
21`: the step crossed one legally passable seg, jumped clean over the subsector
that owns the door's seg, and landed inside the shut door. Fixed by
`moveSteps` (`MOVECODE`, `$7500`): `MOVESUBS = 4` pieces, each a whole move
with its own undo point, `checkMove` and `bspFindSsec`, so the next piece is
tested against the subsector the last one entered. `d & 3` is handed out one
unit per substep so the pieces sum exactly — `floor(d/4)` alone would make
walking west up to 20% faster than east. ~22k cycles against a ~3.1M-cycle
frame, and the main segment got 42 bytes *smaller* (the whole-frame `oldX/oldY`
save went away). **56 of 56 door approaches blocked, from 5 walked through.**

**Seeing past a wall you stand against — the player needed a body.** `doWall`
drops a seg with both endpoints nearer than `NEAR = 16`, and a dropped seg
leaves its columns open for whatever the BSP paints next — the room behind the
wall. A point player could stand *on* the wall, so it was trivially reachable.
The fix is nearly free because the cross product `checkMove` already computes
is **linear in the test point**: the most-outside corner of a box of radius R
is that value plus `R*(|dx| + |dy|)` — Doom's own `P_BoxOnLineSide`, two shifts
and an add, no second cross product (`segBody`, `BODYCODE` at `$7e00`). Three
things must hold before it blocks, and two of them are the whole design:

- `segNear` — the player is beside the seg, not across the room from the
  infinite line it lies on;
- **a passable two-sided seg is never padded.** A portal the body may not
  overlap is a portal the player can never cross;
- `segPush` — the motion pushes *into* the seg. Without it, a player carried
  into the band through a portal (only the subsector he is in is ever tested)
  would be frozen with every direction blocked, including out. Sliding along a
  wall is exactly the `d = 0` case and stays legal.

`PLRAD = 24`, not Doom's 16, because it must exceed `NEAR`: at 24 no wall of
the subsector the player stands in can enter the near plane at all. Exact for
an axis-aligned seg, up to 6.6 units early on a 45-degree one — early is the
safe direction. **Checked for impassable geometry before committing**: an
offline flood of E1M1 on an 8-unit lattice under the engine's own rules loses
15% of the standable cells against R = 8, all of it wall-hugging margin, and
seals no room off. Doors 4 and 68 are still walked through end to end; doors 76
and 81 are not, but they open to 44 units against `MINHEAD = 56` and are shut
to the engine either way — **pre-existing, identical on the previous build, not
fixed here**.

**The renderer's fail-open closed, honestly measured.** The radius cannot reach
segs of *neighbouring* subsectors, and E1M1 still has 538 standable lattice
cells within 16 units of an occluding seg's vertex. So `nearFix` drops a seg
only when *both* endpoints are behind the eye, and otherwise pushes both to
`ry = NEAR` and draws from there — a span narrower than the truth, but the wall
is drawn and its columns close, and the pipeline already handles `ry = NEAR`
endpoints because that is what the clip paths produce. It is *entered* at the
tight spots, but across 48 probed views (6 positions × 8 angles, MATRIX
compared byte for byte against the previous build) **it never changed a pixel**
— those segs lose the backface test or fall off-screen anyway. The radius is
what fixed the artifact; this is a net under a case that stays reachable. A
blockmap would close it properly; out of scope, and only worth pricing if
hugging a neighbour's wall ever leaks visibly. Both fixes confirmed on hardware
2026-08-13.

**RAM.** `MOVECODE` `$7500-$7593`, the page between the HUD's boot staging
(`$74ff`) and the wall tiles (`$7600`) — runtime code inside MATRIX, safe only
because the 160-row viewport stops at `$73ff` (§14a.1). `BODYCODE`
`$7e00-$7eea`, the 512 bytes between the end of MATRIX and `SCREEN0` that the
map had always had spare, and which `make check`'s live-RAM diff is what makes
safe to claim (§11a's lesson: a `.const` proves nothing about ownership).
`WALLSCODE` moved `$ca30` → `$ca28` — the walls block was flush against
`TX_COL` and the fail-safe needed two bytes. Zero page `$d4-$e1`; `$e2-$e3` is
what is left in the machine.

**The test had to change, and the reason generalises.** `walktest` failed after
substepping with a wall leak that never happened: `camX/camY` are written
**speculatively** — `checkMove` applies a move and then slides or undoes it —
and substepping does that four times a frame, so a free-running sample can read
a position the player never stood at. It now samples with the CPU stopped at a
checkpoint on `readInput`: every sample is a settled position, and consecutive
samples are exactly one frame apart. Any future test that reads engine state
mid-frame has the same hazard.

## 12. Phase 10 — Sprites

The hardest phase, and the one whose scope must stay narrow: **things are drawn,
not animated and not intelligent.** Barrels, lamps, corpses, and the static
props that make E1M1 read as a place rather than a maze.

### 12.1 The clipping problem is the real work

The renderer walks front-to-back and consumes `colTop`/`colBot` destructively as
it closes columns. Sprites must be drawn *after* the walls, back-to-front, and
clipped against the geometry that was drawn in front of them — and by then the
information is gone.

**So the wall pass must record a per-column depth.** 160 columns × one byte of
quantised `ry` = 160 bytes, written once per closed column, which is a store the
wall pass mostly already performs. A sprite column is drawn where its `ry` is
nearer than `colDepth[x]`.

**Where those 160 bytes come from, now that `$0400-$07ff` turned out to be
`COLBUF` (§8.3): `colTop` itself.** No new RAM at all.

A column is closed when `colTop[x] >= colBot[x]`, and once closed neither value
is read for anything else — the wall pass only ever re-tests the predicate. So
when the pass closes column *x*, write `colBot[x] = 0` and `colTop[x] =` the
quantised `ry` of the seg that closed it. The predicate still holds for every
depth (`d >= 0` always), so occlusion is unchanged; and after the pass,
`colTop[]` **is** the depth array, with `colBot[x] != 0` marking the columns
nothing ever closed (sky, or an unfinished frame) where a sprite is always
visible. Both arrays are page-aligned and indexed by column already.

This wants proving against the real `doWall` and `spanFill` before §12 depends
on it — floors and ceilings read the same two arrays — but it is one store on a
path that already stores there, in the one place that has no RAM to spend.

**Deliberately simpler than Doom**, which stores per-seg opening ranges and
clips each sprite column against a list of them. One depth per column mis-clips
a sprite that straddles a window opening — a sprite behind a wall with a hole in
it may show through the hole's column range, or be hidden in it. At 160 columns,
with M2 drawing no enemies that move behind windows, that is the right trade.
Revisit it in M3 with combat, not before.

### 12.2 What has to be built

1. **A `THINGS` block**, resident: `[x, y, sector, type, angle]` per thing,
   ~6 bytes × the things M2 draws. Pre-sorted by subsector at build time so the
   BSP walk can pick them up per leaf, which is how Doom does it and it avoids
   a per-frame scan of every thing on the map.
2. **A visible-thing list**, built during the wall pass: as each subsector is
   drawn, append its things with their transformed `rx`/`ry`. `transformPoint`
   is already paid for the subsector's sphere.
3. **A distance sort**, back-to-front, over that list. Insertion sort over
   ~10 entries is a few hundred cycles and needs no scratch.
4. **A masked, scaled blit.** Column stepping is the wall path's fixed-point
   accumulator; row stepping is a second one. Transparency is a reserved
   intensity value (intensity 0 is available — the ramp nibble makes it
   distinguishable from a legitimate black), tested per pixel.
5. **Sprite graphics in REU**, streamed per visible sprite per frame. A 32×32
   4-bit sprite is 512 bytes ≈ 0.5 ms of DMA. This is why the phase's budget is
   dominated by streaming, not by pixels.

### 12.3 The scaling that keeps it honest

Sprite scale is `VFOCAL / ry`, one divide per sprite — negligible. But **a
sprite near the camera is enormous**, and a full-height 176-row sprite at
32 columns is 5.6k pixels of masked blit, which is a fifth of the screen at
roughly twice `spanFill`'s per-pixel cost.

Cap it: clip the sprite to the viewport (it must be clipped anyway) and accept
that a barrel pressed against the camera costs a frame. If that turns out to be
common, the answer is a near-distance cap on drawn sprites, not a faster blitter.

### 12.4 What it should cost

Streaming dominates: 5-8 visible sprites × 512 B = 2.5-4 ms of DMA, at
1 byte/µs, unaffected by the 64 MHz clock. Pixels: ~3-5k drawn sprite pixels at
~40 cycles each (masked, with two accumulators) ≈ 2-3 ms. Sort and list build:
under 0.5 ms.

**Estimate: 6-8 ms.** The obvious optimisation, if it overruns, is a per-sprite
REU cache keyed on the fact that consecutive frames draw the same things — but
§4's revert says model it with a hit count first, because "trade CPU for REU
bytes" has been close to exhausted in this engine at this frame size.

### 12.5 Landing note *(2026-08-13)*

Built to plan: `THINGS`/`SPRIMG` resident blocks (`wad2reu.py`), `sprPick`
hooked into `bsp.asm`'s `renderSsec`, `sprSort`/`sprFrame`/`sprDraw`/`sprBlit`
across three code segments (SPRCODE2/SPRCODE3/SPRCODE, packed like `tex.asm`'s
eleven pieces because that is what the machine had room for). Confirmed on
hardware: barrels, dead bodies, and candelabra all render.

**Bug found only by hardware play, not by `make check`/`framehash`: only
barrels (type 0) ever drew.** `sprStep` (the routine that turns an art
dimension into the 8.8 fixed-point `uStep`/`vStep` used to walk the sprite's
source pixels) built its dividend in `zA`, but `udiv` reads its dividend from
`zD` — so every call divided whatever `zD` happened to hold left over from the
*previous* division (`sprScale`'s box-size math), not `art_dim*256`. Garbage
steps pinned the source pointer near art column/row 0 for the frame, which for
most types sampled straight into `SPR_CLEAR` (transparent) the whole way
through — nothing blitted. Barrels apparently sampled real pixels often enough
by luck of the stale value to be visible at all, which is also the likely
explanation for the flicker noted below. Three-line fix, `zD`/`zD+1`/`zD+2`
instead of `zA`/`zA+1` (+2 B; SPRCODE3 219/227 → 221/227 of true budget).
Found and confirmed via a synchronized live capture over the VICE binary
monitor: an exec checkpoint at `wpnFrame`'s entry (`$7eeb`) — the instant
after `sprFrame` finishes and before its zero-page scratch is reused by the
weapon-view code — reading `sprUStep`/`sprVStep` and scanning the MATRIX
buffer for the sprite's ramp nibble. Before: `uStep=0`, `vStep=3`, 0 pixels of
that ramp anywhere on screen. After: `uStep=1.07`, `vStep=1.0`, 150 pixels
landed in the sprite's projected box.

**Left over, not yet exercised:**

- **Whole-box reject flicker.** §12.1's simplification — a sprite whose
  projected box pokes off any screen edge is dropped entirely for that frame,
  no partial clip — makes a barrel visibly disappear/reappear as its box
  crosses an edge while the player moves. Confirmed on hardware and explicitly
  accepted as-is: "strange, yet acceptable." Revisit only if it stops reading
  as a rendering quirk and starts reading as a bug, per §12.1's own M3 note.
- ~~§12's other five types haven't each been individually eyeballed~~ **closed
  2026-08-13, see below.**
- ~~`SPR_NEAR`/`MAXVIS`/`SPR_BIAS` caps haven't been stress-tested~~ **closed
  2026-08-13, see below.**
- ~~Full regression not yet re-run~~ **closed 2026-08-13**, modulo a units
  mix-up along the way (below) and hardware `u64-fps` still to run.

### 12.6 Verification pass *(2026-08-13)*

**`tools/vicedbg/phaseprof.py`'s `ms/frame` column is emulated 1 MHz
milliseconds, not hardware ms** — it reads CIA2 Timer B (1000 cycles/tick at
VICE's 1 MHz), and the `ms/frame`/`kcycles` columns print identical numbers,
which is the tell. Divide `kcycles` by 64 for the real Ultimate figure. This
was misread once as `renderFrame` costing 2631 *milliseconds* (a 60x
regression); it's actually 2632 kcycles = 41.1 ms @ 64 MHz, exactly where it
has always been. Compute total: 3128.7 kcycles = **48.9 ms** against the
49.7 ms `FPS_CAP_TICKS` mark (the real raster deadline is 59.85 ms, ~11 ms
slack — see §14a's own note). Sprites cost +97.1 kcycles (+1.5 ms) over the
pre-sprite §12a baseline — on plan, and `convert` fell as expected from the
160→144 row cut. Separately: a stale `build/assets.reu` (left over from
before the map-format version bump) makes `make check`'s screenshot render as
a flat 2-colour fill, which looks exactly like a hung/broken renderer —
`rm build/assets.reu && make assets` before trusting a `make check` failure.
`make check`/`walktest`/`doortest` all green at HEAD with fresh assets.

**All seven `SPRTYPES` individually confirmed rendering, except one.**
Floor lamp (COLUA0), bloody mess (PLAYW0), dead player (PLAYN0), and pool of
blood (POL5A0) all confirmed by camera-teleport + MATRIX ramp-nibble scan
over the VICE monitor (same technique as the original zA/zD bug hunt) —
alongside the already-confirmed barrel, candelabra, and one corpse type, that
is all seven types seen at least once.

**Except: the tech column (type 3, ELECA0) draws nowhere, from any tested
vantage point (60+ positions, both map instances).** Root-caused, not a code
defect: ELECA0's world height is 128 — far taller than any other type (next
tallest is 61) — and `SPR_NEAR`'s forced minimum apparent distance pushes its
projected box's top row above the viewport for the near instance, so it fails
§12.1's whole-box reject on every position tried; the far instance passes the
reject and computes a legitimate box but draws zero pixels, consistent with
being genuinely occluded by nearer geometry at every angle tried. This is
§12.1's already-accepted "no partial clip" and §12.3's `SPR_NEAR` clamp
colliding with one outlier-tall asset, not a bug with an obvious fix.
**Closed 2026-08-13 (Honza's call): capped harder in `wad2reu.py`.**
`SPR_WORLD_HMAX = 61` — the tallest value already confirmed to survive the
whole-box reject at `SPR_NEAR` (the candelabra) — now clamps every type's
`world_wh`, not just ELECA0's; nothing else in `SPRTYPES` was near that
ceiling so only ELECA0 (raw 128) is actually affected. Confirmed rendering
after the fix: 1250 TECH-ramp pixels landed on screen from a real vantage
point (vs. 0 before), `make check` still green.

**`SPR_NEAR`/`SPR_BIAS` stress-tested clean; `MAXVIS` untested at its
actual limit.** A barrel pressed to 1, 3, and 8 world units from the camera
clamps to a bounded box every time (no hang, no garbage, no crash). The
busiest cluster found in E1M1 (sector 72, ~11 in-scope things) produced
`sprVisN = 6` from the best vantage point — never reached `MAXVIS = 10`, so
the cap itself went unexercised at its limit. E1M1's own layout doesn't
appear to put more than ~6 in-scope things in one sightline; treat `MAXVIS`
as untested rather than confirmed safe at capacity.

**Still open:** hardware `make u64-map`/`make u64-fps`, to confirm the 48.9 ms
emulator figure against the real Ultimate and see where the frame actually
lands relative to the 59.85 ms raster deadline.

## 12a. A weapon view *(proposed 2026-08-13, not built)*

A first-person weapon overlay — screen-fixed, not a world Thing, so it needs
none of §12's per-subsector list, transform or sort. **Recommended sequencing:
before §12**, because it is a strict subset of §12.2 item 4's masked blit (no
scale accumulator, fixed size and position), and building the simple case
first de-risks the general one.

**Decided scope:** one static pose, the shotgun (`SHTGA0`) — the widest of the
WAD's weapon sprites, chosen because it maximises the occlusion pre-seed's
payoff (below). No firing, no animation frames, no selection between weapons —
weapon state is M3 (ammo/combat) territory, and §13's HUD pattern (wire fixed
values to variables now, let M3 make them live) is the template: a single
resident "which weapon" byte, read once, so M3 adds graphics and a keypress
selector without touching the streaming or blit path.

**It moves with the player.** §11b's `bobStep` already computes a per-frame
triangle wave for the eye-height bob and is resident; the weapon's vertical
screen origin reads that same value for a few pixels of offset. No new state,
no new table — the same wave, read twice.

**Art pipeline** — extends [tools/wad2reu.py](tools/wad2reu.py)'s HUD path
(`decode_picture` + the nearest-neighbour downsample `_picture_intensity_grid`
already uses for `STBAR`/`STTNUM`), but unlike the HUD (which bakes into
post-conversion `BITMAP` format, boot-only), the weapon must decode into
**`MATRIX`'s own byte-per-pixel intensity format**, because it overlaps the
viewport that `chunky2mc` reconverts every frame — there is no "paint once"
option here. Packed 4-bit (2 px/byte, transparent = a reserved value, same
convention as §12.2), streamed fresh each frame since nothing in `MATRIX`
survives between frames. The same streamed blob carries a **per-column
silhouette top-row byte** for the columns the sprite covers — transient, read
once per frame and discarded, so the irregular outline costs no permanent RAM.

**Occlusion pre-seed, the free win.** Before the wall/floor pass, for each
column the weapon covers, set `colBot[x]` to that column's silhouette top-row
instead of the viewport bottom — reusing §3/§12.1's existing clip mechanism, so
`doWall`/`spanFill` never draw the rows the weapon would cover. This is what
makes a large, iconic weapon (the shotgun) cheaper than a small one would
suggest: the bigger the covered area, the more fill work it cancels.

**Sizing, priced, not assumed.** Starting point ~96×56 (≈60%×35% of the
160×160 viewport) ≈ 2.7 KB packed ≈ 2.7 ms DMA, plus a masked row-copy blit
(no scale accumulator) at well under §12.4's 40 cy/px scaled-blit figure.
**Per §4's rule this must be priced with `phaseprof`/`profile.py` before the
size is fixed** — expected net cost (stream + blit, minus the pre-seed's
savings) is roughly 2-4 ms, but §12's sprites draw from the **same** ~10 ms
margin the doc currently earmarks for things, so the two must be measured and
budgeted together, not assumed independently affordable.

## 13. Phase 11 — The HUD *(closed 2026-08-12)*

Cheap, independent of everything else, and jumped the queue while a hardware
question elsewhere was waiting on the machine. Status bar with health/armour/
ammo, blitted from REU into `BITMAP0`/`BITMAP1` once at boot below the
viewport — confirmed on hardware, `make check` green.

**Shipped simpler than planned, on purpose**: values are wired to real bytes
(`hudHealth`/`hudArmor`/`hudAmmo`, read once by `hudBoot`) so M3 can make them
live later, but the **runtime patch-on-change path was not built** — code RAM
was at zero in every hole that mattered, and a static paint costs nothing
per-frame. `make framehash` is unchanged (`27f1774c…`) — proof the renderer
has no idea the HUD exists. 10 digit glyphs, no face frames. The whole feature
is boot-only code in MATRIX (`BOOTCODE6`) + 2 REU blocks, costing the resident
build only the 3 value bytes.

Four traps found by diffing live memory (all now commented at the site): the
dither-accumulator routine can't be transliterated to indirect addressing
without losing state across `ora`s; a block's boot-staging address can't
assume descriptor emission order; **`$07e8` looked free and wasn't** — it's
`tex.asm`'s `TX_SEED` tail, same shape as §10's "free hole is actually X"
mistakes; and `hudBlitCell` clobbers X, so its caller's loop counter needed
its own zero-page byte. Asset lesson: a HUD digit needs at least 2×2 cells to
read, and must **not** be ordered-dithered (intensities snapped to
`chunky2mc`'s fixed points) or it comes out speckled.

**Frame cost, measured idle**: `compute 49.7 ms` against the 59.85 ms
deadline, `raster frames 3x335 4+x0 -- 100%`, with the tool's own "every frame
fits in 3 raster frames" verdict and **no outlier
warning at all** — the first §12-era reading with a completely empty `4+`
bucket. **The HUD costs nothing measurable**, which it cannot: `hudBoot` runs
once from `bootMain`, the per-frame path is untouched, and the framehash is
bit-identical. ~10 ms of budget remains for §12 sprites.

Confirms §11's back-to-back-readings lesson again: the first runs this session
read 90-92% until four minutes of quiet between uploads produced the clean
number above.

**`u64-fps` does not push the REU** (`--reu` is commented out in the Makefile,
on purpose) — after changing `assets.reu`, run `make u64-map` first or the
engine halts on a stale image and the tool reports "frame counter never
advanced".

## 14. M2 risk register

| # | Risk | Early warning | Response if it arrives |
|---|---|---|---|
| 1 | ~~**There is nowhere to put M2's state.**~~ **Arrived, day one.** `$0400-$07ff` is `COLBUF` and always was | §9.1's watched-region run, before any design depends on it — which is exactly what caught it | ~200 B of data RAM and ~90 B of code RAM is the real budget (§8.3). Sprite depth moves into `colTop` (§12.1), Stage B textures get less likely, boot-only code goes into MATRIX |
| 2 | **Textures overrun 9 ms.** The per-pixel estimate is 3-7× wrong, as it has been before | `ftComp` after the first textured wall, measured on hardware | Tile size 8×8 → 4×4; texture only one-sided segs; last resort, texture only walls within a depth threshold |
| 3 | **Multicolor cells break anyway.** Intensity-only texturing still crosses a cell boundary where two surfaces meet, and always did | The first textured frame, by eye | This is M1's risk #5 returning; the fix is the same, in `wad2reu.py`'s ramp table |
| 4 | **Sprite clipping mis-draws through openings** (§12.1's known simplification) | A sprite visible through a window in E1M1 | Accept for M2. It is a per-seg opening list in M3, which needs RAM M2 does not have |
| 5 | **Three raster frames still is not enough.** Everything lands and compute exceeds 59.85 ms | `ftHist`'s `4+` bucket leaving zero | Four frames is 12.5 fps and that is below playable. Cut sprites to a near-distance cap first, then Stage A textures on fewer surfaces |
| 6 | **The Ultimate's `404 Cannot open file` recurs** after §9.1's fix | Any `make run-u64` in a long session. Deliberately re-run 2026-08-11 — 12 `run_prg` calls in 40 s, clean — but 40 s is not a session | Then it is not upload volume, and the milestone needs a reliable reset procedure before it needs features |

## 14a. Budget relief — the options, priced *(analysed 2026-08-12, mostly not decided)*

Both budgets are tight at the same time, and it is worth being precise about
where they stand before spending either.

**Time.** 46.7 ms compute against 59.85 ms (§10's landing note) = **13.1 ms
free**. Doors measured at effectively nothing (§11) and the HUD has landed,
so the whole remainder is §12's sprites, estimated at 6-8 ms. That closes M2
with ~5 ms of margin *if the estimate holds*, and §4 is unambiguous that this
class of estimate has been wrong by 3-7× in this engine, in both directions.

**RAM.** `defs.asm` now reads *"below MATRIX the largest unclaimed run left is
five bytes"*. ~90 B of code RAM in ten fragments, ~200 B of data RAM, and the
640 B under I/O is spent on doors. There is nothing left.

**Both budgets are consumed by the same object.** `MATRIX` is `$1000-$7dff` —
28160 B, 160×176 chunky, **45% of usable RAM** — and the per-pixel work over it
(`spanFill`, the texture sampler, `chunky2mc`'s conversion) is the bulk of the
frame. That is why the options below are largely one compromise wearing
different hats, and why the first is the only one that pays into both budgets
at once.

### 14a.1 Viewport height *(closed 2026-08-12: 176 → 160; reopened and closed again 2026-08-13 at 144 — see §14a.1b)*

176 → 160 rows (20 cell-rows), a contained edit in four places (`math.asm`,
`bsp.asm`, `walls.asm`, `chunky2mc.asm`), freeing 2560 B of MATRIX — the tail
past the new 25600-byte live buffer, **contiguous, above `$0801`, and code-
capable**, unlike every other RAM find this milestone. `make check`/
`walktest`/`doortest` green, `make framehash` a new digest (expected — the
frame genuinely shrinks), `clearHudRows` extended to blank the new letterbox
rows. Taller cuts (144, 128 rows) are the same edit with a different constant
and are not scheduled — 160 is the look judgement to live with first.

**Priced with a new instrument, `make phaseprof`** (stopping exec checkpoints
on each `mainLoop` phase against the CIA clock — exact, not sampled). Result:
the cut **returned a quarter of what the row percentage predicted** — `convert`
(chunky2mc) dropped its full 9.1% as expected, but `renderFrame`'s cost is
dominated by per-seg/per-column work (7485 `mul8` calls/frame) that the
removed rows barely touch. Net: **compute −2.4%, ~1.1 ms on hardware**, not the
~4 ms the pixel percentage implied — so a further cut to 144 rows would buy
roughly another 1.1 ms, not 4. `chunky2mc` itself costs **391.2k cycles = 6.1
ms of a hardware frame (13.5% of compute)** — previously unpriced — and the
cost model this run established (`ms ≈ cycles/64e6 + 1 µs/DMA byte`) predicted
§10's textured-wall hardware measurement to within a percent, validating
phaseprof's cycle counts as usable without a hardware trip.

**What it costs:** a letterboxed view — Doom's own 320×200 view is 168 rows
under its status bar, so 176 was already generous.

#### 14a.1b Reopened for §12: 160 → 144 rows, split evenly *(closed 2026-08-13)*

"Not scheduled" lasted one section. §12 needs ~2 KB of contiguous code-capable
RAM for resident sprite art and there is no other lever in the machine that
produces any (§14a.7), so the second cut was taken after all: **160 → 144 rows
(18 cell-rows), freeing another 2560 B** and, as §14a.1 predicted to the
decimal, **another 1.13 ms** (compute 3051.1k → 2979.1k cycles, −2.4%;
`convert` 391.1k → 352.1k, exactly the 18/20 row ratio).

**The 32 rows now come off symmetrically — 16 top, 16 bottom.** The first pass
took all 32 off the bottom, which is cheaper to write (the buffer still starts
at row 0) but drops eye level to two thirds of the way down the picture: the
player reads it as permanently looking up at the ceiling. Symmetric splits the
letterbox into two 16-row bands and keeps the horizon at raster 88 where it has
always been. It costs one constant offset, applied in exactly one place —
`initFrame` aims the converter's three output pointers `VIEWCELLTOP` cell-rows
in, and nothing upstream of the bitmap knows. Two coordinate systems now exist
and `defs.asm` names both: MATRIX rows 0..143 with `HORIZON` = 72 (what
`projRow` subtracts from), and raster rows 0..199 with the view at 16..159.

Fallout worth knowing: the burst in `flip` has to reach a *fourth* page of
`$d8xx` once the view starts at colour cell 80, and those nine bytes overran
the converter's block. `cntBump` moved to the top of the same 21-byte gap
(`instrument.asm`) — the two blocks now spend the gap exactly, with an
`.errorif` on each side. `TABLES_FREE` is not a fallback despite the name;
SEGBUF, the BSP node test and the counters have taken all of it.

Also fixed here, not in this section's scope but found by it: `make shot` ran
`SHOT_CYCLES = 50000000` and was landing the screenshot *inside* the first
conversion, so `checkshot.py` was passing a bitmap half full of staging bytes
at 39.7% coverage. Raised to 80M. §4's warning that `make framehash`, not
`make shot`, is the acceptance test was showing up in the gate itself.

### 12a landing note *(2026-08-13)*

The gun is on screen, streamed, bobbing and sealing its own columns.

**Sized to Doom, not to §12a.** SHTGA0 is 79×60 of Doom's 320×200 = 24.7% of
the screen width; this viewport is 160 columns of 2:1 pixels covering the same
320, so faithful is **40 columns, not §12a's 96** — which would have made the
gun more than twice as wide as the one in Doom. That also takes the per-frame
stream from 2688 B to **1120 B = 1.12 ms** of the REU's flat microsecond a byte.

**The pre-seed scans up from the bottom, not down from the top.** `colBotSeed`
is a 160-byte table `renderFrame` now seeds `colBot` from (the two window loops
merged into one to pay for the extra load — that block had no bytes left).
Seeding each column from its topmost *opaque* pixel would also forbid the world
to draw in any transparent gap below it, and a gap the world may not draw and
the gun does not paint is a black hole. `wad2reu.py`'s `_solid_from_bottom`
stops at the first such gap so every sealed row is a row the blit fills, and
`validate()` re-checks that against the shipped art. `make framehash` reporting
**nonzero 100.0%** is the invariant holding.

**The art is ranked, not stretched.** A linear min..max map produced a black
blob: SHTGA0 has half its opaque pixels in the bottom quarter of its own
luminance range and its maximum in a highlight a dozen pixels wide, so 77% of
the gun landed at intensity ≤ 5 — and the dither turns intensity 3 into one lit
pixel in five. Spreading by *rank* gives every intensity an equal share of the
sprite's pixels, so what survives 4 bits is the contrast within the sprite,
which is the only kind a foreground object needs. §12's sprites use the same
path.

**Ranking normalises brightness, and the foreground did not want that.** After
hardware confirmed the gun renders and paces, its remaining fault was that it
read grey against grey walls — rank spreading gives every sprite the same *mean*
brightness, which is right for props scattered through a level and wrong for the
one object permanently in front of the camera. Two levers, and only the second
one works. Ramp 14 dropped a step at each end (brown / **dgrey / grey**, was
brown / grey / lgrey) — that is as dark as the VIC goes, since below brown there
is nothing but blue and black, so past it *darker* can only mean **more black**.
Squeezing the intensity range does that but takes the top down with it, because
rank spreading is uniform: at 1..8 the gun is 88% black-and-brown with no third
tone, a flat silhouette rather than a dark object. Raising the rank to a power
(`WPN_GAMMA = 3.0`, range 1..15) darkens the body and leaves the top rank at 1.0,
so the barrel highlight survives. Over SHTGA0's 1292 opaque cells, by share of
subpixels:

| | black | | | |
|---|---|---|---|---|
| original, 2..15 γ1 | 5.5% | brown 36.2% | grey 39.3% | lgrey 19.0% |
| squeezed, 1..8 γ1 | 23.5% | brown 64.4% | dgrey 12.1% | grey 0.0% |
| **curved, 1..15 γ3** | **41.4%** | brown 35.6% | dgrey 16.5% | grey 6.5% |

Mean intensity 8.5 → 4.42. Floor 1 and not 0 because 0 is `SPR_CLEAR` — the blit
skips it and `colBotSeed` has sealed the column, so a zero would be a black hole
by the §12a rule above. **The black is the dither's, not the intensity's**, which
is why a tone curve darkens at all.

**Cost, `make phaseprof`, 8 frames:** compute 2979.1k → **3031.6k cycles**
(+52.5k = 0.82 ms at 64 MHz) for prep + blit, *net of* whatever the seal saved
inside the traversal — the two are in one bucket and were not separated. Plus
**1.12 ms of REU DMA** that VICE does not charge and hardware does. That puts a
frame at roughly **48.5 ms against the 49.7 ms cap**, which is the first time
this milestone has been inside one raster frame of the limit: §12's sprites
have to be measured on hardware before they are believed.

### 14a.2 Resident downsampled sprites, instead of streamed *(open, recommended)*

§12.4 says sprite cost is **dominated by REU streaming** — 5-8 sprites × 512 B
= 2.5-4 ms of the 6-8 ms estimate. But M2's sprites are static props and there
are few *distinct* ones. At **16×16 4-bit = 128 B**, eight props is **1 KB
fully resident** and the streaming cost goes to zero, taking the phase to
plausibly 2-3 ms.

This is precisely §10's Stage A argument applied to §12, and Stage A shipped.
It converts the phase's largest and least controllable cost into a fixed RAM
charge, payable out of what §14a.1 frees.

**What it costs:** blockier sprites than the walls behind them — at 160 columns
with 2:1 pixels, a 16×16 sprite scaled up close is visibly coarse. Mitigated by
§12.3's near-distance cap, which is wanted regardless.

### 14a.3 Drop double buffering *(open, held in reserve)*

`BITMAP1` (`$e000-$ff3f`, 8000 B) + `SCREEN1` (`$c000`, 1000 B) = **9 KB**, the
largest single block available, freed at **zero cost in frame time**.

**What it costs:** tearing. `chunky2mc` writes the bitmap across the frame and
`flip` syncs to raster 251; single-buffered, the conversion is visible as it
happens, and at 16.7 fps on a three-raster-frame period that is not subtle.
Ranked **below** §14a.1 and §14a.2 despite the larger number: it is the option
most likely to look *broken* rather than to look *reduced*. The card to play if
Stage B textures become the thing worth having most.

### 14a.4 Halve horizontal resolution to 80 columns *(rejected)*

MATRIX → 80×176 = 14080 B (**14 KB**), the column loop halves, the divide count
halves, texture sampling halves. Probably 15+ ms and 14 KB in one change, and
it dominates every other option numerically.

**Rejected on look.** Multicolor is already 2:1; this is 4:1, which changes what
the game is rather than how much of it there is. Recorded so it does not have to
be re-derived.

### 14a.5 Cold-code REU overlay *(open, modest)*

The general question was: can RAM be found by DMAing code blobs from REU,
executing them, and overwriting them with the next blob?

**Not for the hot path.** The ~90 B shortage is tight because `bspLoop`,
`doWall`, `spanFill`, the texture sampler and `checkMove` must be
*simultaneously* resident — they call each other within one pass and none of
them idles long enough to be safely overwritten. Reloading a 1-2 KB overlay
every frame also costs 1-2 ms/frame *permanently* at the REU's flat 1 byte/µs,
which spends the scarce frame budget to relieve the RAM budget — the inverse of
§3's one trade that works. And it does not produce what Stage B actually needs,
which is *data* scratch concurrent with rendering: MATRIX is the framebuffer
during play, not idle memory.

**Yes for cold code.** The door thinker, the use-key/walkover handler and the
HUD blit run rarely, not every frame. Making them on-demand overlays reclaims a
few hundred bytes of *resident* code RAM with no recurring per-frame cost,
because the reload only happens when the feature fires. `lineBoot`/BOOTCODE5
already does exactly this at boot, and `probe.py`'s relocated-block check
already guards the pattern (§11a) — so this is extending a mechanism the
codebase trusts, not inventing one.

### 14a.6 A fourth raster frame *(separate question, not a RAM lever)*

12.5 fps buys ~20 ms outright through machinery that already exists
(`FPS_CAP_TICKS`, `TARGET_FRAMES`, §8.1's phase-drift fix), and is far more
frame budget than any option above.

**But it frees no RAM at all**, and §14's risk #5 already called 12.5 fps below
playable. The two are independent: dropping to four frames does not require
overlays, and overlays do not require four frames. Worth keeping them separate
so that the cheap lever is not credited to the complicated mechanism.

### 14a.7 The combination worth revisiting

**§14a.1 at 144 rows + §14a.2** would together give ~5 KB of contiguous
code-capable RAM and land sprites at 2-3 ms instead of 6-8 — leaving roughly
15 ms free rather than 5, which is enough to make **Stage B textures a live
question again** after §10 closed them on budget grounds.

That is recorded as the shape of the argument, not as a plan. The agreed step
is 160 rows, looked at on hardware first.

## 15. Sequencing

Everything through §13 (clearing the ground, textures, doors, jump, bob, HUD)
is closed. **§12, sprites, is what remains of M2** — the only phase whose RAM
requirement is firm and whose budget has no fallback smaller than "draw fewer
things". §12a (the weapon view) is recommended to land first: it is a strict
subset of §12.2 item 4's masked blit (no scale accumulator, fixed position),
so it de-risks the general blit and streaming path cheaply before sprites
commit to it.

The lesson worth repeating for this phase, as for every phase before it:
**build the instrument first.** Every session that skipped a `phaseprof`/
`profile.py` checkpoint before estimating a cost had sound reasoning and the
wrong conclusion.

# Doom C64U — The Movement-to-Pixels Pipeline

This document traces one complete frame, from the moment the player presses a
movement key to the moment the resulting pixels are visible in VIC-II memory.
It is the "how it actually works" companion to the other documents:

| Document | Answers |
|---|---|
| `design.md` | *Why* the engine is shaped this way (target architecture) |
| `algorithm.md` | *What* the stages are, in abstract pseudo-code |
| `docs/reu-format.md` | *What the data looks like* — the frozen formats the engine actually reads |
| `3d-renderer-design.md` | *How the final raster stage works* (converter design) |
| **`pipeline.md`** (this file) | **The end-to-end compute path, as built, with numbers** |
| `IMPLEMENTATION_PLAN.md` | What is built, what is broken, what is next |

Everything below describes **Milestone 1 as it exists in `src/`** — a portal
renderer with flat-shaded walls, floors and ceilings. Where the implementation
deliberately differs from the target architecture in the design documents, the
difference is called out in a *Deviation* note. Sections marked **(planned)**
describe stages that do not exist yet.

> **Status caveat — read this before §11.** This document was written against
> the *portal* renderer and the hand-built three-sector test map, and against
> flat-shaded walls. Milestone 1 replaced the portal traversal with a BSP walk
> over real E1M1 geometry; Milestone 2's Stage A (2026-08-12) replaced flat
> walls with intensity-textured ones. **§5, §7, §8.7, §9 and §12.1-§12.3 were
> reconciled on 2026-08-12 and are current.** Only **§11** still traces a frame
> through the deleted test map at flat shading — retracing it against real
> E1M1 geometry needs a live capture (the tooling `debug-notes/` used), which
> is out of scope for a documentation-only pass; the numbers there are kept as
> a worked example of the *method*, not as current state. `IMPLEMENTATION_PLAN.md` §9.4 has the section-by-
> section accounting.
>
> [§13](#13-known-defects-and-unenforced-invariants) lists the defects that were
> fixed to get to a visible frame and the invariants that are still unenforced;
> its zero-page appendix is also portal-era. The cycle counts in §12.1 are
> static instruction counts, but the frame rate is measured: the engine now
> runs on a real C64 Ultimate at **16.63 fps with compute at 46.7 ms against
> a 59.85 ms deadline** (§12.1, §12.3), every frame on the three-raster-frame
> crossing.

---

## Table of contents

1. [The pipeline at a glance](#1-the-pipeline-at-a-glance)
2. [Number formats: the contract between stages](#2-number-formats-the-contract-between-stages)
3. [Stage 1 — Key press to intent bits](#3-stage-1--key-press-to-intent-bits)
4. [Stage 2 — Intent to world motion](#4-stage-2--intent-to-world-motion)
5. [Stage 3 — Sector resolution and collision](#5-stage-3--sector-resolution-and-collision)
6. [Stage 4 — Frame setup and camera basis](#6-stage-4--frame-setup-and-camera-basis)
7. [Stage 5 — BSP traversal: scene resolution](#7-stage-5--bsp-traversal-scene-resolution)
8. [Stage 6 — Per-wall geometry: transform, clip, project](#8-stage-6--per-wall-geometry-transform-clip-project)
9. [Stage 7 — Column loop: lifting 2D lines into vertical spans](#9-stage-7--column-loop-lifting-2d-lines-into-vertical-spans)
10. [Stage 8 — Chunky to multicolor conversion](#10-stage-8--chunky-to-multicolor-conversion)
11. [A fully worked frame](#11-a-fully-worked-frame)
12. [Frame budget accounting](#12-frame-budget-accounting)
13. [Known defects and unenforced invariants](#13-known-defects-and-unenforced-invariants)
14. [Where this pipeline grows next](#14-where-this-pipeline-grows-next)

---

## 1. The pipeline at a glance

```
        PLAYER PRESSES W
               |
   [1] readInput            input.asm      keyboard matrix + joy2 -> zInput bits
               |            ~120 cy
               v
   [2] movePlayer           input.asm      intent -> camX/camY/camA
               |            ~900 cy        dx = cos*speed >> 14   (2 x smulTrig)
               v
   [3] checkMove             input.asm      convex containment test, per seg of
               |            ~1.3k cy/seg   the destination subsector:
               |                           cross = (x1-x0)(py-y0) - (y1-y0)(px-x0)
               |                           -> stay | slide | descend to new subsector
               v
  ============ camera state is final for this frame ============
               |
   [4] renderFrame          bsp.asm        reset colTop[160]/colBot[160],
               |            ~2.5k cy       fetch camSin/camCos, seed BSP stack
               v
   [5] BSP descent          bsp.asm        stack of node/subsector indices,
               |  <---------------+        bounding-sphere + backface rejection
               v                  |
   [6] doWall (per seg)           |        world -> camera -> screen
        transformPoint            |          ry = (tx*cos + ty*sin) >> 14
        near-plane clip           |          rx = (tx*sin - ty*cos) >> 14
        projSX / projRow          |          sx  = 80 + rx*80/ry
        backface + screen clamp   |          row = 88 - dz*160/ry
        lineSetup x2, x4 or x5    |        4 screen-space lines + u (textured),
               |                  |        24-bit accumulators
               v                  |        14k cy (solid) / 22k cy (two-sided)
   [7] per-column loop            |        for x in [c0..c1]:
        clampAcc x2 or x4         |          clamp lines into open window
        spanFill x2 (flat)        |          ceiling / floor: flat
        spanFillTex x1 or x2      |          wall: textured, ~1.8x a flat pixel
        window update ------------+          two-sided: narrow window
               |                             solid: close column, openCols--
               |                           ~11 cy/pixel flat, ~18-20 cy/pixel wall
               v
   +-------------------------------------------+
   |  MATRIX  $1000-$7DFF  160x176 chunky      |   1 byte/pixel: %rrrriiii
   |  cell-major: cell n at MATRIX + n*32      |   ramp 0-15 | intensity 0-15
   +-------------------------------------------+
               |
   [8] convert              chunky2mc.asm  880 cells x ~411 cy = ~362k cy
               |                           ldy matrix,x / ora ditherTab,y
               |                           = dither + bit-position + code, fused
               v
   +-------------------+  +-------------------+  +-------------------+
   | BITMAP0/1  8000 B |  | SCREEN0/1  880 B  |  | COLBUF     880 B  |
   +-------------------+  +-------------------+  +-------------------+
               |
   [9] flip                 chunky2mc.asm  wait $d012 == 251,
               |            ~11k cy        swap VIC bank via $dd00,
               v                           burst COLBUF -> $d800
        VISIBLE ON SCREEN
```

The organising principle is **monotonic work reduction**: every stage must hand
the next stage strictly less, and more regular, work than it received.
E1M1's 725 segs become ~15-19 visible ones per frame after sphere and backface
rejection, which become ~160 column jobs, which become ~28k byte writes, which
become one linear 880-cell packing pass. No stage is allowed to hand the next
stage an unbounded problem.

---

## 2. Number formats: the contract between stages

Every stage boundary is a fixed-point contract. Getting these wrong is the
single largest source of bugs in an engine like this, so they are stated once,
here, and referenced everywhere else.

| Quantity | Format | Range | Where |
|---|---|---|---|
| World X/Y | signed 16-bit **integer** map units | ±32767 | `camX`, `wX0Lo/Hi` |
| World Z (heights) | signed 16-bit integer map units | ±32767 | `camZ`, `secFloorLo/Hi` |
| Angle | unsigned 8-bit turn | 0..255 = full circle | `camA` |
| Trig | signed **2.14** (16384 = 1.0) | ±1.0 | `sinLo/Hi`, `camSin`, `camCos` |
| Camera-space rx/ry | signed 16-bit integer map units | ±32767 | `zRX0`, `zRY0` |
| Screen X | signed 16-bit integer (clamped to 0..159 late) | ±32767 | `zSXW0`, `zC0` |
| Screen row | signed 16-bit integer (clamped to 0..175 late) | ±32767 | `zTop0`, `zBot0` |
| Line accumulator | signed **16.8** in 24 bits (frac, lo, hi) | ±32767.996 | `accTop`..`accBB` |
| Line step | signed **8.8** in 16 bits | ±127.996 | `stepTop`..`stepBB` |
| Clip param `t` | unsigned **0.8** | 0..0.996 | `zT+2` |
| Matrix pixel | `%rrrriiii` ramp:intensity | 16 ramps × 16 levels | `MATRIX` |

> **Deviation from `design.md`.** The design documents specify signed **16.16**
> world coordinates and a 16-bit angle space (65536 steps). The implementation
> uses **integer** 16-bit world coordinates and an **8-bit** angle. This was a
> deliberate Milestone-1 simplification — it halves every multiply and removes
> the shift/round step from `transformPoint` — and it has two visible costs:
>
> - **No sub-unit motion.** `MOVE_SPEED = 14` is an integer; the player cannot
>   move slower than 1 map unit per frame, and diagonal motion truncates
>   independently on each axis. Sub-unit velocity, acceleration and any smooth
>   deceleration require the 16.16 upgrade.
> - **Angular granularity of 1.406°** (360/256). At the screen centre one turn
>   step (`TURN_SPEED = 3`, i.e. 4.22°) shifts the view by
>   `tan(4.22°) x 80 = 5.9 columns`. Turning is visibly stepped. The sin table
>   is already 2.14, so the fix is to widen `camA` to 16 bits and index the
>   table with the high byte — the table itself does not change.

### Why 2.14 for trig

Trig is the only value in the pipeline that is always in `[-1, 1]`, so it gets
the format that spends every bit on fraction: 2.14 gives a resolution of
`1/16384 ≈ 6.1e-5`. Peak is `16383`, not `16384`, so that `+1.0` and `-1.0`
both fit in a signed 16-bit word. That one-LSB deficit is real and measurable:

```
dx = MOVE_SPEED * cos(0) >> 14
   = 14 * 16383 >> 14
   = 229362 >> 14
   = 13          <-- not 14
```

Walking due east at `MOVE_SPEED = 14` actually advances 13 units/frame, a
**0.006% systematic shortfall** compounded by truncation to 7.1%. This is
harmless for movement but would matter if the same routine were used for
anything that must round-trip (e.g. rotating a vector and rotating it back).
`smulTrig` truncates rather than rounds; adding a rounding bias
(`+0x2000` before the shift) costs ~8 cycles and removes the bias.

---

## 3. Stage 1 — Key press to intent bits

**Source:** `src/input.asm:9` (`readInput`)
**Output:** `zInput`, one byte, 4 meaningful bits
**Cost:** ~120 cycles, constant

The C64 keyboard is an 8×8 matrix: write a row mask to `$DC00`, read the
column bits back from `$DC01`, where a **pressed** key reads as **0**.

```
        lda #%11111101      ; pull row 1 low
        sta $dc00
        lda $dc01
        tay                 ; keep the row byte -- three keys are tested from it
        and #%00000010      ; W  = row 1, col 1
        bne !+
        lda #1              ; bit 0 = forward
        ora zInput
        sta zInput
```

Row 1 holds `3 W A 4 Z S E LSHIFT`, so a single strobe yields W (bit 1),
A (bit 2), S (bit 5) **and E (bit 6)**. D needs row 2 (`5 R D 6 C F T X`,
bit 2) and Q needs row 7 (`1 <- CTRL 2 SPACE C= Q RUN/STOP`, bit 6), so exactly
**three** matrix strobes cover all six keys. `tay` caches the row-1 byte so its
four tests cost one read, not four — the strafe keys were chosen partly for
that: putting strafe-right on E makes it free.

Joystick port 2 shares `$DC00`. Writing `$FF` releases every keyboard row, and
reading `$DC00` back gives the joystick directions in bits 0-3, active low:

```
        lda #$ff
        sta $dc00
        lda $dc00
        eor #$ff            ; active low -> active high
        and #%00001111
        ora zInput          ; same bit assignment as the keys
```

The bit layout was chosen so keyboard and joystick **merge with a single
`ora`** — no translation table, no branch. The joystick only reaches the low
four bits, so strafing is keyboard-only:

| Bit | Meaning | Key | Joystick |
|---|---|---|---|
| 0 | forward | W | up |
| 1 | backward | S | down |
| 2 | turn left | A | left |
| 3 | turn right | D | right |
| 4 | strafe left | Q | — |
| 5 | strafe right | E | — |

**Optimization approach.** Input is a fixed-cost stage with no data dependency
on the world, so it is placed first and never revisited. There is no key
repeat, no edge detection and no debounce: the renderer runs at a fixed rate,
so "held" is the only state that matters and the matrix read *is* the debounce.

> **Resolved (was: suspected defect).** `A` used to decrement `camA` and `D`
> increment it. The camera basis is `forward = (cos θ, sin θ)` with θ increasing
> counter-clockwise and `rx` the *rightward* axis, so **increasing `camA` turns
> left** — the keys were backwards, as playing it on hardware confirmed.
>
> This was settled by measurement rather than by argument, because the
> competing fix — flipping the sign of `rx` in `transformPoint` — would have
> resolved the symptom in the opposite direction and left the world mirrored.
> `tools/u64shot.py` grabbed the MATRIX off a running C64 Ultimate at
> `camA = 0`, `+8` and `-8`: at `+8` the portal moves **right** across the
> screen, which is what turning left looks like. So `camA` increasing is a left
> turn, and `IN_LEFT` now increments it.
>
> The fix is in `movePlayer`, not `readInput`. Both the keys and the joystick
> feed bits 2 and 3, so correcting the *effect* of those bits fixes the stick at
> the same time; swapping which key sets which bit would have fixed the keyboard
> and left the joystick reversed.

---

## 4. Stage 2 — Intent to world motion

**Source:** `src/input.asm:51` (`movePlayer`)
**Output:** `camX`, `camY`, `camA` updated; `oldX`/`oldY` saved for undo
**Cost:** ~900 cycles when moving, ~40 when not

### 4.1 Turning

```
camA = (camA ± TURN_SPEED) mod 256
```

Free: the 8-bit angle wraps in the register. There is no normalisation step
anywhere in the engine, which is precisely why the angle is 8-bit — a
`0..65535` turn space would need explicit masking, and a radian representation
would need a modulo.

### 4.2 Translation

The camera basis is fetched fresh **after** turning, so a turn takes effect on
the same frame it is pressed:

```
        ldy camA
        lda sinLo,y  / sinHi,y   -> camSin
        tya : clc : adc #64 : tay
        lda sinLo,y  / sinHi,y   -> camCos     ; cos(a) = sin(a + 64)
```

**Optimization: one table, two functions.** `cos θ = sin(θ + 90°)`, and 90° is
exactly 64 steps of a 256-step turn, so the cosine table is the sine table read
at an offset. The `adc #64` wraps in 8 bits for free. This halves the trig
table from 1024 bytes to 512 and, more importantly, halves the *hot* table
footprint that must stay resident.

Then the two scaled basis components:

```
zCosT = (MOVE_SPEED * cos) >> 14
zSinT = (MOVE_SPEED * sin) >> 14
```

computed by `smulTrig` (`src/math.asm:97`) — **twice per frame, no matter how
many direction keys are held.** That is the point of hoisting them out. The
camera's two axes are

```
forward = ( cos,  sin)
right   = ( sin, -cos)
```

so both are spanned by the same pair of values, and every direction key
degenerates into a pair of 16-bit adds into a displacement accumulator:

| Intent | `zMvDX` | `zMvDY` |
|---|---|---|
| forward (W) | `+= zCosT` | `+= zSinT` |
| backward (S) | `-= zCosT` | `-= zSinT` |
| strafe right (E) | `+= zSinT` | `-= zCosT` |
| strafe left (Q) | `-= zSinT` | `+= zCosT` |

`camX += zMvDX; camY += zMvDY` once, then `checkSector`. Walking and strafing
together therefore cost what walking alone used to: ~840 cycles of `smulTrig`
plus ~100 of adds, against ~1680 if each axis re-derived its own product.

Sanity check at `camA = 0` (facing east): `right = (0, -1)` = south, which is
indeed on your right facing east — and that is what hardware reports, `E`
moving the player south and `Q` north (`§3`'s resolved note describes the same
harness).

Diagonals are *not* normalised: holding W and E together moves `√2 ×
MOVE_SPEED`. Doom did the same thing, and fixing it needs the 16.16 upgrade
this section's Deviation note already calls for.

### 4.3 `smulTrig`: the signed 2.14 multiply

```
smulTrig:  zA (signed 16) * zB (signed 2.14) >> 14 -> zA (signed 16)
```

Sign is stripped first (`zSign = zA+1 EOR zB+1`, then `abs` both), the
magnitudes go through the unsigned `umul16`, and the sign is reapplied at the
end. This keeps `umul16` purely unsigned — one routine, used by every consumer.

The `>> 14` of a 32-bit product is done as `<< 2` then take the high word:

```
        asl zP+1 : rol zP+2 : rol zP+3      ; P <<= 1
        asl zP+1 : rol zP+2 : rol zP+3      ; P <<= 1
        lda zP+2 -> zA                       ; take bytes 2,3 = >> 16
        lda zP+3 -> zA+1
```

Six shift instructions plus two loads, versus fourteen right-shifts of a
32-bit value. **Shifting the *other* way and re-slicing the word boundary is
almost always cheaper than shifting to the boundary you want.**

### 4.4 `mul8`: quarter-square multiplication

Everything above rests on `mul8` (`src/math.asm:35`), the engine's only
primitive multiply. The 6502 has no multiplier, and a shift-add 8×8 loop costs
~180 cycles. The quarter-square identity replaces it with two table lookups:

```
a*b  =  f(a+b) - f(|a-b|)        where  f(x) = floor(x*x / 4)
```

Proof: `f(a+b) - f(a-b) = ((a+b)² - (a-b)²)/4 = 4ab/4 = ab`. The floors cancel
because `(a+b)` and `(a-b)` always have the same parity, so both quarter-squares
have identical fractional parts.

The tables are `sqrLo`/`sqrHi`, **512 entries each** (indices `0..510`, since
`a+b` can reach 510) — 1024 bytes total. The lookup uses self-modifying code:

```
        sta m8a+1           ; patch the low byte of the operand to sqrLo + a
        sta m8b+1
        ...
m8a:    lda sqrLo,y         ; effectively sqrLo[a + b], Y = b
```

Because `sqrLo` is page-aligned, writing `a` into the operand's low byte moves
the table base to `sqrLo + a`, and indexing by `Y = b` reaches `sqrLo[a+b]`.
Two `sta`s (8 cycles) buy an indexed 16-bit table read that would otherwise
need a 16-bit add. **Cost: ~53 cycles versus ~180 for shift-add — a 3.4×
speedup on the single hottest primitive in the engine.**

`umul16` composes four `mul8` calls in the schoolbook arrangement
(`ll`, `hh`, `lh`, `hl`) for ~330 cycles including glue.

**Optimization approach summary for this stage:**

| Technique | Saves |
|---|---|
| `cos = sin(a+64)` from one table | 512 bytes of hot RAM |
| 8-bit angle wraps for free | all angle normalisation |
| Quarter-square `mul8` | ~127 cy per 8×8 multiply |
| Self-modified table base | a 16-bit add per lookup |
| `<< 2` + word re-slice for `>> 14` | ~8 shift instructions |
| One basis pair spans both axes (walk + strafe) | two `smulTrig` (~840 cy) |
| Early-out when no movement bits set | ~900 cy on idle frames |

---

## 5. Stage 3 — Sector resolution and collision

**Source:** [`src/input.asm:247`](src/input.asm#L247) (`checkMove`) — M1 called
this `checkSector` and tested the hand-built map's sectors; it now tests the
segs of the subsector `bspFindSsec` descends to.
**Output:** `camSec`/`camSsec` (possibly new), or `camX`/`camY` slid or reverted
**Cost:** ~1.3k cycles per seg tested; E1M1 averages 3.09 segs per subsector

This is where "scene resolution" begins: the engine must know **which sector
the camera is in** before it can render, because the sector supplies the floor
and ceiling planes and the shading bytes.

### 5.1 The convexity assumption

Every subsector is **convex** — a BSP leaf is convex by construction, which is
what the hand-built map had to assert about its sectors by hand — with its segs
wound clockwise in standard math axes (x east, y north) so the interior lies to
the **right** of each directed seg.
For a convex polygon, "inside" is simply "on the interior side of every edge" —
no ray casting, no winding number, no edge-crossing parity.

For a directed wall `(x0,y0) -> (x1,y1)` and point `(px,py)`:

```
cross = (x1-x0)*(py-y0) - (y1-y0)*(px-x0)
```

`cross < 0` means the point is to the right of the wall, i.e. inside.

### 5.2 The sign-only trick

The two products are full signed 32-bit values (`ssmul32`), but **only the sign
of their difference is needed**. So the subtraction is done for the carry chain
alone, discarding every result byte:

```
        lda zNum   : sec : sbc zP+0      ; results thrown away --
        lda zNum+1 :       sbc zP+1      ; only the borrow propagates
        lda zRXt   :       sbc zP+2
        lda zRXt+1 :       sbc zP+3
        bvc !+
        eor #$80                          ; signed-compare fixup
!:      bmi !inside+
```

No `sta` in the whole chain: 4 loads, 4 subtracts, a V-flag fixup, one branch.
The `bvc / eor #$80` pair is the standard signed-comparison correction — when
overflow occurred, N is inverted relative to the true sign.

Note also that the intermediate 32-bit product is parked across two unrelated
zero-page pairs (`zNum` and `zRXt`) rather than in a dedicated buffer — a
deliberate reuse of scratch that is dead at this point in the frame. Zero page
is the scarcest resource on this machine, and `defs.asm` documents the overlaps
explicitly (`oldX`/`oldY` alias the renderer's line accumulators, which are
dead during movement).

### 5.3 Three outcomes

On the first wall where the point tests **outside**:

```
        lda sgBack,x        ; wBack, in M1's hand-built map
        cmp #$ff
        beq !blocked+       ; one-sided seg -> undo the whole move
        sta camSec          ; two-sided     -> enter the neighbouring sector
        ; and drop the eye to the new floor: camZ = secFloor[new] + EYE
!blocked:
        ; restore camX/camY from oldX/oldY
```

**Collision was undo-based, not slide-based** — this describes M1. Hitting a
wall cancelled the entire frame's motion, including the component parallel to
the wall, which is the cheapest correct blocking model and is why `oldX`/`oldY`
are saved before any displacement is applied.

> **M2 (2026-08-12) made it slide-based**, which is what `algorithm.md`'s
> `collision.slide_move` always specified. `checkMove` now projects the
> remaining motion onto the *seg direction* — the same vector as
> `v - n(v·n)/(n·n)`, one fewer sign to get wrong — and re-tests, up to three
> times per frame. The cost is two divides and four multiplies per blocked
> wall, on blocked frames only. See `src/input.asm` (`slideVec`),
> `IMPLEMENTATION_PLAN.md` §9.2, and `make walktest`.

**Optimization approach.** Convexity is doing enormous work here. It converts
point-in-sector from an O(n) ray cast with parity bookkeeping into an O(n)
loop that **early-exits on the first failure** and needs no state at all. The
same assumption pays off again in §8 (no wall sorting) and §9 (a single
top/bottom line pair per wall). It is the load-bearing constraint of the whole
renderer, and it is enforced by the map format, not checked at runtime.

> **Limitation, still open.** After following a portal, the test returns
> immediately without re-testing containment in the *new* subsector. A single
> frame's motion that crosses two boundaries (through a corner, or a corridor
> narrower than `MOVE_SPEED`) is only tested against the first.
>
> M2's slide loop does *not* close this, and the iteration cap it added is not
> the fix it was expected to be: re-descending the BSP with the destination
> point returns the subsector that **contains** that point, so every seg of it
> then tests as inside and the extra iteration finds nothing. Only a blocked
> destination is re-tested usefully. The real fix is to march the motion
> subsector by subsector, testing the *segment* old→new against each one's
> segs. At `MOVE_SPEED = 21` against E1M1's subsector sizes it has not been
> observed, and `make walktest` intersects every frame-to-frame step with every
> one-sided linedef in the map, which is what would catch it.

---

## 6. Stage 4 — Frame setup and camera basis

**Source:** `src/render/walls.asm:37` (`renderFrame`)
**Cost:** ~2.5k cycles

Four things happen before any geometry is touched:

**1. Reset the column clip windows.**

```
        ldx #159 : lda #0     -> colTop[x] = 0      ; first open row
        ldx #159 : lda #176   -> colBot[x] = 176    ; first closed row below
```

`colTop`/`colBot` are the entire occlusion structure — two 160-byte arrays,
one page each, holding the still-visible vertical window of every screen
column. This is Doom's own `ceilingclip`/`floorclip`, and it is what makes the
renderer **occlusion-complete without a Z-buffer**: 320 bytes replace 28160.

**2. Fetch the camera basis** — same `sin`/`cos(a+64)` pattern as §4.2. It is
recomputed here rather than reused from `movePlayer` because `movePlayer`
skips the fetch entirely when no movement key is held.

**3. Clear `visitedSec[]`** — one byte per sector, ensuring each sector is
rendered at most once per frame regardless of how many portals lead to it.
This is what bounds portal traversal on maps with cycles.

**4. Seed the traversal stack** with the camera's own sector and the full
screen window:

```
        pStkSec[0] = camSec ; pStkXL[0] = 0 ; pStkXR[0] = 159 ; stackN = 1
        visitedSec[camSec] = 1
```

**Optimization approach.** No frame clear. The MATRIX is never zeroed, because
every column is guaranteed to be fully painted: ceiling span, wall span and
floor span between them cover `[0,176)` exactly. Skipping the clear saves
28160 byte writes — roughly **170k cycles, about 9% of a 25 fps frame at
48 MHz**. This guarantee is a *contract*, not an accident: if a future change
ever allows a column to be left partially unpainted (a sky that is not drawn,
an early-out on budget overflow), the clear must come back or the previous
frame will show through.

---

## 7. Stage 5 — BSP traversal: scene resolution

**Source:** `src/render/bsp.asm` (`bspLoop`, `sideOf`, `nodeStep`,
`renderSsec`, `ssecHdr`/`ssecSegs`), `src/render/walls.asm:126` (`segFacing`)
**Reconciled 2026-08-12** — replaces the portal-stack description this
section carried through M1; see `IMPLEMENTATION_PLAN.md` §2 for the
architecture summary this expands on.

> **Deviation from the design documents and from M1's own hand-built map.**
> `algorithm.md` and the early sessions of this engine assumed a **portal
> graph**: sectors linked by two-sided walls, walked depth-first with a
> narrowing screen-space window (`pStkSec`/`pStkXL`/`pStkXR`, `visitedSec[]`).
> That graph does not exist for real WAD geometry — E1M1's 85 sectors are not
> convex, so there is no sector-level polygon to test a point against or to
> carry a portal window through. What *is* convex, by construction, is a BSP
> **subsector** (237 of them in E1M1), and the traversal is the BSP descent
> Doom itself uses to visit them front-to-back, not a portal walk.

The visible set is discovered by descending `NODES`, front child first, with
an explicit stack — no recursion, no portal window, no per-sector visited
flag:

```
push(root)
while stack not empty:
    node = pop()
    if node is a leaf (subsector):
        if !sphereVisible(ssecSphere[node]): continue      # frustum reject
        DMA in SSECDATA[node]                              # segs + sector id
        renderSsec(node)                                    # every seg, in seg order
        if openCols == 0: return                            # frame done early
        continue
    if !sphereVisible(nodeSphere[node]): continue            # whole subtree reject
    side = sideOf(camX, camY, node)                          # which child is "near"
    push(far child)
    push(near child)                                         # popped first
```

`renderSsec` calls `doWall` once per seg of the subsector, in the order the
seg record streams from the REU — there is no window to clip against and no
column range to narrow, because occlusion is carried entirely by
`colTop`/`colBot` (§9), not by a screen-space interval handed down the stack.

### 7.1 Why front-to-back, and where the column window went

The BSP invariant — near child first, then far child, per node — puts the
frame's geometry in front-to-back order automatically; §8.5's "no sort"
argument still holds, but the thing it is no longer sorting is *subsectors*
as well as *walls within a subsector*. There is no `[xL, xR]` window carried
between stack entries, because there is no portal geometry to intersect it
against — every seg is projected and clamped against the *screen's* `[0,159]`
directly (§8.5), and `colTop`/`colBot` do the only narrowing this renderer
needs.

`openCols` (a live count of columns with `colTop[x] < colBot[x]`, at `$5f`)
replaces `visitedSec[]`'s job of bounding traversal: once every column is
closed, the frame is visually complete and the descent returns immediately,
however much of the BSP remains unvisited. This is a **stronger** guarantee
than the portal renderer's — it does not merely cap depth or breadth, it
detects true completion — but it costs a decrement and a compare per solid
column instead of nothing.

### 7.2 Two rejection tests ahead of `doWall`

The BSP descent adds two whole-subtree/whole-subsector rejections that the
portal renderer had no equivalent of, because a portal graph has no bounding
volume to test before committing to a sector's walls:

| Test | Where | What it removes |
|---|---|---|
| Bounding sphere vs. frustum | `bspLoop`, before descending a node; `renderSsec`, after the 8-byte subsector header | whole subtrees and whole subsectors — E1M1 averages 71.7 node descents and 39.3 subsectors visited out of 234/235 |
| World-space backface | `segFacing`, before any `transformPoint`/`projSX` call | ~53.6 segs/frame that would otherwise cost two projections each |

Both are described in full in `IMPLEMENTATION_PLAN.md` §2 and §4 (the sphere
test is deliberately conservative — `k = r + (r>>1)` rather than an exact
`sqrt(2)·r` — because a coarse *transform* that needed 128 units of slop cost
more than the exact frustum test saved).

### 7.3 Per-subsector setup

`renderSsec` hoists everything constant across the subsector's segs, exactly
as `renderSector` did per sector in the portal renderer — the sector a
subsector belongs to still supplies one ceiling, one floor and two shading
bytes:

```
zDzC = secCeil[s]  - camZ         ; height of ceiling above the eye
zDzF = secFloor[s] - camZ         ; depth of floor below the eye (negative)
zCeilByte  = secCByte[s]          ; flat shading byte for the ceiling
zFloorByte = secFByte[s]          ; flat shading byte for the floor
```

Computing `dz` **relative to the eye, once per subsector** is what allows the
row projection in §8.4 to be a single divide with no subtraction in the inner
loop — unchanged from the portal renderer, because nothing about the vertical
projection depends on how the visible set was discovered.

---

## 8. Stage 6 — Per-wall geometry: transform, clip, project

**Source:** `src/render/walls.asm:126` (`doWall`)
**Cost:** ~14.3k cycles (solid wall), ~22.0k cycles (portal wall)

This is the mathematical core. Each wall goes through six steps, each of which
can reject the wall and return early — ordered **cheapest test first**.

### 8.1 World to camera space

```
        tx = wx - camX          ; translate
        ty = wy - camY
```

then rotate by `-camA` (`transformPoint`, `walls.asm:716`):

```
        ry = (tx*cos + ty*sin) >> 14        ; forward axis
        rx = (tx*sin - ty*cos) >> 14        ; rightward axis
```

Sanity check at `camA = 0` (facing east): `cos = 1, sin = 0`, giving
`ry = tx` (forward is +x, east ✔) and `rx = -ty` (rightward is -y, south —
which is indeed on your right when facing east ✔).

Cost: four `smulTrig` calls ≈ 1780 cycles per endpoint, 3560 per wall. **This
is the single most expensive step in the pipeline** and the first place to
optimise: a 2D rotation can be done with three multiplies instead of four
(Gauss's trick), or the endpoints can be transformed *once per vertex* rather
than once per wall — in the test map every vertex is shared by two walls, so
vertex-level caching would halve this outright.

### 8.2 Near-plane clip

`NEAR = 16` map units. Three cases, ordered by frequency:

| `ry0` | `ry1` | Action | Cost |
|---|---|---|---|
| ≥ NEAR | ≥ NEAR | pass through | ~20 cy |
| < NEAR | < NEAR | **reject** | ~15 cy |
| mixed | mixed | clip the near endpoint | ~1.3k cy |

The clip solves for the parameter `t` where the wall crosses `ry = NEAR`:

```
t = (NEAR - ry0) / (ry1 - ry0)          computed as (num << 8) / den  -> 0.8 fixed
rx0 += (rx1 - rx0) * t >> 8
ry0  = NEAR
```

`clipT` (`walls.asm:780`) and `mulT` (`walls.asm:799`) implement this. `t` is
deliberately only **8 bits of fraction** — at 160 columns, a clip position
error of `1/256` of a wall's length is far below one pixel for any wall that
survives to be drawn, so the extra precision would be spent and then discarded.

Clipping only `rx`/`ry` (never the texture coordinate, because there is no
texture coordinate yet) is why this is cheap. When textured walls arrive, `t`
must also interpolate `u`, and `t`'s precision requirement rises.

### 8.3 Horizontal projection

```
sx = 80 + rx * HFOCAL / ry              HFOCAL = 80
```

`HFOCAL = 80` on a 160-column screen sets the horizontal half-FOV to
`atan(80/80) = 45°`, i.e. **a 90° horizontal field of view** — Doom's own.
`projSX` (`walls.asm:828`) strips the sign, does `umul16` then `udiv`, clamps
the quotient to `$7FFF`, and adds or subtracts from the screen centre.

### 8.4 Vertical projection

```
row = 88 - dz * VFOCAL / ry             VFOCAL = 160
```

`VFOCAL = 2 × HFOCAL` is not arbitrary. **Multicolor pixels are twice as wide
as they are tall.** A 160×176 multicolor display occupies the same physical
area as a 320×176 hi-res one, so to keep the projection square in *physical*
terms the vertical focal length must be double the horizontal. Without this,
every wall would look half as tall as it should.

The resulting vertical field of view is `2 × atan(88/160) = 57.6°`, correctly
proportioned to the 90° horizontal.

The horizon sits at row 88 (of 176) — dead centre, so there is no pitch, no
look-up/look-down, and `88` is a compile-time constant in the projection rather
than a variable to load. Adding pitch means replacing `#88` with a zero-page
`horizon` variable: about 2 extra cycles per call, 6 calls per wall.

Both `projSX` and `projRow` end with:

```
        lda zD+1 : bpl !+           ; quotient exceeded $7FFF?
        lda #$ff : sta zD+0
        lda #$7f : sta zD+1         ; saturate
```

Saturation rather than wraparound. A near-plane-grazing wall produces an
enormous quotient; wrapping it would place the wall on the *wrong side* of the
screen and corrupt the column loop, while saturating merely places it far
off-screen where the window clamp discards it.

### 8.5 Backface culling and window clamping

```
        if !(sx0 < sx1) : reject         ; signed compare -> back-facing
        c0 = max(sx0, xL)
        c1 = min(sx1 - 1, xR)
        if c1 < c0 : reject
```

**Backfacing is a single signed comparison.** Clockwise winding means a wall
seen from its interior side always projects left-to-right. No normal vector, no
dot product — the projection has already computed everything needed.

`c1 = sx1 - 1` makes the interval half-open in world terms and closed in column
terms: wall spans `[sx0, sx1)`, columns run `c0..c1` inclusive. This is what
guarantees adjacent walls of a convex sector meet exactly, with no shared
column and no gap.

**Optimization: convexity removes the sort.** In a convex sector, the
front-facing walls project to **disjoint, contiguous** column ranges covering
`[xL, xR]` exactly once. There is therefore nothing to sort and nothing to
depth-test *within* a sector — the walls can be drawn in map order.
`algorithm.md`'s `sort.front_to_back(filtered_walls)` stage does not exist in
the implementation because convexity makes it unnecessary. This is worth
~n·log n comparisons per sector and, more importantly, an entire scratch array.

§11 shows this working: the three visible walls of sector A cover columns
`0-60`, `61-98` and `99-159` — disjoint, contiguous, exhaustive.

### 8.6 Distance shading

```
        light = (ry0 + ry1) >> 7                 ; = mean(ry) / 64
        intensity = max(15 - light, 2)
        wallByte = ramp[wall] | intensity
```

The two `ry` values are added and shifted seven times, which is `mean/64`. So
intensity falls by one step every 64 map units, from 15 at point-blank to the
floor value of 2 at `13 × 64 = 832` units. Sector A is 1024 units across, so a
wall at the far side of the room renders at near-minimum brightness — the
"depth cue for free" that `3d-renderer-design.md` describes, delivered by
`ora`-ing an intensity nibble into a ramp nibble.

The clamp to a minimum of 2 (rather than 0) keeps distant geometry visible as
silhouette rather than dissolving it into the black background.

**One shading value per wall, not per column.** The wall is flat-shaded at its
midpoint depth. Per-column shading would need the depth interpolated across the
wall — cheap in principle (another accumulator), and the natural next step once
textures make banding visible.

### 8.7 The screen-space lines

The projection produces, per wall, the endpoint rows of up to four *vertical*
interpolators, plus one *horizontal* one that Stage A textures added
(2026-08-12):

| Line | Index | Meaning | Present when |
|---|---|---|---|
| `top` | 0 | ceiling / wall top edge | always |
| `bot` | 1 | floor / wall bottom edge | always |
| `btop` | 2 | back sector's ceiling | two-sided seg only |
| `bbot` | 3 | back sector's floor | two-sided seg only |
| `u` | — | texel column, along the wall | textured seg only |

> **Textured walls (§9, `IMPLEMENTATION_PLAN.md` §10) reuse `lineSetup`
> itself for `u` rather than adding a fifth line to the `zTop0`/`accTop`
> layout below.** `u` is monotonic along a seg — it is the seg's dominant
> world axis, scaled `>>4`, with no per-seg texture offset — so `lineSetup`'s
> existing `((y1-y0)<<8)/dx` machinery seeds it exactly like `top`/`bot`,
> stepped once per column. There is no per-seg 64-byte strip table: a column
> unpacks its texel only when `u`'s integer part changes, which for a
> perspective-correct `u` is at most once, so the lazy unpack costs nothing
> extra on the common case and avoids the ~2048-cycle/seg table build a strip
> table would have cost. `v` needs no new interpolator at all — it is the
> wall-span row accumulator (`accTop`/`accBot`) already being stepped, masked
> to the 8×8 tile height; its vertical scale is affine per seg (taken at
> mid-`ry`) rather than a true perspective divide, which is where the
> approximation actually lives.**

**The key geometric fact that makes this renderer cheap:** in a perspective
projection with a level camera, the top and bottom edges of a vertical-sided
wall are **exactly linear in screen x**. They are not linear in world space and
not linear in depth — but on screen, they are straight lines. So each edge needs
its endpoints projected (2 divides) and then costs *pure addition* across every
column it covers.

`lineSetup` (`walls.asm:638`) builds each interpolator:

```
step_i = ((y1_i - y0_i) << 8) / dx           ; 8.8 signed, via sdiv
acc_i  = (y0_i << 8) + step_i * (c0 - sx0)   ; 16.8, pre-advanced to the
                                             ; first *visible* column
```

Two details worth noting:

- **`<< 8` before the divide, not after.** Dividing `dy << 8` by `dx` yields the
  step directly in 8.8 with full precision. Dividing first and scaling after
  would quantise the step to whole pixels and make long walls visibly stair-step.
- **The accumulator is pre-advanced by `(c0 - sx0)`**, so a wall clipped to a
  narrow window pays one multiply instead of stepping the accumulator across the
  invisible columns. For a wall clipped from 160 columns to 10, this saves ~150
  iterations of a 36-cycle `AddStep`.

The layout of the endpoint variables is **load-bearing**: `zTop0`, `zTop1`,
`zBot0`, `zBot1`, `zBTop0`, ... are laid out so that line `i`'s endpoint `y0`
sits at `zTop0 + i*4`, and its accumulator at `accTop + i*3`, with steps at
`stepTop + i*2`. `lineSetup` and `clampAcc` both index by a computed offset
rather than branching on the line index. `defs.asm:69` flags this explicitly:
*"layout is load-bearing"*. Reordering those zero-page constants breaks the
renderer silently.

---

## 9. Stage 7 — Column loop: lifting 2D lines into vertical spans

**Source:** `src/render/walls.asm:475` (`!colloop`), `src/render/tex.asm`
(texture sampling, landed 2026-08-12)
**Cost:** ~270 cy/column (solid) or ~400 cy/column (two-sided), plus ~11 cy per
flat-shaded pixel written, **~18-20 cy per textured wall pixel** (§9.1a)

This is the "lifting" step: four 2D lines and two clip arrays become vertical
runs of bytes in the chunky buffer. Floors and ceilings stay flat-shaded
(`IMPLEMENTATION_PLAN.md` §8 keeps flats out of M2's scope); only the wall
span samples a texture.

### 9.1 The per-column sequence

```
for x = c0 .. c1:
    wt = colTop[x] ; wb = colBot[x]
    if wb <= wt: goto advance                     # column already closed

    tw = clamp(accTop, wt, wb)                    # wall top,    clipped
    bw = clamp(accBot, tw, wb)                    # wall bottom, clipped

    spanFill(x, colTop[x], tw,  ceilByte)         # ceiling, flat
    spanFill(x, bw,        wb,  floorByte)        # floor, flat

    if solid:
        spanFillTex(x, tw, bw, ramp, texel(u, v))  # full wall, textured
        colTop[x] = 176 ; colBot[x] = 0           # column permanently closed
    else:                                          # two-sided
        bt = clamp(accBT, tw, bw)                 # opening top
        bb = clamp(accBB, bt, bw)                 # opening bottom
        spanFillTex(x, tw, bt, ramp, texel(u, v))  # upper wall (step down)
        spanFillTex(x, bb, bw, ramp, texel(u, v))  # lower wall (step up)
        colTop[x] = bt ; colBot[x] = bb           # window narrowed to opening

advance:
    accTop += stepTop ; accBot += stepBot ; u += stepU
    if two-sided: accBT += stepBT ; accBB += stepBB
```

Three properties make this loop cheap:

**1. Clamping is chained, not independent.** `bw` is clamped into `[tw, wb]`,
not `[wt, wb]`; `bb` into `[bt, bw]`. Each clamp uses the previous result as its
lower bound, which makes span ordering (`ceiling ≤ wall top ≤ wall bottom ≤
floor`) structurally impossible to violate — even when the interpolators
disagree with the window because of accumulated rounding. It costs nothing:
`clampAcc` takes its bounds from `zWT`/`zWB`, which the caller simply overwrites
between calls.

**2. `clampAcc` reads only the integer bytes.** The accumulator is 24-bit
(frac, int-lo, int-hi), but the clamp tests `acc+2` for sign, then `acc+1`
against the bounds. The fraction is *never* examined — it exists only to keep
the step from drifting. ~26 cycles.

**3. Occlusion is a two-byte write.** A solid wall closes its column with
`colTop[x] = 176, colBot[x] = 0`, which makes every later `wb <= wt` test fail
in ~20 cycles. A two-sided seg narrows the window to the opening instead of
closing it. There is no depth comparison anywhere.

### 9.1a Texture sampling (Stage A, landed 2026-08-12)

**Source:** `src/render/tex.asm`; design rationale in
`IMPLEMENTATION_PLAN.md` §10.

`spanFillTex` replaces `spanFill` only for the wall span — floors and
ceilings still call the flat `spanFill` above. The insight the matrix format
hands this stage (`IMPLEMENTATION_PLAN.md` §10.1) is that a texture must
modulate the **intensity nibble only** and leave the ramp alone, because a
4×8 multicolor cell can only hold the colours of one ramp: every wall in a
family shares its ramp byte exactly as a flat wall did, so the attribute
constraint that made M1's frames clean survives texturing for free.

```
texel = tile[(u & 7), (v & 7)]            ; 8x8 nibble-packed tile, resident
byte  = ramp | clamp(texel + depthBias, 1, 15)
sta MATRIX,y : ora #byte
```

Depth falloff, which used to set the whole intensity nibble (§8.6), becomes a
**bias** added to the texel's own intensity and clamped back into `1..15` —
the wall stays readable as silhouette at range exactly as it did flat-shaded.

Three things keep this close to a flat `spanFill` in cost:

- **`v` is nearly free.** It is the wall-span row accumulator already being
  stepped for `clampAcc` (§9.1), masked to the tile's 8-row height — no new
  interpolator, no extra divide.
- **`u` reuses `lineSetup`**, seeded and stepped exactly like `top`/`bot`
  (§8.7) rather than needing a per-column perspective divide. A texel is
  re-fetched only when `u`'s integer part changes, which along a monotonic
  seg happens at most once per column.
- **One `ora` per pixel**, same as the flat case, once the texel nibble is in
  a register — the tile lookup and the depth-bias clamp are the only new
  work.

Measured cost (`IMPLEMENTATION_PLAN.md` §10.4, §10 landing note): a flat pixel
is ~11 cy in `spanFill` (~22 cy/pixel once `spanFill`'s own overhead is
counted against the whole frame); a textured pixel is **~1.8× that, ~18-20
cy**, for the fixed-point `v` accumulate, the tile-nibble fetch/unpack and the
`ora`. Walls are ~40% of E1M1's pixels, so the whole-frame effect measured on
hardware was **+8.7 ms** (37.6 → 46.7 ms compute, §12.1) — the top of the
6-9 ms estimate that section had predicted, and the reason Stage B (real
64×64 streamed texels, §10.2) did not land in M2.

### 9.2 `AddStep`: 24-bit accumulate with a 16-bit signed step

```
        lda acc   : clc : adc step   : sta acc
        lda acc+1 :       adc step+1 : sta acc+1
        lda acc+2
        bit step+1 : bmi neg         ; sign-extend the step into byte 2
        adc #0     : jmp done
neg:    adc #$ff
done:   sta acc+2
```

`bit step+1` tests the step's sign **without disturbing the carry** from the
previous `adc` — `bit` sets N from bit 7 of the operand and leaves C alone.
Sign extension then costs one `adc #0` or `adc #$ff`. ~36 cycles for a 24-bit
signed accumulate.

### 9.3 `spanFill`: MATRIX addressing

**Source:** `src/math.asm:253`

The MATRIX is **cell-major**: the buffer is ordered by 4×8-pixel character
cell, not by scanline.

```
pixel(x, y) = MATRIX + (y>>3)*1280      ; which row of cells      (22 rows)
                     + (x>>2)*32        ; which cell in that row  (40 cells)
                     + (y&7)*4          ; which row inside the cell
                     + (x&3)            ; which pixel inside that row
```

40 cells × 22 rows = 880 cells × 32 bytes = **28160 bytes = exactly 110 pages**.

This layout exists to serve the *converter* (§10), which must read all 32 bytes
of a cell consecutively. It costs the rasterizer a discontiguous vertical step,
but that cost is small and bounded:

- **Within a cell**, stepping down one row is `+4`.
- **Crossing to the next cell row** is `+1280 = $500` — and because the low byte
  of 1280 is zero, the step only touches the pointer's **high byte**:
  `lda zSPtr+1 : clc : adc #5 : sta zSPtr+1`. A 16-bit pointer advance for the
  price of an 8-bit one. It is inlined at both of its sites; as a subroutine
  that preserved A across itself it cost 29 cycles against the 64 the eight
  stores it serves are worth, and the cell loop runs ~4600 times a frame
  (`IMPLEMENTATION_PLAN.md` §15).

The pointer is built from two tables so no multiplication is needed:

```
        ldx zSX
        lda zSY0 : lsr : lsr : lsr : tay          ; Y = y >> 3 = cell row
        lda xOfsLo,x : clc : adc rowCellLo,y : sta zSPtr
        lda xOfsHi,x :       adc rowCellHi,y : sta zSPtr+1
```

`xOfs[x] = (x>>2)*32 + (x&3)` (160 entries, `chunky2mc.asm:53`) and
`rowCell[r] = MATRIX + r*1280` (22 entries, `math.asm:26`). One 16-bit add
replaces two multiplies and three shifts.

The fill itself is structured **head / whole cells / tail**:

| Part | Per-pixel cost | Notes |
|---|---|---|
| head (0-7 px to the cell boundary) | ~19 cy | `sta (zp),y` + 4× `iny` + loop |
| whole 8-pixel cells | ~11.3 cy | 8 unrolled `ldy #n : sta (zp),y` + the inlined cell step |
| tail (0-7 px) | ~19 cy | as head |

The whole-cell path unrolls all eight stores with immediate `ldy` values
(`0, 4, 8, ... 28`), eliminating the increment and the loop test. Averaged over
a typical span, **~11 cycles per pixel**.

> This is the pipeline's largest single cost after the converter (§12), and the
> clearest optimization target. The obvious win is that spans are written with
> a *constant* byte, so a whole cell row could be filled with a 4-byte pattern
> rather than 8 individual stores.
>
> **Not by REU DMA, though** — that was the other candidate, and hardware has
> ruled it out. REU DMA runs at exactly 1 byte/µs and does *not* scale with the
> turbo clock (`IMPLEMENTATION_PLAN.md` §10). At 64 MHz a CPU store costs
> ~11 cycles = 0.17 µs per byte, so DMA fill would be **~6× slower**, and it
> halts the CPU for the duration. The open question in
> `3d-renderer-design.md` §REU usage is answered, and the answer is no.

---

## 10. Stage 8 — Chunky to multicolor conversion

**Source:** `src/render/chunky2mc.asm`; full design rationale in
`3d-renderer-design.md`
**Cost:** ~411 cycles/cell × 880 cells = **~362k cycles**

The renderer's output is a byte-per-pixel buffer in a format that no VIC-II
mode can display. This stage packs it into a real multicolor bitmap.

### 10.1 The matrix byte

```
bit:  7 6 5 4   3 2 1 0
      ramp id   intensity
      (0-15)    (0-15)
```

Sixteen 3-colour luminance ramps, each implicitly starting at **black** (the
global background, `$D021`). Intensity 0-15 selects a position along the ramp;
levels 0/5/10/15 are the four pure colours and everything between is an ordered
4×4 Bayer blend of the two neighbouring ramp colours — **16 perceived shades
per material out of 4 hardware colours**.

### 10.2 The fused inner loop

VIC multicolor bitmap gives each 4×8 cell four colours, selected per pixel-pair
by a 2-bit code: `%00` = `$D021` background, `%01` = screen hi nibble,
`%10` = screen lo nibble, `%11` = colour RAM.

The converter collapses **four separate operations** — dither threshold lookup,
intensity-to-code quantisation, bit-position shift, and byte assembly — into
one table read plus one `ora`:

```
        ldy MATRIX + s*4 + j, x                    ; 4 cy: fetch the pixel
        ora ditherTabs + [j*4 + (s&3)]*256, y      ; 4 cy: dither+shift+code
```

**8 cycles per pixel, total.** The table is chosen at *assembly* time by the
pixel's position `(j, s&3)` within the 4×4 Bayer tile, so the position never
enters the runtime computation at all:

```
.for (var px=0; px<4; px++)
  .for (var row=0; row<4; row++)
    .fill 256, dcode(i&15, px, row) << [6 - px*2]

.function dcode(v, px, row) {
    .var t = bayer.get(row).get(px)
    .return min(floor(v/5.0 + (t+0.5)/16.0), 3)
}
```

16 tables × 256 bytes = **4 KB of dither tables**, buying zero-cost dithering.
That is the single best RAM-for-cycles trade in the engine. Note the tables are
indexed by `i&15` — the ramp nibble is masked off, so *all sixteen ramps share
one dither table set*.

The 4×4 Bayer tile repeats every 4 pixels horizontally (once per cell width) and
every 4 rows vertically (twice per cell height).

### 10.3 Per-cell attributes: one sample, no quantisation

```
        ldy MATRIX + 13, x          ; cell offset 13 = row 3, pixel 1
        lda scrTab,y : sta SCREEN   ; ramp[c0]<<4 | ramp[c1]
        lda colTab,y : sta COLBUF   ; ramp[c2]
```

The cell's three non-background colours come from **a single sampled pixel** —
its ramp nibble indexes two 256-byte tables. There is no per-cell colour
histogram, no error metric, no branching. Constant time, ~20 cycles.

When a cell straddles two materials, the pixels of the losing ramp still map by
**intensity**, so they land at the right *luminance* with the wrong *hue*. That
is the error the eye forgives most readily — luminance acuity far exceeds
chroma acuity at high spatial frequency. This is the design decision that
eliminates attribute clash as a runtime problem: it is solved by the *format*,
not by the code.

### 10.4 Self-modifying code as the addressing mode

The loop must walk 110 pages of MATRIX and 8000 bytes of bitmap with
`(zp),y`-style flexibility but `abs,x` speed. It resolves this by patching its
own operands:

```
patchMatrixPage:                    ; 33 stores, once per 8 cells
        lda matPage
        .for (var k=0; k<fetchHiOps.size(); k++) sta fetchHiOps.get(k)
```

The 33 `ldy MATRIX+n,x` operand high-bytes are rewritten once per matrix page,
amortised over 8 cells (256 pixels). `abs,x` costs 4 cycles; `(zp),y` costs 5
and would need the pointer maintained. Over 28160 pixels that is **28k cycles
saved** for ~100 cycles of patching per page.

The same trick aims the screen, colour and bitmap stores at whichever buffer is
the back buffer (`initFrame`), so double-buffering costs nothing in the inner
loop.

### 10.5 Double buffering and the colour RAM problem

Two bitmap+screen pairs live in VIC banks 2 and 3, flipped via `$DD00`/`$D018`.
**Colour RAM at `$D800` cannot be banked** — there is exactly one copy. So the
converter writes to `COLBUF`, a staging buffer, and `flip` burst-copies 880
bytes into `$D800` immediately after the bank switch:

```
        lda #251                    ; wait for the bottom border
!:      cmp $d012
        bne !-
        ...switch $dd00 / $d018...
        ldx #0                      ; 3 fully unrolled 256-byte strides
!:      lda COLBUF,x     : sta $d800,x
        lda COLBUF+$100,x: sta $d900,x
        lda COLBUF+$200,x: sta $da00,x
        inx
        bne !-
```

Three strides are interleaved in one loop so the loop overhead (`inx`/`bne`,
5 cycles) is amortised across three copies instead of one — ~11k cycles for the
whole burst, comfortably inside the vertical blank.

> **Deviation from `3d-renderer-design.md`.** That document places `COLBUF` at
> `$C400`; the implementation puts it at `$0400` (`defs.asm:15`), because
> `$C400` is now occupied by the math tables. The memory map in §12.2 below is
> authoritative.

---

## 11. A fully worked frame

Everything above, executed once, with real numbers.

**Setup.** Player at spawn: `camX = 512, camY = 512, camA = 0` (facing east),
`camSec = 0` (room A). Sector A has `floor = 0, ceil = 256`, so
`camZ = 0 + EYE = 41`. Trig: `camSin = sin[0] = 0`, `camCos = sin[64] = 16383`.

### 11.1 The player presses W

```
dx = (14 * 16383) >> 14 = 229362 >> 14 = 13         # not 14 -- see §2
dy = (14 *     0) >> 14 = 0
camX = 525, camY = 512
```

`checkSector` tests sector A's six walls. Wall 3, the portal `(1024,640) →
(1024,384)`:

```
tx = x1-x0 = 0 ; ty = y1-y0 = -256
cross = 0*(512-640) - (-256)*(525-1024) = 0 - 127744 = -127744  < 0  -> inside
```

All six walls report inside, so the player stays in sector A and no undo occurs.

### 11.2 Rendering — traced at the spawn position

To compare against captured hardware state, the trace below is taken at
`camX = 512` exactly (the state `IMPLEMENTATION_PLAN.md` recorded from the live
machine).

`renderFrame` opens all 160 columns to `[0, 176)` and pushes `(sector 0, 0, 159)`.
`renderSector(0)` computes `dzC = 256-41 = 215`, `dzF = 0-41 = -41`,
`ceilByte = $02` (stone, intensity 2), `floorByte = $45` (moss, intensity 5).

Then the six walls, in map order:

| Wall | Endpoints | `ry0, ry1` | Outcome |
|---|---|---|---|
| 0 | (0,0)→(0,1024) | -511, -511 | both behind near plane → **reject** (~15 cy) |
| 1 | (0,1024)→(1024,1024) | -511, +511 | near-clipped, then `sx1 = 0` → **reject** |
| 2 | (1024,1024)→(1024,640) | 511, 511 | **drawn, solid**, columns 0-60 |
| 3 | (1024,640)→(1024,384) | 511, 511 | **drawn, portal → B**, columns 61-98 |
| 4 | (1024,384)→(1024,0) | 511, 511 | **drawn, solid**, columns 99-159 |
| 5 | (1024,0)→(0,0) | 511, -511 | near-clipped, `c0 = 160 > c1 = 159` → **reject** |

The three drawn walls cover columns `0-60`, `61-98`, `99-159` — **disjoint,
contiguous, and exactly exhausting `[0,159]`**, exactly as §8.5 predicts for a
convex sector.

### 11.3 Wall 2 in full — checked against the live machine

```
endpoint 0 = (1024,1024):  tx = 512, ty = 512
    ry = (512*16383)>>14 + (512*0)>>14 = 511 + 0        =  511
    rx = (512*0)>>14 - (512*16383)>>14 = 0 - 511        = -511

endpoint 1 = (1024,640):   tx = 512, ty = 128
    ry = 511                                            =  511
    rx = 0 - (128*16383)>>14 = -127                     = -127

near plane:  both ry = 511 >= 16                        -> no clip

sx0 = 80 + (-511 * 80)/511 = 80 - 80                    =    0
sx1 = 80 + (-127 * 80)/511 = 80 - 10160/511 = 80 - 19   =   61

backface:  sx0 = 0 < sx1 = 61                           -> front-facing
c0 = max(0, xL=0)     = 0
c1 = min(61-1, xR=159) = 60
dx = sx1 - sx0 = 61

rows (both endpoints share ry = 511, so the lines are horizontal):
top = 88 - (215*160)/511 = 88 - 34400/511 = 88 - 67     =   21
bot = 88 - (-41*160)/511 = 88 + 6560/511  = 88 + 12     =  100

shading: light = (511+511)>>7 = 7 ; intensity = 15-7 = 8
         ramp = $60 (metal) ; wallByte = $68
```

**These five values — `zTop = 21`, `zBot = 100`, `zDX = 61`, `zC0 = 0`,
`zC1 = 60` — are exactly the values captured from the live machine's zero page
under VICE** (`IMPLEMENTATION_PLAN.md`, "The geometry math is fine"). The
transform, near-plane test, both projections and the window clamp all reproduce
hardware state to the digit. The projection chain is verified.

Each of columns 0-60 is then filled with three spans:

```
rows [  0,  21)  ->  $02   dark stone ceiling
rows [ 21, 100)  ->  $68   metal wall, intensity 8
rows [100, 176)  ->  $45   moss floor
colTop[x] = 176 ; colBot[x] = 0        (column closed)
```

### 11.4 Wall 3 — the portal

```
endpoint 0 = (1024,640):  rx = -127, ry = 511  ->  sx0 = 61
endpoint 1 = (1024,384):  rx = +127, ry = 511  ->  sx1 = 99
c0 = 61 ; c1 = 98

front (sector A):  top = 21, bot = 100          (as wall 2)
back  (sector B):  floor 24, ceil 152
    back dzC = 152-41 = 111 -> row = 88 - 17760/511 = 88 - 34 =  54
    back dzF =  24-41 = -17 -> row = 88 +  2720/511 = 88 +  5 =  93
```

Columns 61-98 each receive **four** spans, and the window narrows instead of
closing:

```
rows [  0,  21)  ->  $02   ceiling
rows [ 21,  54)  ->  $68   upper wall  (B's ceiling is lower than A's)
rows [ 54,  93)  ->  left open -- this is the corridor opening
rows [ 93, 100)  ->  $68   lower wall  (B's floor is higher than A's)
rows [100, 176)  ->  $45   floor
colTop[x] = 54 ; colBot[x] = 93
```

and sector B is pushed as `(1, 61, 98)`.

### 11.5 Sector B, through the window

`renderSector(1)`: `dzC = 152-41 = 111`, `dzF = 24-41 = -17`, wood ramps.

Wall 6 is the portal back to A — the exact reverse of wall 3, so it projects
`sx0 = 99 > sx1 = 61` and is **rejected as back-facing** in ~6k cycles. (This is
why `visitedSec` is a belt-and-braces guard rather than the primary mechanism:
back-facing rejection already stops most re-entry.)

Wall 7, `(1024,640) → (1536,640)`, is the corridor's left wall seen almost
edge-on — and it is the first wall in this frame where the interpolators do real
work, because its endpoints are at **different depths**:

```
endpoint 0: tx = 512,  ty = 128  ->  ry =  511, rx = -127  ->  sx0 = 61
endpoint 1: tx = 1024, ty = 128  ->  ry = 1023, rx = -127  ->  sx1 = 71

top0 = 88 - 17760/511  = 54        top1 = 88 - 17760/1023 = 71
bot0 = 88 +  2720/511  = 93        bot1 = 88 +  2720/1023 = 90

stepTop = ((71-54) << 8)/10 =  435  =  1.699 rows/column   (8.8: $01B3)
stepBot = ((90-93) << 8)/10 =  -76  = -0.297 rows/column   (8.8: $FFB4)
```

Over ten columns the ceiling drops 17 rows and the floor rises 3 — the corridor
visibly converging toward its far end. The fractional steps are why the
accumulator carries 8 bits of fraction: at 1.699 rows/column, integer-only
stepping would produce a 7-row error across the wall.

Wall 8, `(1536,640) → (1536,384)`, is the portal to sector C at columns 71-88.
Sector C is both taller and deeper than the corridor, so its projected ceiling
(row 45) and floor (row 99) both clamp to the corridor's own opening `[71, 90)`
— the deeper room is correctly seen *through* the corridor's aperture, not
through its own. That clamp is `clampAcc` doing exactly the job §9.1 describes.

---

## 12. Frame budget accounting

### 12.1 Where the cycles go

**Reconciled 2026-08-12.** The table this section carried through M1 was a
static per-instruction count for the frame traced in §11 — three hand-built
sectors, six walls, full-screen coverage — a map that no longer loads
(`IMPLEMENTATION_PLAN.md` §9.4). Rather than re-derive a static count for
E1M1 (which needs the live-capture retrace §11 is still waiting on), what
follows is the **measured** breakdown that exists today, from
`IMPLEMENTATION_PLAN.md` §1, §8.1 and §10's landing notes — real hardware
numbers, not instruction-counted estimates, which is a strictly better source
where it is available.

| Stage | Cost | Source |
|---|---:|---|
| `checkMove` (per seg tested) | ~1.3k cy/seg; E1M1 averages 3.09 segs/subsector | §5 |
| BSP descent + sphere rejection | prunes 234→71.7 node descents, 235→39.3 subsectors visited | §7.2 |
| World-space backface (`segFacing`) | removes ~53.6 segs/frame before any projection | §7.2 |
| **`spanFill` — flat pixels** | ~2593 calls / 28.4k pixels / **~22 cy/pixel** ≈ **~27% of the pre-texture 37.6 ms frame** | `IMPLEMENTATION_PLAN.md` §10.4 |
| **`spanFill` — textured wall pixels (Stage A)** | ~18-20 cy/pixel, **~1.8×** the flat cost; walls are ~40% of a typical E1M1 view | §9.1a, `IMPLEMENTATION_PLAN.md` §10.4 |
| **`convert` — 880 cells** | ~362k cycles, fixed — independent of scene geometry | §10 (unchanged since M1) |
| `flip` + COLBUF → `$D800` burst | ~11k cycles | §10.5 (unchanged) |
| **Total compute, measured on hardware** | **37.6 ms (pre-texture) → 46.7 ms (post Stage A)** | `IMPLEMENTATION_PLAN.md` §1, §10 landing note |

**Frame rate is measured, not estimated**, and the deadline itself changed
during M2 (`IMPLEMENTATION_PLAN.md` §8.1): M1 closed on a **two-raster-frame**
budget (39.90 ms), M2 deliberately moved to **three** (59.85 ms) to make room
for textures, doors, sprites and a HUD without judder. Current state:

| Build | Compute (measured) | Deadline | Raster frames | fps |
|---|---:|---:|---|---:|
| M1 final (flat-shaded, BSP) | 37.6-38.6 ms | 39.90 ms (2×) | 100% at 2 | 25.05 |
| M2, cap moved to 3, pre-texture | 37.6-38.6 ms | 59.85 ms (3×) | 100% at 3 | 16.71 |
| M2, Stage A textures landed | **46.7 ms** | 59.85 ms (3×) | 100% at 3 | 16.63 |

**13.1 ms of budget remains** for doors (<0.5 ms, measured effectively free —
§11.1/§11.4), sprites (6-8 ms estimated, not yet built) and the HUD (0 ms
measured — §13.1). That leaves little slack, which is why Stage B's real
64×64 streamed textures did not land in M2 (`IMPLEMENTATION_PLAN.md` §10
landing note): Stage A measured at the top of its 6-9 ms estimate, and the
gate for Stage B was measuring *well inside* it.

**The two hot spots are still the two byte-per-pixel passes** — the
rasterizer writes into MATRIX and the converter reads it all back out — but
`spanFill` is no longer the single constant-cost pass it was in M1: it is
now two costs, flat and textured, and which one dominates a given frame
depends on how much of the view is wall versus flat. `convert`'s ~362k
cycles are unchanged and worth revisiting first for M3, per the dirty-mask
idea already on record in `design.md`.

### 12.2 Memory map (authoritative — from `src/defs.asm`)

```
$0002-$00A5  zero page: math / renderer / converter / camera / span /
             accumulators / the sliding collision test ($98-$a5)
$0100-$01FF  6510 stack
$0200-$029F  colTop[160]      renderer clip window, first open row (owns the page)
$02A0-$02AF  frame timer      ftInt/ftComp/ftCMin/ftCMax + the raster histogram
$0300-$039F  colBot[160]      renderer clip window, first closed row (owns the page)
$0400-$07E7  COLBUF           colour RAM staging (880 + 120 HUD bytes)
$0810-$0C2D  mainLoop + input + movement + the sliding collision test
$0C30-$0CB2  sphereVisible + sphereTest
$0D00-$0D31  udiv8            udiv's eight-iteration short path
$0D33-$0D3B  MUSREU           the nine REU registers the music IRQ saves/restores
$0D40-$0DE7  ftInit / frameStat / frameMark   the per-frame compute timer
$0E00-$0E1F  MAPINFO          resident block 0
$0E20-$0E5C  nodeSphere       the per-node sphere fetch
$0E60-$0E67  SSECHDR          subsector slot header + its bounding sphere
$0E70-$0EEE  collision helpers
$0F00-$0F3F  BSP descent stack (32 x 16-bit child words)
$0F40-$0F50  frameCnt, reuOK, mapOK, mapErr, mapSum
$0F51-$0FC3  segFacing        world-space seg backface test
$0FC4-$0FF7  music player RAM  musBuf DMA window, musPtr/musLoop/musEnd, status
$1000-$7DFF  MATRIX           28160 B = 110 pages, cell-major chunky buffer
             ... staging MAPHDR at $5000, and three boot-only code blocks:
                 $5100-$5299  mapLoad
                 $5300-$54C5  musInit
                 $5500-$564A  reuProbe/reuInit, turboOn, clearHudRows and
                              main's own boot sequence (bootMain)
$8000-$83FF  SCREEN0          (VIC bank 2)
$8400-$973F  converter tables dither 4 KB, scrTab/colTab 512 B, xOfs 320 B
$9740-$97BF  SEGBUF           one subsector's segs, DMA target
$97C0-$98E3  bsp node test    sideOf / nodeStep / bspFindSsec
$98E4-$98FE  instrumentation counters (INSTRUMENT = 1 builds only)
$9900-$9B4A  converter code
$9B4B-$9B5A  cntBump          the counter helper
$9B60-$9D7B  math + spanFill code
$9D80-$9F8D  walls helper routines
$9F8E-$9FD8  CIA2 ms clock + framePace
$A000-$BF3F  BITMAP0          (VIC bank 2)
$C000-$C3FF  SCREEN1          (VIC bank 3)
$C400-$CA2B  math tables      sqr 1024 B, sin 512 B, rowCell 44 B
$CA30-$CDFC  doWall
$CE08-$CFDA  bsp traversal    renderFrame, renderSsec, ssecHdr/ssecSegs
$D000-$DEFF  NODES + SECTORS  resident, under the I/O space ($01 = $34 to read)
$E000-$FF3F  BITMAP1          (VIC bank 3, under Kernal ROM -- write-only)
$FF40-$FFF9  MUSCODE          the music IRQ handler, copied up by musInit --
                              not part of the PRG image, see below
```

Some things worth knowing about this map:

- **Low RAM is fragmented, and every fragment is asserted.** The code blocks
  between `$0C30` and `$0FF7` are there because that is where the holes were,
  not because anything about them belongs together. Every one is bounded by an
  `.errorif` against whatever follows it, so growing one past its block fails
  the build with the block's name in the message — which is what makes the
  arrangement maintainable rather than merely tight.
- **Boot-only code is assembled into MATRIX**, and this is the lever the
  engine reaches for whenever low RAM runs out. `mapLoad` went first, at
  `$5100`: it runs once, before the first frame, and `spanFill` overwrites it
  during that frame — `MAPHDR` was already staged there on the same argument.
  That freed 411 contiguous bytes and is what let `sphereTest` grow from the
  box test to the exact one. M2 spent the lever twice more: `musInit` at
  `$5300`, and at `$5500` the REU probe, `turboOn`, `clearHudRows` and `main`'s
  own boot sequence — ~200 bytes, which is what the sliding collision test of
  §5.3 is assembled into. Nothing in any of those blocks may be called after
  boot.
- **`$FF40-$FFF9` holds the music IRQ handler**, which has to be reachable from
  the vector at `$FFFE`. The PRG image still ends at `$CFDA`: `music.asm`
  assembles the handler with `.pseudopc MUSCODE` inside a boot block and
  `musInit` copies it up. That indirection is deliberate — reaching past
  `$CFDA` in the image itself would write 4 KB of filler across `$D000-$DFFF`
  on load, which is fine under VICE's RAM injection and untested on the U64's
  DMA path.
- **The math tables end at `$CA2C` and the walls code begins at `$CA30`.**
  Four bytes of slack. Adding a single table entry to `sqr`, `sin` or `rowCell`
  will silently overrun into executable code unless `WALLSCODE` moves first.
  `main.asm` carries `.errorif` guards for the other segment boundaries; this
  one has none.
- **`$9740-$98FF` (448 B) was free and named `TABLES_FREE`.** 352 of it was the
  dead scanline-major `rowLo`/`rowHi` pair from `3d-renderer-design.md`, deleted
  now that `spanFill` is confirmed to use the cell-major `rowCell` pair instead;
  `main.asm` has an `.errorif` keeping the dither tables from growing back into
  it. It is now fully spent: `SEGBUF`, the node test, and the counters.
- **`$D000-$DEFF` is where E1M1 lives.** 4 KB of RAM hides under the I/O space,
  and nothing else claims it, so E1M1's 236 BSP nodes and 85 sectors are
  resident there; everything else streams from the REU one subsector at a time.
  The engine runs with `$01 = $35` (I/O visible) and switches to `$34` only to
  read those two tables. Both states keep RAM at `$A000`/`$E000` where the
  bitmaps live, so a bank switch never changes what a bitmap write does — and
  it is only safe at all because interrupts are masked for the whole run.
  `docs/reu-format.md` is the authority on that layout.

### 12.3 Frame pacing — and what hardware actually does

`flip` waits for raster line 251 (`cmp $d012`), which happens once per PAL
frame, so the engine is hard-synced to 50 Hz. Effective frame rate is therefore
`50/n` where `n` is the number of raster frames the render takes: **50, 25,
16.7 or 12.5 fps, with nothing in between.** A frame that overruns its budget
by one cycle costs a full 20 ms.

**Measured on a C64 Ultimate** (firmware 1.1.0, core 1.49, PAL, 64 MHz,
badlines enabled), test map, `make u64-fps`:

| `$D031` | CPU speed | fps | ms/frame |
|---|---|---:|---:|
| `$00` | 1 MHz | 0.83 | 1203 |
| `$06` | 10 MHz | 7.15 | 140 |
| `$0B` | 24 MHz | 16.78 | 60 |
| `$0F` | 64 MHz | **50.1** | **20.0** |

At 64 MHz the engine is **vsync-locked**: 50.1 fps is PAL's own 50.125 Hz, so
`flip` is waiting, and frame compute is *under* 20 ms rather than at it. The
1 MHz row is the control that proves turbo is genuinely engaged — a 60× spread
across a 64× clock range, the gap being the VIC's cycle stealing.

The intermediate rows also bound the compute time from the other side. They are
quantised to the same 20 ms grid, so 24 MHz landing on 3 frames means the work
takes 40-60 ms there, i.e. **15-22 ms at 64 MHz**. That straddles the vsync
boundary, which is exactly what a naive measurement showed before the startup
transient was excluded: windows that catch a slow frame read 40-44 fps instead
of 50.

So the §12.1 estimate of ~994k cycles was low by roughly a third — 20 ms at
64 MHz is ~1.28M cycles — but right about where the time goes.

**E1M1 measured 17.6 fps (56.9 ms/frame) on the same machine, 22.2 fps
(45.1 ms/frame) after two culling passes, and 25.05 fps — the raster-locked
maximum, every frame on the deadline — after §15's three bit-identical wins.**
The VICE column below is what predicted it:

| Build | VICE ms/frame | E1M1 nodes | subsectors | segs |
|---|---:|---:|---:|---:|
| Phase 4 as measured on hardware | 3888 | 234 | 235 | 725 |
| \+ world-space seg backface test | 3191 | 234 | 235 | 725 |
| \+ node/subsector bounding spheres | **2589** | **72** | **39** | **122** |

Both passes are conservative rejections, so both were verified by comparing the
rendered frame against a build with the test disabled: 0 of 104448 pixels
differ, twice. That is the check that matters — a culling bug does not crash,
it deletes geometry from some angles and not others.

Scaling the VICE column by the ratio that held for the 56.9 ms reading predicts
**37.9 ms of compute**; hardware delivered 45.1. The difference is not error,
it is `flip`'s raster quantisation — frame time can only be a multiple of
19.95 ms, and 45.1 decomposes as `39.90 x 74% + 59.85 x 26%`. Three frames in
four make the 25 fps deadline; one in four misses it. Compute is sitting just
under the two-frame boundary, which is both the worst place to be (variations
flip a frame between 25 and 16.7 fps, which reads as judder) and the cheapest
(another ~10% locks it at a solid 25).

*(§16 revisits this paragraph. The decomposition assumes the only outcomes are
two and three raster frames; the frame timer built later shows a third one —
2.30 s startup frames the Ultimate's post-reset housekeeping causes — that a
20 s average cannot distinguish from many slightly-late frames. How much of
the 45.1 was really judder and how much was one slow frame is no longer
recoverable; that it was mostly judder is consistent with the fact that §15's
9.4% moved the reading to a clean 25.05.)*

**That ~10% has since been taken** — 9.4%, in three bit-identical changes
(`IMPLEMENTATION_PLAN.md` §15): `spanFill`'s cell step inlined, an eight-
iteration path through `udiv` for the quotients that fit in a byte, and the
exact `sqrt(2)·r` frustum test in place of the axis-aligned box, which had been
demanding 0.59 of a radius more clearance than geometry requires. VICE went
2551 → 2311 ms/frame, which through the conversion above predicts ~34.3 ms of
compute, about 5.6 ms clear of the 39.90 ms boundary.

**Hardware confirms it: 25.05 fps, 502 frames in 20.04 s, all 502 of them
exactly two raster frames** (§16). The predicted 34.3 ms of compute was
optimistic — the engine's own timer measures **37.6 ms steady, 38.6 ms worst**
against the 39.90 ms boundary — because REU DMA is 1 byte/µs on both machines
and so is a far larger share of the hardware frame than of the VICE frame,
which makes a whole-frame ratio over-credit every CPU-side saving. Optimistic
by 3 ms, and right about the conclusion: without §15's 9.4% compute is ~41 ms,
at the boundary rather than 2 ms under it, and a reading that mixes 39.90 and
59.85 ms frames is what that looks like.

**The engine times itself now** (`src/clock.asm`, §16): compute per frame, min
and max over a run, and a histogram of how many raster frames each one spanned,
at `$02a0` for `make u64-fps` to read. The average frame rate cannot separate
"1 ms over the deadline" from "10 ms over" — `flip` quantises both to 59.85 ms
— and those two want opposite work. The first hardware run after §15 read
22.73 fps and was believed for half a session; the histogram showed why in one
sample. Two frames, and only ever those two, cost **2.30 s each** while the
Ultimate finished its post-reset housekeeping, and one of them inside a 20 s
window turns 502 frames into 456. No frame the renderer produces varies by a
factor of four, so that bucket is never about the renderer — and `make u64-fps`
now says so instead of averaging it in.

Worth recording alongside it: a *cheaper* transform for the sphere test
measured **slower**. Culling accuracy turned out to be worth several times what
the transform costs — 128 units of radius slop cost 6.7% of the frame, against
the 4.4% the coarse transform saved — and that is what pointed at the frustum
test as the real target.

**Frame pacing now has a floor as well as a ceiling.** Without a cap the engine
runs at whatever `50/n` the frame happens to cost, and everything that moves is
per-frame, so a simple view at 50 fps moved the player twice as fast as a
complex one at 25. `framePace` (`src/clock.asm`) holds each frame to at least `FPS_CAP_TICKS = 39`
CIA ticks before handing over to `flip`'s raster sync, which pins the common
case at 25 fps. **A tick is 1.015 ms, not 1 ms** — PAL phi2 is 985248 Hz, so a
Timer A latch of 1000 underflows a little slower than a millisecond, which
`make u64-fps` confirms as a 0.982 ratio against the host clock. So 39 ticks is
39.58 ms, just under two PAL frames (39.90), and 40 would be 40.60 — past the
line-251 crossing, costing a third raster frame and giving 16.7 fps instead of
25. 39 is the maximum, not merely a good choice. The clock behind it is CIA2's Timer B, cascaded off a Timer A running at
1000 phi2 cycles, which is a millisecond counter that does not care what the
CPU clock is — established in §10 of `IMPLEMENTATION_PLAN.md`, where `reubench`
timed DMA with the same CIA and got identical tick counts at 1 MHz and 64 MHz,
and re-checked against the host's wall clock by `make u64-fps`. Quality scaling (`algorithm.md`'s `quality.degrade_step`) is the
other half of this and still does not exist.

---

## 13. Known defects and unenforced invariants

The renderer reaches a visible frame and `make check` is green. What follows is
the *pipeline* view of how it got there — which stage guarantees what, which
guarantees are now checked at the point of use, and which are still resting on
an argument rather than on an instruction. The forensics live in
[`debug-notes/`](debug-notes/00-index.md).

### 13.1 The failure that is fixed

The program used to hang with a CPU JAM at `$CDD7` — the second operand byte of
`sta colTop,x`, reached because execution landed mid-instruction. `spanFill` was
writing outside MATRIX: 317 corrupted bytes, all holding `$45` or `$02`
(sector A's floor and ceiling bytes), in 29-byte runs at stride 4, repeating
every `$500` — unmistakably `spanFill`'s unrolled cell loop plus its
cell step. The three fixes in §13.5 closed it, and a separate bug (an
init loop whose `BPL` never ran, so `colTop`/`colBot` started as garbage) was
what kept the screen black afterwards.

The lesson worth keeping: **every one of these presented as a dead or black
machine, not as a glitchy frame**, because the corruption fed back into the
geometry that produced it. That is what `make check` exists to catch on the
frame it happens.

### 13.2 The bounds contract, stage by stage

`spanFill` computes `zSPtr = xOfs[zSX] + rowCell[zSY0>>3]`. `xOfs` has 160
entries; `rowCell` has 22. This is the invariant list — and it stays the
checklist for the BSP renderer, which changes who *establishes* each row but not
what has to hold:

| Invariant | Established by | Enforced at use? |
|---|---|---|
| `zSX ∈ [0, 159]` | `zC0`/`zC1` clamped to `[xL, xR] ⊆ [0,159]` (§8.5) | ✓ `cpx #160 / bcs spanEnd` (`src/math.asm:267`) |
| `zSY0 ∈ [0, 175]` | `clampAcc` bounds every row into `[colTop, colBot]` | ✓ `zSY0>>3` checked against `#22` (`src/math.asm:274`) |
| `zSY1 ≤ 176` | same | ✓ clamped on entry (`src/math.asm:254`) |
| `colTop[x] ≤ colBot[x] ≤ 176` | initialised per frame, window only ever narrows (§9.1) | ✗ argument only |
| `zC0 ≤ zC1` | final `cmp zC0 / bcs` guard (§8.5) | ✓ |

The two index checks cost a handful of cycles on a path that already does a
16-bit add, and they convert the entire class of bug above from a memory stomp
into a dropped span. **Keep them.** The row that is still unenforced —
`colTop ≤ colBot` — is the one the BSP rewrite touches directly
(`IMPLEMENTATION_PLAN.md` §5, Phase 4.2 replaces the narrowing-window argument
with a per-column closed test), so it is worth re-deriving rather than
inheriting.

### 13.3 The `zC0` clamp: now explicit

`zC0` used to be clamped *up* to `zXL` but never *down* to `zXR`, so a wall with
`sx0 ∈ [160, 255]` stored an out-of-range `zC0`, caught only by the subsequent
`cmp zC0 / bcs !cols` — which did work (`zC1 ≤ 159 < zC0` always fails the
unsigned compare), but meant a single-instruction change anywhere in that guard
would turn a rejected wall into a 160-column overrun.

**§11.2 shows this firing on real data**: wall 5 at spawn produces
`c0 = 160, c1 = 159`. It is now clamped down to `zXR` explicitly
(`src/render/walls.asm:325`), so the final guard is a backstop rather than the
only line of defence.

### 13.4 Aliasing that turned a bad index into a dead machine

The clip windows used to share page `$0300` with the portal stack:

```
colBot     = $0300      ; indexed 0..159 -> $0300-$039F
pStkSec    = $03A0      ; 12 entries
pStkXL     = $03B0
pStkXR     = $03C0
visitedSec = $03D0
```

`sta colBot,x` with `x ≥ 160` wrote straight into the traversal stack, turning
an off-by-a-few column index into corrupted sector IDs and window bounds, which
then fed the geometry that produced the bad index. `colTop`/`colBot` now own a
private page each and the stack lives at `$0B20` (§12.2), which breaks the
feedback loop structurally instead of relying on the bounds checks alone.

**This is a layout rule, not a one-off fix**: anything the renderer indexes with
a column number gets a page to itself. The BSP node/side stack of Phase 4 is the
next thing to place, and it must not land inside `$0200-$03FF`.

### 13.5 What checks this, and what it cannot see

```sh
make check VICEWRAP='xvfb-run -a'
```

1. **Build** — the `.errorif` guards in `main.asm` catch a segment growing into
   its neighbour. Note the gap the guards *don't* cover: the math tables end at
   `$CA2C` and `WALLSCODE` begins at `$CA30`, four bytes apart (§12.2).
2. **`tools/checkshot.py build/shot.png`** — the 320×176 viewport must be under
   70% black and contain at least 3 distinct colours. Catches the black-screen
   class, and the flat-fill class in the other direction. The known-good
   test-map frame measures 64% coverage in 4 colours.
3. **`tools/vicedbg/probe.py diff`** — zero bytes differing from the loaded PRG
   outside the regions the engine is allowed to write. Catches a stray pointer
   on the frame it happens, not three frames later when the display has already
   gone black.

The two runtime checks are blind in complementary ways, which is why both are in
the gate: `probe.py` cannot see a correct-but-black frame (nothing was written
out of bounds), and `checkshot.py` cannot see a stray write that has not
corrupted anything visible *yet*. Neither can see wrong-but-plausible geometry —
that still needs an eye on `build/shot.png`.

---

## 14. Where this pipeline grows next

Mapping `algorithm.md`'s abstract stages onto what exists today:

| `algorithm.md` stage | Implemented as | State |
|---|---|---|
| `PollInput` | `readInput` | ✅ complete |
| `SimulatePlayer` | `movePlayer` + `checkMove`/`slideVec` | ⚠️ integer coords, no `dt`; sliding landed in M2 §9.2 |
| `ResolveCamera` | inline in `renderFrame` | ✅ complete |
| `PredictStreaming` | `ssecHdr`/`ssecSegs`, `nodeSphere` — per visit, not predictive | ⚠️ no prefetch |
| `BuildVisibleSectorSet` | BSP descent + bounding-sphere rejection | ⚠️ no PVS, no supersectors |
| `CollectCandidateWalls` | `renderSsec`'s seg loop | ✅ complete |
| `FilterWalls` | world-space backface, then near-plane + window clamp | ✅ complete |
| `sort.front_to_back` | **not needed** — convexity (§8.5) | ✅ by construction |
| `ProjectWallsToColumns` | `lineSetup` + the column loop | ✅ complete |
| `BuildSpriteCandidates` / `CullAndSortSprites` | — | ❌ not started |
| `BuildDrawCommands` | **fused** — spans are emitted directly | n/a |
| `RasterizeWallsAndSprites` | `spanFill` | ⚠️ flat-shaded, no textures |
| `draw_deferred_floors_and_ceilings` | drawn inline (causes ~20% overdraw) | ⚠️ |
| `CommitBackbuffer` | `convert` + `flip` | ✅ complete |
| `UpdateAudio` | — | ❌ not started |
| `EndFrame` / `quality.degrade_step` | — | ❌ no profiling, no quality scaling |

Two structural differences from the design are worth stating plainly, because
they are choices rather than omissions:

- **No draw-command queue.** `algorithm.md` builds `draw_cmds` and rasterises
  them in a later pass. The implementation writes spans directly from the
  column loop. That saves a queue, a packing pass and the RAM for both — but it
  is also what forecloses `scheduler.pack_by_material_page` and the deferred
  floor/ceiling pass. When textures arrive and material page locality starts to
  matter, this is the decision to revisit.
- **No quality scaling.** Every cap in the engine today is a hard cap
  (`BSPSTKMAX = 32`, 160 columns, 176 rows) rather than an adaptive budget.
  The clock the feedback loop in `algorithm.md` §4 needs now exists —
  `src/clock.asm` runs CIA2 as a millisecond counter and `framePace` already
  reads it (§12.3) — but nothing yet *reacts* to a frame that overran.

The next milestones, in dependency order:

1. ✅ Done: §13's defects are fixed, `make check` is green.
2. ✅ Done: **Milestone 1** (`IMPLEMENTATION_PLAN.md`): `tools/u64push.py` and an
   REU throughput measurement on real hardware → `src/reu.asm` →
   `tools/wad2reu.py` → the **BSP walk over real E1M1 geometry** (§7) that
   replaced both `testmap.asm` and the portal traversal.
3. ✅ Done (Stage A): **Textured walls** — a `u` coordinate reusing `lineSetup`
   (§8.7, §9.1a) and an intensity-modulating texture sampler in place of flat
   `spanFill` for the wall span. `IMPLEMENTATION_PLAN.md` §10 is the design —
   intensity-only texturing, so the ramp nibble and therefore the multicolor
   attribute constraint survive. **Stage B (real 64×64 streamed texels) did
   not land in M2** — Stage A measured at the top of its cycle budget, so the
   milestone stopped there (§9.1a, §12.1).
4. Deferred floor/ceiling spans — removes the overdraw measured in §12.1.
5. Sprites as column-clipped billboards, reusing `colTop`/`colBot` unchanged.
6. ✅ Done: Music, and the audio-versus-render budget split of `design.md`.
7. ✅ Done: Doors and moving sectors (`IMPLEMENTATION_PLAN.md` §11) — the
   renderer needed no change at all, confirming §7.3's claim that per-frame
   sector heights are the only thing a moving sector touches.

Steps 3-7 are the point at which the target architecture in `design.md` and
`algorithm.md` stops being aspirational and starts being load-bearing for the
parts that have landed; sprites (5) and deferred floor/ceiling spans (4) are
what remain aspirational.

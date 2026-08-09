# Doom C64U — The Movement-to-Pixels Pipeline

This document traces one complete frame, from the moment the player presses a
movement key to the moment the resulting pixels are visible in VIC-II memory.
It is the "how it actually works" companion to the four architecture documents:

| Document | Answers |
|---|---|
| `design.md` | *Why* the engine is shaped this way (target architecture) |
| `algorithm.md` | *What* the stages are, in abstract pseudo-code |
| `data_structures.md` | *What the data looks like* (target formats) |
| `3d-renderer-design.md` | *How the final raster stage works* (converter design) |
| **`pipeline.md`** (this file) | **The end-to-end compute path, as built, with numbers** |
| `IMPLEMENTATION_PLAN.md` | What is built, what is broken, what is next |

Everything below describes **Milestone 1 as it exists in `src/`** — a portal
renderer with flat-shaded walls, floors and ceilings. Where the implementation
deliberately differs from the target architecture in the design documents, the
difference is called out in a *Deviation* note. Sections marked **(planned)**
describe stages that do not exist yet.

> **Status caveat.** Milestone 1 is written but does not yet run to a visible
> frame — see [§13](#13-known-defects-and-unenforced-invariants) and
> `IMPLEMENTATION_PLAN.md`. The math in this document has been hand-traced and
> agrees with values captured from the live machine (§11), but the cycle counts
> in §12 are static instruction counts, not measurements.

---

## Table of contents

1. [The pipeline at a glance](#1-the-pipeline-at-a-glance)
2. [Number formats: the contract between stages](#2-number-formats-the-contract-between-stages)
3. [Stage 1 — Key press to intent bits](#3-stage-1--key-press-to-intent-bits)
4. [Stage 2 — Intent to world motion](#4-stage-2--intent-to-world-motion)
5. [Stage 3 — Sector resolution and collision](#5-stage-3--sector-resolution-and-collision)
6. [Stage 4 — Frame setup and camera basis](#6-stage-4--frame-setup-and-camera-basis)
7. [Stage 5 — Portal traversal: scene resolution](#7-stage-5--portal-traversal-scene-resolution)
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
   [3] checkSector          input.asm      convex containment test, per wall:
               |            ~1.3k cy/wall  cross = (x1-x0)(py-y0) - (y1-y0)(px-x0)
               |                           -> stay | follow portal | undo move
               v
  ============ camera state is final for this frame ============
               |
   [4] renderFrame          walls.asm      reset colTop[160]/colBot[160],
               |            ~2.5k cy       fetch camSin/camCos, seed portal stack
               v
   [5] portal traversal     walls.asm      stack of (sector, xL, xR) windows
               |  <---------------+        visitedSec[] = once per sector per frame
               v                  |
   [6] doWall (per wall)          |        world -> camera -> screen
        transformPoint            |          ry = (tx*cos + ty*sin) >> 14
        near-plane clip           |          rx = (tx*sin - ty*cos) >> 14
        projSX / projRow          |          sx  = 80 + rx*80/ry
        backface + window clamp   |          row = 88 - dz*160/ry
        lineSetup x2 or x4        |        4 screen-space lines, 24-bit accumulators
               |                  |        14k cy (solid) / 22k cy (portal)
               v                  |
   [7] per-column loop            |        for x in [c0..c1]:
        clampAcc x2 or x4         |          clamp lines into open window
        spanFill x3 or x4         |          ceiling / wall / floor runs
        window update ------------+          portal: narrow window, push sector
               |                             solid:  close column
               |                           ~11 cy per pixel written
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
A 16-wall map becomes ~3 visible walls, which become ~160 column jobs, which
become ~28k byte writes, which become one linear 880-cell packing pass. No
stage is allowed to hand the next stage an unbounded problem.

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
A (bit 2) and S (bit 5). D needs row 2 (`5 R D 6 C F T X`, bit 2), so exactly
**two** matrix strobes cover WASD. `tay` caches the row byte so the three tests
on row 1 cost one read, not three.

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
`ora`** — no translation table, no branch:

| Bit | Meaning | Key | Joystick |
|---|---|---|---|
| 0 | forward | W | up |
| 1 | backward | S | down |
| 2 | turn left | A | left |
| 3 | turn right | D | right |

**Optimization approach.** Input is a fixed-cost stage with no data dependency
on the world, so it is placed first and never revisited. There is no key
repeat, no edge detection and no debounce: the renderer runs at a fixed rate,
so "held" is the only state that matters and the matrix read *is* the debounce.

> **Suspected defect.** `A` decrements `camA` and `D` increments it
> (`input.asm:60-73`). But the camera basis is `forward = (cos θ, sin θ)` with
> θ increasing counter-clockwise, and `rx` is the *rightward* axis, so
> **increasing `camA` turns left**. The two keys therefore appear to be
> swapped. This has not been confirmed on hardware because the build does not
> yet reach a visible frame; verify before "fixing", since flipping the sign of
> `rx` in `transformPoint` would also resolve it in the opposite direction.

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

Then displacement, per axis:

```
dx = (MOVE_SPEED * cos) >> 14
dy = (MOVE_SPEED * sin) >> 14
```

computed by `smulTrig` (`src/math.asm:97`), and added or subtracted from
`camX`/`camY` depending on whether bit 1 (backward) is set. Backward motion
reuses the same product with `sbc` instead of `adc` — no second multiply, no
negation.

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
| Reuse the product for backward motion | one full `smulTrig` (~420 cy) |
| Early-out when no movement bits set | ~900 cy on idle frames |

---

## 5. Stage 3 — Sector resolution and collision

**Source:** `src/input.asm:155` (`checkSector`)
**Output:** `camSec` (possibly a new sector), or `camX`/`camY` reverted
**Cost:** ~1.3k cycles per wall tested; 6 walls in sector A = ~8k worst case

This is where "scene resolution" begins: the engine must know **which sector
the camera is in** before it can render, because the sector supplies the floor
and ceiling planes, the shading bytes and the starting node for portal
traversal.

### 5.1 The convexity assumption

Every sector is **convex**, with walls wound clockwise in standard math axes
(x east, y north) so the interior lies to the **right** of each directed wall.
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
        lda wBack,x
        cmp #$ff
        beq !blocked+       ; solid wall -> undo the whole move
        sta camSec          ; portal    -> enter the neighbouring sector
        ; and drop the eye to the new floor: camZ = secFloor[new] + EYE
!blocked:
        ; restore camX/camY from oldX/oldY
```

**Collision is undo-based, not slide-based.** Hitting a wall cancels the entire
frame's motion, including the component parallel to the wall. This is the
cheapest correct blocking model — no projection onto the wall normal, no
re-test after sliding — and it is why `oldX`/`oldY` are saved before any
displacement is applied. `algorithm.md` specifies `collision.slide_move`;
sliding is a Milestone-2 item and needs the parallel component
`v - n(v·n)/(n·n)`, which costs a dot product and a divide per blocked wall.

**Optimization approach.** Convexity is doing enormous work here. It converts
point-in-sector from an O(n) ray cast with parity bookkeeping into an O(n)
loop that **early-exits on the first failure** and needs no state at all. The
same assumption pays off again in §8 (no wall sorting) and §9 (a single
top/bottom line pair per wall). It is the load-bearing constraint of the whole
renderer, and it is enforced by the map format, not checked at runtime.

> **Limitation.** After following a portal, `checkSector` returns immediately
> without re-testing containment in the *new* sector. A single frame's motion
> that crosses two boundaries (through a corner, or a corridor narrower than
> `MOVE_SPEED`) will leave the camera outside its recorded sector. At
> `MOVE_SPEED = 14` and a minimum corridor width of 256 units this cannot
> happen in the test map, but it is not a general guarantee. The fix is to loop
> `checkSector` until it reports no crossing, with an iteration cap.

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

## 7. Stage 5 — Portal traversal: scene resolution

**Source:** `src/render/walls.asm:76` (`popLoop`), `:91` (`renderSector`)

The visible set is discovered by walking portals, depth-first, carrying a
**screen-space column window** with each step:

```
while stackN > 0:
    (sector, xL, xR) = pop()
    renderSector(sector)          # draws every wall, clipped to [xL, xR]
                                  # portals encountered push (back, c0, c1)
```

Each stack entry is `(sector id, left column, right column)` in three parallel
arrays (`pStkSec`, `pStkXL`, `pStkXR`) — structure-of-arrays even for a
12-entry stack, so each field is a flat `lda table,x`.

### 7.1 Why the window narrows monotonically

When a portal wall is drawn across columns `[c0, c1]`, the back sector is
pushed with exactly that range. Since `[c0, c1] ⊆ [xL, xR]` by construction
(§8.5), each level of traversal sees a **strictly narrower or equal** window.
Combined with `visitedSec[]`, this bounds traversal in two independent ways:

- **Breadth** — a sector is entered at most once per frame.
- **Depth** — `PSTKMAX = 12`; deeper portals are silently dropped.

Both are hard caps with deterministic overflow, satisfying rules R1/R2 of
`algorithm.md`. Dropping a too-deep portal costs a small hole in the far
distance, never a frame-time spike.

### 7.2 Where occlusion actually happens

Note what the traversal does **not** do: it does not sort, and it does not test
whether the back sector is visible. Occlusion is entirely delegated to
`colTop`/`colBot`. A sector reached through a portal that has since been
overdrawn will still be traversed, but every one of its columns will find
`colTop[x] >= colBot[x]` and exit immediately at ~20 cycles per column.

**This is the central trade in the design**: the engine accepts some wasted
traversal in exchange for never having to sort or test visibility at the
sector level. It is the right trade at this scale (3 sectors, 16 walls) and it
is the thing to revisit first when real WAD geometry arrives — at which point
`design.md`'s PVS-in-REU and supersector proposals become the answer.

### 7.3 Per-sector setup

`renderSector` hoists everything constant across the sector's walls:

```
zDzC = secCeil[s]  - camZ         ; height of ceiling above the eye
zDzF = secFloor[s] - camZ         ; depth of floor below the eye (negative)
zCeilByte  = secCByte[s]          ; flat shading byte for the ceiling
zFloorByte = secFByte[s]          ; flat shading byte for the floor
```

Computing `dz` **relative to the eye, once per sector** is what allows the row
projection in §8.4 to be a single divide with no subtraction in the inner
loop.

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

### 8.7 The four screen-space lines

The projection produces, per wall, the endpoint rows of up to four lines:

| Line | Index | Meaning | Present when |
|---|---|---|---|
| `top` | 0 | ceiling / wall top edge | always |
| `bot` | 1 | floor / wall bottom edge | always |
| `btop` | 2 | back sector's ceiling | portal only |
| `bbot` | 3 | back sector's floor | portal only |

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

**Source:** `src/render/walls.asm:475` (`!colloop`)
**Cost:** ~270 cy/column (solid) or ~400 cy/column (portal), plus ~11 cy per
pixel written

This is the "lifting" step: four 2D lines and two clip arrays become vertical
runs of bytes in the chunky buffer.

### 9.1 The per-column sequence

```
for x = c0 .. c1:
    wt = colTop[x] ; wb = colBot[x]
    if wb <= wt: goto advance                     # column already closed

    tw = clamp(accTop, wt, wb)                    # wall top,    clipped
    bw = clamp(accBot, tw, wb)                    # wall bottom, clipped

    spanFill(x, colTop[x], tw,  ceilByte)         # ceiling
    spanFill(x, bw,        wb,  floorByte)        # floor

    if solid:
        spanFill(x, tw, bw, wallByte)             # full wall
        colTop[x] = 176 ; colBot[x] = 0           # column permanently closed
    else:                                          # portal
        bt = clamp(accBT, tw, bw)                 # opening top
        bb = clamp(accBB, bt, bw)                 # opening bottom
        spanFill(x, tw, bt, wallByte)             # upper wall (step down)
        spanFill(x, bb, bw, wallByte)             # lower wall (step up)
        colTop[x] = bt ; colBot[x] = bb           # window narrowed to opening

advance:
    accTop += stepTop ; accBot += stepBot
    if portal: accBT += stepBT ; accBB += stepBB
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
in ~20 cycles. A portal narrows the window to the opening. There is no depth
comparison anywhere.

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
  of 1280 is zero, `spanNextCell` only touches the pointer's **high byte**:
  `lda zSPtr+1 : clc : adc #5 : sta zSPtr+1`. A 16-bit pointer advance for the
  price of an 8-bit one.

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
| whole 8-pixel cells | ~13.7 cy | 8 unrolled `ldy #n : sta (zp),y` + `spanNextCell` |
| tail (0-7 px) | ~19 cy | as head |

The whole-cell path unrolls all eight stores with immediate `ldy` values
(`0, 4, 8, ... 28`), eliminating the increment and the loop test. Averaged over
a typical span, **~11 cycles per pixel**.

> This is the pipeline's largest single cost after the converter (§12), and the
> clearest optimization target. The obvious win is that spans are written with
> a *constant* byte, so a whole cell row could be filled with a 4-byte pattern
> rather than 8 individual stores — or, on the U64, by REU DMA fill, if DMA
> throughput scales with the turbo clock (an open question flagged in
> `3d-renderer-design.md`).

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

Static instruction counts for the frame traced in §11 (three sectors, six walls
drawn or tested, full-screen coverage). These are **estimates from counted
instruction timings, not measurements** — treat them as ±30%.

| Stage | Cycles | Share |
|---|---:|---:|
| `readInput` | 120 | <0.1% |
| `movePlayer` (2 × `smulTrig`) | 900 | 0.1% |
| `checkSector` (6 walls × ~1.3k) | 7,800 | 0.8% |
| `renderFrame` setup | 2,500 | 0.3% |
| Wall geometry — rejected walls (3 × ~6k) | 18,000 | 1.8% |
| Wall geometry — drawn walls (~6 × ~18k) | 108,000 | 10.9% |
| **`spanFill` — ~35k pixels × ~11 cy** | **385,000** | **38.7%** |
| Column-loop overhead (~300 columns × ~330) | 99,000 | 10.0% |
| **`convert` — 880 cells × ~411 cy** | **362,000** | **36.4%** |
| `flip` + COLBUF → `$D800` burst | 11,000 | 1.1% |
| **Total** | **~994,000** | **100%** |

At a 25 fps target the frame budget is 40 ms:

| CPU clock | Cycles/frame @ 25 fps | Frame cost | Headroom |
|---|---:|---:|---:|
| 1 MHz (stock C64) | 39,410 | **2,500%** | hopeless, as expected |
| 48 MHz (U64 official max) | 1,920,000 | **52%** | 19 ms spare |
| 64 MHz | 2,560,000 | **39%** | 24 ms spare |

**The two hot spots are the two byte-per-pixel passes**, together 75% of the
frame: the rasterizer writes 28160+ bytes into MATRIX, and the converter reads
all 28160 back out. Everything geometric — transform, clip, projection, the
divides — is 13% combined. This is the expected shape for a low-resolution
software renderer and it says clearly where optimization effort belongs:

1. **`spanFill` (39%)** — spans are constant-coloured, so the 8 individual
   stores per cell could become a 4-byte pattern write, or an REU DMA fill if
   U64 DMA throughput scales with the turbo clock (unverified — see
   `3d-renderer-design.md`).
2. **`convert` (36%)** — already near-optimal at 8 cycles/pixel. The real win
   is *not converting unchanged cells*: `design.md`'s per-tile dirty masks. A
   stationary player changes almost nothing between frames.
3. **`transformPoint` (part of the 11%)** — every vertex in the test map is
   shared by two walls, so per-vertex transform caching halves it.

Note that 35k span pixels exceed the screen's 28160: portal sectors overdraw
the parent's floor and ceiling inside the opening. Deferring floor/ceiling
spans until the column is finally closed — `algorithm.md`'s
`raster.draw_deferred_floors_and_ceilings` — would remove that ~20% overdraw.

### 12.2 Memory map (authoritative — from `src/defs.asm`)

```
$0002-$008F  zero page: math / renderer / converter / camera / span / accumulators
$0100-$01FF  6510 stack
$0200-$029F  colTop[160]      renderer clip window, first open row
$0300-$039F  colBot[160]      renderer clip window, first closed row
$03A0-$03DF  portal stack (pStkSec/XL/XR, 12 each) + visitedSec
$0400-$07E7  COLBUF           colour RAM staging (880 + 120 HUD bytes)
$0810-$0FFF  main + input + testmap code and data
$1000-$7DFF  MATRIX           28160 B = 110 pages, cell-major chunky buffer
$8000-$83FF  SCREEN0          (VIC bank 2)
$8400-$989F  converter tables dither 4 KB, scrTab/colTab 512 B, row/xOfs 672 B
$9900-$9B5F  converter code
$9B60-$9D5F  math + spanFill code
$9D60-$9FFF  walls helper routines
$A000-$BF3F  BITMAP0          (VIC bank 2)
$C000-$C3FF  SCREEN1          (VIC bank 3)
$C400-$CA2B  math tables      sqr 1024 B, sin 512 B, rowCell 44 B
$CA30-$CFFF  walls renderer code
$E000-$FF3F  BITMAP1          (VIC bank 3, under Kernal ROM -- write-only)
```

Two things worth knowing about this map:

- **The math tables end at `$CA2C` and the walls code begins at `$CA30`.**
  Four bytes of slack. Adding a single table entry to `sqr`, `sin` or `rowCell`
  will silently overrun into executable code unless `WALLSCODE` moves first.
  `main.asm` carries `.errorif` guards for the other segment boundaries; this
  one has none.
- **`rowLo`/`rowHi` (352 bytes at `$9600`) are dead.** They were the scanline-
  major addressing helpers from `3d-renderer-design.md`; `spanFill` uses the
  cell-major `rowCell` pair instead. They are the obvious place to reclaim
  space from.

### 12.3 Frame pacing

`flip` waits for raster line 251 (`cmp $d012`), which happens once per PAL
frame, so the engine is hard-synced to 50 Hz. Effective frame rate is therefore
`50/n` where `n` is the number of raster frames the render takes: **50, 25,
16.7 or 12.5 fps, with nothing in between.** A frame that overruns its budget
by one cycle costs a full 20 ms.

This makes the 52% figure above more comfortable than it looks — there is a
2× margin before the frame rate drops a step — but it also means quality
scaling (`algorithm.md`'s `quality.degrade_step`) must react *before* the
overrun, not after. That mechanism does not exist yet.

---

## 13. Known defects and unenforced invariants

Milestone 1 does not currently reach a visible frame. `IMPLEMENTATION_PLAN.md`
has the full diagnosis; what follows is the *pipeline* view — which stage's
contract is being violated, and what each stage assumes but does not check.

### 13.1 The failure

The program hangs with a CPU JAM at `$CDD7` — the second operand byte of
`sta colTop,x`, reached because execution landed mid-instruction. `spanFill` is
writing outside MATRIX: 317 corrupted bytes, all holding `$45` or `$02`
(sector A's floor and ceiling bytes), in 29-byte runs at stride 4, repeating
every `$500`. That signature is unmistakably `spanFill`'s unrolled cell loop
plus `spanNextCell`.

### 13.2 The bounds contract, stage by stage

`spanFill` computes `zSPtr = xOfs[zSX] + rowCell[zSY0>>3]` and **checks
neither index**. `xOfs` has 160 entries; `rowCell` has 22. The pipeline is
supposed to guarantee both are in range:

| Invariant | Established by | Enforced? |
|---|---|---|
| `zSX ∈ [0, 159]` | `zC0`/`zC1` clamped to `[xL, xR] ⊆ [0,159]` (§8.5) | ✗ not re-checked in `spanFill` |
| `zSY0 ∈ [0, 175]` | `clampAcc` bounds every row into `[colTop, colBot]` | ✗ not re-checked in `spanFill` |
| `colTop[x] ≤ colBot[x] ≤ 176` | window only ever narrows (§9.1) | ✗ |
| `zC0 ≤ zC1` | final `cmp zC0 / bcs` guard (§8.5) | ✓ but see below |

Once *any* of these is violated by one stray write, the corruption is
self-amplifying: stray writes land in the map wall table and in `checkSector`'s
own code, which produces worse geometry, which produces a worse index. That is
why it presents as a dead machine rather than a glitchy frame.

### 13.3 Fragile-but-currently-correct: the `zC0` clamp

`zC0` is clamped *up* to `zXL` but never *down* to `zXR`, so a wall with
`sx0 ∈ [160, 255]` stores an out-of-range `zC0`. It is caught only by the
subsequent `cmp zC0 / bcs !cols` — which does work, because `zC1 ≤ 159 < zC0`
always fails the unsigned compare.

**§11.2 shows this firing on real data**: wall 5 at spawn produces
`c0 = 160, c1 = 159` and is rejected solely by that final guard. The rejection
is correct, but it means a single-instruction change anywhere in that guard
turns a rejected wall into a 160-column overrun. It should be clamped
explicitly.

### 13.4 Aliasing that turns a bad index into a dead machine

```
colBot     = $0300      ; indexed 0..159 -> $0300-$039F
pStkSec    = $03A0      ; 12 entries
pStkXL     = $03B0
pStkXR     = $03C0
visitedSec = $03D0
```

`sta colBot,x` with `x ≥ 160` writes straight into the portal traversal stack —
converting an off-by-a-few column index into corrupted sector IDs and window
bounds, which then feed the geometry that produced the bad index in the first
place. Giving `colTop`/`colBot` private pages breaks that feedback loop.

### 13.5 The fixes, in dependency order

1. **Bound both lookups in `spanFill`** (`src/math.asm:253`): reject
   `zSX ≥ 160` and `zSY0 ≥ 176` before the table reads. A handful of cycles on
   a path that already does a 16-bit add, and a memory stomp becomes a dropped
   span.
2. **Clamp `zC0` down to `zXR`** in `doWall` (`src/render/walls.asm:309`).
3. **Move the portal stack and `visitedSec`** out of page `$0300` into the free
   space below MATRIX (`$0B20-$0FFF`, already covered by `main.asm`'s
   `.errorif * > MATRIX` guard).
4. Rebuild and re-run `make debug` — a healthy run reports **zero** unexpected
   differences between live RAM and the loaded PRG.

`make debug` (`tools/vicedbg/probe.py`) is the regression test for this entire
class of bug, and it is a better one than any screenshot: it catches a stray
pointer on the frame it happens, not three frames later when the display has
already gone black.

---

## 14. Where this pipeline grows next

Mapping `algorithm.md`'s abstract stages onto what exists today:

| `algorithm.md` stage | Implemented as | State |
|---|---|---|
| `PollInput` | `readInput` | ✅ complete |
| `SimulatePlayer` | `movePlayer` | ⚠️ integer coords, no sliding, no `dt` |
| `ResolveCamera` | inline in `renderFrame` | ✅ complete |
| `PredictStreaming` | — | ❌ no REU streaming |
| `BuildVisibleSectorSet` | portal stack in `popLoop` | ⚠️ no PVS, no supersectors |
| `CollectCandidateWalls` | `renderSector`'s wall loop | ✅ complete |
| `FilterWalls` | near-plane + backface + window clamp | ✅ complete |
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
  (`PSTKMAX = 12`, 160 columns, 176 rows) rather than an adaptive budget. The
  frame-time feedback loop in `algorithm.md` §4 needs a cycle counter the
  engine does not yet have.

The next milestones, in dependency order:

1. Fix §13 — get to a visible frame, with `make debug` clean.
2. `tools/wad2reu.py` → REU DMA streaming → real WAD geometry replacing
   `testmap.asm`.
3. Textured walls: adds a `u` coordinate through the near-plane clip (§8.2),
   per-column `u/v` steps from the depth-bucket LUTs of
   `data_structures.md` §3.6, and turns `spanFill` into a texture-sampling
   loop.
4. Deferred floor/ceiling spans — removes the overdraw measured in §12.1.
5. Sprites as column-clipped billboards, reusing `colTop`/`colBot` unchanged.
6. Music, and the audio-versus-render budget split of `design.md`.

Steps 3-6 are the point at which the target architecture in `design.md`,
`data_structures.md` and `algorithm.md` stops being aspirational and starts
being load-bearing. Until then, this document describes the whole machine.

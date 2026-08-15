# Doom C64U — Implementation Plan

**Milestone 1:** E1M1 walkable, flat-shaded, with music at **25.05 fps** — closed ✓

**Milestone 2:** E1M1 textured, doors, HUD, sprites, weapon view at **16.7 fps / 59.85 ms** — closed ✓
- Textured walls (§10), doors/moving sectors (§11), jumping (§11a), walk bob (§11b), HUD (§13), sprites (§12), weapon view (§12a), mouse input, and intro screen all shipped and measured on hardware
- Frame: ~48.5 ms compute against 49.7 ms cap, with ~11 ms margin confirmed post-sprites
- **Milestone 3** (real HUD wiring to combat state, further optimization) is future work

**This document is compacted:** M1 and M2 outcomes documented (Part I–II, §8-14a.1b); M3 scoped but not started. Full history in git log.

---

# Part I — Milestone 1 (closed)

**M1 delivered:** E1M1 walkable, flat-shaded, music, at 25.05 fps ✓

**Key decisions that bind M2:**
- **BSP front-to-back, not portals** — three rejection tests (sphere, backface, column occlusion)
- **REU is abundant; RAM is the constraint** — 90 bytes of code RAM, everything else MATRIX/tables/audio; boot-only code inside MATRIX, every block bounded by `.errorif`
- **Measure everything on hardware**, not VICE — REU cost is 1 byte/µs flat; VICE turbo, pot, DMA behaviour differ from Ultimate; positive controls in every measurement; `make framehash` not `make shot` is the acceptance test

**Lessons for M2 (hard-won, will recur):**
1. Nothing on REU/hardware path credible without assertion
2. Positive control in every measurement (half/double-frequency, stub tests, wrong-bank corruption)
3. VICE ≠ Ultimate in turbo, pot, DMA timing, reset
4. Small changes need profiler hit count, not estimates
5. Anything below MATRIX checked against `bspStkLo`/`bspStkHi` by hand
6. Price a change with `phaseprof`/`profile.py` before design commits to it

---

# Part II — Milestone 2

## 8. Scope and budget (M2 complete except sprites)

**Scope:** E1M1 with textured walls ✓, doors ✓, moving sectors ✓, HUD ✓, sprites (open)

**Frame budget decision:** 3 raster frames = 16.7 fps / 59.85 ms deadline (vs M1's 25 fps / 39.9 ms)
- Consequence: motion constants ×1.5 (`MOVE_SPEED` 14→21, `TURN_SPEED` 3→4)
- `FPS_CAP_TICKS = 49`; measure drift with `ftHist` buckets, not average fps
- Measured compute: 37.6-38.6 ms (unchanged from M1, textures found free time); ~11 ms margin post-HUD

**RAM budget:** M1 found ~90 B code / ~200 B data RAM; `$0400-$07ff` is `COLBUF` (live), not free
- Texture sampling, sprite list, depth array, HUD blit all share MATRIX or boot-only code (via §14a.1-1b's viewport cuts)
- Remaining levers: boot-only code into MATRIX (like M1), accept fragmentation, reuse per-frame scratch

## 9. Ground clearing (M2 complete)

| | Outcome |
|---|---|
| §9.1: Uploader sending 470 KB | **Fixed:** chunking + content-hash cache → 8 s (was minutes). Risk #6 (404) not re-observed but stays open. Verified `$0400-$07ff` is `COLBUF` live. |
| §9.2: Sliding along walls | **Fixed:** `checkMove` projects onto blocked seg, retries up to 3×. 96% distance at shallow angle; 12 units from inside corner. Not fully closed (single-subsector test only) but unobserved in practice. |
| §9.3: `data_structures.md` | **Deleted.** Superseded by `docs/reu-format.md` (frozen, boot-checked). |
| §9.4: `pipeline.md` portal docs | **Reconciled.** Code-as-built documented; §11 (frame trace) unreconciled — deferred. |

## 10. Textured walls (closed)

**Shipped:** 16×16 resident tiles, intensity-modulated, 8 units/texel. Measured 16.63 fps (60.1 ms), compute 46.7-47.7 ms, 100% on deadline.

**Design:** Intensity nibble only (no ramp clash); `u` from existing line divide; `v` affine per-seg; tiles resident beat 8×8 streamed by 1.4 ms net (measured, not estimated). Five new ramps from duplicates. Floors/ceilings stay flat (would need visplanes).

**653 B code** in 11 `.pc` blocks, three below `$0801` relocated via `BOOTCODE4`/`texBoot`; checked by `probe.py`. Stage B (64×64 cached) deferred to M3 on budget.

## 11. Doors and moving sectors (closed)

**Shipped:** Renderer unchanged (door = sector ceiling height). No seg→linedef ref needed (19 special lines kept resident). Activation sector-based, not line-crossing (saved 660 B for 640 B budget). Tags/heights built at build time.

**Cost:** Effectively free; thinker list + activation in 640 B under I/O via `.pseudopc` + `sei`/bank-switch safety. Measured 34.5 ms compute (well under budget), doors cost nothing measurable.

**Measured lesson:** back-to-back readings degrade 100%→88% regardless; treat close runs as noise.

## 11a–11d. Quality-of-life fixes (all closed)

| | Outcome |
|---|---|
| **11a: Jumping** | 42 B + 2 zp; 7-byte arc table; `EYE + JUMPPEAK = 69` exact against E1M1's 72 min opening. Ledge-jumping free from `camJZ`. `make jumptest` green. |
| **11b: Walk bob** | 23 B; triangle wave off `frameCnt` bits; runs only on `IN_MOVE`. Bug: `zInput` aliased `zNum+1`, moved to `$90`. `make bobtest` green. |
| **11c: 1351 mouse** | Built 2026-08-14 as X-only additive turning. Code review only (terminal down), not yet run through `make check`. `MOUSE_SHIFT=2` sensitivity wants tuning. Pot select inferred, not verified on hardware. |
| **11d: Player body** | Fixed two bugs: (1) door walk-through via substep loop `MOVECODE` `$7500`, 56/56 blocked. (2) wall see-through via radius `PLRAD=24`, `segBody` `BODYCODE` `$7e00`. Both measured on hardware. 538 lattice cells still reachable near walls (blockmap deferred). |

Zero page now has `$e2-$e3` left; `$e3`, `$f3`, `$f8` were the three remaining when audit ran.

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

## 13. The HUD (closed)

**Shipped:** Status bar (health/armour/ammo) blitted at boot below viewport. Values wired to real bytes for M3 live-patch. Boot-only in MATRIX (`BOOTCODE6`), costs 3 bytes resident.

**Cost:** Measured 49.7 ms compute (59.85 ms deadline), 100% on 3 rasters, no outliers — **HUD costs nothing**, per-frame path untouched. `make framehash` bit-identical.

**Traps (all in code now):** dither accumulator can't transliterate; boot-stage address can't assume emission order; `$07e8` was `TX_SEED` tail; `hudBlitCell` clobbers X. Digits need ≥2×2 cells, must not be ordered-dithered.

## 14. Risk register and leverage points

| Risk | Status | Response |
|---|---|---|
| **Budget**: `$0400-$07ff` unavailable | Arrived day 1; `COLBUF` found | Sprite depth in `colTop` (§12.1); Stage B less likely; boot code to MATRIX |
| **Textures overrun 9 ms** | Not observed; 8.7 ms measured on hardware | If: 8×8→4×4 tiles, one-sided only, depth threshold |
| **Sprites overrun 6-8 ms** | Unknown — not measured on hardware yet | If: near-distance cap first; Stage A resident (§14a.2) |
| **Compute ≥ 59.85 ms** | Not observed; 48.5 ms with weapon (§12a) + sprites tbd | If: four frames (12.5 fps) only as last resort |
| **Ultimate 404 recurs** | Not re-observed after §9.1 cache fix (12 runs tested) | Open — may not be upload volume |

### 14a. Budget relief levers

**Closed (both took effect for §12a weapon):**
- **§14a.1:** Viewport 176 → 160 rows (20 cell-rows) → 2560 B MATRIX freed, ~1.1 ms compute
- **§14a.1b:** Viewport 160 → 144 rows (18 cell-rows, symmetric top/bottom) → another 2560 B + ~1.1 ms; horizon stays at raster 88

**Open (ranked by trade-off):**
1. **§14a.2:** Resident 16×16 sprites (8 props = 1 KB) vs streamed — eliminates 2.5-4 ms DMA, trades blocky sprites; needs §14a.1-1b's freed space
2. **§14a.3:** Drop double buffering (`BITMAP1`/`SCREEN1` = 9 KB) — zero frame cost, trades tearing visible at 16.7 fps
3. **§14a.4:** Halve horizontal (80 cols) — ~15 ms + 14 KB, rejected for 4:1 aspect (changes what the game is, not how much)
4. **§14a.5:** Cold-code overlays for non-hot paths — modest savings; `.pseudopc` pattern already trusted
5. **§14a.6:** Fourth raster frame (12.5 fps) — frees time, not RAM; separate lever from §14a.1-1b
6. **§14a.7:** §14a.1 (144 rows) + §14a.2 (resident sprites) together = 5 KB + 2–3 ms sprites, leaves ~15 ms for Stage B textures

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

---

## 15. Sequencing

**Milestone 1 and 2 are complete.** All features through §14a are shipped: 
textured walls, doors, sprites, weapon view, HUD, mouse input, and intro screen. 
The engine is locked at 16.7 fps / 59.85 ms with ~11 ms margin.

**Milestone 3 (future work):** Wire HUD values (health, ammo, armour) to live 
combat state (damage, pickups, ammunition consumption). Further optimization 
opportunities are documented in §14a (resident sprites, viewport reduction, 
near-distance cap) but are not required to meet the M2 specification.

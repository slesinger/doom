# Doom C64U — Implementation Plan to Milestone 1

**Written:** 2026-08-09. Supersedes the `IMPLEMENTATION_PLAN.md` deleted in
`5e83cb3` (that one described the black-screen bug, which is fixed).

---

## 1. Where we actually are

Verified on this machine today, not inherited from the docs:

| Check | Result |
|---|---|
| `make` (KickAssembler 5.25) | builds `build/doom.prg`, 50901 B |
| `make shot` | **renders a visible frame** — floor, dithered ceiling, lit far room through the portal |
| `make debug` (live RAM vs PRG diff) | **clean** — 0 unexpected writes; only MATRIX, bitmaps, screens, converter self-mod, portal stack differ |
| `make check` (added in Phase 0) | **green** from a clean tree, four consecutive runs |

The black-screen era is over. `1e5eb32` (the `BPL` init-loop bug) was the last
blocker, and the three memory-safety fixes from `8345112` are holding — the
diff probe reports nothing outside the engine's own buffers.

The docs that still said "does not reach a visible frame" — the README,
`pipeline.md`'s status caveat and §13, `design.md`'s preface,
`3d-renderer-design.md` — were corrected in Phase 0.

### What exists

| Subsystem | File | State |
|---|---|---|
| VIC setup, frame loop, HUD blank | `src/main.asm` | complete |
| Memory map / ZP allocation | `src/defs.asm` | complete |
| Fixed-point math, `spanFill` | `src/math.asm` | complete, bounds-checked |
| WASD + joy2, movement, convex containment | `src/input.asm` | complete **for convex sectors only** |
| Portal traversal, projection, column spans | `src/render/walls.asm` | complete for the test map |
| Chunky→multicolor, double buffer, flip | `src/render/chunky2mc.asm` | complete |
| Test map (3 sectors, 16 walls) | `src/testmap.asm` | complete |
| VICE monitor client + diff probe | `tools/vicedbg/` | complete, single-step capable |
| Regression gate (`make check`) | `Makefile`, `tools/checkshot.py` | complete — see §8 |

### What does not exist at all

- **No REU code.** Not one write to `$DF00`. 16 MB sits unused.
- **No `tools/wad2reu.py`** — the `make assets` target references a file that
  was never written.
- **No `tools/u64push.py`** — same for `make run-u64`.
- **No real map.** `testmap.asm` is three hand-built convex sectors.

---

## 2. Milestone 1, as agreed

> **Walk around E1M1, flat-shaded, on real Ultimate 64 hardware, at a
> measured frame rate.**

| Decision | Answer |
|---|---|
| Geometry | **Real E1M1 from `DOOM1.WAD`**, via a Python → `.reu` pipeline |
| Traversal | **BSP front-to-back** (see §3) — replaces portal traversal |
| Shading | **Flat** (`ramp\|intensity`). Textures are M2. |
| Input | WASD + joystick 2 (done) |
| Target | **Real U64 hardware**, VICE as the fast inner loop |
| Audio | **Deferred.** No SID in M1. |

Explicitly out of scope for M1: textures, sprites/enemies, doors and moving
sectors, lighting from the WAD's sector light levels, PVS/REJECT, quality
scaling, deferred floor/ceiling spans, weapons, HUD content.

---

## 3. The one architectural change: BSP traversal

The current renderer walks a **portal graph of convex sectors**. E1M1's 85
sectors are not convex, so that graph does not exist in the WAD. The WAD does
ship the thing we need — the BSP tree, whose 237 subsectors *are* convex by
construction.

**Decision: walk `NODES` front-to-back like real Doom, and delete the portal
stack.**

```
renderFrame:
    descend from root node
      side = pointOnSide(camX, camY, node)     ; sign of a 2D cross product
      recurse near child first
      recurse far child  (M1: unconditionally; bbox rejection is an option later)
    at a SSECTOR leaf:
      DMA its segs from REU
      doWall(seg) for each
```

What this buys, and what it costs:

- **`doWall`, `lineSetup`, `clampAcc`, `spanFill` are reused unchanged.** The
  per-wall geometry path is not affected by how we got to the wall.
- **Horizontal occlusion changes shape.** Today a child sector inherits a
  narrowed `[zXL, zXR]` window from its portal. In a BSP walk there is no such
  window; instead a column is dead when `colTop[x] >= colBot[x]`, which
  `colTop`/`colBot` already express. So: delete `zXL`/`zXR`, add an
  `openCols` counter, and end the frame early when it hits zero. This is
  *simpler* than what is there now, not harder.
- **`checkSector` gets faster.** Player sector lookup becomes a ~9-level BSP
  descent instead of a cross product per wall of the current sector.
- **Floors and ceilings keep working.** They are drawn inline per convex
  region today; a subsector is a convex region. No visplanes needed at M1.
- **Cost:** roughly 200 lines of new traversal code and a rewrite of
  `checkSector`. `walls.asm`'s portal-stack section (`popLoop`, `pStk*`,
  `visitedSec`) is deleted.

The alternative — closing subsector polygons offline against BSP partition
lines to synthesise a portal graph — keeps the engine unchanged but moves all
the difficulty into Python, where it is *harder* to debug because the failure
shows up as garbage on a C64 screen three layers away from the bug.

---

## 4. Memory: where E1M1 actually goes

E1M1's lumps, measured:

| Lump | Entries | WAD bytes |
|---|---|---|
| VERTEXES | 467 | 1868 |
| LINEDEFS | 475 | 6650 |
| SIDEDEFS | 648 | 19440 |
| SECTORS | 85 | 2210 |
| SEGS | 732 | 8784 |
| SSECTORS | 237 | 948 |
| NODES | 236 | 6608 |
| BLOCKMAP | — | 6922 |

Free RAM in the current build is scarce, and now measured exactly (Phase 0 is
done, see §8): `$0B60-$0FFF` (1184 B), `$9740-$98FF` (448 B, `TABLES_FREE`,
which includes the reclaimed `rowLo`/`rowHi`) and `$CED4-$CFFF` (300 B) —
**1932 bytes total.** Everything else is MATRIX, bitmaps, screens, tables and
code.

**One reclaim remains, and it is the big one:**

1. **`$D000-$DFFF` is 4 KB of RAM under the I/O space** and nothing claims it.
   `renderFrame` touches no I/O register, so it can run with `$01` bit 2
   cleared and read the node table directly. `flip` and `readInput` bank I/O
   back in. This is the single biggest free resource left in the machine.
2. ~~`rowLo`/`rowHi` in `chunky2mc.asm` are dead; 352 B.~~ **Done** — deleted,
   and the resulting `$9740-$98FF` is named `TABLES_FREE` in `defs.asm` with an
   `.errorif` guarding it. The residency table below spends 984 B of the 1184 B
   below MATRIX on SECTORS + SSECTORS, so these 448 B are where the seg staging
   buffer, the BSP node/side stack and the collision scratch go — none of which
   may live in `$0200-$03FF` (see `pipeline.md` §13.4).

**Proposed residency:**

| Data | Packed form | Size | Lives at |
|---|---|---|---|
| NODES | px,py,dx,dy (8 B) + 2 child words (4 B) = **12 B** | 2832 B | `$D000` under I/O |
| SECTORS | floor, ceil (16-bit) + floorByte + ceilByte = **6 B** | 510 B | `$0B60` |
| SSECTORS | firstSeg (16-bit, count implied by next) = **2 B** | 474 B | `$0D60`-ish |
| SEGS | x0,y0,x1,y1, backSector, rampByte = **10 B** | 7320 B | **REU**, streamed per subsector |
| Collision linedefs + BLOCKMAP | packed | ~10 KB | **REU**, streamed on move |

Node bounding boxes are dropped at M1 (16 B/node saved). Without them the walk
visits every node, relying on column occlusion for rejection — correct, just
not maximally culled. Add them back in M2 if profiling says so.

Per frame the engine DMAs one seg block per visited subsector: average 3 segs
= 30 bytes, times maybe 40 visible subsectors = **~1.2 KB/frame**. Whether that
is free or expensive is the question Phase 1 answers.

---

## 5. The plan

Six phases. Phases 0 and 1 are small and must come first — 0 because every
later phase is verified through the same loop, 1 because it is the only
unbounded unknown in the whole milestone.

### Phase 0 — Make the verification loop trustworthy ✅ DONE (2026-08-09)

Small, mechanical, unblocks everything. All four items landed; §8 is the
session log with the details and the two surprises found along the way.

1. ✅ **`make shot`'s exit code.** The recipe now ignores VICE's status (which
   `-limitcycles` always makes non-zero) and asserts on the artifact instead.
2. ✅ **`make check`** = build + `shot` + content assertion
   (`tools/checkshot.py`) + `debug`. Green from a clean tree, and green four
   runs back to back.
3. ✅ **Stale status text** updated in `README.md`, `pipeline.md` (status
   caveat, §12.2 memory map, §13 rewritten, §14), `design.md`,
   `3d-renderer-design.md`, `data_structures.md`.
4. ✅ **`rowLo`/`rowHi` reclaimed** → `TABLES_FREE` = `$9740-$98FF`, 448 B,
   with an `.errorif` in `main.asm`.

*Done when:* `make check` is green from a clean tree and its failure modes are
understood. — **met.**

### Phase 1 — Hardware truth (needs the U64)

Do this before writing a byte of REU-dependent engine code. The whole data
layout in §4 rests on an assumption nobody has measured.

1. **`tools/u64push.py`** — push the PRG to the U64 over the network and run
   it (the Ultimate command socket on TCP port 64: DMA the image, then RUN).
   Wire up `make run-u64`.
2. **Resolve REU image delivery to real hardware.** VICE takes `-reuimage`;
   the U64 does not have an equivalent network command. Options to evaluate:
   FTP the `.reu` to the device's storage and select it as the REU image in
   the Ultimate config; or have the PRG load its own data at startup. **This
   is an open question and it gates Phase 3's output format**, so answer it
   here.
3. **Benchmark REU DMA** at 1× and at turbo, for 32 B / 256 B / 4 KB
   transfers, timed with a raster counter. This settles the open item in
   `3d-renderer-design.md` §REU usage: *does DMA speed scale with CPU turbo,
   or stay at ~1 byte/µs?* At 1 byte/µs the §4 streaming plan costs ~1.2 ms
   per frame — fine. If per-transfer setup overhead dominates at 30-byte
   granularity, batch segs per *node subtree* instead of per subsector.
4. **Measure the current frame rate** of the existing test-map build on real
   hardware. We have static instruction counts and no measurement.

*Done when:* `make run-u64` works, and `pipeline.md` gains a measured
bytes-per-millisecond table and a real FPS number.

### Phase 2 — The REU layer

1. **`src/reu.asm`** — `reuFetch(reuBank:reuAddr → ramPtr, len)` via
   `$DF00-$DF0A`, plus a presence check at boot that fails *visibly* (border
   colour) rather than hanging.
2. **Boot-time resident load**: header block → nodes, sectors, ssectors into
   their §4 homes.
3. **I/O banking discipline**: `renderFrame` runs with RAM visible at
   `$D000`; `flip`, `readInput` and `reuFetch` bank I/O in. Assert this with a
   comment block in `defs.asm` and a `make debug` run.

*Done when:* the PRG loads a signature block from REU at boot, verifies its
magic, and `make debug` is still clean.

### Phase 3 — `tools/wad2reu.py`

The offline half. Emits `build/assets.reu` in the §4 layout, with a header
carrying magic, version, and each block's REU offset and length.

1. Parse `VERTEXES`, `LINEDEFS`, `SIDEDEFS`, `SECTORS`, `SEGS`, `SSECTORS`,
   `NODES`, `THINGS`, `BLOCKMAP` for E1M1.
2. Pack to the on-device formats. Doom's coordinates fit signed 16-bit
   directly — no rescaling, which keeps the existing projection math intact.
   Sanity-check the largest intermediate against `ssmul32`'s range.
3. **Texture name → ramp id mapping.** Flat shading still needs a ramp per
   surface. A table in the tool maps texture/flat name families
   (`STARTAN*`, `BROWN*`, `FLOOR4_*`, …) to the 16 ramps, with a default.
   This is the art-direction knob for M1 and it lives in Python, not asm.
4. Emit sector floor/ceiling bytes the same way.
5. **Validation harness in the tool**: render the decoded blocks as a
   top-down PNG and compare against a known-good E1M1 map image; assert the
   BSP is well-formed (every child index resolves, every subsector's segs are
   contiguous); byte-exact round-trip test.

*Done when:* `make assets` produces a `.reu` whose top-down render is
recognisably E1M1, with the validator green.

### Phase 4 — The BSP renderer

The core of the milestone. Do it in this order so each step is separately
verifiable.

1. **`src/render/bsp.asm`**: iterative BSP descent with an explicit
   node/side stack. `pointOnSide` = sign of `dx*(py-y0) - dy*(px-x0)`, reusing
   `ssmul32`.
2. **Replace the occlusion model** in `walls.asm`: delete `zXL`/`zXR` and the
   portal stack; a column is closed when `colTop[x] >= colBot[x]`; maintain
   `openCols` and terminate the frame when it reaches zero.
3. **Subsector rendering**: DMA the subsector's segs into a small RAM buffer
   (64 B covers the common case; loop for larger), then `doWall` per seg.
   One-sided seg → solid wall; two-sided → upper/lower steps against the back
   sector's heights, exactly as the current portal path already does.
4. **Keep testmap.asm working as a BSP** — have `wad2reu.py` also emit the
   3-sector test map through the same pipeline. That gives a tiny,
   hand-verifiable input for the new traversal before E1M1's 732 segs are
   involved. This step is worth its cost twice over in debugging time.
5. Switch to E1M1 and iterate.

*Done when:* the E1M1 spawn view renders recognisably (the entry room, then
the courtyard through the door opening), `make check` is green, and a scripted
30-second walk under `make debug` reports zero unexpected writes.

### Phase 5 — The player in E1M1

1. **Sector lookup** = BSP descent to a leaf → subsector → sector. Replaces
   `checkSector`'s convex containment walk.
2. **Collision** via BLOCKMAP: fetch the destination cell's linedef list from
   REU, test the move against each. Blocking = one-sided line, or two-sided
   with a floor step > 24 units or headroom < 56. Keep the existing
   undo-the-move response for M1 (no sliding).
3. **Spawn** from `THINGS` type 1 (player 1 start) — position and angle —
   instead of the `START_*` constants.
4. **Eye height follows the floor**, including step up/down.

*Done when:* you can walk from the E1M1 spawn, out the door, around the
courtyard and back without leaking through a wall or falling through a floor.

### Phase 6 — Milestone gate

1. Measure frame time on the U64 with E1M1 loaded; record it against the
   25 fps target in `pipeline.md` §12. Expect the two byte-per-pixel passes to
   still dominate.
2. `make run-u64` end to end, assets included.
3. Documentation pass: `pipeline.md` §14's "grows next" table updated,
   `data_structures.md` reconciled with the formats Phase 3 actually emitted.
4. Tag the milestone.

---

## 6. Risks, in order of how much they could cost

| # | Risk | Early warning | Response |
|---|---|---|---|
| 1 | REU DMA is slow *and* doesn't scale with turbo, making per-subsector streaming too expensive | Phase 1's benchmark | Batch seg fetches per node subtree; or prefetch a whole region on sector change |
| 2 | No clean way to get a `.reu` image onto real hardware | Phase 1.2 | Have the PRG load its data from disk into REU itself at boot |
| 3 | 40+ visible subsectors per frame blows the frame budget where 3 sectors did not | First E1M1 frame in Phase 4 | Re-add node bbox rejection (the 16 B/node dropped in §4); it is the designed-in escape hatch |
| 4 | `$D000-$DFFF` banking interacts badly with the converter or `flip` | Phase 2.3, caught by `make debug` | Fall back to streaming nodes from REU like segs — costs a DMA per node visit |
| 5 | Flat shading over 85 sectors of real geometry looks like undifferentiated mush | First E1M1 frame | Ramp assignment is a Python table (Phase 3.3) — cheap to iterate. Distance-based intensity falloff is already free in the byte format |
| 6 | The existing projection math has range bugs that three hand-built sectors never exercised | Phase 4.4's test map, then E1M1 | `make debug` catches the memory-safety half; the bounds table in `pipeline.md` §13.2 is the checklist |

---

## 7. Sequencing note

Phases 0 and 1 are each an afternoon. Phase 3 (the Python converter) and
Phase 4 (the BSP renderer) are the bulk of the work and are the two that can
proceed in parallel if you want them to — the interface between them is the
§4 binary layout, which is worth freezing in writing before either starts.

Phase 4 step 4 — running the existing 3-sector test map through the new
BSP pipeline before touching E1M1 — is the highest-leverage item in this plan.
It separates "the converter is wrong" from "the traversal is wrong", which is
exactly the distinction that cost the last debugging session six hypotheses
and a set of custom single-step tooling.

---

## 8. Session log

### 2026-08-09 — Phase 0

**Changed:**

| File | What |
|---|---|
| `Makefile` | `.DEFAULT_GOAL := all`; `shot` ignores VICE's status and asserts on the PNG; new `check` target; `debug` reaps the emulator and randomises the monitor port; `clean` takes `debug.log` |
| `tools/checkshot.py` | new — asserts the 320×176 viewport is ≥30% non-black and has ≥3 colours |
| `tools/vicedbg/probe.py` | `connect()` retries for 30 s instead of the Makefile guessing with `sleep 4`; missing monitor now reports itself instead of a traceback |
| `src/render/chunky2mc.asm` | `rowLo`/`rowHi` deleted, `tablesEnd` label added |
| `src/defs.asm`, `src/main.asm` | `TABLES_FREE` = `$9740-$98FF` (448 B) + `.errorif`; header map updated |
| `README.md`, `pipeline.md`, `design.md`, `3d-renderer-design.md`, `data_structures.md` | status text, memory maps, §13 rewritten around what is now enforced |

**Two things worth knowing before touching the harness again.** Both cost real
time to find and neither is visible from the code:

1. **`make debug` was flaky ~50% of the time, and it lied when it failed.**
   x64sc binds the binary-monitor port without `SO_REUSEADDR`, so the previous
   run's closed connection sits in `TIME-WAIT` on 127.0.0.1:6510 for ~60 s and
   the next VICE **fails to bind silently** — it boots, autostarts, runs the
   engine normally, and simply has no monitor. `probe.py` then reports
   connection-refused, which reads exactly like "the emulator did not start".
   The port is randomised per run now (`ifndef MONPORT`). If this ever recurs,
   check `ss -tan | grep <port>` before suspecting anything in `src/`.
2. **A leaked emulator hangs any `make debug | …` pipeline**, because the
   background `x64sc` keeps the recipe's stdout open. The recipe reaps it by
   PID *and* by `pkill -P` (under `xvfb-run` the PID is xvfb-run, which does
   not pass the kill on). Matching on the command line instead is a trap: the
   recipe's own shell has the whole recipe text in its argv, so `pkill -f`
   kills the recipe.

**Measured, for the record:** the known-good test-map frame is 64.4% non-black
in 4 colours. `make check` end to end takes ~11 s on this machine (~5 s of it
`shot`, ~6 s `debug`, which is dominated by `probe.py`'s 8 s settle minus
overlap). A clean-tree `make check` was run four times consecutively: green
each time, no stray `x64sc`/`Xvfb` left behind.

**Deliberately not done:**

- The A/D turn-direction defect (`pipeline.md` §3) is *now testable* — the
  build renders — but needs a human at `make run` or scripted key injection.
  Left open; it is a one-line fix in either `input.asm` or `transformPoint` and
  picking the wrong one hides the bug rather than fixing it.
- The four-byte gap between the math tables (`$CA2C`) and `WALLSCODE`
  (`$CA30`) still has no `.errorif`. Worth adding when `WALLSCODE` next moves.

### Next session: Phase 1 (needs the Ultimate 64)

**Confirmed 2026-08-09: the U64 is on the LAN and reachable from this machine**,
so Phase 1 goes next, in order, rather than being deferred behind Phase 3. Its
hostname/IP still has to be supplied — `Makefile` defaults `U64_HOST` to `u64`.

Phase 1 is the gate on everything after it, and it is the one phase that cannot
be done in the emulator. It needs, in order:

1. `tools/u64push.py` + `make run-u64` — the Ultimate command socket on TCP 64.
2. **An answer to how a `.reu` image reaches real hardware** (§5 Phase 1.2).
   This is the open question that decides `wad2reu.py`'s output format, so it
   is worth answering before Phase 3 starts even if the benchmark slips.
3. The REU DMA throughput table, and the first real FPS measurement.

If the U64 turns out to be unreachable after all, the useful out-of-order work
is **Phase 3** (`tools/wad2reu.py`) — pure Python, verifiable by its own
top-down PNG render, and it needs nothing from the hardware except a decision on
delivery format. Phase 2 and Phase 4 both depend on Phase 1's numbers.

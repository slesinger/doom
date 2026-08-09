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
| Ultimate REST/FTP client | `tools/u64.py` | complete |
| Turbo config, push+run, hardware screenshot | `tools/u64config.py`, `u64push.py`, `u64shot.py` | complete — see §9 |

### What does not exist at all

*(This list is from the start of the session. Everything in it has since
landed — see §11. What is left is Phase 4's BSP renderer and Phase 5's player.)*

- ~~**No REU code.**~~ `src/reu.asm`, `src/mapload.asm`, `src/reuload.asm`.
- ~~**No `tools/wad2reu.py`.**~~ Written; `make assets` produces E1M1 and the
  test map through the same packers.
- **The renderer still draws `testmap.asm`.** E1M1's geometry is in the REU and
  its nodes and sectors are resident in RAM, but nothing reads them yet. That
  is Phase 4.

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

**Residency, as built** (frozen in `docs/reu-format.md`, which is authoritative):

| Data | Packed form | Size | Lives at |
|---|---|---|---|
| NODES | 12 SoA arrays of 240 | 2880 B | `$D000` under I/O |
| SECTORS | 6 SoA arrays of 96 | 576 B | `$DC00` under I/O |
| MAPINFO | counts, root, spawn, SSECDATA base | 32 B | `$0E00` |
| SSECDATA | `[segCount, sectorId, segs…]` in a 128 B slot per subsector | 30336 B | **REU**, streamed per subsector |

Three changes from what this section originally proposed, all of them
simplifications:

- **There is no resident SSECTORS table.** It was to be 237 entries × 4 arrays
  = 948 B of RAM plus a 16-bit multiply per subsector visit. Instead each
  subsector owns a fixed 128-byte REU slot at `ssecReuBase + (i << 7)` holding
  its seg count, its sector id and its segs. One shift, no multiply, no table —
  30 KB of REU (which is free) traded for 948 B of RAM (which is not).
- **Everything resident fits under `$D000`.** With SSECTORS gone, nodes and
  sectors together are 3456 B of the 4 KB there, so the whole `$0BC6-$0DFF`
  free block stays available for Phase 4's BSP stack. `MAXNODES = 240` and
  `MAXSEC = 96` are round numbers chosen so the two blocks end at `$DEFF`,
  one page short of the REU registers.
- **BLOCKMAP and the collision linedefs are gone entirely** — see Phase 5.

Node bounding boxes are still dropped at M1 (16 B/node saved). Without them the
walk visits every node, relying on column occlusion for rejection — correct,
just not maximally culled. Add them back in M2 if profiling says so.

Per frame the engine DMAs one subsector slot per visit, in two transfers: 2
bytes of header, then `segCount × 10`. At E1M1's mean of 3.09 segs that is 33
bytes rather than the 82 a fixed-size slot fetch would cost, so ~40 visible
subsectors is **~1.3 KB/frame ≈ 1.3 ms** of halted CPU at the measured
1 byte/µs.

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

### Phase 1 — Hardware truth (needs the U64) ✅ DONE (2026-08-09)

Do this before writing a byte of REU-dependent engine code. The whole data
layout in §4 rests on an assumption nobody has measured.

1. ✅ **`tools/u64push.py`** — pushes the PRG over the **REST API**, not the
   legacy TCP-64 command socket: `POST /v1/runners:run_prg` resets the
   machine, DMAs the image in and starts it. `make run-u64` is wired, along
   with `make u64-config` and `make u64-fps`. See §9.
2. ✅ **REU image delivery is solved: FTP + REU Preload.** The Ultimate's FTP
   service takes the `.reu` (anonymous login, `/Usb0/...`), and the config
   items `REU Preload Image` / `REU Preload Offset` / `REU Preload` point the
   machine at it; the image is loaded into REU RAM on the next reset, which
   `run_prg` performs anyway. `u64push.py --reu` does all of it. Tested end to
   end with a 64 KB pattern file. **Phase 3 is unblocked, and its output
   format is just "the raw REU image", same as VICE's `-reuimage`.**
   *Caveat:* that the file reaches the device and the setting arms is
   verified; that the bytes land in REU RAM cannot be confirmed until Phase 2
   has code that reads `$DF00`.
3. ✅ **REU DMA benchmarked** — `make reubench`, and the answer is flat:
   **exactly 1 byte/µs at every size, and it does not scale with the CPU
   clock.** See §10.
4. ✅ **Frame rate measured on real hardware: 50.1 fps, vsync-locked**, with
   the speed sweep that proves turbo is engaged. `pipeline.md` §12.3 has the
   table. Frame compute is 15-22 ms at 64 MHz — the test map is *at* the PAL
   frame boundary, not comfortably inside it.

*Done when:* `make run-u64` works, and `pipeline.md` gains a measured
bytes-per-millisecond table and a real FPS number. — **FPS met; the
bytes-per-millisecond table is item 3 and moves to Phase 2.**

### Phase 2 — The REU layer ✅ DONE (2026-08-09)

1. ✅ **`src/reu.asm`** — the `reuSet` macro fills `$DF02-$DF08`, a store to
   `$DF01` fires the transfer, and `reuProbe` round-trips a signature through
   REU address 0 at boot. `main.asm` records the verdict in `reuOK`.
   *Deliberately not fatal yet:* nothing reads the REU, so refusing to run
   would only break machines the engine currently works on. It becomes fatal
   in Phase 4, when the map lives there.
   `make check` now **asserts** `reuOK == 1` — see §10 for why that assertion
   is not paranoia.
2. ✅ **Boot-time resident load** — `src/mapload.asm`. Reads the 64-byte
   header from REU offset 0, checks magic and version, then walks the block
   descriptors and copies each resident block to its home. It checks the load
   address in the image against `defs.asm` and the length against the space
   reserved, and sums each block into `mapSum` as it copies.
   Blocks cannot be DMA'd straight to `$D000` — with I/O banked in the transfer
   would hit the registers, with it banked out `$DF01` is unreachable — so each
   one is staged through MATRIX and block-copied under `BANK_RAM`.
3. ✅ **I/O banking discipline** — `$01 = $35` is the engine's default state,
   set once at boot; `$34` is entered only to touch the node and sector tables
   and always restored. Both keep RAM at `$A000`/`$E000` where the bitmaps
   live, so a bank switch never changes what a bitmap write does. Safe only
   because interrupts are masked for the whole run. `docs/reu-format.md` §6.1.
4. ✅ **Delivery to real hardware**, which turned out to be the hard part —
   REU Preload does not work. See §11.

*Done when:* the PRG loads a signature block from REU at boot, verifies its
magic, and `make debug` is still clean. — **met, and then some**: all three
resident blocks are verified byte-for-byte in VICE and by checksum on real
hardware, `make check` asserts it, and `make u64-map` is the hardware
equivalent.

### Phase 3 — `tools/wad2reu.py` ✅ DONE (2026-08-09)

The offline half. Emits `build/assets.reu` in the §4 layout, with a header
carrying magic, version, and each block's REU offset and length. All five items
below landed; the format is frozen in `docs/reu-format.md` and §11 has the
numbers.

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
recognisably E1M1, with the validator green. — **met.** `build/assets-map.png`
is unmistakably E1M1. `make assets` also emits `build/testmap.reu`, the
3-sector map of `testmap.asm` run through a BSP builder in the same tool, which
is Phase 4.4's input.

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
2. **Collision against the destination subsector's segs, not BLOCKMAP.**
   Descend the BSP with the destination point to find its subsector, then test
   the move against that subsector's segs — which the renderer already streams,
   in the format it already uses. Blocking = a one-sided seg, or a two-sided
   one with a floor step > 24 units or headroom < 56. Keep the existing
   undo-the-move response for M1 (no sliding).

   This drops BLOCKMAP, LINEDEFS and SIDEDEFS from the image entirely — about
   10 KB and a whole second geometry format to keep in sync — and it makes
   `checkSector` a generalisation of what it already does rather than a rewrite:
   subsectors are convex, so the existing sign-only cross product works
   unchanged.

   The one thing to get right: a subsector's boundary includes edges along BSP
   partition lines that are **not** in `SEGS`, because those are interior
   boundaries between subsectors, not walls. Not blocking there is the correct
   behaviour, not a gap. What this shares with the current code is the
   limitation in `pipeline.md` §5.3 — a single frame's motion crossing two
   boundaries — and it wants the same fix, looping with an iteration cap.
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
| 1 | ~~REU DMA is slow *and* doesn't scale with turbo~~ | Phase 1's benchmark | **Closed.** 1 byte/µs flat, no setup penalty, so per-subsector streaming needs no batching (§10). ~1.3 KB/frame = ~1.3 ms |
| 2 | ~~No clean way to get a `.reu` image onto real hardware~~ | Phase 1.2 | **Closed the hard way.** REU Preload does not deliver on firmware 1.1.0; `src/reuload.asm` + `machine:writemem` does, and verifies every chunk (§11) |
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

## 9. Session log — 2026-08-09, Phase 1

### The machine

**C64 Ultimate at `192.168.1.65`** — product string "C64 Ultimate", firmware
1.1.0, FPGA 122, core 1.49, hostname `C64-Ultimate-3D82C5`. It does **not**
advertise itself over mDNS, so `U64_HOST` in the `Makefile` is an IP, not a
name. To find it again: `curl -s -m2 http://<ip>/v1/info` across the subnet —
the Ultimate is the host that answers with a JSON `product` field.

Everything is driven through the **REST API** (firmware ≥ 3.11), documented at
`1541u-documentation.readthedocs.io/en/latest/api/api_calls.html`. That turned
out to be far more capable than the TCP-64 command socket the old plan assumed:
besides `runners:run_prg`, it offers `machine:readmem` / `machine:writemem`
(DMA, no cooperation from the running program) and full read/write access to
the configuration menu. Those three are what made the rest of this session
possible.

### Machine configuration is a build dependency, not a setup step

The engine picks its CPU speed by writing `$D031`. That register **only exists
when the machine's Turbo Control is set to "C64U Turbo Registers"**; in any
other mode it reads `$FF`, the write is discarded, and the engine runs at 1 MHz
with nothing to indicate it. This bit us immediately: the setting had reverted
to `Off` between two runs an hour apart.

So it is applied and verified from the build, by `make u64-config`, which
`run-u64` and `u64-fps` depend on:

| Setting | Value | Why |
|---|---|---|
| Turbo Control | `C64U Turbo Registers` | the only mode that takes the speed from the menu *and* lets `$D031` change it |
| CPU Speed | `64` | speed index 15 on this machine |
| Badline Timing | `Enabled` | keeps C64-compatible bus timing; the VIC has priority either way |
| SuperCPU Detect (D0BC) | `Disabled` | nothing probes `$D0BC` |

Now also saved to the Ultimate's flash, so it survives a power cycle.

**Turbo must be toggled, not set.** Writing the target speed to `$D031` after a
reset does not engage it; the register has to be walked down to 1 MHz and back
up. `turboOn` in `main.asm` does exactly that, unconditionally, for six cycles.

`$D031` is an unconnected VIC mirror on a stock C64 (`$31 mod $40 = 49`, past
the last real register at `$2e`), so all of this is inert in VICE and `make
check` is unaffected.

### What the hardware said

- **50.1 fps, PAL vsync-locked**, test map. The full speed sweep is in
  `pipeline.md` §12.3. 1 MHz gives 0.83 fps, which is the control proving turbo
  is genuinely on.
- **Frame compute is 15-22 ms at 64 MHz** — bracketed from the 10 MHz and
  24 MHz rows, which are quantised to the same 20 ms grid. The test map is
  *at* the frame boundary, not inside it. §12.1's ~994k cycle estimate was low
  by about a third.
- **There is a ~1 s startup transient** after `run_prg` during which frames are
  dropped — the Ultimate is still finishing its own post-reset housekeeping. A
  0-5 s window reads 37.8 fps; every window after reads exactly 50.00.
  `u64push.py` discards it. Any future benchmark must too, or it will report a
  20% deficit that is not the engine's.

### Two bugs the session found in passing

1. **The main segment had three bytes of headroom and no guard.** It ended at
   `$0B1C`; `pStkSec` was at `$0B20`. Adding strafing pushed it to `$0BC5`,
   straight through the portal stack. The stack moved to `$0F00` and
   `main.asm` now carries `.errorif * > pStkSec`. `tools/vicedbg/probe.py`'s
   allowed-region table had to move with it — worth remembering that the
   probe's table is a second, independent copy of the memory map.
2. **The A/D turn-direction defect was real** and is fixed — see
   `pipeline.md` §3. It was resolved by looking at the machine rather than by
   argument, which mattered: the competing fix would have mirrored the world.

### `tools/u64shot.py` — screenshots from real hardware

`machine:readmem` will DMA out the whole 28160-byte MATRIX in about a second,
and the chunky format is trivially renderable off-device, so hardware frames
can now be looked at without a capture card or the U64 video stream. It takes
`--cam X,Y,A` to place the camera first, which makes it a scripted turntable.
This is what settled the A/D question and it is the obvious way to check the
first E1M1 frame in Phase 4.

It renders the *chunky* buffer, i.e. the renderer's output before `chunky2mc`
packs it — so it shows what the 3D code drew, not what the VIC displays.
Attribute artefacts will not show up in it; wrong geometry will.

A companion trick worth keeping: `machine:writemem` can patch the running
engine. Overwriting `readInput` with `lda #bit / sta zInput / rts` forces a
single intent bit, which is how all six directions were verified on hardware
without anyone touching the keyboard.

---

## 10. Session log — 2026-08-09, Phase 2 (partial)

### REU DMA: 1 byte/µs, flat, and independent of the CPU clock

`make reubench` builds `src/reubench.asm`, runs it on hardware and DMA-reads
the results back. It times N back-to-back transfers with CIA 2 timer A — which
keeps ticking at 1 MHz while the REU has the 6510 halted, and does not care
about the turbo setting — then times the identical loop with the command store
neutered and subtracts. Measured:

| Size | 1 MHz | 64 MHz | µs/transfer | Rate |
|---:|---:|---:|---:|---:|
| 32 B | 4173 µs / 128 | 4096 µs / 128 | 32.0 | 1.00 B/µs |
| 256 B | 8192 µs / 32 | 8192 µs / 32 | 256.0 | 1.00 B/µs |
| 4096 B | 16384 µs / 4 | 16384 µs / 4 | 4096.0 | 1.00 B/µs |

Three things fall out of this, in increasing order of how much they matter:

1. **DMA does not scale with the turbo clock.** 64 MHz is 1.00× the 1 MHz
   rate. This closes the open item in `3d-renderer-design.md` §REU usage.
2. **There is no per-transfer setup penalty.** 32 bytes costs 32 µs, not
   32 µs plus a fixed overhead — the cost is exactly linear in size down to
   the smallest transfer measured. So §4's per-subsector streaming does *not*
   need to be batched per node subtree. That contingency can be dropped.
3. **REU DMA is far too slow to use as a memset.** `pipeline.md` §9.3 floats
   filling spans by DMA instead of by CPU stores. At 64 MHz the CPU writes a
   span byte every ~11 cycles = 0.17 µs; DMA takes 1.00 µs. **DMA fill would
   be about 6× slower**, and it halts the CPU while it runs. That idea is
   dead, and the note should stop suggesting it.

The cost of the actual plan: ~1.2 KB/frame of seg streaming = **~1.2 ms per
frame of halted CPU**. Against a 20 ms PAL frame that is 6% — affordable in
isolation, but the test map already occupies 15-22 ms (§9), so it comes
straight out of a budget that has no slack. Worth remembering when Phase 4's
first E1M1 frame is slower than expected.

### `-default` had been switching the REU off for the whole life of the project

`reuProbe` failed in VICE while succeeding on hardware. The cause was the
`x64sc` command line: `-reu -reusize 16384 ... -default`. **`-default` resets
every setting to its factory value, including the REU enable**, and it was
sitting after `-reu`. So no VICE run this project has ever made had an REU
attached — and `-reuimage`, which Phase 3 was going to rely on for the whole
inner development loop, would have been silently ignored too.

Nothing indicates this from inside the C64: with no REU, `$DF00-$DF0A` read
back `$00` (not `$FF`), stores go nowhere, and every transfer "succeeds"
instantly. It is a perfectly silent failure, which is exactly why the fix is
paired with an assertion rather than just a reordering: `tools/vicedbg/probe.py`
now reads `reuOK` and `make check` fails if it is not 1.

The general lesson, which cost a Makefile comment: **`-default` must come first
on VICE's command line, before any setting it would otherwise undo.**

### Next session: Phase 3 (`tools/wad2reu.py`)

Everything it needed is now settled. The delivery format is a raw `.reu`
image, identical for hardware (FTP + REU Preload) and for VICE
(`-reuimage`, which now actually works). The transport cost is known and
linear, so the §4 packing can be taken at face value. It is pure Python,
verifiable by its own top-down PNG render, and needs no hardware.

Phase 2's remaining two items (resident load, `$D000` banking) are blocked
behind it and should follow immediately after.

---

## 11. Session log — 2026-08-09, Phases 3 and 2 (completed)

Phase 3 in full, then Phase 2's two blocked items, then the hardware
verification that the whole delivery path actually works. `make check` is green
and `make u64-map` passes on the C64 Ultimate.

### What was decided before any code

Four questions, answered up front because each one changes what gets built:

| Question | Answer |
|---|---|
| Freeze the format first? | Yes — `docs/reu-format.md`, written before either half |
| Emit the test map through the same pipeline? | Yes — `make assets` produces `build/testmap.reu` too |
| Collision: BLOCKMAP or the BSP's own segs? | **Segs.** Drops ~10 KB and a second geometry format (Phase 5.2) |
| Who picks the texture → ramp mapping? | Proposed in `RAMPS` at the top of `wad2reu.py`, yours to tweak |

### `tools/wad2reu.py`

E1M1, measured: 467 vertices, 475 linedefs, 85 sectors, 732 segs, 237
subsectors, 236 nodes (root 235). Subsector seg ranges are contiguous and in
order; the largest subsector has 8 segs; coordinates span x −768…3808,
y −4864…−2048, so nothing needs rescaling and the projection math in
`pipeline.md` §8 carries over untouched. Spawn is `(1056, −3616)` facing 90°,
which is `camA = 64` in the engine's 8-bit angle space, in subsector 103 of
sector 38.

All 32 of E1M1's wall textures and all 24 flats are mapped to ramps by name
family; nothing falls through to the default. Flat intensity comes from the
sector's WAD light level mapped to 2…15 — a deliberate small step past M1's
"no lighting from WAD light levels" exclusion, because the intensity nibble has
to hold *something* and a constant flattens all 85 sectors into one brightness.

The test map goes through a BSP builder in the same file: 14 linedefs → 16 segs
→ 3 subsectors, 2 nodes, no splits. That the three convex sectors come out as
exactly three leaves is the expected answer and a useful sanity check on the
builder.

Validation re-parses the finished image with a reader that shares no code with
the packers, and checks the descent the engine will do against the one Python
does. `build/assets-map.png` is a top-down render of the *decoded* blocks — it
is unmistakably E1M1, which is the check that no structural assertion can make.

### Three silent failures, found in a row

Each one lets every REU read "succeed" and return the wrong bytes. That shape is
now familiar enough to be the design assumption: **nothing on this path may be
believed without an assertion.**

1. **`reuProbe` was overwriting the header it was about to verify.** It
   round-trips a signature through REU address 0, which is where the image's
   magic lives, and it runs first. Moved to `$00F000`; `wad2reu.py` asserts the
   image stays below that.

   Bank 1 offset 0 was the first fix and had to be abandoned: with `$DF06 = 1`
   the Ultimate stashed to REU `$000000` anyway, which VICE does not do.

2. **VICE silently ignores a `-reuimage` whose size is not exactly the emulated
   REU size.** It prints one line to stderr and boots with a zeroed REU. Images
   are now padded to 128 KB and the Makefile runs `-reusize 128`; raise the two
   together or neither. `+reuimagerw` also stops VICE writing the image back on
   exit and stamping runtime state into a build artifact.

3. **The Ultimate's REU Preload does not deliver the image** on firmware 1.1.0 /
   FPGA 122 / core 1.49. The file uploads over FTP at the right size, all three
   settings arm and read back correct, and REU offset 0 keeps whatever a running
   program last wrote there, across any number of resets. Tried and did not
   help: re-running with the setting already armed, `save_config_to_flash` plus
   an explicit reset, toggling `RAM Expansion Unit` off and on, toggling
   `REU Preload` off and on, and matching `REU Size` to the image size in case
   preload wants an exact fit the way VICE does.

   This is the answer to Phase 1.2's caveat — *"that the bytes land in REU RAM
   cannot be confirmed until Phase 2 has code that reads `$DF00`"* — and the
   answer is that they did not.

### `src/reuload.asm` — the delivery that does work

A standalone PRG with an 8-byte mailbox at `$0340`. The host DMAs a chunk into
C64 RAM with `machine:writemem` and writes the mailbox in one call; the trigger
byte is **last** in the mailbox, so the stub cannot see it before the parameters
it describes. `tools/u64push.py` drives it in 16 KB chunks and reads every chunk
back with a matching REU fetch before moving on. E1M1's 34688 used bytes take
three chunks and a few seconds.

The REU itself was never the problem — writes from the C64 persist across
resets, which is exactly how the stale bytes were identified.

### Verification, on both machines

| | VICE (`make check`) | Ultimate (`make u64-map`) |
|---|---|---|
| MAPINFO `$0E00` +32 | byte-exact | byte-exact, sum `$06D2` |
| NODES `$D000` +2880 | byte-exact | sum `$44FA` |
| SECTORS `$DC00` +576 | byte-exact | sum `$9F92` |

The two blocks under `$D000` cannot be read back from a host at all: the
Ultimate's `machine:readmem` DMAs the bus as the engine has it banked, so a read
of `$D000` returns the I/O registers. `mapload.asm` therefore sums each block
into `mapSum` while it copies, under `BANK_RAM`, which is the only view of that
RAM anything outside the engine can get. The sums agree with the image on both
machines and with each other.

`make u64-fps` still reports **50.01 fps**, so none of this costs a frame.

### Two things to know before touching this again

- **The main segment now ends at `$0DC6`, 58 bytes below `MAPINFO`.**
  `main.asm`'s `.errorif` was checking against the portal stack at `$0F00`,
  which no longer bounds anything; it checks `MAPINFO` now. Phase 4 gets about
  250 B back by deleting `testmap.asm` and the portal stack.
- **The memory map now has four independent copies**: `defs.asm`, the image's
  own load-address bytes, `probe.py`'s allowed-region table, and
  `docs/reu-format.md`. The first two are cross-checked at boot and the third
  fails `make check` when it drifts. The document is the one nothing enforces.

### Next session: Phase 4

Everything it needs exists. `build/testmap.reu` is the input to bring the BSP
walk up on before E1M1, `pointOnSide` is `checkSector`'s existing sign-only
cross product with the wall delta swapped for the node delta, and MAPINFO
carries a precomputed spawn subsector for the engine's first descent to check
itself against.

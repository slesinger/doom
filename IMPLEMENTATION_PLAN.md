# Doom C64U — Implementation Plan

**Milestone 1 is closed** on real hardware: E1M1, walkable, flat-shaded, with
music, at a measured **25.05 fps with 100% of frames on the deadline**.

This document is now in two parts. **Part I** is the compacted record of M1 —
the architecture as built, the constraints that are still binding, and the
hard-won facts that cost a session each to learn. **Part II** is the plan for
**Milestone 2**: textures, doors and moving sectors, sprites, and a HUD.

> **Renumbered 2026-08-11.** Part I compacts what was 1400 lines of session log.
> A dozen source files cite the old section numbers; they are not stale, they
> point at a document that no longer carries the text. The map:
>
> | Old | Now |
> |---|---|
> | §3 BSP decision, §4 memory and residency | §2, §3 |
> | §6 risks, §7 sequencing | §5 |
> | §8-§18 session logs | §6's index — the findings worth keeping are in §4 |
>
> **The full untruncated logs are in this file's git history**, newest revision
> `1ae6533`. A citation of the form "IMPLEMENTATION_PLAN.md §13" in `src/` or
> `tools/` means that session's log, and `git show 1ae6533:IMPLEMENTATION_PLAN.md`
> is where to read it.

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

**Nothing on the REU or hardware path may be believed without an assertion.**
Three silent failures were found in a row on the delivery path alone, each of
which let every read "succeed" and return wrong bytes: `reuProbe` overwriting the
header it was about to verify; VICE ignoring a `-reuimage` whose size is not
exactly the emulated REU size; and the Ultimate's REU Preload not delivering at
all on firmware 1.1.0. With no REU attached, `$DF00-$DF0A` read back `$00`, stores
go nowhere and every transfer succeeds instantly.

**Build a positive control into every measurement.** A run in which every write
was silently dropped looks like a clean pass. The SID test's half- and
double-frequency cases, the sphere test stubbed to `sec/rts`, the IRQ test's
deliberately-wrong bank restore — each is what makes the corresponding zero mean
something.

**VICE and the Ultimate disagree in specific, known ways.**

| | VICE | Ultimate |
|---|---|---|
| `$d031` turbo | inert, always 1 MHz | real; must be *toggled* down to 1 MHz and back, and needs `Turbo Control = C64U Turbo Registers` in the menu or it reads `$FF` and the write is discarded |
| `$d41b` (voice 3 osc) | advances one unit per CPU cycle regardless of frequency | tracks the frequency register |
| REU DMA share of the frame | tiny (a 1 MHz frame is 2.3 emulated seconds) | 1 byte/µs — the same absolute cost, so a far larger share |
| `-default` | **resets every setting, including the REU** — must come first on the command line | — |

The consequence that matters for M2: **a change that trades CPU cycles for REU
bytes is judged wrongly by `make stats`**, in either direction. So is anything
driven by a real-time interrupt — the music tick costs +5.7% in VICE and nothing
measurable on hardware, because an emulated frame absorbs ~231 ticks where the
Ultimate absorbs 4.

**The Ultimate steals the bus for ~2.3 s after reset.** Two frames, always
exactly two, cost 2268 ticks each. Inside a 20 s window that turns 25.0 fps into
22.7 — which is a plausible-looking regression, and was believed for half a
session. `WARMUP_SECONDS = 20` in `u64push.py` sits it out and the report names
the transient rather than silently discarding it.

**Price a small change with a profiler hit count, not an estimate.** The 6-byte
seg record was estimated at +0.46 ms/frame and measured +0.06 — both halves of
the estimate were wrong in the same direction. The static ratio is not the
fetched ratio (67.6% of segs are compact, but only 40% of *fetched* segs are,
because the sphere test rejects exactly the small far cells), and the cost of
unpacking is the stores, not the arithmetic (140 cycles, not 20). It was
complete, correct, pixel-exact, and reverted: 135 bytes of fragmented low RAM for
0.16% of a frame. `tools/vicedbg/profile.py` sets non-stopping checkpoints and
costs the engine nothing; it is the only way to price a change smaller than an
instrument's resolution.

**`make framehash`, not `make shot`, is the acceptance test.** `-limitcycles`
stops mid-flip often enough that two runs of the same build differ by ~30 pixels.
`framehash` reads the renderer's own 28160-byte buffer at a frame boundary and
prints its sha256.

**Anything placed below MATRIX must be checked against `bspStkLo`/`bspStkHi`
by hand.** `$0eef-$0f3f` reads as free in the memory map and is the BSP stack; it
assembles clean, links clean, and renders character-mode garbage.

**`make debug`'s port is randomised for a reason.** x64sc binds the monitor port
without `SO_REUSEADDR`, so the previous run's socket sits in `TIME-WAIT` and the
next VICE fails to bind *silently* — it boots and runs normally with no monitor,
which reads exactly like "the emulator did not start".

## 5. The M1 risk register, closed out

| # | Risk | Outcome |
|---|---|---|
| 1 | REU DMA slow and not turbo-scaled | **Real, and priced.** 1 byte/µs flat, no setup penalty, so per-subsector streaming needs no batching. ~1.3 KB/frame ≈ 1.3 ms |
| 2 | No way to get a `.reu` onto hardware | **Closed the hard way.** REU Preload does not deliver; `src/reuload.asm` + `machine:writemem` does, verifying every chunk |
| 3 | 40+ visible subsectors blows the frame budget | **Arrived.** 17.6 fps at first light. Answered by spheres + backface test |
| 4 | `$D000` banking breaks the converter or `flip` | **Never seen.** `make debug` stays clean |
| 5 | Flat shading looks like mush | **Arrived twice** — two flats on one ramp, and depth falloff that had never worked (`sta` sets no flags) |
| 6 | Projection math has range bugs real geometry exposes | **Never seen.** Projected rows match the arithmetic to the pixel |

## 6. Session index

Full logs are in this file's git history. One line each:

| Date | What | Commit |
|---|---|---|
| 08-09 | Phase 0 — `make check`, the monitor-port and leaked-emulator traps | — |
| 08-09 | Phase 1 — the Ultimate at `192.168.1.65`, REST API, turbo as a build dependency, 50.1 fps on the test map | — |
| 08-09 | Phase 2 — `reu.asm`, REU benchmarked at 1 byte/µs, `-default` found switching the REU off | — |
| 08-09 | Phases 3+2 — `wad2reu.py`, the format frozen, three silent failures, `reuload.asm` | — |
| 08-09 | Phases 4+5 — the BSP renderer, E1M1 on screen and walkable, depth shading fixed after years | `2aa06fe`, `5229310` |
| 08-10 | Frame time — backface test, bounding spheres, the 25 fps cap. 56.9 → 45.1 ms | `4228b1e` |
| 08-10 | The two audio unknowns — interrupts are bank-safe, SID survives turbo | — |
| 08-10 | The last 10% — `profile.py`, `spanFill` inlining, `udiv`'s short path, the exact frustum test. −9.4%, bit-identical | `5f79f8e` |
| 08-10 | The 25 fps lock — the frame timer, and the two boot frames that hid it | `a5d4602`, `832c699` |
| 08-10 | The 6-byte seg record — built, measured at 0.06 ms, reverted | `4603944` |
| 08-11 | Music — no player on the C64; a SID register stream replayed from REU | `1ae6533` |

## 7. Carried into M2

Named here so nothing has to be rediscovered:

- **Sliding along walls** and **one boundary per frame** — Phase 5's two open
  items, untouched. Now §9.2.
- **`data_structures.md` has never been reconciled** with the formats
  `wad2reu.py` actually emits. Now §9.3.
- **The uploader sends one span from offset 0**, so the 405 KB music block makes
  every `make run-u64` a multi-minute upload. Now §9.1, and it is a blocker.
- **Quality scaling.** The clock a feedback loop needs exists; nothing reads it.
  Not in M2.
- **One unexplained hardware reading**: 24.10 fps / 93% on deadline, taken
  immediately after a 470 KB upload, never reproduced.

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
| HUD | **In.** Status bar with live health/ammo/armour (§13) |
| Enemy behaviour, weapons, damage, pickups | **Out.** M3 |
| PVS/REJECT, quality scaling, visplanes | **Out** |

### 8.1 The frame budget triples the room, and that is the whole plan

> **Landed 2026-08-11.** `make u64-fps` on hardware:
> `fps: 335 frames in 20.04 s = 16.71 fps (59.8 ms/frame)`,
> `raster frames 1x0 2x0 3x335 4+x0 -- 100% made the 16.7 fps deadline`,
> compute 37.6 min / 38.6 max against 59.85. `make framehash` is unchanged at
> `c5d78e65…` and `make check` is green. **~21 ms of budget is now free.**
>
> `FPS_CAP_TICKS` is **49, not the 58 this section predicted**, and the pacer's
> reference point moved — see the drift note at the end of this section.

**Decision: M2 targets three raster frames — 16.7 fps, a 59.85 ms deadline.**
25 fps with textures and sprites is not reachable on this hardware without
giving up one of them, and 16.7 fps locked is preferable to 25 fps that judders,
which is the trap M1 spent two sessions climbing out of.

| | M1 | M2 |
|---|---:|---:|
| Deadline | 39.90 ms | **59.85 ms** |
| `FPS_CAP_TICKS` | 39 | **49** |
| Measured compute | 37.6 ms | 37.6-38.6 ms measured |
| **Available** | ~2 ms | **~21 ms** |

**The cap is 49, and the reason it is not 58 is a phase drift M1 could not
show.** 58 was chosen here as the largest wait that still fits inside three
raster frames, by the same argument that made 39 the maximum at two. Built and
measured, it gave **95%, not 100%**: `2x16 3x325`, sixteen frames landing a
raster frame *early* in an otherwise perfect run.

That is a beat, not jitter. `framePace` measured from its own last *release*,
so release-to-release was pinned at 58 ticks = 58.87 ms against a raster grid
of 59.85 ms. The phase walks back 0.98 ms every frame, and every ~20th frame it
crosses a raster line and `flip` catches the earlier one. **M1 had exactly the
same drift and it was invisible**: at 39 ticks the drift is 0.32 ms/frame, and
37.6 ms of compute makes a 39.90 ms flip-to-flip physically impossible, so the
beat was floored away rather than absent.

The fix is the reference point, not the number: `framePace` now measures from
`msFrame`, the last flip, which `frameMark` re-seeds at every raster crossing —
so the phase resets each frame and cannot accumulate. That also makes the cap's
exact value uncritical, because `flip` does the quantising and any wait landing
strictly between the two-frame crossing (39.3 ticks) and the three-frame one
(58.97 ticks) selects the same crossing every time. **41…58 all work; 49 is the
middle, with ~10 ms of slack against each.** Hardware then read 335 of 335.

The general lesson is the one §4 keeps making: the instrument decided the
answer. An average frame rate reads 16.96 fps and 16.71 fps as the same engine
running well; only `ftHist` separates "paced" from "paced except every
twentieth frame", and only the second reading is a lock.

**Three consequences, all of which must land in the same commit as the cap:**

1. **Everything that moves must be rescaled by 1.5×**, because the frame period
   is 1.5× longer and every motion in this engine is per-frame. `MOVE_SPEED`
   14 → **21**, exactly. `TURN_SPEED` 3 → 4.5 is not representable in an 8-bit
   angle space, and **it is 4**: 67°/s where M1 turned at 75. The fractional
   accumulator that would give the exact rate costs a zero-page byte and six
   cycles a frame, and is the thing to reach for if 67 feels sluggish in play.
   Nothing tests this — it is a feel judgement, deliberately deferred to one.
2. **`ftHist`'s target bucket moves from 2 to 3.** Done: `TARGET_FRAMES` in
   `u64push.py`, which derives the deadline, the percentage and the bucket
   index from one number. The `4+` alarm stays the alarm. The buckets in
   `frameMark` did **not** move — they count raster frames, which is a property
   of the VIC, not of the cap.
3. **The music tick is unaffected** — it is CIA-driven, in real time, not
   per-frame. It simply fires 6 times per rendered frame instead of 4, which is
   0.26 ms of DMA and register writes instead of 0.17.

Do this **first**, before any feature work. Measuring M2's features against M1's
deadline would report false failures all milestone, and rescaling the movement
constants twice means tuning the game's feel twice.

### 8.2 The budget, allocated

22 ms available, ~2 ms held back as margin — M1 shipped on 2 ms of margin and
that was uncomfortably tight.

| | Estimate | Basis |
|---|---:|---|
| Wall textures | 6-9 ms | §10.4 |
| Doors and moving sectors | < 0.5 ms | §11; the renderer needs no change |
| Sprites | 6-8 ms | §12.4, dominated by REU streaming |
| HUD | < 0.5 ms | §13; redrawn only when a value changes |
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
  `mapLoad` stages, which is what §10.2 already proposed.

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

> **Done.** `make run-u64` is **8 seconds**, of which most is `u64config` and
> the loader stub's 3 s settle: `0 chunk(s) sent, 28 unchanged and skipped`.
> A first upload after a power cycle still sends all 28. `make u64-map` then
> read every one of those 28 chunks back off the machine and matched — the
> independent check that the cache is not lying about what is in REU RAM.
>
> **The 404 did not recur.** Twelve `run_prg` calls in ~40 s, a higher rate
> than the ~10-per-minute that wedged the machine before, all clean. So the
> cause was upload volume rather than a per-call resource leak, and the fix is
> the fix — but risk #6 stays in the register, because a negative result over
> 40 s is weaker than the positive one that motivated it.
>
> The three items below landed as: claimed-region chunking (28 chunks instead
> of 29 — the hole was worth less than it looked), a content-hash skip cache in
> `build/.reu-upload-cache.json` (this is the win), and the deliberate 404
> re-run. `--no-reu-cache` forces a full send.

The image went from ~36 KB to ~470 KB when music landed, because `u64push.py`
sends one contiguous region from offset 0 to the last byte any descriptor claims.
Three chunks became 29 and `make run-u64` went from seconds to minutes. Worse:
after several such uploads in one session, `POST /v1/runners:run_prg` began
answering `404 Cannot open file` for every PRG, survived `machine:reset`, and
needed a power cycle. That is correlation, not proven cause — but M2 is a
milestone of many iterations and this is not usable as it stands.

1. **Send only the regions descriptors actually claim.** The 28 KB hole between
   the map and `MUSIC_OFFSET` is currently uploaded as zeros.
2. **Content-hash each chunk and skip the ones that match.** The music never
   changes between builds; the common rebuild-and-run should be back to three
   chunks and seconds.

   The cache cannot simply be believed: REU RAM survives a reset but not a
   power cycle, and another checkout or a hand load from the Ultimate's menu
   can have written it since. So a random 16-byte token goes into REU RAM at
   `$00F010` — in the unclaimed hole above `reuProbe`'s scratch, which no
   descriptor covers and no chunk touches — and the cache is trusted only when
   the token still reads back. It is **cleared before an upload and written
   after** a fully successful one, so an upload that dies halfway leaves no
   token and the next run sends everything. `--verify-reu` reads back every
   chunk regardless, skipped ones included, which is what keeps the whole
   mechanism falsifiable.
3. **Re-run the `404` scenario deliberately** once the upload is small, and
   record whether it recurs. If it does, it is a firmware constraint the whole
   project needs to know about; if it does not, the cause was upload volume and
   the fix is the fix.

Also verify `$0400-$07ff` here, since it gates §8.3. **Done, and it failed:**
the block is `COLBUF` and always was — `probe.py` already listed it, and a
`dump` run reads 880 of 896 bytes non-zero. §8.3 carries the numbers. The check
cost twenty minutes and it was asked for by name in this plan, which is the
only reason a kilobyte of imaginary RAM did not end up underneath §12's sprite
design.

### 9.2 Sliding along walls, and the two-boundary loop

M1's single biggest gameplay defect: a blocked move is undone whole, so walking
into a wall at a shallow angle stops you dead. Both open items want the same
change to `checkMove`, so they are one job:

```
for attempt in 0..2:                     ; iteration cap
    descend BSP with the destination point
    find the blocking seg, if any
    if none: commit the move, done
    project the remaining motion onto the seg's direction
    retry with the projected destination
undo the move
```

The projection is `d - n(d·n)` with `n` the seg normal — two `ssmul32` calls
and a shift, reusing the arithmetic `segFacing` already runs. The iteration cap
is what also fixes `pipeline.md` §5.3's "a frame's motion crossing two subsector
boundaries is only tested against the first": each iteration re-descends from the
new destination, so crossing two boundaries is two iterations rather than a
missed test.

Two things this must keep: `segNear`'s bounding-box test inflated by the player
radius (without it, collinear segs in one subsector block on whichever is listed
first — which is exactly the shape of E1M1's start-room exit), and the existing
step/headroom rules (floor step > 24 blocks, headroom < 56 blocks).

*Done when:* you can walk the length of a wall at 20° without stopping, and a
scripted diagonal run into an inside corner neither leaks nor sticks.

### 9.3 `data_structures.md` reconciled

It has described a format the tool does not emit since Phase 3, and M2 changes
the formats again (§10.2, §11.2). Reconcile it once now, against
`docs/reu-format.md`, which is authoritative — or delete it and redirect, if
everything in it is now said better there. Deciding that is part of the job.

The memory map has **four independent copies**: `defs.asm`, the image's own
load-address bytes, `probe.py`'s allowed-region table, and `docs/reu-format.md`.
The first two are cross-checked at boot and the third fails `make check` when it
drifts. The document is the one nothing enforces, which is why it is the one that
rots.

## 10. Phase 8 — Textured walls

The defining feature of M2 and the one with the real risk in it.

### 10.1 The insight the format hands us

The chunky buffer is one byte per pixel, `ramp << 4 | intensity`. `chunky2mc`
packs it into multicolor, where a 4×8 cell may hold only three colours plus
background — and the reason M1's frames are clean is that a whole surface shares
one ramp, so a cell's colours are consistent by construction.

**A texture must therefore modulate the intensity nibble and leave the ramp
alone.** That is not a compromise dressed up as a design: it is the only form of
texture that cannot break the attribute constraint, it costs one `ora` per pixel
because the ramp is already in a register, and it is exactly what Doom's own
textures mostly carry at this resolution — structure, not hue.

The surface's ramp keeps coming from `wad2reu.py`'s `RAMPS` table, which stays
the art-direction knob. Depth falloff, which currently sets the whole nibble,
becomes a *bias* applied to the texel's intensity, clamped to 1-15.

### 10.2 Do it in two stages, with a measurement between them

**Stage A — resident 8×8 intensity tiles.** One 8×8 nibble-packed tile (32
bytes) per texture family, indexed by `(u & 7, v & 7)`. E1M1 uses 32 wall
textures across roughly 16 families → **512-1024 bytes, fully resident**, no
streaming, no cache, no eviction. Generated in `wad2reu.py` by downsampling the
real WAD texture to 8×8 and normalising its intensity range.

This is not a placeholder for a "real" implementation — it is the version that
is certain to fit in both RAM and the frame, and it delivers most of what
texturing is *for* at 160×176: surfaces that are distinguishable and read as
material rather than as flat colour.

**Stage B — real texels, 64×64, streamed and cached.** Only if Stage A measures
well inside its budget. A 64×64 4-bit texture is 2 KB, so a cache is 2-3
textures at most and there is nowhere to put it; the honest form is a
*per-frame* cache keyed on the fact that a frame draws few distinct textures,
streamed into a MATRIX scratch region the way `mapLoad` staged through it.

**Model Stage B before building it**, with a `profile.py` checkpoint on the
sampler's inner loop and a hand-counted cycle cost. §4 is unambiguous that this
class of estimate is wrong by 3-7× in this engine, in both directions.

### 10.3 The u coordinate is where the cycles go

`v` is nearly free: the wall column already steps a fixed-point row accumulator,
and the texel row is that accumulator's high bits masked to the tile height.

`u` is the perspective divide. Doing it per column is up to 160 extra `udiv`
calls a frame against the 628 the whole engine currently makes — divides are
~18% of the frame, so that alone is +1 to +2 ms.

**Interpolate `1/z` and `u/z` linearly across the seg and divide once every
8 columns**, affine within the subspan. This is what Doom does and the error at
this resolution is sub-texel for anything but a wall nearly edge-on. It takes the
divide count to ~20/frame — a rounding error — and turns the per-column work
into two adds.

The seg already computes `ry0`/`ry1` at both endpoints for projection, so the
endpoints of the interpolation exist. What is new is the along-wall distance at
each endpoint, which the seg record does not carry.

### 10.4 What it should cost

`spanFill` is 2593 calls / 28.4k pixels / ~27% of a 37.6 ms frame ≈ **22 cycles
per pixel** at 64 MHz. A textured pixel adds a fixed-point `v` accumulate, a
nibble fetch and unpack, and the `ora` — call it +18 cycles, so a textured pixel
is ~1.8× a flat one.

Walls are roughly 40% of the screen's pixels in a typical E1M1 view (floors and
ceilings dominate, and they stay flat). So: 11.4k pixels × 18 cycles ≈ 3.2 ms,
plus the subspan divides and setup, plus a nibble unpack that may want a
256-byte lookup table instead of a shift.

**Estimate: 6-9 ms.** Wide, deliberately. This is the number that decides whether
Stage B ever happens, and §4's lesson is that the way to narrow it is a
checkpoint on the real inner loop, not more arithmetic in this document.

### 10.5 The acceptance test changes shape

Every optimisation in M1 was verified as *0 of 104448 pixels differ*.
Texturing changes the frame by design, so that oracle is gone for this phase and
must be replaced deliberately:

- **`make framehash` still applies within the phase** — capture a hash once the
  first textured frame is judged correct by eye, and hold every subsequent change
  to it.
- **`wad2reu.py --validate` gains a texture check**: every surface resolves to a
  tile, every tile's intensity range is within 1-15 after the depth bias is
  applied at both extremes, and no surface maps to a tile of uniform intensity
  (which would be a silently untextured wall).
- **A known-good reference frame** at the spawn, committed as a PNG, compared by
  eye at each step. The frame is still the only oracle this engine has.

## 11. Phase 9 — Doors and moving sectors

The cheapest feature in M2 by a wide margin, for two structural reasons.

### 11.1 The renderer needs no change at all

A door is a sector whose ceiling height animates. The renderer reads sector
heights from the resident `SECTORS` block at `$DC00` every frame and draws
upper/lower steps against them; a closed door is a two-sided seg whose upper step
covers the whole opening, which `doWall` already draws as a solid band. **Change
the height in RAM and the door renders.**

And the bounding spheres stay valid: they are 2D, in x/y, and a moving sector
moves in z. Nothing needs re-culling, nothing needs re-validating, and the
offline sphere check in `wad2reu.py` is unaffected.

Collision follows for free too — `checkMove`'s step and headroom tests already
read the same live sector heights, so a closing door blocks and an open one does
not, without a line of new collision code.

### 11.2 What has to be built

1. **A trimmed `LINEDEFS` block, resident.** M1 dropped linedefs entirely.
   Only lines with `special != 0` or `tag != 0` need to come back — in E1M1 that
   is a few dozen — as `[v0, v1, special, tag, frontSector, backSector]`.
   Under 300 bytes; it wants a home under `$D000`, where `NODES` + `SECTORS`
   leave 640 bytes.
2. **A seg → linedef reference.** The seg record is 10 bytes and `doWall`
   indexes `SEGBUF` by byte offset, so widening it is not free. Two options,
   and this is the phase's one real design decision:
   - **Widen to 11 or 12 bytes** — a format version bump, +1.5 KB of REU, and
     ~90 more DMA bytes per frame. Simple, and the stride stays uniform.
   - **Look the line up by geometry** — on "use", find the special line whose
     endpoints the seg lies on. No format change, no per-frame cost, and it only
     runs on a keypress.

   **Prefer the lookup.** M1's evidence is that per-frame DMA bytes are the
   scarce thing and a keypress is not; and §4's revert is a warning about
   growing the hottest record for a cold feature.
3. **A thinker list.** A fixed array of active moving sectors —
   `[sector, target, speed, state, delay]` — updated once per frame before the
   render. Eight entries is more than E1M1 ever has active. ~64 bytes of the
   data RAM §8.3 is looking for.
4. **Activation.** Two paths: the **use key**, which raycasts a short distance
   ahead against the current subsector's segs (already streamed, already in
   `SEGBUF`); and **walkover triggers**, which `checkMove` detects as a crossing
   of a special line during its descent — the same test it already does to find
   the blocking seg.
5. **`wad2reu.py`** maps Doom's line specials to the subset M2 implements: door
   open/close/stay, switch, platform, and lift. Anything else becomes a no-op
   and the validator reports what it dropped, so the map does not silently lose
   a mechanism.

### 11.3 The one thing to watch

**A door that closes on the player.** Doom's answer is to reverse the door;
without it, `checkMove`'s headroom test starts failing every move and the player
is stuck inside geometry with no way out. Handle it in the thinker — if the
player's subsector is the moving sector and the headroom would drop below 56,
reverse — not in the collision code.

*Done when:* the E1M1 start-room door opens on use, closes behind you, and the
first lift runs; `make framehash` differs between open and closed and is stable
in each state; `make debug` is clean across a scripted walk that triggers both.

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

## 13. Phase 11 — The HUD

Cheap, independent of everything else, and the thing that most makes the game
look finished. **It can jump the queue** — it shares no code with textures,
doors or sprites, and it is the obvious phase to do while a hardware question
from an earlier phase is waiting on the machine.

1. **The status bar area is already blanked** by `main.asm` — the viewport is
   160×176 of a 200-row screen, so ~24 rows exist below it.
2. **Draw it once, patch digits on change.** Nothing in the HUD changes per
   frame; a redraw costs nothing amortised. A dirty flag per field is the whole
   mechanism.
3. **Graphics from REU at boot**, blitted into the bitmap once: the STBAR
   background, a digit font (12 glyphs), and the face frames if they are wanted.
   No per-frame streaming, no resident graphics, no RAM cost beyond a few dozen
   bytes of state.
4. **Values are engine state that mostly does not exist yet** — health, armour
   and ammo have no source until M3's combat. M2 should draw the bar with fixed
   plausible values and wire the fields to variables, so that M3 changes a
   number and not a renderer.

*Done when:* the bar renders on hardware, `ftComp` is unchanged from before it,
and changing a health variable over the monitor updates the display.

## 14. M2 risk register

| # | Risk | Early warning | Response if it arrives |
|---|---|---|---|
| 1 | ~~**There is nowhere to put M2's state.**~~ **Arrived, day one.** `$0400-$07ff` is `COLBUF` and always was | §9.1's watched-region run, before any design depends on it — which is exactly what caught it | ~200 B of data RAM and ~90 B of code RAM is the real budget (§8.3). Sprite depth moves into `colTop` (§12.1), Stage B textures get less likely, boot-only code goes into MATRIX |
| 2 | **Textures overrun 9 ms.** The per-pixel estimate is 3-7× wrong, as it has been before | `ftComp` after the first textured wall, measured on hardware | Tile size 8×8 → 4×4; texture only one-sided segs; last resort, texture only walls within a depth threshold |
| 3 | **Multicolor cells break anyway.** Intensity-only texturing still crosses a cell boundary where two surfaces meet, and always did | The first textured frame, by eye | This is M1's risk #5 returning; the fix is the same, in `wad2reu.py`'s ramp table |
| 4 | **Sprite clipping mis-draws through openings** (§12.1's known simplification) | A sprite visible through a window in E1M1 | Accept for M2. It is a per-seg opening list in M3, which needs RAM M2 does not have |
| 5 | **Three raster frames still is not enough.** Everything lands and compute exceeds 59.85 ms | `ftHist`'s `4+` bucket leaving zero | Four frames is 12.5 fps and that is below playable. Cut sprites to a near-distance cap first, then Stage A textures on fewer surfaces |
| 6 | **The Ultimate's `404 Cannot open file` recurs** after §9.1's fix | Any `make run-u64` in a long session. Deliberately re-run 2026-08-11 — 12 `run_prg` calls in 40 s, clean — but 40 s is not a session | Then it is not upload volume, and the milestone needs a reliable reset procedure before it needs features |

## 15. Sequencing

**§9.1 first and alone.** It is a blocker, it is host-side Python, and every
subsequent phase iterates through it. §8.1's cap change lands with it, or
immediately after, so that all M2 measurement is against M2's deadline.

Then **§9.2 and §9.3** — small, self-contained, and they clear M1's debts while
the texture design is being thought about.

Then **§10 (textures)**, which is the milestone's centre of gravity and the one
whose measurement decides how much room the rest has. **Stop after Stage A and
measure on hardware before deciding whether Stage B exists.**

**§11 (doors)** is independent of textures and is the phase most likely to
finish early. **§13 (HUD)** is independent of everything and is the right thing
to pick up whenever the Ultimate is unreachable — which has happened twice.

**§12 (sprites)** last, because it is the only phase whose RAM requirement is
firm and whose budget has no fallback smaller than "draw fewer things".

The M1 lesson worth repeating in every phase: **build the instrument first.**
Three sessions in a row, the profiler or the counter or the frame timer
overturned the plan's assumption within an hour of existing, and each time the
plan's reasoning had been sound and its conclusion wrong.

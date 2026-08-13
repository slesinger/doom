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
  `wad2reu.py` actually emits. Now §9.3 — and the answer was to delete it.
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
| HUD | **In**, and landed — status bar with health/ammo/armour. **Fixed values, not live**: no code RAM for a runtime patch path, see §13.1 |
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
| Wall textures | ~~6-9 ms~~ **8.7 ms spent** | §10.4; measured on hardware 2026-08-12, §10's landing note |
| Doors and moving sectors | < 0.5 ms | §11; the renderer needs no change |
| Sprites | 6-8 ms | §12.4, dominated by REU streaming |
| HUD | **0 ms spent** | §13.1; measured, painted once at boot, nothing runs per frame |
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

### 9.2 Sliding along walls, and the two-boundary loop *(closed 2026-08-12)*

> **Done, except for one half of the second claim.** `checkMove` now projects a
> blocked move onto the seg it hit and re-tests, up to `SLIDETRY` = 3 times
> (`src/input.asm`, `slideVec`). `make walktest` is the acceptance test and it
> is green: a 20-degree run along a 704-unit wall in E1M1 covers **96% of the
> unobstructed distance** along it, and a run into a 90-degree inside corner
> ends **12 units** from the vertex without crossing a linedef. M1 would have
> scored 0% and stopped at first contact.
>
> **`pipeline.md` §5.3 is reduced, not closed, and the plan's reasoning above
> was wrong about why.** Re-descending the BSP with the *destination* cannot
> catch a second boundary: `bspFindSsec` returns the subsector that *contains*
> that point, so every one of its segs then tests as inside and the extra
> iteration is a no-op. What the iteration cap does buy is real but narrower —
> a blocked-and-slid destination is re-tested from the top, which is what makes
> an inside corner resolve against both of its walls in one frame. A move that
> passes *legally* through an opening and out through a wall of the next
> subsector is still tested only against the first boundary. Closing that needs
> a march along the motion, subsector by subsector, testing the *segment*
> old->new rather than the destination point; it is not written, and at 21
> units per frame against E1M1's subsector sizes it has not been observed.
>
> RAM: the routine is ~250 bytes and the main segment had 2. It was paid for
> out of §8.3's first lever — `reuProbe`, `clearHudRows`, `turboOn` and the
> boot sequence itself are boot-only and now assemble into MATRIX as
> `BOOTCODE3` ($5500). `make check` and `make framehash` are unchanged by all
> of it.

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

### 9.3 `data_structures.md` reconciled *(closed 2026-08-12 — deleted)*

> **Outcome: the document is gone**, and that was the reconciliation. Section
> by section, everything in it was either superseded by a frozen document or
> was describing code that no longer exists:
>
> | `data_structures.md` | Why it went |
> |---|---|
> | §1-2 `MAPBIN` container, sections, portal entries, supersectors, PVS, collision grid, `ThingSpawn` | A format the project decided against. The engine uses the WAD's own BSP, and `docs/reu-format.md` is the frozen, boot-checked container |
> | §3 LUT bank taxonomy | There is one tier and everything is in it. What exists is in `pipeline.md` §12.2, from `defs.asm` |
> | §4 sprite catalog and billboard encoding | Contradicted in detail by §12.2 below, which is RAM-aware and measured where the old text was speculative |
> | §5 frame working sets | `pipeline.md` §12.2 and §13.2 |
> | §6-7 optimisation rules, build outputs (`map.bin`, `lut.bin`, `sprite.bin`, `stream_plan.bin`) | `wad2reu.py` emits one image and `docs/reu-format.md` §8 documents what its validator checks |
> | §8 "as implemented (M1)" | `src/testmap.asm` was deleted in Phase 4 |
>
> The references in `README.md`, `pipeline.md` (the doc table, §14) and
> `docs/georam-vs-reu.md` were rewritten to name the surviving authority
> directly rather than to point through it.
>
> The memory map still has **four independent copies**: `defs.asm`, the image's
> own load-address bytes, `probe.py`'s allowed-region table, and
> `docs/reu-format.md`. The first two are cross-checked at boot and the third
> fails `make check` when it drifts; `pipeline.md` §12.2 is a fifth and is
> transcribed by hand. Nothing enforces the last two, which is why they are the
> ones that rot — deleting a document that nothing enforced is one fewer.

### 9.4 `pipeline.md` still describes the portal renderer *(found while closing §9.3)*

Not planned work — found by following §9.3's references out of the deleted
document and into the one that survives. `pipeline.md` opens with a caveat that
it describes "the *portal* renderer" and that Milestone 1 "replaces portal
traversal with a BSP walk", written in the future tense before Phase 4 landed.
That replacement happened, and these sections did not follow it:

| Section | What it describes | What is there now |
|---|---|---|
| §5 | `checkSector` over a sector's walls | `checkMove` over a subsector's segs. **Header, cost line and §5.1-5.3 reconciled 2026-08-12**; the rest of the section's math is unchanged and still correct |
| §7 | portal traversal — `renderSector`, `popLoop`, the `pStkSec`/`pStkXL`/`pStkXR` window stack | `bsp.asm`: a BSP descent with bounding-sphere rejection and `openCols` as the termination condition. **Reconciled 2026-08-12** — §7 now describes `bspLoop`/`sideOf`/`renderSsec` directly |
| §8.7 | four screen-space lines (`top`/`bot`/`btop`/`bbot`), no texture coordinate | Stage A's `u` reuses `lineSetup` rather than adding a fifth line to the layout. **Reconciled 2026-08-12** |
| §9 | flat `spanFill` only, ~11 cy/pixel | `spanFillTex` for the wall span, ~18-20 cy/pixel textured, flats unchanged. **Reconciled 2026-08-12** (new §9.1a) |
| §11 | a frame traced through the three-sector test map, checked against the live machine | `src/testmap.asm` was deleted in Phase 4. The trace is arithmetically sound and describes geometry the engine can no longer load. **Still not reconciled** — a retrace against E1M1 needs the same live-capture tooling `debug-notes/` used, which is a hardware/emulator session, not a documentation-only pass |
| §12.1 | the cycle budget, itemised, from that same test map | Replaced with the measured hardware breakdown (37.6 ms pre-texture → 46.7 ms post Stage A, against the current 59.85 ms three-frame deadline) in place of a static per-instruction count for a map that no longer exists. **Reconciled 2026-08-12**, along with §12.2 and §12.3 which were already current |
| §13's appendix | zero page and low RAM, including `pStkSec` at `$03A0` | that block is the BSP descent stack at `$0F00` |

§10 — the converter — was untouched by both the BSP change and Stage A
textures (it reads MATRIX bytes regardless of how they were painted) and was
already accurate.

**§11 is the one section left**, and it stays open for the reason the note
below originally gave: a worked-frame retrace needs real per-instruction state
captured from a live E1M1 frame, the way `debug-notes/wallwalk2.py` etc.
captured the deleted test map's — an emulator/hardware session, not something
derivable from this document alone.



## 10. Phase 8 — Textured walls

The defining feature of M2 and the one with the real risk in it.

> **Stage A landed 2026-08-12** (`f5f8d93` host side, `6618dd6` engine side).
> Hardware, `make u64-fps`: `16.63 fps (60.1 ms/frame)`, `compute 46.7 ms last,
> 46.7 min, 46.7 max (deadline 59.85 ms)`, `raster frames 3x168 4+x0 -- 100%`.
> `make check` green, `TEXCODE: 3 relocated blocks intact, 274 bytes`.
>
> **Textures cost +8.7 ms**, the top of §10.4's 6-9 ms estimate — 37.6 → 46.7 ms
> measured on the machine, not extrapolated. **13.1 ms of budget remains** for
> doors (<0.5), sprites (6-8) and the HUD (<0.5), which fits with ~4 ms of
> margin and no room for a surprise.
>
> **Stage B is therefore out of M2.** §10.2's gate was "only if Stage A measures
> well inside its budget"; it measured at the top of it. Revisit in M3, after
> §10.3's subspan divide buys back the affine-v drift and some cycles with it.
>
> Where the build differs from §10.2-§10.3 as designed, and why:
>
> | As built | Why |
> |---|---|
> | An 8-byte **lazy strip**, unpacked when u's texel index changes, not a 64-byte per-seg strip table | u is monotonic across a seg, so a column unpacks at most once. The table cost ~2048 cycles/seg (~3.2 ms/frame) for nothing |
> | u is **lineSetup's fifth line**, exact per column | `lineSetup` already computes `((v1-v0)<<8)/dx` and seeds at `c0`, which *is* u's setup — worth ~190 bytes. §10.3's subspan divide is not needed for u at all |
> | v's step is **affine per seg**, taken at mid `ry` | This is where §10.3's deferred divide actually shows: v's vertical scale drifts toward a seg's ends. v's *anchor* is exact at every column |
> | u is the seg's **dominant world axis >> 4**, no texture offset | Continuity across a BSP split for free, and no 11th byte on the seg record — §4's reverted 6-byte experiment is the standing warning |
> | The family id rides in the **low nibble of `sgRamp`**, reserved and zero through M1 | Same reason: a format bump beats widening the hottest record |
>
> **RAM, and it is the phase's real story:** 653 bytes of code against a largest
> free hole of 192. `tex.asm` is **eleven `.pc` blocks**, one per routine, all
> entered by `jsr` — the TX_* table in `defs.asm` says which hole each lands in.
> Three of them run **below `$0801`**, in the free tails of `colTop`, `colBot`
> and `COLBUF`, where a PRG image cannot load: they are `.pseudopc`'d into
> `BOOTCODE4` (`$5700`) and copied down by `texBoot`. `probe.py`'s
> **`check_texcode`** compares those three against the PRG's own images on every
> `make check`, because `diff` structurally cannot see them — they are outside
> the image, and the source copies in MATRIX are painted over by the first
> frame. A column index that ran past 159 now corrupts *code*, and this is the
> thing that would say so.
>
> Two traps, both found the hard way:
> - **`$98e4` looks like a free 28-byte hole and is `instrument.asm`'s
>   counters.** They only assemble when `INSTRUMENT = 1`, so putting code there
>   does not fail the build — it silently breaks `make stats`.
> - **`INSTRUMENT = 1` does not build**, and did not at `f5f8d93` either
>   (`doWall overflows into the BSP traversal`). Pre-existing. `make stats` and
>   `make profile` report frame times but no hit counts until the `Count` macros
>   are slimmed — which matters, because §4 says a hit count is the only honest
>   way to price the next small change.

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

### 10.6 16×16 tiles, resident *(landed 2026-08-12)*

> **Decided by the user after §14a.1a's measurement**: 16×16 keeping the
> existing sampler, rather than 32×32 with the sampler redesigned. The only
> compromise authorised to pay for it is a fourth raster frame (§14a.6), and it
> has not been needed.

`make check`, `make walktest` and `make doortest` are green. `make framehash`
is a **new** digest — the picture genuinely changes — at
`2f25c6e2350d98db2fb7b7f74845f7c1c5ae663194c1bb65924b08b2798d673d`.

**The tiles are resident, and that is the phase.** Stage A DMA'd a family's
32-byte tile per seg. A 16×16 tile is 128 bytes, and re-fetching one per seg
would be whole milliseconds of REU time at 1 byte/µs. So block 6 is read once
at boot into `WALLTILE` (`$7600`, 2 KB) by `texLoad`, and `texFetch` — which
kept its name and its callers — now writes a 16-bit address into `texCol`'s
self-modified operand instead of programming a transfer.

**The 2 KB is exactly what §14a.1 freed** and nothing had claimed: MATRIX is
28160 B and the 160-row viewport writes only the first 25600. Boot staging
reaches `MATRIX+$64ff`, so `$7600` is under neither the staging nor the live
buffer. **32 bytes of zero page came back too** — `TEXBUF` is gone, `texStrip`
is 16 bytes at `$c4`, and `$d4-$e3` is now the only free zero page in the
machine.

**Cost, measured with `make phaseprof`** (VICE, same idle spawn view):

| | Stage A 8×8 | **16×16 resident** |
|---|---:|---:|
| `renderFrame` | 2503.5 k cycles | **2658.6 k** |
| `convert` | 391.2 k | 391.6 k (untouched, as it must be) |
| compute | 2894.9 k | **3050.6 k** (+5.4%) |

+155.1 k cycles is **+2.4 ms of CPU** at 64 MHz, against which the per-seg tile
DMA that no longer happens is worth **~1.0 ms** on hardware and almost nothing
in VICE (≤33 textured segs a frame × 32 B, at 1 byte/µs — the asymmetry §4
warns about, in the direction that flatters the emulator). Net ≈ +1.4 ms on
hardware, projected at ~46.6 ms of compute against the 59.85 ms deadline.

**Measured on the Ultimate 2026-08-13, and the projection held**: `make u64-map`
(image v6 delivered intact, `mapOK=1`) then `make u64-fps` —

```
fps: 167 frames in 10.04 s = 16.63 fps (60.1 ms/frame)
frame: compute 47.7 ms last, 46.7 min, 47.7 max (deadline 59.85 ms)
frame: raster frames 1x0 2x0 3x168 4+x0 -- 100% made the 16.7 fps deadline
```

46.7-47.7 ms against a 46.6 ms projection — the cost model of §14a.1a
(`ms ≈ cycles/64e6 + 1 µs per DMA byte`) predicted this phase to within a
millisecond. **The fourth raster frame was not needed and stays in reserve**,
and ~12 ms of the deadline is free for §12's sprites. This run also confirms
§14a.1's 160-row cut on hardware for the first time.

Where it differs from what §10.2-§10.3 would have predicted:

| Expected | What is there |
|---|---|
| a finer tile costs about the square of the ratio | It cost **+5.4% of compute**, because residency paid ~1 ms of it back. The strip machinery is unchanged: `texCol` unpacks 16 texels instead of 8, `texUpd` fires about twice as often |
| the sampler needs a redesign for anything past 8×8 | Not at 16×16. §14a.1a sized `texCol`/`texPix` at under 2% of compute, and quadrupling a 2% is affordable in a way quadrupling a 20% would not have been — which is the whole reason that measurement came first |
| `u` needs a shift to become a tile column | **`accU & $78` is the column's byte offset already**: a texel is 8 world units and the tile is 16 wide, so bits 3-6 left in place are `((u>>3)&15)*8`. Three bytes saved at each end, and TX_COL's hole is 27 bytes, which is what forced the question |

**The open question is the texel scale, and it is a look judgement.** The build
above is **8 world units per texel** — a 128-unit repeat, i.e. a Doom wall
texture at its native world scale, and half Stage A's texel size. An earlier
session recorded exactly that density as reading like *noise*, on the grounds
that `chunky2mc`'s 4×4 Bayer dither is the detail floor and a finer texel only
beats against it. That finding was made at 32×32 and is not automatically true
here, but it is the reason to look at this on hardware before believing the
picture.

The coarser alternative is **16 units per texel** — a 256-unit repeat, the
texture at 2× world scale, which buys *variety along a long wall* rather than
detail and cannot beat against the dither. It is three constants in
`src/render/tex.asm` and nothing else:

| | 8 units (built) | 16 units |
|---|---|---|
| `texUpd` | `and #$78` | `and #$f0` + `lsr` |
| `texVSet` shift | `ldx #5` | `ldx #4` |
| `texVSet` step | `13107` (ry/5) | `6554` (ry/10) |

**Settled 2026-08-13: keep 8 units, and the oracle question was the real
mistake.** The earlier "reads as noise" finding was made against `u64shot.py`
and `shot.py`-style *chunky* dumps, which render the `%rrrriiii` buffer at full
16-shade precision — a view in which a fine texel really does look like
per-pixel hash, because nothing has quantised it yet. The picture that matters
is the VIC's, and `make shot` (`-exitscreenshot`) is exactly that: post-dither,
post-attribute, and deterministic, so the emulator's PNG is the hardware
picture. Compared that way the 8-unit and 16-unit builds differ only slightly —
8 units gives finer vertical banding on E1M1's yellow panels, 16 units a
broader roll — and neither disintegrates into noise. The dither does not beat
against the texture, because both tile axes are powers of two on a 4×4 Bayer
grid: they phase-lock rather than moiré. 8 units also keeps the texture at the
scale the artist drew it, so it stays.

Two traps, both the same shape as §11.4's and §13.1's:

1. **`TX_COL` is a 27-byte hole between two other blocks**, not the 46 bytes
   `defs.asm`'s table implies — `lines: the use fetch` starts at `$cdf5`. The
   first version overflowed by two bytes and the assembler named the collision,
   which is the mechanism working.
2. **`texCol`'s self-modified operand lives inside the PRG image**, so
   `make debug` reports it as a runtime write into code — one unexplained byte
   at `$cddf`, which is exactly the signature of the corruption this check
   exists to find. It is declared in `probe.py`'s `ALLOWED` now, **derived from
   `txColBase` in the symbol file** rather than written as a constant, because
   TX_COL moves whenever the bin-packing does and a stale address there would
   silently stop covering the block.

### 10.7 Colour: five ramps claimed, and §10 closed *(2026-08-13)*

**A tile modulates the intensity nibble and never the ramp**, because a VIC
multicolor cell has one three-colour palette and `chunky2mc`'s converter picks
it from a single sample pixel per cell (`MATRIX + 13` — row 3, px 1). That is
not a limitation of the sampler and cannot be bought off with cycles: a
per-texel ramp would put four palettes in a 4-pixel-wide cell and lose three of
them, which is attribute clash, not detail.

So the material's *colour* can only come from the ramp the seg already carries
— and that is where the slack was. Ramps 9-15 were duplicates of stone, while
E1M1's 32 wall texture names shared six ramps: STARTAN sat on WOOD with the
browns, every door on METAL with its own jamb, the computer banks on SKY with
the flat blue screens. Five of the spares are now real materials:

| | ramp | colours | takes |
|---|---|---|---|
| 9 | tan | brown grey lgrey | STARTAN1/3 |
| 10 | slime | green yellow lgreen | NUKE24, SLADWALL, NUKAGE3 |
| 11 | tech | blue grey white | COMPTALL, COMPUTE2, COMPSPAN |
| 12 | door | dgrey orange lgrey | BIGDOOR, DOOR3, EXITDOOR, SW1STRTN |
| 13 | lite | orange yellow white | LITE3, EXITSIGN, TLITE6 |

Wall segs now spread over ten ramps — `stone:220 tan:112 wood:112 moss:105
metal:58 sky:52 lite:25 tech:21 slime:15 door:12` — where they spread over six.
**This costs nothing at runtime**: `ramps` is a KickAss table built at assembly
time, `scrTab`/`colTab` are already 256-byte lookups, and the seg record's ramp
nibble was always there. No cycles, no bytes, no new code path. It is the whole
answer to "textures modulate intensity only", and it is the one that fits the
hardware rather than fighting it.

Two things learned while picking the colours, both cheap to get wrong:

- **VIC "light blue" (`$e`) is violet in Pepto** (120,105,196). The first tech
  ramp used it and the computer banks came out purple. `make shot` showed it
  immediately; a chunky dump could not have.
- **A ramp that duplicates another is worse than a spare**, because it spends a
  material slot to say nothing: dgrey/grey/white for tech would have been METAL
  exactly. Ramps 14-15 stay stone duplicates, unclaimed and honest.

Also closed here:

- **Unknown wall textures now land on a family, not on nothing.** `TEX_PLAIN`
  meant two different things — "the WAD put no texture on this sidedef" (177 of
  E1M1's 732 segs, a fact about the map) and "our table does not know this
  name" (our gap). The first stays untextured; the second falls back to
  `TEX_FALLBACK` = family 2, STARTAN3, the nearest thing E1M1 has to a generic
  panel, and `--report` still counts it as a miss. E1M1 itself has no misses;
  this is what makes a second map degrade gracefully instead of flat.
- **Per-seg texture offsets stay out** by decision — at 160×160 with a 4×4
  dither, alignment at a wall's own seam is below what the display resolves,
  and carrying an offset means widening the hottest record in the engine (§4).
- **Floors and ceilings stay flat**, and the reason is structural rather than
  budgetary. There are no horizontal spans in this renderer: `doWall`'s column
  loop fills ceiling and floor as *vertical* runs of one constant byte
  (`zCeilByte`/`zFloorByte`, `spanFill` in `math.asm`). A textured flat needs
  the opposite rasterizer — horizontal spans, one division per screen row for
  depth, and a 2D u/v walk per pixel — i.e. visplanes, which §8 put out of M2.
  Confirmed by reading the code, not inherited from the §8 table.

**§10 is closed.** Walls are textured, measured on hardware at 46.7-47.7 ms of
a 59.85 ms frame, and the picture is `c1dd1bb3…`. Next is §12, sprites.

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

### 11.2a What replaced §11.2, and why *(decided 2026-08-12)*

Two of §11.2's five items dissolved once E1M1's specials were counted, and the
third was decided by RAM rather than by design.

**E1M1 has 19 special lines out of 475**, and eight of those are scrolling-wall
specials that move no sector. **Eleven lines do something**: 8 DR doors, 1 WR
lift, 1 W1 floor, 1 S1 exit. So:

- **Item 2, the seg → linedef reference, is not needed at all.** Neither the
  11th byte on the seg record nor the geometry search: the whole special set is
  resident, and activation runs against the *lines*, never against a seg.
- **Tags and target heights are resolved in `wad2reu.py`**, not at runtime.
  Doom scans every sector for a tag and every neighbour for a height; the
  engine has neither a tag array (SECTAB has no room) nor any adjacency. Both
  are exact for M2 and stop being exact when two thinkers can act on
  neighbouring sectors, which is M3's problem and is noted in the format doc.
- **Activation is sector-based, not geometric.** The use key takes the point
  `USERANGE` units ahead of the eye and fires the door whose sector that point
  is in; a walkover fires when the player's `camSec` becomes a line's trigger
  sector. Doom's own test — does the motion segment cross the line, four cross
  products per line — was written and then not shipped: it needs ~660 B of code
  against **640 B of RAM under I/O, which is the whole budget** (below). What
  it costs is fidelity at the edges: a trigger fires on entering the sector
  rather than on crossing the exact line, and in principle a door could be used
  through a thin wall. **Logged for M3**, next to §12.1's per-seg opening list,
  which is deferred for exactly the same reason.

**The RAM this phase runs in is new, and it is the largest free block left.**
`$DB40-$DBFF` (192 B, the tail of `NODETAB`'s page), `$DE40-$DEFF` (192 B,
after `SECTAB`) and `$DF00-$DFFF` (256 B, under the REU's own registers) — 640
bytes that M1 and Phase 8 never touched, against the ~90 bytes of low RAM
`tex.asm` left in ten fragments. Both the tables and the code live there.

Putting *code* under I/O is not a stunt: every routine in the phase reads or
writes sector heights at `$DC00`, which only exist with `$01 = BANK_RAM`, so
the whole feature had to bank anyway. Two consequences that are easy to get
wrong and are written into `src/lines.asm`'s header:

1. **The window must be `sei`'d, not merely survived.** With I/O banked out the
   music IRQ writes its SID registers into the RAM underneath them — silently.
   The CIA latch keeps running, so the tick is late, never lost.
2. **Code under I/O cannot call code that touches I/O.** Unbanking to reach the
   REU would make the calling code itself disappear. So anything needing a DMA
   — fetching the player's subsector for the use scan — happens in the
   trampoline, before the bank switch.

### 11.3 The one thing to watch *(closed 2026-08-12 — not an issue)*

**A door that closes on the player.** Doom's answer is to reverse the door;
without it, `checkMove`'s headroom test starts failing every move and the player
is stuck inside geometry with no way out. Handle it in the thinker — if the
player's subsector is the moving sector and the headroom would drop below 56,
reverse — not in the collision code.

> **Not built, and the user has decided that's fine.** E1M1's DR doors reopen
> on use, which is the escape in practice, and play-testing on hardware found
> no case where it mattered. Not scheduled for M3 either unless it actually
> bites.

*Done when:* the E1M1 start-room door opens on use, closes behind you, and the
first lift runs; `make framehash` differs between open and closed and is stable
in each state; `make debug` is clean across a scripted walk that triggers both.

### 11.4 How it landed *(2026-08-12)*

Green on `make check`, `make walktest` and the new **`make doortest`**, which
judges the phase against SECTAB rather than against a picture: a door opens to
its target, holds, and returns; a lift fires on entering its trigger sector; a
use press in another room moves nothing. `make framehash` is **unchanged at
`27f1774c…`** — the renderer genuinely never learned what a door is (§11.1).

Where it differs from §11.2, beyond §11.2a's sector-based activation:

| §11.2 said | What is there |
|---|---|
| the thinker reverses a door closing on the player | **not built, and closed as a non-issue (§11.3)** — E1M1's DR doors reopen on use, which is the escape, and play-testing found nothing to fix |
| — | the whole feature is in the **640 bytes under I/O**, code included, so its three blocks are `.pseudopc` images copied by `lineBoot` (BOOTCODE5). A block at `$dbd0` would extend the PRG over `$d000-$dfff` and make *loading* it a 4 KB write across the I/O space |
| — | the image header grew **64 → 128 bytes**; block 7 was the eighth descriptor and seven is all the old header held (`mapErr=4`) |
| — | `IN_USE` is bit 4 because that is both joystick fire's bit in `$dc00` and SPACE's in keyboard row 7, and `IN_SLEFT` is bit 6 because that is Q's — row 7 became a mask with no branches, and the use key cost **−2 bytes** |

Three traps, all of which cost a debugging pass and are commented where they
bite: `lnHPtr` must preserve X (both callers hold a thinker index in it);
`segFacing` reloads X from `zWIdx`, so a caller's cursor has to live there; and
`ldx` sets Z, which silently inverted the use key's edge test.

**`segFacing` tests which side of the seg the player is on, not where they are
looking**, so a door sharing their subsector opens whichever way they face.
That is the visible price of §11.2a; M3's geometric line test is what removes
it.

**Frame cost, measured idle 2026-08-12.** `make u64-fps` (20 s window):
`fps: 334 frames in 20.04 s = 16.67 fps (60.0 ms/frame)`,
`compute 34.5 ms last, 15.2 min, 70.0 max (deadline 59.85 ms)`,
`raster frames 3x334 4+x1 -- 100%` on deadline, one frame flagged by the
tool's own diagnostic as the residual one-time post-reset housekeeping cost
rather than the engine. **Doors cost effectively nothing measurable** —
compute is at or below §10's 46.7 ms baseline, consistent with §11.1's claim
that the renderer never learned what a door is. ~13 ms of budget remains
for §12 sprites and §13 HUD, unchanged from §10's estimate.

Three back-to-back readings taken in the same session ranged from 100% down
to 88% on deadline, with the 4+-raster-frame outlier count climbing each time
rather than settling — likely repeated `run_prg` calls in quick succession
degrading the connection, the same shape as the §9.1 upload-load risk, not a
property of the engine. The first, cleanest reading is the one recorded
above; treat repeated measurements taken close together as suspect until
spaced out.

## 11a. Jumping *(added 2026-08-12, out of sequence)*

Not in the M2 scope and built anyway, because it is the cheapest way left to
make the world read as three-dimensional: everything else the engine does to
sell depth — the walls, the shading, the textures — moves when the *player*
turns, and nothing until now moved when the world stayed still. Forty-two
bytes of code and two of zero page.

**SPACE, the key that already opens doors.** `IN_USE` is a level here, not an
edge (`lines.asm` keeps its own edge for the door), so holding it bunny-hops
and a held key still opens a door exactly once.

**The arc is a table, not physics.** `jumpTab` is seven bytes of eye height
above the floor and an `$ff`; `jumpStep` walks it one entry a frame. A
velocity and a gravity would have cost more code, a second zero-page byte, and
— the reason it was not done — a peak at the mercy of rounding. Nothing in the
renderer or the collision test stops the eye rising through a ceiling, so
`EYE + JUMPPEAK = 69` against E1M1's lowest openings (72) is the whole safety
argument, and it has to be exact.

**`setEyeZ` is the only place that reads `camJZ`**, which buys two behaviours
for no bytes: the eye follows a moving floor while airborne, and `stepOK`'s
step test — `zBackF + EYE`, i.e. the step measured *below the eye* — sees a
ledge as `camJZ` shorter, so a jump climbs anything within `MAXSTEP + camJZ`.
Ledge-jumping was not implemented; it was already there once the eye moved.

**Where the 43 bytes came from**, since §8.3's hunt had already spent the low
RAM: the code is in three fragments (`JUMPCODE`, `JUMPCODE2`, `JUMPTAB` in
`defs.asm`). `playerFrame` (17 B at `$0eef`) was paid for by moving `TX_CLIP`
into `TX_SHADE`'s slack and nudging `TX_UADV` two bytes up into the four it was
wasting below `$d000`; `jumpTab` fits `SSECHDR`'s tail hole; and `jumpStep`
runs at `$ffe4`, in the 22 bytes between the music IRQ handler and the CPU
vectors. `mainLoop` calls `playerFrame` in place of `movePlayer`, which is why
the main segment's last free byte is still free.

**`jumpStep` cost a lesson as well as 18 bytes.** It was first put at `$0f40`,
read off the memory map as the gap between the BSP stack and `BFACECODE`. It is
not a gap: `$0f40-$0f50` is `frameCnt`, `reuScratch` and the map checksums, so
boot overwrote the routine and the jump silently did nothing on a build that
was green — the `.errorif` guards only prove a block does not overlap the
*next* block, never that the address is unowned. The fix is the relocation
pattern `LINECODE*` and `MUSCODE` already use: assemble with `.pseudopc`, copy
up in `lineBoot`, and let `probe.py`'s relocated-block check (`make check`)
compare live RAM at `$ffe4` against the image every run. That check is what the
`$0f40` version did not have, and it is the reason this class of bug is now
caught rather than played around.

`make jumptest` judges it against the table in the source rather than against
a picture: the eye must walk the arc, clear the ceiling, and land.

## 11b. The walk bob *(added 2026-08-12, out of sequence)*

Doom's up-and-down while walking, for the same reason the jump was built: it
moves the world when the player does not turn. **23 bytes, no zero page, no
table.**

**The wave is computed, not looked up.** `bobStep` takes the low three bits of
`frameCnt`, reflects them at 4 and doubles: `0 2 4 6 6 4 2 0`, one entry per
frame — a triangle, which at four samples up and four down is the same picture
as a sine. Eight table bytes plus the load would have cost 17 against the
arithmetic's 12, and 23 is exactly what the hole holds. Eight frames is 0.48 s
against Doom's 20-tic 0.57 s, and `BOBPEAK` is 6 units against Doom's ±8.

**Upward only, because `camJZ` is unsigned**: `setEyeZ`'s first add is what
carries into the sector floor, and a signed offset would need a sign-extended
16-bit add in a block that ends against `$d000` with nothing spare.

**The phase is `frameCnt`, not frames-spent-walking**, which would have cost a
zero-page byte and two instructions there was no room for. The bob therefore
picks the wave up wherever it is instead of starting from zero — invisible at
0.48 s. It runs off `IN_MOVE` (the four translation bits), so turning on the
spot leaves the eye still, and it bobs when walking into a wall, as Doom's
does, because Doom bobs on the command and not on the displacement.

**Where the 23 bytes came from.** `$83e8`, the 24-byte gap behind SCREEN0's
video matrix, was the last hole in the machine wide enough — the largest run
left below `$d000` after it is 20 bytes. `wallSpan` had it (`TX_WSPAN`, 13
bytes in 24) and moved into `TX_SEED`'s tail in COLBUF, which is a pure
address change: every texture block is entered by `jsr` or `jmp`.

**It cost one real bug, found by its own test.** The bob test walks and reads
`zInput` back, and `zInput` was `$8f` — which is also `zNum+1`, and `checkMove`
writes `zNum` twice per seg per attempt. So walking overwrote the input byte
with the high byte of a cross product *before* `playerFrame` and `lineFrame`
read it: `IN_USE` landing in there at random is why walking around fired jumps
and opened doors nobody had asked for. `zInput` is `$90` now, which `msLast`
stopped using when the pacing moved to `msFrame`. The lesson is §11a's again in
another key — a `.const` proves nothing about ownership, and only a test that
reads the byte back while the engine is running can tell you who else has it.

`make bobtest` judges the eye against the wave from `defs.asm`'s `BOBPEAK`
rather than against the machine: it must trace the triangle unbroken while W
is down, and be perfectly still while standing or only turning.

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

## 13. Phase 11 — The HUD *(landed 2026-08-12 — see §13.1)*

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

### 13.1 How it landed *(2026-08-12)*

Green on `make check`, and **confirmed on hardware by the user** — the bar
renders, three plausible numbers in roughly Doom's layout. `make framehash`
is **unchanged at `27f1774c…`**, and
that is a real result rather than a coincidence: the digest covers MATRIX, the
renderer's own chunky buffer, and the bar is blitted straight into
`BITMAP0`/`BITMAP1` below the 22-row viewport. The renderer has no idea the
HUD exists, which is the whole point of doing it at boot.

Where it differs from §13's four bullets:

| §13 said | What is there |
|---|---|
| draw once, **patch digits on change**, a dirty flag per field | **not built.** Code RAM is at or near zero in every hole that matters (main segment, `JUMPCODE`, `LINECODE3`, zero page — the `.errorif` guards say so), so a runtime patch path would have needed its own byte-hunt first. The bar is painted **once**, from fixed values. §13's "changing a health variable over the monitor updates the display" is **not met**, deliberately |
| values wired to variables | **done, and it is the part that survives.** `hudHealth`/`hudArmor`/`hudAmmo` are real bytes, read once by `hudBoot`; M3 makes them live and calls the redraw again, rather than redesigning a pipeline |
| a digit font of 12 glyphs | 10 (`STTNUM0`..`9`). No face frames — §13 calls them optional |
| — | the entire feature is **boot-only code in MATRIX** (`BOOTCODE6`, `$5c40-$6008`) plus two streamed REU blocks. It costs the resident build **3 bytes** of RAM, the three values |

Four traps, in the order they cost a pass, and all four were found by diffing
live memory rather than by looking at the screen:

1. **`convert()`'s dither chain cannot be transliterated to indirect
   addressing.** It accumulates four pixels into A across three `ora`s, and
   gets each pixel into Y with `ldy MATRIX+s*4+j,x` — absolute, so A survives.
   Writing that as `ldy #s*4+j / lda (zHudSrc),y / tay` quietly destroys the
   accumulator between the `ora`s; every packed byte came out as the last
   pixel's *source value* ORed with its own dither code. `hudBlitCell` copies
   the cell into a fixed 32-byte buffer first and keeps the absolute
   addressing.
2. **A block's staging address must not assume descriptor order.** The HUD
   blocks are 8 and 9 but `LINEDEFS` (7) is emitted after them, and `lineLoad`
   stages through `MATRIX+0` — so the bar's first cells were raw linedef
   records. HUD staging moved to `$6100`, in the MATRIX tail nothing else
   claims.
3. **`$07e8` was not dead RAM.** §8.3 is right that COLBUF's tail past what
   `flip` copies back is never read, but `$0770-$07ff` is `TX_SEED`, and
   tex.asm's 137 relocated bytes reach `$07f8`. `texBoot` runs *after*
   `bootMain` writes the placeholders and copied `wallSpan` over the top; the
   bar drew AMMO **180** from two opcodes. The three values are at
   `$07fd-$07ff` now and `TX_SEED_END` is pulled down to `$07fd` so the
   collision is a build error by name.
4. **`hudBlitCell` clobbers X** (its `scrTab`/`colTab` sample lookup), and
   `hudBoot`'s background loop was counting in it. The count now lives in
   `zHudCnt`. This is the same class as §11.4's `lnHPtr`/`segFacing` traps.

Two asset findings, both measured off a live bitmap dump rather than judged
from a screenshot (`docs/reu-format.md` §4.9 has the detail): a 1-cell digit
is an illegible blob and 2×2 cells are the minimum that reads, and the HUD
must **not** be ordered-dithered — intensities are snapped to the four values
that are fixed points of `chunky2mc.asm`'s `dcode()`, or the bar comes out a
speckle with the digits a shade lost in it.

**Frame cost, measured idle 2026-08-12** (20 s window):
`compute 49.7 ms last, 28.4 min, 49.7 max (deadline 59.85 ms)`,
`raster frames 3x335 4+x0 -- 100%` on deadline, with the tool's own
`every frame's compute fits in 3 raster frames` verdict and **no outlier
warning at all** — the first §12-era reading with a completely empty `4+`
bucket. **The HUD costs nothing measurable**, which it cannot: `hudBoot` runs
once from `bootMain`, the per-frame path is untouched, and the framehash is
bit-identical. ~10 ms of budget remains for §12 sprites.

§11.4's warning about back-to-back readings earned its keep again, and the
shape is worth pinning down because it wasted a pass here: the first three
runs of the session gave 90% and 92% on deadline with `compute` climbing run
to run (76 ms, then 96 ms), and **raising `WARMUP_SECONDS` to 60 did not help
— it made it worse**, because the problem is not post-reset housekeeping, it
is how recently the previous `run_prg` was. Four minutes of quiet between
runs is what produced the clean number above. Treat any reading taken within
a minute or two of a previous upload as noise, and do not try to warm your way
out of it. (`WARMUP_SECONDS` is an environment override in `u64push.py` now,
because the tool's own warning tells you to raise it and there was no way to —
useful, just not the lever this needed.)

One more `u64-fps` trap, which cost the first attempt entirely: **the target
does not push the REU** (`--reu` is commented out in the Makefile, on
purpose). After changing `assets.reu`, `make u64-map` first, or the engine
halts on a stale image and the tool reports `frame counter never advanced`.

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
free**. Doors measured at effectively nothing (§11.4) and the HUD has landed,
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

### 14a.1 Viewport height *(landed 2026-08-12: 176 → 160)*

> **Agreed 2026-08-12: 176 → 160 rows, and no further for now.** The taller
> cuts are listed because they are the same edit with a different constant, not
> because they are scheduled. **160 is to be built and looked at first**; 144
> is reconsidered only if the letterbox turns out to read as deliberate rather
> than as a smaller game.
>
> **Built.** The four constants: `math.asm`'s `rowCellLo/Hi` table (22 → 20
> entries) and `spanPrep`'s row clamp/bound (177/176/22 → 161/160/20);
> `bsp.asm`'s `colBot` init (176 → 160); `walls.asm`'s column-close value
> (176 → 160); `chunky2mc.asm`'s `pageCnt` (110 → 100 pages, i.e. 880 → 800
> cells) and `flip`'s color-RAM burst copy (880 → 800 bytes). `clearHudRows`
> grew to blank rows 20-24 in one pass instead of 22-24 — rows 20-21 are the
> letterbox the shorter viewport opens up, and without a boot-time clear they
> would show whatever the boot-staging blocks left in that part of MATRIX's
> chunky buffer rather than a clean black bar (the bitmap-only clear is exact
> to `BITMAP0`'s 8000-byte end, so it can't spill into `TX_UENDS` just past
> it). `checkshot.py`, `u64shot.py` and `framehash.py` all updated to the new
> 160-row/25600-byte buffer.
>
> `make check`, `make walktest` and `make doortest` are all green, unchanged
> in substance. `make framehash` is a **new** digest, expectedly — the frame
> genuinely differs — at `398eb98fea794c1b97486a292c943f4e222e9b2d8d2f71a37d0385d04059879e`
> over 25600 bytes, 100% non-zero (the old hash's buffer included 2560 bytes
> the renderer never wrote, past `MATRIX_LEN`, that never asserted anything).
> `make shot` shows a visible but thin black bar between the 3D view and the
> HUD — the look judgement this section deferred to hardware. **Not yet
> measured on real hardware**: no network path to the Ultimate from this
> session. §10.2's called-for `profile.py` checkpoint on `chunky2mc`'s own
> share of the frame — the number this section says is needed before judging
> whether the pixel-work saving tracks the row percentage — is still open,
> and so is the RAM side: the freed 2560 B tail of MATRIX (past the new
> 25600-byte live buffer, inside the old boot-staging region up to
> `MATRIX+$6e00`) is free for code once the first frame has run, but nothing
> has claimed it yet.

#### 14a.1a `chunky2mc` priced, and the height cut measured *(2026-08-12)*

> The measurement this section called "the cheapest one in this section" —
> and it says the height cut returned **a quarter of what the row percentage
> predicted**.

The instrument is new: **`make phaseprof`** (`tools/vicedbg/phaseprof.py`).
A *stopping* exec checkpoint on each of `mainLoop`'s eight `jsr` targets, and
the engine's own CIA millisecond clock read at every stop. A monitor stop costs
no emulated time, so the phase boundaries are exact rather than sampled, and at
VICE's 1 MHz one tick is exactly 1000 cycles — the reading is a cycle count in
disguise. `profile.py` answers *how many times*; this answers *for how long*.

**It carries its own positive control**: the phases it calls compute sum to
2894.9 ticks against the engine's own `ftComp` of 2895, which is arithmetic the
tool and the engine do independently, from the same clock, at different points.

| Phase | 176 rows (`f9f7cb5`) | **160 rows (`0df949a`)** | Δ |
|---|---:|---:|---:|
| `renderFrame` | 2535.5 k cycles | **2503.5 k** | −1.3% |
| **`convert`** (chunky2mc) | 430.4 k | **391.2 k** | **−9.1%** |
| `flip` | 18.0 k | 10.6 k | (mostly raster wait) |
| input + `playerFrame` + `lineFrame` | 0.5 k | 0.1 k | — |
| **compute** | **2966.4 k** | **2894.9 k** | **−2.4%** |

**So `chunky2mc` is 391.2 k cycles = 13.5% of compute = 6.1 ms of a hardware
frame**, and the cycle count travels: it touches no REU and no I/O, so its
share is the same share at 64 MHz. The cost model that falls out of the two
readings — hardware ms ≈ cycles/64e6 + one µs per DMA byte — predicts 46.4 ms
of CPU at 176 rows against §10's **46.7 ms measured on the machine**, i.e.
emulator cycles and hardware agree to a few percent, which is what makes the
table above usable as hardware numbers without another trip to the Ultimate.

**The height cut is worth ~1.1 ms on hardware, not the ~4 ms −9% implied.**
`convert` returned its row percentage exactly, as it must — it is a fixed
number of cycles per cell over 800 cells instead of 880. `renderFrame` did
not, and that is the finding: the renderer's cost is dominated by per-seg and
per-column work (the multiply chain is 7485 `mul8` calls a frame, the divides
434) rather than by the spans the rows remove. **A further cut to 144 rows
would buy roughly another 1.1 ms, not 4** — which changes §14a.7's arithmetic
materially, because that combination was priced at the pixel percentage.

Two smaller things the run recorded, both wanted by §10's Stage B question:
`convert` costs **489 cycles/cell**, not the ~415 the file header claims (the
`ldy MATRIX+s*4+j,x` reads cross a page about half the time); and the Stage A
strip rebuild is **156 `texCol` / 1248 `texPix` calls a frame**, ~56 k cycles,
under 2% of compute. That last number is the one that sizes a finer tile:
`texPix` runs once per *texel* of every rebuilt strip, so tile height
multiplies the rebuild and tile width multiplies how often it happens.

`176` is 22 cell-rows and appears in **four places**: `math.asm`'s `rowCell`
bound, `bsp.asm`, `walls.asm`'s column close, and `chunky2mc.asm`'s header. A
contained edit, not a rewrite.

| Height | MATRIX | RAM freed | Pixel work |
|---|---:|---:|---:|
| 176 (22 rows, now) | 28160 | — | — |
| **160 (20 rows)** | **25600** | **2560 B** | **−9%** |
| 144 (18 rows) | 23040 | 5120 B | −18% |
| 128 (16 rows) | 20480 | 7680 B | −27% |

The RAM freed is **contiguous, above `$0801`, and can hold code** — a
categorically better resource than the ten fragments every phase since §10 has
fought over. The boot-staging blocks at `MATRIX+$4000…+$6e00` (BOOTCODE*,
`HUDBG_STAGE`, `HUDFONT_STAGE`) still work at boot either way; everything past
the new MATRIX end becomes permanent free RAM once the first frame has run.

**The measurement this needs first**, and it is the cheapest one in this
section: **`chunky2mc`'s share of the frame is not recorded anywhere.**
`spanFill` is ~27% and textures are 8.7 ms measured, but the conversion pass is
unpriced, and it decides whether a height cut returns roughly its pixel
percentage or rather less. A `profile.py` checkpoint, per §4 — every session in
§6 that skipped this step had sound reasoning and the wrong conclusion.

**What it costs:** a letterboxed view. Doom's own 320×200 view is 168 rows under
the status bar, so 176 was already generous. This is a look judgement and it is
deliberately being made by eye, on hardware, rather than by this table.

### 14a.2 Resident downsampled sprites, instead of streamed *(open, recommended)*

§12.4 says sprite cost is **dominated by REU streaming** — 5-8 sprites × 512 B
= 2.5-4 ms of the 6-8 ms estimate. But M2's sprites are static props and there
are few *distinct* ones. At **16×16 4-bit = 128 B**, eight props is **1 KB
fully resident** and the streaming cost goes to zero, taking the phase to
plausibly 2-3 ms.

This is precisely §10.2's Stage A argument applied to §12, and Stage A shipped.
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

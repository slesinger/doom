# `assets.reu` — the map image format

**Frozen 2026-08-09.** This is the interface between `tools/wad2reu.py` (which
writes it) and `src/mapload.asm` + `src/render/bsp.asm` (which read it).
`IMPLEMENTATION_PLAN.md` §7 asks for this to be written down before either side
is built, because the two halves are developed independently and a mismatch
shows up as garbage on a C64 screen three layers from the bug.

Everything here is little-endian, matching the 6502 and the WAD itself.

| | |
|---|---|
| Produced by | `tools/wad2reu.py` → `build/assets.reu` (`make assets`) |
| Delivered to hardware by | `machine:writemem` + `src/reuload.asm` (`tools/u64push.py --reu`) — **not** REU Preload, see §9 |
| Delivered to VICE by | `-reuimage build/assets.reu`, with `-reusize` matching the padding (§9) |
| Consumed by | `mapload.asm` at boot (resident blocks), `bsp.asm` per frame (subsector slots) |

---

## 1. Why the shape is what it is

Three constraints drove every decision below.

**REU DMA is 1 byte/µs, flat, and does not scale with the turbo clock**
(`IMPLEMENTATION_PLAN.md` §10). There is no per-transfer setup penalty, so many
small transfers cost the same as few large ones — but every byte transferred
halts the CPU for a microsecond. So the format optimises for *fetching few
bytes*, not for *fetching them in few transfers*.

**Zero page and low RAM are the scarce resources, not REU space.** 16 MB of REU
against under 2 KB of contiguous free RAM. Anything that trades REU bytes for
RAM bytes or for 6502 instructions is a good trade, and this format takes that
trade three times (§4.3, §5).

**Arrays the 6502 indexes with a single `X` must be ≤ 256 entries.** Every
resident table below is structure-of-arrays with a capacity of 240 or less, so
every access is a flat `lda table,x` with no 16-bit address arithmetic. This is
the same reason the hand-built test map was SoA before it was deleted.

---

## 2. Header

At REU offset `$000000`, 64 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic, ASCII `D64U` |
| 4 | 1 | format version — **1** |
| 5 | 1 | block count `N` |
| 6 | 2 | reserved, zero |
| 8 | 8×`N` | block descriptors |

`mapload.asm` rejects the image if the magic or the version does not match,
recording why in `mapErr` and leaving `mapOK` at 0. **As of Phase 4 that is
fatal**: the map is the only thing there is to draw,
so `main.asm` stops with `mapErr` in the border colour rather than rendering
whatever happens to be in RAM. `make check` and `make u64-map` still assert
`mapOK == 1` as well. That check is not paranoia: this project has already lost a
session to a silently absent REU (`IMPLEMENTATION_PLAN.md` §10), and a stale or
undelivered `assets.reu` fails the same way — every read succeeds and returns
the wrong thing.

### Block descriptor (8 bytes)

| Offset | Size | Field |
|---|---|---|
| 0 | 1 | block id (§3) |
| 1 | 1 | flags — bit 0 = resident (load at boot) |
| 2 | 3 | REU offset, 24-bit (lo, hi, bank) |
| 5 | 2 | length in bytes |
| 7 | 1 | load address **high byte**; 0 for non-resident blocks |

Resident blocks always load at a **page-aligned** C64 address, which is why one
byte is enough for the destination and why the boot loader is a single loop over
the descriptors rather than a hand-written sequence of transfers.

The load address is in the image *as well as* in `defs.asm`. That is deliberate
duplication: `mapload.asm` asserts the two agree and halts if they do not, so a
format change that outruns the engine is caught at boot instead of rendering
wrongly. `tools/vicedbg/probe.py`'s allowed-region table is a third copy of the
same map, and it has already been out of date once (`IMPLEMENTATION_PLAN.md` §9).

---

## 3. Blocks

| id | Name | Resident | Loads at | Size (E1M1) |
|---:|---|---|---|---:|
| 0 | `MAPINFO` | yes | `$0E00` | 32 B |
| 1 | `NODES` | yes | `$D000` | 2880 B |
| 2 | `SECTORS` | yes | `$DC00` | 576 B |
| 3 | `SSECDATA` | no — streamed | — | 30336 B |

Resident total: **3488 B**, of which 3456 sit under the I/O space (§6).

Blocks are stored in the image in id order, each padded to a 256-byte boundary.
Padding costs REU space, which is free, and makes every block's offset
inspectable in a hex dump, which is not.

---

## 4. Resident block layouts

### 4.1 `MAPINFO` — 32 bytes at `$0E00`

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | `numNodes` |
| 2 | 2 | `numSubsectors` |
| 4 | 1 | `numSectors` |
| 5 | 1 | `ssecStrideShift` — **7**, i.e. a 128-byte slot (§5) |
| 6 | 3 | `ssecReuBase`, 24-bit REU offset of `SSECDATA` |
| 9 | 2 | `rootNode` — node index the BSP walk starts from |
| 11 | 2 | `spawnX` |
| 13 | 2 | `spawnY` |
| 15 | 1 | `spawnAngle`, engine convention (§7) |
| 16 | 2 | `spawnSsector` — the subsector the tool computes for the spawn point |
| 18 | 1 | `spawnSector` |
| 19 | 2 | `numSegs` |
| 21 | 1 | `mapId` — 0 = test map, 1 = E1M1 |
| 22 | 10 | reserved, zero |

`spawnSsector` is redundant — the engine's own BSP descent will find it — and
that is the point. `main.asm` compares the two at boot and halts with
`mapErr = 9` if they disagree: a mismatch means the Python `pointOnSide` and
the 6502 `sideOf` disagree about a sign, which is the single most likely way
this pipeline breaks and the hardest to see from a rendered frame. It passes
on E1M1 — the first thing the engine proved when the traversal came up.

### 4.2 `NODES` — 12 arrays of 240 bytes at `$D000`

Capacity `MAXNODES = 240`; E1M1 uses 236. Unused entries are zero.

| Address | Array | Meaning |
|---|---|---|
| `$D000` | `ndPxLo` | partition line origin x, low byte |
| `$D0F0` | `ndPxHi` | |
| `$D1E0` | `ndPyLo` | partition line origin y |
| `$D2D0` | `ndPyHi` | |
| `$D3C0` | `ndDxLo` | partition line direction x |
| `$D4B0` | `ndDxHi` | |
| `$D5A0` | `ndDyLo` | partition line direction y |
| `$D690` | `ndDyHi` | |
| `$D780` | `ndRightLo` | right (front) child |
| `$D870` | `ndRightHi` | |
| `$D960` | `ndLeftLo` | left (back) child |
| `$DA50` | `ndLeftHi` | |
| `$DB40` | — | end; `$DB40-$DBFF` free |

**Child encoding is Doom's, unchanged**: bit 15 set means the low 15 bits are a
subsector index; clear means a node index. So the engine's leaf test is
`bit ndRightHi,x / bmi isLeaf` — one instruction, no mask, no compare. Keeping
the WAD's own encoding rather than inventing a cleaner one is worth a paragraph
because it is the only place this format does not repack: any other scheme costs
an instruction per node visit and buys nothing.

**Node bounding boxes are not carried.** They are 16 B/node in the WAD and would
not fit under `$D000` alongside the rest. Without them the walk visits every
node and relies on column occlusion (`colTop`/`colBot`) plus the `openCols`
early-out for rejection — correct, just not maximally culled. This is
`IMPLEMENTATION_PLAN.md` risk #3, and Phase 4 has now **called it in**: E1M1
costs 3.2x the test map per frame and lands the engine at roughly half the
25 fps target. The escape hatch is a quantised bbox, and the shape it should
take is a *streamed* one — 4 bytes per node fetched alongside the node visit,
in a new block, rather than resident, because there are only 384 free bytes
under the I/O space and 236 nodes need 944.

### 4.3 `SECTORS` — 6 arrays of 96 bytes at `$DC00`

Capacity `MAXSEC = 96`; E1M1 uses 85.

| Address | Array | Meaning |
|---|---|---|
| `$DC00` | `secFloorLo` | floor height, signed 16-bit map units |
| `$DC60` | `secFloorHi` | |
| `$DCC0` | `secCeilLo` | ceiling height |
| `$DD20` | `secCeilHi` | |
| `$DD80` | `secFByte` | floor shading byte, `%rrrriiii` |
| `$DDE0` | `secCByte` | ceiling shading byte |
| `$DE40` | — | end; `$DE40-$DEFF` free |

These were `testmap.asm`'s `secFloorLo`/`secFloorHi`/`secCeilLo`/`secCeilHi`/
`secFByte`/`secCByte` arrays; that file is gone and the arrays live here, under
the I/O space, which is why every read of them is bracketed by a bank switch
(§6.1) rather than being a bare `lda`.

Heights are Doom's own units with no rescaling — E1M1's floors span −136…136 and
ceilings −40…264, so the existing 16-bit integer world coordinates and the
projection math in `pipeline.md` §8 carry over untouched.

---

## 5. `SSECDATA` — the streamed subsector slots

Subsector `i` lives at REU offset `ssecReuBase + (i << 7)`. **One shift, no
multiply, no offset table.**

| Offset in slot | Size | Field |
|---|---|---|
| 0 | 1 | `segCount` (0…12) |
| 1 | 1 | `sectorId` — the front sector of every seg in this subsector |
| 2 | 10×`segCount` | seg records (§5.1) |
| … | | padding to 128 B, zero |

This replaces the resident `SSECTORS` table that `IMPLEMENTATION_PLAN.md` §4
proposed (237 entries × 4 arrays = 948 B of RAM). Spending 30 KB of REU to save
948 B of RAM and a 16-bit multiply is the trade §1 describes; it is what lets
every resident block fit under `$D000` and leaves the whole `$0BC6-$0DFF` free
block for the BSP stack.

**The engine fetches each slot in two transfers, not one:**

1. 2 bytes at `ssecReuBase + (i<<7)` → `segCount`, `sectorId`
2. `segCount × 10` bytes at `+2` → `SEGBUF` (`$0E80`, 128 B)

Two transfers rather than one fixed 82-byte fetch, because DMA has no setup
penalty but every transferred byte costs a microsecond. At E1M1's mean of 3.09
segs/subsector that is 2 + 31 = 33 bytes instead of 82 — a 2.5× saving on the
frame's dominant REU cost. Roughly 40 visible subsectors per frame gives
**~1.3 KB/frame ≈ 1.3 ms of halted CPU**, against a 20 ms PAL frame.

`segCount ≤ 12` is a hard cap of the slot size (`2 + 12*10 = 122 ≤ 128`) and
`wad2reu.py` asserts it. E1M1's maximum is 8; the distribution is
1:38 2:66 3:35 4:64 5:14 6:14 7:1 8:5.

`segCount == 0` is legal and means solid space — a leaf the BSP build reached
with nothing to draw. Every subsector in the shipped E1M1 has at least one seg,
but a node builder can produce empty leaves on the back side of a partition, so
the renderer must skip a zero-seg subsector rather than assume it cannot happen.

### 5.1 Seg record — 10 bytes

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | `x0`, signed 16-bit |
| 2 | 2 | `y0` |
| 4 | 2 | `x1` |
| 6 | 2 | `y1` |
| 8 | 1 | `backSector` — sector id, or `$FF` for a one-sided (solid) seg |
| 9 | 1 | `rampByte` — `ramp << 4`; the intensity nibble is filled per-wall from depth |

**Winding**: `(x0,y0) → (x1,y1)` with the seg's *front* sector on the **right**.
This is both Doom's linedef convention and `testmap.asm`'s ("interior is on the
RIGHT of each directed wall"), so `doWall`'s backface test — the single signed
compare `sx0 < sx1` of `pipeline.md` §8.5 — works on WAD segs unchanged.

`backSector = $FF` matches `testmap.asm`'s `wBack` sentinel. E1M1 has 85 sectors,
so `$FF` stays unambiguous.

Seg vertices are the WAD's `VERTEXES` entries referenced by the seg, i.e. already
split at BSP partition lines. The engine never sees a linedef.

---

## 6. Where it lands in the machine

```
$0810-$0DB1  main segment     code; .errorif guards the gap below MAPINFO
$0DB2-$0DFF  free, 78 B       main-segment headroom
$0E00-$0E1F  MAPINFO          32 B, resident block 0
$0E20-$0E5F  MAPHDR           64 B, the image header, kept for post-mortems
$0E60-$0E61  SSECHDR          2 B, the slot header of the current subsector
$0E70-$0EEE  collision helpers   segNear / padClass, out of line
$0F00-$0F3F  BSP stack        32 x 16-bit, the address the portal stack had
$0F40-$0F50  frameCnt, reuOK, mapOK, mapErr, mapSum
   ...
$9740-$97BF  SEGBUF           128 B, DMA target for one subsector's segs
$97C0-$98E3  bsp node test    sideOf / nodeStep / bspFindSsec
   ...
$CA30-$CE0F  doWall           one seg into the column windows
$CE10-$CFC2  bsp traversal    renderFrame, renderSsec, ssecFetch, sector reads
   ...
$D000-$DB3F  NODES            resident block 1   ]
$DB40-$DBFF  free, 192 B                         ]  under the I/O space:
$DC00-$DE3F  SECTORS          resident block 2   ]  visible only with
$DE40-$DEFF  free, 192 B                         ]  $01 = $34
$DF00-$DFFF  REU registers    never used as RAM
```

`SEGBUF` is in `TABLES_FREE` rather than next to `MAPINFO` because the main
segment ends just short of `$0E00`: everything below it is code headroom, and
`main.asm` has an `.errorif` on it. Deleting `testmap.asm` bought about 190 B
of that back, most of which Phase 5's collision code then spent.

The engine's code now lands in five pieces because the free RAM does. Every
one of them is bounded by an `.errorif` against whatever follows it, which is
what makes the arrangement maintainable rather than merely tight: growing a
routine past its block fails the build with the block's name in the message.

The resident tables end at `$DEFF`, one page short of `$DF00`, so the REU
register window is never shadowed by map data. That is not an accident of
arithmetic — `MAXNODES` and `MAXSEC` were chosen to make it true.

### 6.1 Banking discipline

`$D000-$DFFF` is RAM only when `$01`'s low three bits are `%100`. The engine
therefore runs in two states:

| `$01` | `$A000` | `$D000` | `$E000` | Used by |
|---|---|---|---|---|
| `$35` | RAM | **I/O** | RAM | default — `flip`, `readInput`, every REU transfer |
| `$34` | RAM | **RAM** | RAM | node and sector table reads |

Both states keep RAM at `$A000` and `$E000` where `BITMAP0`/`BITMAP1` live, so
switching never changes what a bitmap write does. `main.asm` sets `$01 = $35`
once at boot, and the KERNAL is never called after that.

Interrupts are masked for the whole run (`main.asm` opens with `sei` and never
clears it), so a bank switch cannot be interrupted halfway. **If an interrupt
handler is ever added, every `$34` window becomes a hazard** — the handler would
vector through `$FFFE` in RAM.

### 6.2 Why the boot load stages through MATRIX

A resident block cannot be DMA'd straight to `$D000`. The REU drives the C64 bus
through the same PLA the CPU does, so with I/O banked *in* the transfer would
land in the I/O registers, and with it banked *out* the `$DF01` command register
needed to start the transfer is not reachable. The two requirements are mutually
exclusive.

`mapload.asm` resolves it the boring way: DMA the block into `MATRIX` (`$1000`,
28 KB and unused until the first frame), switch `$01` to `$34`, block-copy to the
destination, switch back. This is boot-time only and costs a few milliseconds.

The copy loop also sums the block's bytes into `mapSum[id]` (`$0F49`, 16 bit).
That sum is the **only** view anything outside the engine gets of the two blocks
under `$D000`: the Ultimate's `machine:readmem` DMAs the bus as the engine has
it banked, so a host read of `$D000` returns the I/O registers, not the node
table. `tools/u64push.py --verify-map` and `tools/vicedbg/probe.py` both compare
that sum against the image. It is a plain byte sum, so it cannot see a
reordering — right for what it has to catch, which is "nothing arrived", "half
of it arrived", and "the previous image is still there".

The alternative is the `$FF00` trigger mode, where the REU snoops a write to
`$FF00` on the bus regardless of banking. It works on real hardware and is one
transfer instead of two steps — but its behaviour under the Ultimate's REU
implementation and under VICE is one more thing to verify, for a saving that is
invisible at boot. Not taken.

---

## 7. Conventions the tool converts

**Angle.** Doom's `THINGS` angle is degrees counter-clockwise from east. The
engine's `camA` is 0-255 counter-clockwise from east, so
`camA = round(deg * 256 / 360) & 255`. E1M1's player-1 start faces 90° → `camA =
64`. `pipeline.md` §2's deviation note (8-bit angle, 1.406° granularity) applies:
the spawn angle is quantised.

**Coordinates** pass through unscaled. E1M1's vertices span x −768…3808,
y −4864…−2048 — comfortably inside signed 16-bit, and the largest intermediate
in `ssmul32` (a coordinate difference of ~4600 times a 2.14 trig value) stays
inside 32 bits.

**Ramp assignment** is the M1 art-direction knob and lives in `RAMPS` at the top
of `tools/wad2reu.py`, mapping Doom texture and flat name families onto the eight
ramps defined in `chunky2mc.asm` (stone, wood, flesh, sky, moss, violet, metal,
fire). Eight further ramp slots exist and are duplicates of stone; filling them
is an asm change and is not part of M1.

**Flat intensity.** Walls get their intensity nibble from depth at runtime
(`pipeline.md` §8.6), but floors and ceilings have no per-column depth, so
`secFByte`/`secCByte` carry a fixed intensity. It is derived from the sector's
WAD light level, mapped to 2…15. This is a deliberate small step past M1's "no
lighting from WAD light levels" exclusion: the nibble has to hold *something*,
and a constant would flatten all 85 sectors into one brightness. Per-wall light
levels remain out of scope.

---

## 8. What the validator checks

`wad2reu.py --validate` (run by `make assets`) asserts, before the image is
written:

1. Magic, version, and that every descriptor's REU offset + length lies inside
   the image.
2. Every node child resolves — node indices `< numNodes`, subsector indices
   `< numSubsectors`.
3. Every subsector has `1 ≤ segCount ≤ 12` and a `sectorId < numSectors`.
4. Every seg's `backSector` is `$FF` or `< numSectors`, and a seg is two-sided
   iff its linedef is.
5. Every seg's front sector equals its subsector's `sectorId`.
6. Byte-exact round-trip: the image is re-parsed with an independent reader and
   compared against the structures that produced it.
7. `spawnSsector` found by descending the packed nodes equals the one found by
   descending the WAD's nodes.

and writes `build/assets-map.png`, a top-down render of the *decoded* blocks —
segs coloured by ramp, subsectors outlined — which is the check that the
geometry survived packing at all.


---

## 9. Getting the image onto a machine

Both delivery paths turned out to have a trap, and both traps are silent from
inside the C64 — the REU answers every transfer and returns whatever is in its
RAM. So both are checked rather than assumed: `mapload.asm` verifies the header
and sums each block, and `make check` / `make u64-map` assert the results.

### 9.1 The image is padded to 128 KB, and that is not cosmetic

VICE's `-reuimage` loads the file with `util_file_load()`, which fails unless the
file is **exactly** the emulated REU size. On a mismatch it prints
`Reading REU image ... failed` to stderr, boots anyway with a zeroed REU, and the
engine reads a header full of nothing.

So `wad2reu.py` pads every image to `REU_IMAGE_SIZE` = 128 KB — VICE's smallest
REU and the smallest real 1750 — and the Makefile runs `-reusize 128`. Raise the
two together or neither. `+reuimagerw` is also passed, so VICE does not write the
image back on exit and stamp runtime state into a build artifact.

### 9.2 The Ultimate's REU Preload does not deliver the image

`IMPLEMENTATION_PLAN.md` Phase 1.2 established that the `.reu` file reaches the
Ultimate over FTP and that `REU Preload Image` / `Offset` / `Preload` all arm and
read back as armed, and flagged the remaining question: whether the bytes reach
REU RAM. With `mapload.asm` in place that is now answerable, and on **firmware
1.1.0 / FPGA 122 / core 1.49 the answer is no.** REU offset 0 keeps whatever a
running program last wrote there, across any number of resets.

Tried, all with the file present at the right size and the settings reading back
correct, none of which helped:

- re-running with the setting already armed from a previous run
- `save_config_to_flash` followed by an explicit `machine:reset`
- toggling `RAM Expansion Unit` off and on to force a cartridge re-init
- toggling `REU Preload` off and on
- setting `REU Size` to 128 KB, in case preload demands an exact fit the way
  VICE's `-reuimage` does

The REU itself is fine — writes from the C64 persist across resets, which is how
the stale bytes were identified in the first place.

### 9.3 What is used instead

`src/reuload.asm` is a small standalone PRG with an 8-byte mailbox at `$0340`.
The host DMAs a chunk into C64 RAM with `machine:writemem`, writes the mailbox
in one go — the trigger byte is **last** in the mailbox, so the stub cannot see
it before the parameters it describes — and the stub issues the REU stash.
`tools/u64push.py` drives it in 16 KB chunks and reads every chunk back with a
matching REU **fetch** before moving on, because this is exactly the leg of the
path that turned out not to be trustworthy.

E1M1's image is 34688 used bytes of the padded 128 KB, so three chunks. The
whole upload plus verification takes a few seconds and runs before `doom.prg`.

### 9.4 REU scratch outside the image

`reuProbe` runs before the loader and round-trips a signature through REU RAM.
It must not use REU address 0 — that is the header it is about to verify, and
the first version of this did exactly that and reported "bad magic" at itself.
The scratch is at bank 0, `$F000`, and `wad2reu.py` asserts the image's used
region stays below it.

Bank 1 offset 0 was the first choice and had to be abandoned: with `$DF06 = 1`
the C64 Ultimate stashed to REU address `$000000` anyway, which VICE does not
do. Nothing here needs the bank register — 64 KB is reachable with the two
address bytes alone, and the image is 34 KB.

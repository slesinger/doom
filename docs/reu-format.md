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

At REU offset `$000000`, 128 bytes:

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | magic, ASCII `D64U` |
| 4 | 1 | format version — **5** |
| 5 | 1 | block count `N` |
| 6 | 2 | reserved, zero |
| 8 | 8×`N` | block descriptors |

It was 64 bytes through version 4, which held seven descriptors. Version 5's
special lines are the eighth block, so the header doubled — it costs nothing,
since the first block starts at `$000100` either way, and it stops the next
block from being a format change to the header as well. `mapload.asm`'s
`MAXDESCS` is derived from `HDRSIZE` rather than written down, so the two
cannot drift.

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
| 1 | 1 | flags — bit 0 = resident (load at boot), bit 1 = length is in pages |
| 2 | 3 | REU offset, 24-bit (lo, hi, bank) |
| 5 | 2 | length, in bytes — or in 256-byte pages if flags bit 1 is set |
| 7 | 1 | load address **high byte**; 0 for non-resident blocks |

**The page-unit flag exists for one block.** The music stream (§4.6) is ~400 KB
and the length field is 16 bits. Only the host-side uploader ever reads that
length for a non-resident block, so this costs the 6502 nothing:
`mapload.asm` tests bit 0 and skips the descriptor before it looks at a length
at all. `tools/u64push.py` does read it, and sizing that upload in bytes would
have delivered 1583 bytes of a 405 KB stream — 0.4% of a tune, replayed as
noise, with every check green.

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
| 4 | `NODESPH` | no — streamed | — | 1920 B |
| 5 | `MUSIC` | no — streamed | — | 405136 B |
| 6 | `WALLTEX` | no — streamed, read once at boot | `$7600` | 2048 B |
| 7 | `LINEDEFS` | no — streamed, read once at boot | `$DB40` | 80 B |
| 8 | `HUDBG` | no — streamed, read once at boot | — | 3840 B |
| 9 | `HUDFONT` | no — streamed, read once at boot | — | 1280 B |

Resident total: **3488 B**, of which 3456 sit under the I/O space (§6).

`LINEDEFS` is the odd one: it is read exactly once, at boot, and then lives at a
fixed address like a resident block. It is not one because a descriptor carries
a load *page* and `$DB40` is not a page boundary — the 640 free bytes under I/O
begin mid-page (§6). So `mapLoad` stages it in MATRIX with the streamed blocks
and `lineLoad` copies it down. `tools/vicedbg/probe.py`'s `check_lines` is what
asserts it arrived, since the resident-block check cannot see it.

Blocks are stored in the image in id order, each padded to a 256-byte boundary —
with one exception, `MUSIC`, which sits at a fixed offset above everything else
(see below), so `WALLTEX` at id 6 is physically *below* it. The descriptors say
where each block is and nothing reads them in order, so the exception costs
nothing; it is called out here because a hex dump does not read as id order.
Padding costs REU space, which is free, and makes every block's offset
inspectable in a hex dump, which is not.

`MUSIC` is the one block that does not simply follow its predecessor: it sits at
a fixed `MUSIC_OFFSET` of `$010000`, above `reuProbe`'s scratch (§9.4), so the
map below it keeps the whole first 64 KB and nothing has to move when a tune
changes length. It is also **optional** — `make assets` without a stream omits
the block and leaves `miMusBase` at zero, which `src/music.asm` reads as "render
in silence" rather than as an error. `build/testmap.reu` is built that way.

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
| 22 | 3 | `sphReuBase`, 24-bit REU offset of `NODESPH` |
| 25 | 3 | `musReuBase`, 24-bit REU offset of `MUSIC` — **0 means no music** |
| 28 | 3 | `texReuBase`, 24-bit REU offset of `WALLTEX` — **0 means no textures** |
| 31 | 1 | reserved, zero |

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

**Node bounding boxes are not carried here.** The WAD's are 16 B/node and would
not fit under `$D000` alongside the rest — there are 384 free bytes there and
236 nodes would need 944. Format version 2 carries a *bounding sphere* instead,
streamed, in its own block: §4.4.

### 4.4 `NODESPH` — the streamed node bounding spheres

Block 4, `MAXNODES` records of 8 bytes at `sphReuBase + (i << 3)`, one per node,
never resident.

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | centre x, signed 16-bit map units |
| 2 | 2 | centre y |
| 4 | 2 | radius, **unsigned**, rounded up |
| 6 | 2 | pad, zero |

The sphere contains every seg endpoint in the subtree below the node. The
validator checks exactly that, for every node and every subsector, against the
points themselves — a bound that is wrong by one unit makes geometry vanish, and
nothing about the rendered frame would say which node did it.

Two things are the way they are on purpose.

**A sphere, not a box.** A box is 8 B of payload against the sphere's 6, and the
frustum test on it is four compares against three. The sphere is the looser
bound, but a *node's* bound is loose anyway — it wraps a whole subtree — so the
tightness buys much less than the arithmetic costs.

**The stride is 8, not 6.** Six bytes of every eight are used and 480 of E1M1's
1920 are padding, so that the record offset is `index << 3` — three shifts
rather than a multiply, per node, per frame. The block is streamed, so the
padding costs REU space, which is free.

The same record appears a second time, inline, as bytes 2–7 of every subsector
slot header (§5), and the engine DMAs both into the same six bytes of RAM.

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

### 4.6 `MUSIC` — the SID register stream

Block 5, never resident, at `musReuBase`. Written by `tools/sidstream.py`,
embedded by `wad2reu.py --music`, replayed by `src/music.asm`.

**There is no player in this format, and that is the point.** A `.sid` is 6502
code at fixed absolute addresses — `DooM_Medley` wants `$0FF6-$3E6A` — and that
lands inside `MATRIX`. The engine's free RAM is about 360 bytes in four holes
(`IMPLEMENTATION_PLAN.md` §14), so a resident player was never possible. But the
SID chip only ever sees register writes, so the player runs once at build time in
`tools/cpu6502.py`: `init` is called, `play` is called at the tune's own rate,
and `$D400-$D418` is snapshotted after every call. What ships is the snapshots.
Chip-identical by construction, zero resident player code, and the loop is a
pointer rewind rather than a second `init`.

#### Header — 16 bytes at offset 0

| Offset | Size | Field |
|---|---|---|
| 0 | 2 | magic, ASCII `MU` |
| 2 | 1 | stream version — **1** |
| 3 | 1 | `window` — bytes the player must fetch per tick |
| 4 | 2 | CIA 1 timer A latch, i.e. the tune's own tick rate |
| 6 | 3 | `loopOffset` — where the tune repeats from |
| 9 | 3 | `endOffset` — one past the last record |
| 12 | 3 | `tickCount` |
| 15 | 1 | reserved, zero |

All three offsets are from the **start of the stream**, header included, and the
engine adds `musReuBase` to each at boot. The rate is carried rather than assumed
because tunes set their own: `DooM_Medley` wants 100.25 Hz (latch `$2663`), not
the 50 Hz a vertical-blank player would use.

#### Records — one per tick, variable length

A count byte, then that many `(register, value)` pairs for the registers that
changed since the previous tick. `DooM_Medley` changes a mean of 3.3 of 25, so
this is 9.1 bytes where a raw snapshot is 25 — 405 KB against 1.11 MB for the
whole 7:22. That ratio was about upload time rather than REU space, which is
free; since §9.3's skip cache the stream is uploaded once and skipped on every
later run, so it is now mostly about the first upload after a power cycle.

**The chip must start at zero.** The encoder's "previous" frame begins as 25 zero
bytes, so a register the tune never writes is never in any record. `musInit`
therefore clears `$D400-$D418` before the first tick; without it those registers
keep whatever the KERNAL's reset left in them.

**`window` is why the stream is padded.** The player DMAs a *fixed* number of
bytes and only then reads the count byte to learn how long the record was, so the
window has to cover the longest record in the stream — and the last record's
fetch therefore runs off the end by design. `sidstream.py` appends `window` bytes
of padding for exactly that, and `wad2reu.py`'s validator checks the padding is
there. `MUSWINDOW` in `src/defs.asm` is the ceiling the player can offer (40 B);
`musInit` rejects a stream asking for more rather than replaying truncated
records as noise. `DooM_Medley` asks for 39.

#### What it costs the frame

Six ticks per 59.85 ms frame at 100.25 Hz — the tick is CIA-driven, in real
time, so M2's longer frame absorbs more of them at the same cost per second.
Each is an interrupt (1.7 µs, §14 measured on hardware), a 40-byte DMA and a
mean of 3.3 register writes — about **0.26 ms a frame, ~0.4% of the budget**,
and most of it is the DMA. REU DMA is
1 µs/byte and does not scale with the turbo clock (§1), so the window is the one
part of this that a faster CPU does not make cheaper.

**`make stats` over-reports this by roughly sixty times, and will keep doing
so.** It measured 2307 → 2438 ms/frame, +5.7%, which is real arithmetic about
the emulator and says nothing about the machine. The tick rate is fixed in *real*
time — 100.25 Hz is a CIA latch — while VICE's 1 MHz frame lasts 2.3 emulated
seconds instead of 39.9 ms. So an emulated frame absorbs ~231 ticks where the
Ultimate absorbs 4. The handler's ~350 cycles are also 350 µs at 1 MHz and 5.5 µs
at 64 MHz. Every other change to this engine can be judged in VICE and converted
(`IMPLEMENTATION_PLAN.md` §12); this one cannot, and `make u64-fps` is the only
honest measurement of it.

The rendered frame is **bit-identical** with the player running —
`make framehash` gives `c5d78e65…` with and without it, which is the same
standard §13/§15 held optimisations to. That is the useful thing VICE can still
say here: the interrupt lands inside the BSP walk's bank windows and inside the
renderer's REU setup thousands of times per frame, and changes not one pixel.

#### The two hazards the handler exists to survive

Both come from the engine having been written with `sei` held for its whole run,
which is no longer true — `main.asm` now does a `cli` once `musInit` returns.

1. **`$01`.** The BSP walk reads the node and sector tables with `$34` banked in
   (§6.1). The handler saves `$01`, forces `$35`, and restores what it found.
   `src/irqtest.asm` measured this on hardware with a positive control: zero
   mismatches over thousands of interrupts landing inside those windows, and the
   deliberately-broken variant failing immediately.
2. **The REU transfer registers.** A transfer is "fill in `$DF02-$DF08`, then
   write `$DF01`", and an interrupt between those two writes would otherwise
   return to a command register holding *the music's* parameters. The handler
   saves and restores `$DF02-$DF0A` around its own DMA. `$DF00` is excluded on
   purpose — reading the status register clears it. The DMA itself cannot be
   interrupted, because the REU halts the CPU for its duration, so the setup
   window is the whole hazard.

#### How it is verified

`tools/vicedbg/probe.py`'s `check_music`, run by `make check`, reads `musPtr` and
all 25 SID registers from the running machine **without leaving the monitor in
between**, then walks the stream from its start to that pointer in Python and
compares. A match proves the whole path at once: the tick fires, the DMA lands,
the pointer arithmetic stays on record boundaries, and every write reaches the
chip. The boundary check is the one that matters most — a replay head half a
record out of step still writes plausible bytes to the SID and merely sounds
wrong, which no screenshot and no checksum would catch.

**That exact test is VICE-only, for two independent reasons**, and
`tools/u64push.py`'s `verify_music` is the weaker hardware version:

- The SID is write-only, and the Ultimate's `machine:readmem` is a DMA into a
  *running* machine. `$D400-$D418` reads back as `$40` in every register —
  open bus, not chip state.
- Even if it did read back, there is nothing to stop time between the two
  reads. Four music ticks land per frame, so the pointer and the registers
  would be sampled from different ticks.

So on hardware the check is: the header was accepted (`musErr == 0`), and the
pointer is inside the block and advancing. Measured on a C64 Ultimate: 487
stream bytes in 0.5 s, which at the medley's mean record length of 9.1 B is
~107 ticks/s against the tune's 100.25 Hz — the tick rate is right, and it is
right because the CIA runs at 1 MHz whatever the CPU's turbo setting is.

### 4.7 `WALLTEX` — the wall texture tiles

Block 6, at `texReuBase` (MAPINFO +28). Sixteen families of 128 bytes; family
`f` is at `texReuBase + (f << 7)`. Zero in `texReuBase` means the image carries
none, which is not an error — the engine then draws walls flat, exactly as M1
did.

**Format 6 took the tile from 8×8 to 16×16 and the block from 512 B to 2048 B**
(`IMPLEMENTATION_PLAN.md` §10.6). The descriptor still says *streamed*, but the
engine reads the whole block **once, at boot**, into `WALLTILE` — `texLoad` in
`src/mapload.asm`, the same treatment `LINEDEFS` gets and for the same reason:
a resident descriptor carries a load *page* and is checked against tables that
are `MAPNBLK` wide, which is not worth changing for a block read once.

Residency is what makes the size possible. Stage A re-fetched a family's tile
per seg; at 128 B a tile that is ~1 KB … 8.7 KB of REU traffic per frame, i.e.
whole milliseconds at the REU's flat 1 byte/µs. Resident, the per-frame cost is
zero and Stage A's own ~1 KB/frame goes away with it.

A family is one **16×16 grid of intensity nibbles**, nibble-packed
**column-major**: eight bytes per `u` column, `v = 0` in the first byte's high
nibble, `v = 1` in its low one, and so on down the column.

| Byte in family | Holds |
|---|---|
| `u*8 + 0` | `v0 << 4 \| v1` |
| `u*8 + 1` | `v2 << 4 \| v3` |
| … | … |
| `u*8 + 7` | `v14 << 4 \| v15` |

Column-major because the engine unpacks **one `u` column at a time** into a
sixteen-byte strip and then walks `v` down the screen inside it: `u` is constant
for a screen column, so the strip is selected once and indexed per pixel.

The engine's `u` is `accU & $78` — the column's *byte offset* in the tile, with
no shift at either end, which is only true because a texel is 8 world units and
the tile is 16 wide.

**The tile modulates intensity and never touches the ramp.** The chunky byte is
`ramp << 4 | intensity` and a 4×8 multicolor cell holds three colours plus
background, so a surface's cell stays legal only while the whole surface shares
one ramp (`IMPLEMENTATION_PLAN.md` §10.1). Material *colour* therefore rides on
the seg's ramp nibble, not on the tile — see §10.7 for the five ramps that were
claimed to give it somewhere to ride. The engine's combination is

```
final = clamp(depthIntensity + texel - 8, 2, 15)
```

so a texel of 8 leaves M1's shading byte exactly as it was. Keeping the depth
term as the base rather than the texture's own brightness is what stops a dark
texture from going black at distance.

One texel is **8 world units** on both axes (`TEX_UNITS_SHIFT`), so a tile
repeats every 128 units — the same world scale Stage A had at 16 units over 8
texels. The tile got finer; the mapping did not move, and `u` stays a plain
world coordinate so it is continuous across a BSP seg split with no offset in
the seg record.

Tiles are the 16×16 box downsample of a real WAD texture's luminance, quantised to
±4 around 8 with a gain that saturates at ±25 luma units — so a flat texture
modulates less than a high-contrast one instead of every tile being normalised
to full swing. `wad2reu.py`'s `FAMILY_TEXTURE` names the texture each family is
built from, and `WALL_TEX_FAMILY` maps E1M1's 30 wall texture names onto the
fifteen non-plain families by longest prefix, the same way `WALL_RAMPS` does.

**Family 0 is `plain` and is uniform**: 177 of E1M1's 732 segs are two-sided
lines the WAD itself leaves untextured. `--validate` exempts family 0 from the
"no uniform tile" check and applies it to every other family, because a uniform
tile anywhere else is a wall that is textured with nothing and looks exactly
like a wall that is not textured yet.

**`u` and `v` come from world coordinates, not from a texture offset.** `u` is
the seg's dominant world axis and `v` is `z`, both `>> 4`, so 16 world units is
a texel and the mapping is *continuous across a BSP seg split*. That is what
lets the 10-byte seg record stay 10 bytes: Doom carries a per-seg offset along
the linedef precisely because its `u` is per-linedef, and a world-space `u`
needs no such thing. The cost is that a diagonal wall's texture is stretched by
up to √2 and that `u` does not honour the sidedef's own x offset — neither is
visible at 8×8 and 160 columns.

### 4.8 `LINEDEFS` — the special lines

Block 7, 80 bytes, copied to `$DB40` at boot. Five parallel arrays of
`MAXLINES` = 16, indexed the way every other table in this format is:

| Array | At | Holds |
|---|---|---|
| `ldKind` | `$DB40` | `LK_*` in the low nibble, `LF_WALK`/`LF_REPEAT` above it; 0 = empty slot |
| `ldSec` | `$DB50` | the sector that **moves** |
| `ldTrig` | `$DB60` | the sector that **fires** it |
| `ldTgtLo` | `$DB70` | where the moving height ends up, 16-bit … |
| `ldTgtHi` | `$DB80` | … signed, in world units |

Kinds: 1 door (its sector's **ceiling** moves), 2 lift, 3 floor, 4 exit — which
is carried, drawn, and does nothing in M2, there being no level to exit to.

**The tags and the target heights are resolved by `wad2reu.py`, not at
runtime.** Doom searches every sector for a tag and every neighbour for a
height; the engine can do neither — `SECTORS` carries no tag and the image
holds no adjacency anywhere — and it does not have to, because nothing in M2
changes what the answer would be. A door's target is the lowest neighbouring
ceiling minus 4, a lift's is the lowest neighbouring floor, a floor's is the
highest neighbouring floor plus 8.

`ldTrig` is what makes activation a sector question rather than a geometric
one (`IMPLEMENTATION_PLAN.md` §11.2a): a walkover line emits **one record per
side**, so it fires from either direction, and a use-activated line sets
`ldTrig` to the sector that moves — the player is holding the key while
standing in a subsector with that sector behind one of its segs.

### 4.9 `HUDBG` and `HUDFONT` — the status bar

Blocks 8 and 9, `IMPLEMENTATION_PLAN.md` §13. Both streamed and read exactly
once, at boot, like `LINEDEFS` — and for the same underlying reason `LINEDEFS`
gives (§4.8): nothing reads either block again after the bar is painted, so
there is nothing for a resident descriptor to be resident *of*. Neither block
has a `MAPINFO` field either; the engine's boot-time loader finds them by
block id while it walks the descriptor table, the exact mechanism `lineLoad`
already uses for block 7.

**The engine paints the status bar once, at boot, with fixed placeholder
values.** There is no runtime patching: M2 has no code RAM left for a
dirty-flag mechanism (`IMPLEMENTATION_PLAN.md` §13's landing note has the
numbers), so health/armour/ammo are wired to three bytes the boot code reads
once rather than baked in as immediates, and M3 — which gives them a real
source — is what makes them live.

**Both blocks are raw VIC multicolor bitmap bytes, not `MATRIX`'s
ramp/intensity chunky format and not `WALLTEX`'s nibble-packed one.** A cell
is one multicolor cell — 4 px wide, 8 tall: 8 bitmap bytes, 1 screen-RAM
byte, 1 colour-RAM byte, 10 bytes total — and both blocks are simply strips
of these cells, row-major (cell index = `row*width + col`). `hudBlitCell`
(`src/mapload.asm`) copies them straight into `BITMAP0/1` + `SCREEN0/1` +
`$D800`; there is no dither step and no `ditherTabs`/`scrTab`/`colTab`
involved, unlike the 3D renderer's per-frame converter.

That is a deliberate change from the original approach, which downsampled the
WAD's own `STBAR`/`STTNUM0..9` lumps through the renderer's dither chain —
snapping every pixel to one hue's four shades (`chunky2mc.asm` samples one
pixel per cell to pick its screen/colour-RAM pair, so a cell can only ever
show one ramp). That produced a washed-out bar no matter how the source art
was massaged. Real VIC multicolor bitmap format has no such restriction *at
the engine level* — the only limit is the hardware's own (background colour
shared across the whole screen, plus two screen-RAM colours and one
colour-RAM colour per cell) — so the art is instead hand-painted directly in
a real C64 multicolor editor (e.g. Multipaint), which already enforces those
exact limits, and cropped out of the result: a crop, not a conversion, so
what is painted is what lands on screen.

`HUDBG`, 1600 B: `40 x 4` cells, cropped from `assets/hud.kla` at cell
`(HUD_BAR_COL0, HUD_BAR_ROW0)` = `(0, 21)` — the four rows `main.asm`'s
`clearHudRows` reserves below the viewport, so the artist
can paint the bar in its actual on-screen position. `HUDFONT`, 400 B: ten
glyphs, each **2×2 cells** (8×16 logical pixels), cropped starting at
`(HUD_FONT_COL0, HUD_FONT_ROW0)` = `(0, 0)`, digits 0-9 left to right — a
size kept from the original approach, where one cell (4×8) per glyph was
tried first and measured (§4's rule) to render every digit as a near-solid
blob, Doom's HUD font reading by outer silhouette rather than an internal
hole.

`assets/hud.kla` is a single combined image (one canvas, two regions) rather
than two files, so the artist can see the bar and the font glyphs together
while painting; everything outside the two regions above is unused and can
be left blank. It must be a standard 10003-byte Koala Painter file — 2-byte
PRG load address, 8000 B bitmap, 1000 B screen RAM, 1000 B colour RAM, 1 B
background colour, the same layout `src/intro/intro.asm` already imports raw
for `doom-title.kla` — with its background colour set to black (0): the
engine's `$d021` is fixed to black at boot and never changed again
(`src/main.asm`), so any other background in the source image would show a
seam the moment it lands on screen. `wad2reu.py --hud` (default
`assets/hud.kla`) reads it; if the file is missing, a fixed, deliberately
unrealistic placeholder pattern is used instead (the same role `_pattern_tile`
plays for `WALLTEX`'s test-map path) so a build never hard-fails on it.


Both blocks share **ramp 8**, the first of `chunky2mc.asm`'s spare ramp slots,
redefined with the WAD's own status-bar palette. No table growth, no RAM
impact — the slot was already resident. Slots 9-13 were claimed the same way
for wall materials (`IMPLEMENTATION_PLAN.md` §10.7); 14-15 remain free.

`--validate` checks both blocks are present, exactly the expected length, and
— echoing the `WALLTEX` uniform-tile check — that no digit glyph quantises to
a single byte value, which would render as a blank digit.

---

### 4.10 `THINGS` — static props, sorted by subsector

Block 11, `IMPLEMENTATION_PLAN.md` §12. Streamed and read exactly once at
boot, like `LINEDEFS`/`HUDBG` — `thingsLoad` (`src/mapload.asm`) DMAs it
straight into `SPRDATA` (`$6d00`) and nothing reads the block's own REU
offset again after that; unlike `WEAPON`, a prop's picture never moves once
placed, so there is no per-frame re-fetch to point at.

`wad2reu.py`'s `THING_TYPE_OF` filters Doom's THINGS lump down to the 7
doomednums `SPRTYPES` lists (a barrel, a lit floor lamp, a candelabra, a tall
techno column, two flavours of bloody remains, and a pool of blood and
bones) — every monster, pickup, and other decoration is out of M2's scope
(props are "drawn, not animated and not intelligent") and dropped at the
tool, not on the 6502. Each survivor is placed by `descend()`, the same
BSP-descent helper the runtime's own `bspLoop`/`sideOf` walk performs, so a
thing's recorded subsector always agrees with which subsector `renderSsec`
will actually be drawing it from.

There is no per-thing world Z. Every in-scope prop stands on its own
subsector's floor, which `secFront` (`src/render/bsp.asm`) already leaves in
`zDzF` by the time `sprPick` runs — storing a Z here would only be that same
value, baked stale, for `MAXTHINGS` bytes.

Layout, `SPRDATA` (`$6d00`) to `SPRDATA_END`, byte for byte (`src/defs.asm`):

| Offset | Size | Field |
|---|---|---|
| 0 | `MAXSSEC+1` = 238 | `sprSsecFirst` — prefix-sum index. Subsector `i`'s things are `[sprSsecFirst[i], sprSsecFirst[i+1])` into the five arrays below |
| 238 | `MAXTHINGS` = 36 | `thingXlo` |
| 274 | `MAXTHINGS` | `thingXhi` |
| 310 | `MAXTHINGS` | `thingYlo` |
| 346 | `MAXTHINGS` | `thingYhi` |
| 382 | `MAXTHINGS` | `thingType` — index into the type table below, `0..NUM_SPRTYPES-1` |
| 418 | `NUM_SPRTYPES` = 7 | `sprTypArtLo` — art offset into `SPRIMG`, low byte |
| 425 | 7 | `sprTypArtHi` |
| 432 | 7 | `sprTypW` — art box width, columns |
| 439 | 7 | `sprTypH` — art box height, rows |
| 446 | 7 | `sprTypHW` — world half-width, the on-screen size a thing's projection is computed from |
| 453 | 7 | `sprTypWH` — world height |

Total 460 bytes, budgeted to 588 (`SPRART`'s `$300`-byte block 11 slot
leaves room for `SPRIMG` to start on the next page at `SPRART+$300`). `MAXSSEC`
= 237 (E1M1's own subsector count) and `MAXTHINGS` = 36 (33 in-scope E1M1
things + slack) are compile-time buffer bounds, not read at runtime — the
same shape as `MAXNODES`/`MAXSEC`.

`sprTypW`/`sprTypH` are the *downsampled art* box (`SPR_WMAX x SPR_HMAX`,
aspect-corrected from the Doom picture, the same "tight box, not a fixed
grid" call `WALLTEX`'s tiles make); `sprTypHW`/`sprTypWH` are the *world*
half-width/height a thing's on-screen size is computed from, which per
Doom's own convention is just the source picture's raw pixel size in world
units, not the downsampled box — coarse art at the true on-screen size beats
sharp art at the wrong one. There are no precomputed 8.8 fixed-point
u-step/v-step-per-`ry` coefficients: `sprDraw` (`src/render/sprite.asm`)
computes them at draw time from `sprTypHW`/`sprTypWH` instead, trading two
extra divides a frame per visible thing for simpler, less bug-prone code.

`--validate` checks `sprSsecFirst` is monotonic and its prefix sums agree
with which subsector each thing actually landed in, that its total matches
the thing count, and that every `thingType` entry is a valid type index.

### 4.11 `SPRIMG` — the resident sprite pictures

Block 12, `IMPLEMENTATION_PLAN.md` §12, §14a.2. Streamed and read exactly
once at boot — `sprImgLoad` (`src/mapload.asm`) DMAs it straight into
`SPRIMG` (`$7000`, page-aligned) — but unlike `THINGS`, the art it lands
lives on afterward: `sprDraw` samples it directly out of that fixed address
every frame a prop is visible, the same "resident, not streamed" trade
`NODES`/`SECTORS`/`MAPINFO` make and `WEAPON`'s art deliberately does not
(§4a's per-row DMA exists because there was nowhere to put 1120 bytes
resident; `SPRIMG`'s 7 pictures together fit in `SPRIMG_CAP` = 1024 bytes).

Column-major, one byte per pixel — `%rrrriiii`, ramp in the high nibble,
4-bit intensity in the low, `SPR_CLEAR` (0) transparent — not 4-bit packed
like `WALLTEX`'s tiles or `WEAPON`'s art, because a masked scaled blit reads
one source pixel per destination pixel at an arbitrary (non-integer) step
and byte-per-pixel needs no nibble-parity bookkeeping at the read cursor the
way a packed format would.

The 7 pictures are packed back to back in `SPRTYPES` order, no padding
between them; `sprTypArtLo`/`sprTypArtHi` (block 11) give each one's byte
offset into this block, `sprTypW`/`sprTypH` its `art_w * art_h` extent.
Each picture is `art_w` columns of `art_h` bytes, `_picture_intensity_grid`'s
same box-average + rank-spread downsample the HUD font and weapon art use,
with the type's ramp (one of the existing thematic ramps — moss for the
barrel, lite for the lamp, fire for the candelabra, tech for the column,
flesh for the corpses/blood — §12 claims no new ramp, reusing `chunky2mc.asm`
slots 9-13) baked into every opaque byte at build time so `sprDraw` never
has to OR one in at blit time.

`--validate` checks the block is present whenever the map has things, that
its length does not exceed `SPRIMG_CAP`, and that it is not entirely clear
(which would mean every prop renders invisible).

---

## 5. `SSECDATA` — the streamed subsector slots

Subsector `i` lives at REU offset `ssecReuBase + (i << 7)`. **One shift, no
multiply, no offset table.**

| Offset in slot | Size | Field |
|---|---|---|
| 0 | 1 | `segCount` (0…12) |
| 1 | 1 | `sectorId` — the front sector of every seg in this subsector |
| 2 | 2 | bounding sphere centre x |
| 4 | 2 | bounding sphere centre y |
| 6 | 2 | bounding sphere radius, unsigned |
| 8 | 10×`segCount` | seg records (§5.1) |
| … | | padding to 128 B, zero |

The sphere is the same record as `NODESPH`'s (§4.4), inline here so that the
first transfer below carries it — a subsector outside the view is rejected
before the second transfer fetches a single seg.

This replaces the resident `SSECTORS` table that `IMPLEMENTATION_PLAN.md` §4
proposed (237 entries × 4 arrays = 948 B of RAM). Spending 30 KB of REU to save
948 B of RAM and a 16-bit multiply is the trade §1 describes; it is what lets
every resident block fit under `$D000` and leaves the whole `$0BC6-$0DFF` free
block for the BSP stack.

**The engine fetches each slot in two transfers, not one:**

1. 8 bytes at `ssecReuBase + (i<<7)` → `segCount`, `sectorId`, the sphere
2. `segCount × 10` bytes at `+8` → `SEGBUF` (`$9740`, 128 B)

Two transfers rather than one fixed 128-byte fetch, because DMA has no setup
penalty but every transferred byte costs a microsecond — and a microsecond
regardless of the CPU's clock, which is why this does not get cheaper on a
64 MHz Ultimate. At E1M1's mean of 3.09 segs/subsector that is 8 + 31 = 39 bytes
instead of 128. Since the header grew to carry the sphere the split buys more
than the byte count: the second transfer never happens at all for a subsector
the sphere test rejects.

`segCount ≤ 12` is a hard cap of the slot size (`8 + 12*10 = 128`) and
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
| 9 | 1 | `rampByte` — `ramp << 4 \| texFamily` (§4.7) |

**The low nibble was reserved and zero through format 3**, because the byte's
low nibble is the *intensity*, and the intensity is not a property of the seg —
`doWall` computes it per wall from depth and ors it in. Format 4 spends that
nibble on the texture family, which is why Stage A texturing is a version bump
and not a wider seg record. `doWall` masks with `and #$f0` before the or; an
engine that forgets to would shade every textured wall 0–15 steps too bright.

Widening the record to carry a texture id was the alternative and was rejected
on M1's evidence: the 6-byte seg record experiment (`IMPLEMENTATION_PLAN.md` §4)
was complete, correct and reverted, and per-frame DMA bytes out of `SSECDATA` are
the scarce thing an 11th byte would spend.

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
$0810-$0DBA  main segment     code; .errorif guards the gap below SPHCODE2
$0DBC-$0DFF  sphere compares  sphereTest -- what used to be the headroom here
$0E00-$0E1F  MAPINFO          32 B, resident block 0
$0E20-$0E5C  node sphere      nodeSphere, the per-node fetch -- MAPHDR's old home
$0E60-$0E67  SSECHDR          8 B, the slot header of the current subsector,
                              and the six bytes a node's sphere is DMA'd into
$0E70-$0EEE  collision helpers   segNear / padClass, out of line
$0F00-$0F3F  BSP stack        32 x 16-bit, the address the portal stack had
$0F40-$0F50  frameCnt, reuOK, mapOK, mapErr, mapSum
$0F51-$0FC3  seg backface     segFacing, the world-space cross product
$0FC4-$0FF7  music state      musBuf (the per-tick DMA window), the three
                              stream pointers, musBank/musOK/musErr
$1000-$7DFF  MATRIX           ... and MAPHDR stages at $5000, the map loader
                              at $5100 and musInit at $5300, before frame 1
   ...
$9740-$97BF  SEGBUF           128 B, DMA target for one subsector's segs
$97C0-$98E3  bsp node test    sideOf / nodeStep / bspFindSsec
   ...
$CA30-$CE06  doWall           one seg into the column windows
$CE08-$CFF8  bsp traversal    renderFrame, renderSsec, ssecHdr/ssecSegs, sectors
   ...
$D000-$DB3F  NODES            resident block 1   ]
$DB40-$DB8F  LINEDEFS         block 7, copied    ]  under the I/O space:
$DB90-$DBCF  thinkers         8 moving sectors   ]  visible only with
$DBD0-$DBFF  lineThink        + the SECTAB accessors ]  $01 = $34
$DC00-$DE3F  SECTORS          resident block 2   ]
$DE40-$DEFF  lnStep           the door state machine ]  All three code blocks
$DF00-$DFFF  lnUse/lnEnter    activation, and lineInit ]  are .pseudopc images
                              -- the REU registers are here with $01 = $35,   ]
                              and this is RAM with $01 = $34 (src/lines.asm)  ]
   ...
$FF40-$FFE3  music handler    musIrq, copied there by musInit -- NOT in the
                              PRG image, which still ends at $CFDA (§4.6)
$FFFA-$FFFF  CPU vectors      NMI -> an rti inside that block, IRQ -> musIrq
```

`SEGBUF` is in `TABLES_FREE` rather than next to `MAPINFO` because the main
segment ends just short of `$0E00`: everything below it is code headroom, and
`main.asm` has an `.errorif` on it. Deleting `testmap.asm` bought about 190 B
of that back; Phase 5's collision code took some, and the sphere compares have
now taken the last byte of it.

The engine's code lands in eight pieces because the free RAM does. Every
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

**Interrupts are no longer masked, and every `$34` window is therefore live.**
`main.asm` still opens with `sei`, but it now clears it once `musInit` returns
(§4.6), so the music tick lands inside those windows about four times a frame.
The handler is what makes that safe: it saves `$01`, forces `$35` for the I/O it
needs, and restores exactly what it found. `src/irqtest.asm` measured that on
hardware before the player was written, positive control included — thousands of
interrupts landing inside the windows, zero mismatches, and the deliberately
broken variant failing on the first one.

Anything else added to the handler inherits the same rule: **nothing it touches
may assume a banking state until `$01` has been forced.** The zero page and
everything below `$D000` are RAM either way; the SID, the REU and the CIAs are
not.

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
8. `NODESPH` is non-resident and `sphReuBase` points at block 4.
9. **Every bounding sphere contains every point below it** — each subsector's
   sphere against its own seg endpoints, each node's against every seg endpoint
   in its subtree. This is the one check that matters most: the engine rejects
   whole subtrees on these spheres, so a bound that is short by one unit deletes
   geometry from the frame, silently and only from some angles.
10. The music stream, if the image has one: `miMusBase` points at block 5, the
   block is non-resident and flagged `BF_PAGES`, its header is a v1 `MU` stream,
   its DMA window fits `MUSWINDOW`, its loop point is inside it, and the padding
   for the last record's over-read is present. An image with no music block must
   have `miMusBase == 0` — a block that is present but unreachable sounds
   exactly like a build with no tune in it, and is not.

and writes `build/assets-map.png`, a top-down render of the *decoded* blocks —
segs coloured by ramp, subsectors outlined — which is the check that the
geometry survived packing at all.


---

## 9. Getting the image onto a machine

Both delivery paths turned out to have a trap, and both traps are silent from
inside the C64 — the REU answers every transfer and returns whatever is in its
RAM. So both are checked rather than assumed: `mapload.asm` verifies the header
and sums each block, and `make check` / `make u64-map` assert the results.

### 9.1 The image is padded to the REU size, and that is not cosmetic

VICE's `-reuimage` loads the file with `util_file_load()`, which fails unless the
file is **exactly** the emulated REU size. On a mismatch it prints
`Reading REU image ... failed` to stderr, boots anyway with a zeroed REU, and the
engine reads a header full of nothing.

So `wad2reu.py` pads every image to `REU_IMAGE_SIZE` and the Makefile runs a
matching `-reusize`. **Raise the two together or neither** — that pair went out
of step once, on 2026-08-10, when `REU_IMAGE_SIZE` went to 512 KB for the music
stream and `-reusize 128` did not follow: VICE refused the image and fell back
to a BASIC `READY` screen, which is indistinguishable from a hung engine until
you read its stderr. `+reuimagerw` is also passed, so VICE does not write the
image back on exit and stamp runtime state into a build artifact.

The size is currently **512 KB**: 128 KB was VICE's smallest REU and the
smallest real 1750, and it stopped being enough when the music stream (block 5,
~400 KB at offset `$010000`) was added. On real hardware the machine's own
**REU Size** setting has to cover it too; `u64push.py` checks that and refuses
rather than uploading an image the machine cannot hold.

### 9.2 REU Preload delivers the image — but only when armed from the menu

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

**Retested with an image exactly the size of the REU, and it still does not
deliver.** Everything above used a 128 KB `doom.reu` against a 16 MB REU, and
the one variation never tried was the other direction: an image that is exactly
`REU Size`, which is what VICE demands of `-reuimage` (§9.1). `build/intro.reu`
is padded to exactly 16 MB, so that configuration is now testable. Uploaded over
FTP, `REU Preload Image` / `Offset` / `Preload` armed and read back correct, a
reset performed, and REU RAM read back through `src/reuload.asm`'s fetch:

| REU offset | result |
|---|---|
| `$000000` | matches the image |
| `$004000` | matches the image |
| `$400000` | 1 of 256 bytes match |
| `$700000` | 0 of 256 bytes match |

The two low offsets are not evidence of anything — a previous `reuload.asm`
upload wrote them, and REU contents survive a reset. The 4 MB and 7 MB probes
are the discriminator, because no upload in this project has ever written past
about 1.3 MB, and they come back as uninitialised SDRAM.

**But that is a statement about the REST API, not about preload.** Setting the
same three items from the Ultimate's *own menu* and resetting **does** deliver
the image — confirmed on the same machine and firmware, with `intro.prg`
playing 3.6 MB of music that nothing ever pushed. So the feature works; what
does not work is arming it through `PUT /v1/configs/...`. The write is
accepted, `GET` reads it back correct, and the load step still never happens —
the config item and the action behind it are evidently not wired together on
this path.

That split the two images, for a while:

- **`intro.reu` (3.6 MB, changes only when the mp3 does)** is loaded by hand
  from the menu, once, and survives resets. `run-intro-u64` therefore pushes
  only the PRG.
- **`assets.reu`**, rebuilt on every map or packer change, stayed on the
  `reuload.asm` path in §9.3, because a manual menu step per build seemed worse
  than a three-chunk upload.

**The split stands, and preload cannot be driven from the host at all**
(2026-08-11). `assets.reu` was moved to preload for a day, after the chunked
uploader appeared to fail on a 512 KB image, and moved straight back when both
halves of that turned out to be wrong:

- The uploader was not failing on size. `_stash_chunk` was sending `GO_DONE`
  after every chunk, and `GO_DONE` *terminates* the stub — see §9.3. Fixed;
  the same 3-chunk upload now verifies clean.
- Preload does not fire on any reset the host can ask for. Measured directly,
  by poisoning REU RAM at five offsets with a pattern that is not in the image
  and reading it back: after `machine:reset` — still poisoned; after the reset
  inside `run_prg` — still poisoned. Only a reset from the machine's own menu
  or a power cycle delivers, which is how `intro.reu` was loaded by hand and
  why that looked like it worked.

That leaves `assets.reu` on the `reuload.asm` path in §9.3 (automatic,
verified per chunk) and `intro.reu` on the menu (loaded by hand, once, and it
survives resets). `--reu-mode preload` uploads the file over FTP for that
workflow, checks the three settings read back armed — an unarmed preload fails
exactly like an armed one, because the REU answers every transfer with
whatever its RAM already held — and then says plainly that a hand reset is
still required, because nothing it can do will complete the job.

**The failure this hid is worth naming.** The engine ran, mapOK=1, all three
resident blocks checksummed correct, and the walls were still garbage: the
resident blocks all live in the first 4 KB of the image, so an image whose
first 16 KB arrived and whose tail did not passes `--verify-map` exactly like
a whole one. `--verify-reu` closes that — it diffs the entire used region,
streamed blocks included — and `make u64-map` now runs both.

### 9.3 The chunked uploader (`--reu-mode stash`)

`src/reuload.asm` is a small standalone PRG with an 8-byte mailbox at `$0340`.
The host DMAs a chunk into C64 RAM with `machine:writemem`, writes the mailbox
in one go — the trigger byte is **last** in the mailbox, so the stub cannot see
it before the parameters it describes — and the stub issues the REU stash.
`tools/u64push.py` drives it in 16 KB chunks and reads every chunk back with a
matching REU **fetch** before moving on, because this is exactly the leg of the
path that turned out not to be trustworthy.

E1M1's map blocks are ~36 KB of used bytes, so three chunks — but the music
stream sits at `$010000` and runs to ~467 KB (§4.6), so a full upload is
**28 chunks**, which is minutes rather than seconds.

**Two things keep that off the common path** (2026-08-11):

- **Only the chunks a descriptor claims are sent.** `image_regions` walks the
  block descriptors instead of taking one span from 0 to the last claimed byte,
  so the 28 KB hole between the map and `MUSIC_OFFSET` is no longer uploaded as
  zeros. Worth one chunk of 29 — less than it looks, because the hole is
  smaller than the stream by a factor of fifteen.
- **A chunk whose content has not changed is not sent again.** REU RAM survives
  a reset, so the previous upload's bytes are still there; `u64push.py` hashes
  each chunk into `build/.reu-upload-cache.json` and skips the matches. The
  music never changes between builds, so the rebuild-and-run case sends **zero
  chunks** and `make run-u64` takes about 8 seconds.

The cache is only believed when a random 16-byte token it recorded still reads
back from REU `$00F010` — in the hole above `reuProbe`'s scratch (§9.4), which
no descriptor claims and no chunk covers. The token is cleared *before* an
upload and written *after* a successful one, so a power cycle, a hand load from
the machine's menu, or an upload that died halfway all fail the check and send
everything. `--verify-reu` reads back every chunk regardless, skipped ones
included; `--no-reu-cache` forces a full send.

This is the same discipline as everything else on this path: the mechanism that
makes the upload fast is not trusted to be correct, it is checked by a
mechanism that does not share its assumptions.

**`go` = `$ff` means terminate, not "chunk done".** `rlDone` in `reuload.asm`
is an infinite loop that performs no further transfers — and it keeps clearing
the trigger byte, so the host's poll is answered instantly and every later
command is silently ignored. The host does not see a hang; it sees a verify
failure, because the fetch never ran and the readback is the zeros the host
itself staged in the buffer. From the retry refactor until 2026-08-11
`_stash_chunk` sent it after *every* chunk, so:

- every upload past one chunk failed at chunk 2, always;
- the byte count differing was exactly the non-zero bytes of that chunk
  (4489 of 16384 for `assets.reu`, all 32768 in the one 32 KB-chunk
  experiment) — the tell, in hindsight, that the readback was pure zeros
  rather than corrupt;
- retrying in place could never help, and restarting the stub "recovered"
  precisely one further chunk, which is what made a deterministic bug look
  intermittent and drove the whole retry/restart apparatus in `u64push.py`.

It is now sent once, by `finish_stub`, after the last chunk.

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

# GeoRAM versus REU for this engine

**Status: decided — the answer is no. Stay on the REU.** §9.1's measurement has
been taken on the hardware (2026-08-10, firmware 1.1.0 / FPGA 122 / core 1.49)
and it came back negative: I/O accesses on the Ultimate are synchronised to the
1 MHz bus. **§11 has the numbers and supersedes the arithmetic in §4 and §5**,
both of which assume the opposite and are wrong. The rest of the document is
left as written, because the reasoning is still the right reasoning — it was
the input that was missing, and §9.1 was correct that this one measurement
decides everything.

This began as analysis, not a decision. It exists because the question "would a
memory-mapped window beat a DMA engine here?" has a *quantitative* answer for
this engine, and one measurement nobody had taken decided it.

Everything below is measured against the numbers already in the tree:
`IMPLEMENTATION_PLAN.md` §10 (REU throughput), §13 (frame time and the
per-frame instrumentation counters), `pipeline.md` §12 (frame budget), and
`docs/reu-format.md` (what is actually streamed).

---

## 1. The short version

The REU was chosen under an assumption that was true on a 1 MHz C64 and is
**false on a 64 MHz Ultimate**: that DMA is the fast way to move bytes.

REU DMA is 1 byte/µs, flat, and — measured, §10 — *does not scale with the
turbo clock*. At 64 MHz the CPU copies a byte in ~8 cycles = 0.125 µs. **The
CPU is eight times faster than the DMA engine.** Every byte this engine
streams is therefore paid for at the worst rate the machine offers.

GeoRAM is not a DMA engine. It is a 256-byte window at `$DE00` plus two
page registers. If that window runs at the turbo clock, then a subsector's
segs are not *fetched* at all — they are simply *read where they lie*, at
`lda $DE00,y`, four cycles a byte, with no staging buffer and no transfer.

For E1M1 as it renders today that is worth **~2.4 ms of a 39.9 ms frame
(~6%)** — more than half of the "~10% and it locks at a solid 25 fps" gap the
README describes. For **textured walls it is the difference between possible
and not**: the same wall columns cost ~20 ms/frame over REU DMA and ~0.02 ms
through a GeoRAM window.

**The one thing that decides it:** whether an access to I/O space on the
Ultimate 64 runs at the turbo clock or is synchronised down to the 1 MHz bus.
If I/O accesses are 1 MHz, a GeoRAM read costs ~1 µs — exactly REU DMA's rate
— and the entire advantage evaporates. §9 says how to settle that in an
afternoon, **without owning or configuring a GeoRAM**, using the benchmark
harness already in `src/reubench.asm`.

---

## 2. What the two devices actually are

| | REU (1750-style) | GeoRAM |
|---|---|---|
| Mechanism | DMA controller; halts the 6510 and moves bytes itself | 256-byte memory window, CPU-addressable |
| CPU-visible footprint | 11 registers at `$DF00-$DF0A` | window `$DE00-$DEFF`, two write-only registers |
| Addressing | 24-bit source/dest/length in registers | `$DFFF` = block (16 KB), `$DFFE` = page (256 B) |
| Address formula | linear, set once per transfer | `addr = block<<14 \| page<<8 \| offset` |
| Capacity | 16 MB on the Ultimate | 512 KB classic; 1–4 MB on clones (NeoRAM) and in VICE |
| Cost of one byte | 1.00 µs, clock-invariant (measured, §10) | one `lda abs,y` — 4 cycles **if** I/O runs at CPU speed |
| Cost of *seeking* | ~90 cycles of register setup per transfer | 2 stores = 8 cycles per page change |
| Can it write? | yes (stash) | yes, the window is RAM |
| Registers readable? | status at `$DF00` | **no** — both registers are write-only; shadow them in RAM |
| Bulk block move | one command, CPU idle-but-halted | a CPU copy loop, or none at all if you read in place |

Two structural consequences fall out of that table before any timing.

**GeoRAM has no transfer, so it has no staging buffer.** `SEGBUF` (`$9740`,
128 B) exists only because the REU must deliver bytes *somewhere* in the 64 KB
address space. A subsector slot is 128 bytes and page-aligned, so two slots
fit a GeoRAM page exactly: `doWall` would read seg fields straight out of the
window with the same `lda abs,y` it uses today on `SEGBUF`. The copy is not
made faster, it is deleted.

**GeoRAM's granularity is the page, and this format is already page-shaped.**
`docs/reu-format.md` §1 rule 3 — "arrays the 6502 indexes with a single `X`
must be ≤ 256 entries" — produced SoA blocks of 240 and 96 entries and 128-byte
subsector slots. Every one of those maps onto a GeoRAM page without being
repacked. The format was designed for a windowed device by accident.

---

## 3. What this engine actually asks of external memory

Per frame, from the instrumentation counters in `IMPLEMENTATION_PLAN.md` §13
(E1M1, after both culling passes):

| Access | Count/frame | Bytes each | Bytes/frame |
|---|---:|---:|---:|
| node bounding sphere (`nodeSphere`) | ~82 (71.7 descended + 10.2 culled) | 8 | 656 |
| subsector slot header (`ssecHdr`) | 49.4 (39.3 drawn + 10.1 culled) | 8 | 395 |
| subsector segs (`ssecSegs`) | 39.3 | 10 × 3.09 | 1221 |
| **total** | **~131 transfers** | | **~2272 B** |

Three properties matter more than the total:

1. **Every access is small.** The mean transfer is 17 bytes. This is random
   access to a structured store, not streaming.
2. **Every access is on the critical path.** There is no prefetch
   (`pipeline.md` §14: `PredictStreaming` is "per visit, not predictive"), so
   the CPU is halted for the full duration each time.
3. **The read pattern is pointer-chasing**, driven by the BSP descent. Nothing
   about it is sequential, so the REU's one genuine strength — moving a large
   contiguous block in one command — is never exercised.

That is close to the worst possible workload for a DMA engine and close to the
best possible one for a memory window.

---

## 4. The cost model at 64 MHz

One cycle at 64 MHz is 15.6 ns. The relevant rates:

| Operation | Cost | Per byte |
|---|---:|---:|
| REU DMA | 1.00 µs/byte, **clock-invariant** | 1.000 µs |
| CPU copy `lda abs,x` / `sta abs,x` | 8 cycles | 0.125 µs |
| CPU read in place `lda abs,y` | 4 cycles | 0.063 µs |
| GeoRAM page change | 8 cycles (2 × `sta abs`) | — |

This is the inversion, and it is worth stating plainly because the whole
project was architected before it was measured: **on a stock C64 the REU moves
bytes 5–8× faster than the CPU can; on a 64 MHz Ultimate the CPU moves them
8× faster than the REU.** §10 already drew one conclusion from this (DMA span
fill is dead, 6× slower than CPU stores). This document draws the other one.

### Per-access comparison

| | REU today | GeoRAM |
|---|---|---|
| node sphere (8 B) | ~90 cy setup (1.4 µs) + 8 µs DMA = **9.4 µs** | index→block/page (~25 cy) + 2 stores (8 cy) + read in place = **~0.5 µs** |
| subsector header (8 B) | ~90 cy setup + 8 µs = **9.4 µs** | ~0.5 µs, and the sphere test then reads the six bytes *in the window* |
| 3.09 segs (31 B) | ~70 cy setup + 31 µs = **32.1 µs** | **0 µs** — same page as the header; `doWall` reads the window directly |

### Per-frame

| | REU | GeoRAM |
|---|---:|---:|
| streaming cost | **~2.4 ms** | **~0.07 ms** |
| share of a 39.9 ms (two-PAL-frame) budget | **6.0%** | 0.2% |

The README's position is that compute sits just under the two-raster-frame
boundary, three frames in four make 25 fps, and "another ~10% off the frame
would lock the game at a solid 25". **This is 6 of that 10**, and unlike the
other candidates (dirty-tile `convert`, deferred floors) it costs no rendering
work and cannot change a pixel — the bytes arriving are identical, only the
mechanism that fetches them differs. That makes it the cheapest of the
remaining optimisations to *verify*: the pixel-diff harness used for both
culling passes applies unchanged, and 0-of-104448-pixels-differ is the whole
acceptance test.

---

## 5. Where it actually becomes decisive: textures and big LUTs

M1's streaming is 2.3 KB/frame. **Textured walls are a different order of
magnitude**, and this is where the choice stops being a 6% optimisation.

`pipeline.md` §14 step 3 turns `spanFill` into a texture sampler. A textured
column needs its texture column resident while the column is drawn:

| | REU | GeoRAM |
|---|---|---|
| 160 columns × 128-texel texture column | 20480 B DMA = **20.5 ms/frame** | 160 page selects = 1280 cy = **0.02 ms** |
| verdict | **impossible** — half the frame budget before a single texel is shaded | free |

A 128-texel texture column fits inside one 256-byte page with room to spare.
Store textures **column-major, one page per column**, and the texture mapper's
inner loop is `lda $DE00,y` — the same four cycles it would cost if the texture
were in main RAM, except that main RAM has no 40 KB to give it. The paging
write happens once per screen column, in the outer loop, where 8 cycles
disappears.

Any REU-based texturing scheme has to pay 1 µs per texel fetched, once, before
shading. There is no cache, no batching that helps (§10: no setup penalty
means no economy of scale), and column-major locality does not reduce byte
count. The honest conclusion is that **REU streaming and textured walls are
incompatible at 64 MHz** unless the texture working set is cut to something
that fits in main RAM — which is a few kilobytes, i.e. a handful of textures.

### The user's LUT question, specifically

> lookup tables can only reside in GeoRAM and the actual lookup can be done by
> mapping the particular bank to the C64's RAM and use directly

Yes, and the rule that makes it work is: **the page index must be the
slowly-varying dimension of the table.** A lookup costs 4 cycles when it lands
on the currently-mapped page and 12 when it does not, so the table's layout has
to align with the loop that reads it.

`data_structures.md` §3 lists the LUTs the target architecture wants and
`pipeline.md` §12.2 shows what actually fits today: `sqr` 1024 B, `sin` 512 B,
`scrTab`/`colTab` 512 B, 4 KB of dither. §3.2's **reciprocal LUT does not
exist** — the engine divides — and §3.6's texture step LUTs do not exist,
because there is nowhere to put them.

| LUT | Size | Access pattern | Fit |
|---|---:|---|---|
| `sqr` quarter-square (mul8) | 1 KB | two random reads per multiply, across 4 pages | **keep in RAM** — 2 page writes per multiply is a loss |
| `sin`/`cos` 2.14 | 512 B | random by angle | **keep in RAM** — hot, tiny, already fits |
| 16-bit reciprocal 1/z | 128 KB | `z` hi byte → page, lo byte → offset | **GeoRAM.** `z` varies smoothly along a wall, so the page is usually already right. Replaces `udiv` in the column loop |
| texture step / depth bucket (§3.6) | tens of KB | one bucket per wall | **GeoRAM.** Page = depth bucket, chosen once per wall |
| texture columns | 100s of KB | one page per screen column | **GeoRAM**, as above |
| column ray LUT (§3.3) | 160 entries | sequential by column | RAM |

The distinction is not "big versus small" — it is **how often the page changes
relative to how often you read**. Tables read once per wall or once per column
are perfect. Tables read twice per multiply are not, and belong in the 64 KB
where they already are. GeoRAM does not replace main RAM for hot tables; it
makes possible the class of tables that *cannot exist today at any size*.

---

## 6. How the existing data would land in GeoRAM

No format changes are needed. `docs/reu-format.md` maps over directly:

| Block | Today | With GeoRAM |
|---|---|---|
| `SSECDATA` | streamed, slot `i` at `base + (i<<7)` | block `i>>7`, page `(i>>1)&63`, offset `(i&1)<<7`. Two slots per page, never straddling. Read in place; **`SEGBUF` is deleted** |
| `NODESPH` | streamed, 8 B at `sphReuBase + (i<<3)` | 32 records/page; or fold into the subsector slot header, where it already appears |
| `NODES` | **resident**, 2880 B at `$D000` | 240-entry SoA arrays are one page each — 12 pages. Could stay resident, *or* move out and **free 2.8 KB of RAM** at the cost of a page write per field read |
| `SECTORS` | **resident**, 576 B at `$DC00` | 96-entry arrays, 6 pages; same trade |
| `MAPINFO` | resident, 32 B | resident, unchanged |

That third row is the second prize, and it is not small: `pipeline.md` §12.2
says "there is no free block below MATRIX any more" and the engine's code lands
in **eight fragments** because that is where the holes are. Moving `NODES` and
`SECTORS` into GeoRAM hands back the whole `$D000-$DEFF` region — with the
caveat that `sideOf` reads 8 node fields per visit, so 8 page writes per node
against ~82 node visits is ~5200 cycles = 0.08 ms/frame. Affordable, but it is
a real cost, and it is optional: keep them resident and pay nothing.

### The `$01` banking discipline still works, with one wrinkle

The GeoRAM window is at `$DE00`, in I/O space. `docs/reu-format.md` §6.1's two
states survive intact:

| `$01` | `$D000-$DFFF` | Sees |
|---|---|---|
| `$35` | I/O | **GeoRAM window and registers** |
| `$34` | RAM | resident `NODES` / `SECTORS` |

The engine already alternates exactly this way for every REU transfer, so the
discipline is not new. The wrinkle: `SECTORS` occupies `$DC00-$DE3F`, which
*overlaps* the window's address range. They are different banks and cannot
collide — but a loop that reads a sector height and a GeoRAM byte in the same
breath must bank-switch between them, 10 cycles each way. `secFront` already
does this dance for the REU.

The §6.1 note about interrupts applies with more force, not less: an interrupt
handler taken between `sta $DFFE` and `lda $DE00,y` that itself touched GeoRAM
would corrupt the read. Interrupts are masked for the whole run, so this is
fine today, and it is one more entry on the list of things that break if a
music IRQ is ever added (`pipeline.md` §14 step 6).

---

## 7. What GeoRAM costs you

Honest accounting; none of these is fatal, three are real work.

**Capacity: 512 KB against 16 MB.** E1M1 packs to 34 KB, so this is not an M1
constraint. It becomes one around "all nine E1 maps plus a texture set":
9 maps ≈ 310 KB (mostly the 128-byte slot padding), leaving ~200 KB for
textures and LUTs. A 4 MB clone or the emulated equivalent removes the problem;
a 512 KB classic makes the 128-byte slot padding stop being free, and §5's
"padding costs REU space, which is free" is the one sentence in
`docs/reu-format.md` that a GeoRAM migration falsifies.

**Write-only registers.** Neither `$DFFE` nor `$DFFF` reads back. Every
routine that changes the page must either restore it or leave a documented
postcondition, and a shadow copy in zero page is the usual answer. This is the
kind of invariant this project already enforces with `.errorif` and probe
assertions, but it is a *new* class of silent failure: a stale page register
returns valid-looking data from the wrong subsector, and the frame renders
wrongly rather than crashing.

**No DMA means no free bulk moves.** Nothing in the engine currently wants one
(§10 killed the only candidate), and boot-time residency becomes a CPU copy of
3488 B at ~8 cycles/byte = 0.4 ms — faster than today's REU path, which has to
stage through MATRIX because DMA cannot reach under I/O (§6.2). Net win, but
worth stating that the win exists only because the CPU is fast.

**The tooling chain has to be rebuilt and re-earn its trust.** This is the
largest real cost, and `docs/reu-format.md` §9 is the reason: three separate
silent failures have already been found on the delivery path, each one letting
every read "succeed" and return the wrong bytes. What would need redoing:

| Piece | Today | With GeoRAM |
|---|---|---|
| host → device | `reuload.asm` stub + `machine:writemem`, 16 KB chunks | 256 B/page through the window. **Possibly no stub at all** — if `machine:writemem` reaches I/O space, the host can write `$DFFF`/`$DFFE`/`$DE00` directly. Unverified; see §9 |
| verification | REU fetch read-back per chunk + `mapSum` per block | same shape; readback is *easier* because `machine:readmem` on `$DE00` reads the window through the current banking |
| VICE | `-reuimage`, exact-size padding to 128 KB (§9.1) | `-georam -georamsize -georamimage`; the exact-size trap probably applies identically — verify |
| presence probe | `reuProbe`, signature round-trip | same idea, **but harder to get right**: an absent cartridge leaves an open bus, and open I/O reads on a C64 do not reliably return zero. Probe by writing *different* signatures to two pages and checking that changing `$DFFE` changes what comes back — a test that open-bus cannot pass |
| `make check` asserts | `reuOK`, `mapOK`, `mapSum` | identical set, renamed |

**The Ultimate's own I/O usage.** The Ultimate cartridge has a command
interface in the `$DF00` range and some modes claim I/O1. Whether GeoRAM
emulation, the REU, and the Ultimate's own registers can coexist is a config
question, not a design one — but note that the classic GeoRAM decodes its
registers in I/O2 and several clones **mirror them across the whole
`$DF00-$DFFF` page**, which is where the REU lives. Plan on this being an
either/or: REU *or* GeoRAM, not both.

---

## 8. What neither device fixes

Worth saying, because the framing "memory is the bottleneck" is wrong for this
engine. From `pipeline.md` §12.1:

| Stage | Share of frame |
|---|---:|
| `spanFill` | 38.7% |
| `convert` | 36.4% |
| wall geometry | 12.7% |
| **all external-memory streaming** | **~6%** |

**75% of the frame is two byte-per-pixel passes over 28 KB of main RAM**, and
neither an REU nor a GeoRAM touches them. The dirty-tile `convert` of
`design.md` and the deferred floor/ceiling pass remain the two largest wins
available, by a factor of six. GeoRAM's case is that it takes 6% for a
mechanical change with a pixel-exact acceptance test, and that it unblocks
step 3 of `pipeline.md` §14 — not that it is the biggest number on the page.

---

## 9. The three unknowns, and how to settle each cheaply

### 9.1 Does an I/O access run at the turbo clock? — *decisive, and free to test*

Everything in §4 assumes `lda $DE00,y` costs 4 cycles at 64 MHz. If the
Ultimate synchronises I/O-space accesses to the 1 MHz bus, it costs ~1 µs —
**identical to REU DMA per byte, plus register writes** — and GeoRAM is
strictly worse than what is already built. There is no middle case that
changes the recommendation.

**This is testable today, with no GeoRAM, on the current build.**
`src/reubench.asm` already has the harness: it times N iterations with CIA 2
Timer A (which ticks at 1 MHz regardless of the turbo setting, established in
§10), subtracts a neutered baseline, and DMAs the results back to the host.
Clone it as `src/iobench.asm` and time three loops at `$D031 = $00` and
`$D031 = $0F`:

| Loop | Address | What it tells you |
|---|---|---|
| `lda $DE00,x` × 256 | open I/O1 — where the window would be | the number that decides this document |
| `sta $DF09,x` × 256 | REU IRQ mask, harmless to write | whether I/O *writes* (the page registers) are slow too |
| `lda $C000,x` × 256 | plain RAM | the control — this one must show ~64× |

If the RAM control shows a 64× spread and the I/O loops show ~1×, stop reading:
stay on the REU. If the I/O loops track the RAM control, §4's arithmetic holds
and the migration is worth costing out properly.

One caveat on interpreting it: open-bus I/O1 and an *emulated cartridge*
answering at I/O1 need not have the same timing path. This test can cleanly
disprove the idea; confirming it needs a real GeoRAM configured (§9.2).

### 9.2 Does the Ultimate emulate GeoRAM at all?

The machine at `192.168.1.65` was unreachable while this was written, so this
is unanswered. It is one REST call:

```sh
python3 - <<'EOF'
import sys; sys.path.insert(0, 'tools')
from u64 import Ultimate
u = Ultimate('192.168.1.65')
print(u._json("GET", "/v1/configs"))          # every category
print(u.get_category("Cartridge Settings"))    # and the one that would carry it
EOF
```

If the answer is no, the fallback is a physical GeoRAM in the U64's cartridge
port — and that almost certainly settles §9.1 in the negative, because the
external port runs at C64 bus timing. **Internal emulation is a precondition,
not a detail.**

### 9.3 Can `machine:writemem` write I/O space?

If yes, the host can page GeoRAM itself and the whole `reuload.asm` stub
disappears from the upload path — 136 page-writes for E1M1 with no C64-side
code, and `machine:readmem` verifies each page directly instead of via
checksums. If no, a GeoRAM equivalent of `reuload.asm` is an afternoon; it is
the same mailbox pattern with a `sta $DFFE` in place of the DMA command.

Test: `writemem($DF09, b'\x00')` is harmless — but so is every read of a
register that does not read back, so test it somewhere observable: write the
border colour at `$D020` and look at a screenshot.

---

## 10. Recommendation

| If §9.1 says | Then |
|---|---|
| I/O accesses run at the turbo clock **and** §9.2 says the Ultimate emulates GeoRAM | **Migrate, after M1 ships.** Expect ~2.4 ms/frame (6%) back for a change with a pixel-exact acceptance test, `SEGBUF` deleted, and — the real prize — textured walls becoming affordable at all. Budget the tooling rewrite in §7 honestly; it is most of the work |
| I/O accesses are synchronised to 1 MHz | **Stay on the REU.** GeoRAM's per-byte cost equals DMA's and it adds banking, write-only registers and a tooling rewrite for nothing |
| the Ultimate has no GeoRAM emulation | **Stay on the REU.** An external cartridge on the U64 port will not be fast, and M1 targets the Ultimate |

Sequencing, in any case: **not before Milestone 1.** The REU path works, is
asserted end-to-end by `make check`, and the three silent failures it has
already survived are exactly what a rewrite would have to re-discover. §9.1 is
worth running now — it is an hour, it reuses an existing harness, and its
answer is a fact about the machine that will inform the texture work regardless
of what happens to the REU.

### If the answer is "stay on the REU"

The same ~2.4 ms is partly reachable without changing hardware, by moving
fewer bytes:

- **Shrink the seg record from 10 bytes to 6.** Seg endpoints are stored as
  four absolute 16-bit coordinates. Relative to the subsector's bounding-sphere
  centre — already in the slot header — E1M1's segs fit in signed bytes for the
  overwhelming majority of cases, with an escape flag for the rest. 122 segs ×
  4 B = **488 B/frame ≈ 0.5 ms**, at the cost of an add per coordinate (~20
  cycles = 0.3 µs, so it pays for itself 3:1).
- **Fold `NODESPH` into the parent's slot.** A node's sphere fetch is 8 bytes
  for 6 used; the padding-for-shift trade (§4.4) costs 2 bytes × 82 fetches =
  164 B/frame. Small, but it is pure waste at 1 µs/byte.
- **Prefetch.** `pipeline.md` §14 flags `PredictStreaming` as "per visit, not
  predictive". The REU halts the CPU, so prefetch cannot overlap with compute —
  it can only merge transfers, and §10 established there is no setup penalty to
  amortise. **This one does not work.** Worth writing down so it is not
  re-proposed.

---

## 11. The measurement, and what it settled

Taken 2026-08-10 on the Ultimate at `192.168.1.65`, firmware 1.1.0 / FPGA 122 /
core 1.49, with `RAM Expansion Unit` = `GeoRAM Mode`, `REU Size` = 4 MB — a
real GeoRAM window, not §9.1's open-bus stand-in. Harness: `src/geobench.asm`
and `tools/geobench.py`, CIA 2 timer A, empty loop measured and subtracted, so
each figure is one instruction.

| Access | 1 MHz | 64 MHz | Speedup |
|---|---:|---:|---:|
| `lda $c000,x` — plain RAM, the control | 3997 ns | 63.5 ns | **63.0×** |
| `sta $c000,x` — plain RAM, the control | 4997 ns | 79.6 ns | **62.8×** |
| `lda $de00,x` — GeoRAM window read | 3997 ns | **920 ns** | 4.3× |
| `sta $de00,x` — GeoRAM window write | 4997 ns | **1920 ns** | 2.6× |
| `sta $dffe` — page select | 3997 ns | 920 ns | 4.3× |

The control is what makes this readable: plain RAM shows the full 63× turbo
spread, so the clock switch took and the timer is honest. Against that, the
window barely moves. The gross figures are exact to the microsecond — 2048
accesses in 2048 µs, writes in 4096 µs — because **every I/O access is locked
to one 1 MHz bus cycle, and a write to two.**

**A GeoRAM window read costs ~1 µs. REU DMA costs 1.00 µs/byte (§10). They are
the same number.** This is the second row of §10's table, and the
recommendation there stands unaltered: stay on the REU.

Reproduced the same day with the Ultimate's bad-line timing disabled. The
64 MHz column came back bit-identical — 2048 µs gross, 920.4 ns/access, 4096 µs
and 1920.4 ns for the write — which is the expected result, since
`geobench.asm` blanks the screen before timing anything and the VIC was already
out of the measurement. It confirms the 1 µs floor is I/O decode synchronised
to φ2, not bus contention: nothing about screen timing can move it. In that
run every 1 MHz row also collapsed onto two values (3534.7 ns for the reads and
page select, 4534.7 ns for the writes) — at bus speed the window is
indistinguishable from RAM, which is the control result the fast pass needs.

Three consequences worth stating explicitly, because they kill the two
strongest claims in this document:

1. **§4's ~2.4 ms/frame saving does not exist.** At 0.92 µs a byte instead of
   1.00, the ~2272 B/frame of §3 costs ~2.1 ms against the REU's ~2.4 ms. The
   6%-of-frame prize is roughly 0.7%, before counting the page selects, which
   are 0.92 µs each and which the REU does not pay.
2. **§5 is false, and it was the real argument.** "REU streaming and textured
   walls are incompatible at 64 MHz" is true — but so is GeoRAM streaming. A
   texture sampler's inner loop is `lda $de00,y` at 0.92 µs a texel, not the
   four cycles §5 assumes, so 160 columns × 128 texels costs ~18.8 ms/frame
   rather than 0.02 ms. The window does not unblock `pipeline.md` §14 step 3.
   Whatever makes textures affordable, it is not this.
3. **Reading in place would be a regression, not a saving.** Today `doWall`
   reads seg fields out of `SEGBUF` in main RAM at 4 cycles. Deleting the
   staging buffer moves those reads into the window at 920 ns each — 14.5×
   slower per access — and `doWall` reads several fields more than once. The
   one structural elegance GeoRAM offered turns out to be the thing that costs
   the most.

The honest summary: this document's reasoning was sound and its conclusion
inverted by a single fact about the machine. On a 64 MHz Ultimate the CPU is 8×
faster than DMA *for main-memory work*, which is what §10's dead span-fill
established — but it has no fast path to expansion memory at all. Both devices
reach it at 1 µs a byte. The memory is not the bottleneck (§8), and no choice
of expansion device changes that.

### A trap in the tooling, found on the way

Worth recording because it cost most of a session and will re-bite anyone who
probes a cartridge device over REST: **`runners:run_prg` starts the program
with the Ultimate's cartridge personality disabled.** A GeoRAM probe delivered
that way reports "no device, open bus at $de00" on a machine where memtest64,
loaded normally, finds 4 MB. The REU is not a cartridge and is unaffected,
which is why nothing in this project ever noticed.

`tools/u64.py` grew `run_prg_basic()` for this: reset, DMA the program into
RAM, fix BASIC's `VARTAB`, and type `RUN` through the keyboard buffer. That
leaves the machine in the state an ordinary load-and-run leaves it in, cartridge
included. Anything testing a cartridge-side device must use it; `run_prg` is
fine for everything else.

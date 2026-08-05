# Doom C64U — implementation status and plan

The other four documents in this repo (`design.md`, `algorithm.md`,
`data_structures.md`, `3d-renderer-design.md`) describe the intended architecture.
This one tracks what is actually built, what is broken, and what happens next.

## Status

**Milestone 1 — walkable 3D demo: written, not yet working.** Every module is
complete, but the program hangs during its first frame and the display stays black.

| File | State |
|---|---|
| `src/main.asm` | VIC setup, spawn, main loop, HUD blanking |
| `src/defs.asm` | memory map + zero-page allocation |
| `src/math.asm` | `mul8` (quarter-square), `umul16`, `smulTrig`, `ssmul32`, `udiv`, `sdiv`, `spanFill` |
| `src/render/walls.asm` | portal traversal, near-plane clip, projection, line interpolators, column spans |
| `src/render/chunky2mc.asm` | Bayer-dithered chunky→multicolor converter, double buffering, `flip` |
| `src/input.asm` | WASD + joystick 2, convex-sector containment |
| `src/testmap.asm` | 3 sectors, 16 walls, 2 portals |

Nothing beyond Milestone 1 exists yet: no WAD parsing, no REU streaming, no textures,
no sprites, no music. `assets/DOOM1.WAD` is committed but unused, and the `assets` /
`run-u64` make targets call `tools/wad2reu.py` and `tools/u64push.py`, neither of
which has been written.

## The black screen — diagnosed

Reproduced under VICE 3.7.1 and traced with `tools/vicedbg`.

The program **hangs with a CPU JAM at `$CDD7`** (VICE logs
`*** Main CPU: JAM at $CDD7`). That address is not an instruction boundary: `$CDD5`
holds `9d 00 02` = `sta $0200,x` (`sta colTop,x`), so `$CDD7` is its second operand
byte — and `$02` is the 6510 JAM opcode. Execution landed mid-instruction.

It gets there because **`spanFill` writes outside MATRIX**. Diffing live RAM against
the loaded PRG shows 317 corrupted bytes outside every region the engine is allowed
to touch:

    $09c1-$09dd  $45   inside checkSector code
    $0ac1-$0add  $02   inside the map wall table (wX1Lo)
    $0ec1-$0edd  $45
    $0fc1-$0fdd  $02
    $7e01-$7edd  $45   past MATRIX's end
    $87c1-$88dd  $45   inside the converter's dither tables

The values written are `$45` and `$02` — precisely `secFByte[0]` and `secCByte[0]`,
sector A's floor and ceiling bytes. Each run is 29 bytes long at a stride of 4, which
is exactly the eight stores of `spanFill`'s full-cell loop, and the runs repeat at
`$500` — `spanNextCell`'s `+1280`. There is no ambiguity about which code is at fault.

`spanFill` computes its destination as

    zSPtr = xOfsLo/Hi[zSX] + rowCellLo/Hi[zSY0 >> 3]

`xOfs` has exactly 160 entries and `rowCell` exactly 22, and **neither index is
bounds-checked**. An out-of-range index reads whatever follows the table — `rowCellHi`
is followed at `$CA30` by the walls code itself — producing a pointer outside MATRIX.
The stray writes corrupt the map data and the code, which produces worse geometry,
which produces a worse index. The failure is self-amplifying, which is why it presents
as a dead machine rather than a glitchy frame.

Two facts worth recording:

- **The geometry math is fine.** At the hang, `zTop0/zTop1 = 21`, `zBot0/zBot1 = 100`,
  `zDX = 61`, `zC0 = 0`, `zC1 = 60` — all matching a hand-trace of sector A from the
  spawn point. Projection, trig and the line interpolators are not implicated.
- **`X = $B5` (181) at the JAM**, confirming the runaway column index that
  `build/mon.txt` (`break cd76 if .X > $a0`) was written to catch.

### Aliasing that turns a bad index into a dead machine

`src/defs.asm` puts the clip arrays and the portal stack in one page:

    colBot     = $0300     // indexed 0..159 -> $0300-$039F
    pStkSec    = $03A0     // 12 entries
    pStkXL     = $03B0
    pStkXR     = $03C0
    visitedSec = $03D0

`sta colBot,x` with `x >= 160` writes straight into the portal stack.

## Next steps

1. **Bound the two lookups in `spanFill`** (`src/math.asm`): reject `zSX >= 160`
   before the `xOfs` lookup and `zSY0 >= 176` before the `rowCell` lookup. A few
   cycles on a path that already does a 16-bit add, and a memory stomp becomes a
   dropped span.
2. **Clamp `zC0` on the high side** in `doWall` (`src/render/walls.asm`). It is
   currently clamped up to `zXL` but never down to `zXR`, so a wall with
   `sx0 = 160..255` stores an out-of-range `zC0` and depends solely on the later
   `cmp zC0 / bcs` to reject it.
3. **Move `pStkSec`/`pStkXL`/`pStkXR`/`visitedSec`** out of the `$0300` page into the
   free space below MATRIX (`$0B20-$0FFF`, already covered by the `.errorif * > MATRIX`
   guard in `src/main.asm`), so `colTop`/`colBot` own private pages.
4. Rebuild, re-run `make shot`, and confirm a non-black frame: dark stone ceiling
   band, metal wall band broken by the brighter corridor opening around columns
   60-99, moss floor below.

Beyond Milestone 1, in dependency order: `tools/wad2reu.py` → REU DMA streaming →
real map geometry replacing `testmap.asm` → textured walls → floors/ceilings →
sprites → music. `tools/u64push.py` is independent of all of it.

## Building and testing

    sh tools/setup-dev-env.sh          # VICE + C64 ROMs (see note below)
    make                               # needs KickAssembler
    make shot  VICEWRAP='xvfb-run -a'  # screenshot to build/shot.png
    make debug VICEWRAP='xvfb-run -a'  # live-RAM vs PRG diff

`make debug` is the regression test for the bug above: a healthy run reports **zero**
unexpected differences. It is what found this one, and it will catch the next stray
pointer far faster than staring at a black screenshot.

**KickAssembler** is only distributed from `theweb.dk`. It is not vendored here; put
`KickAss.jar` in `tools/kickass/` or set `KICKASS_JAR`.

**C64 ROMs**: the Debian/Ubuntu `vice` package ships without them, so `x64sc` refuses
to start. `tools/setup-dev-env.sh` restores them from VICE's own upstream tree.

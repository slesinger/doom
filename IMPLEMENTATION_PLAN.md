# Doom C64U — implementation status and plan

Four documents in this repo (`design.md`, `algorithm.md`, `data_structures.md`,
`3d-renderer-design.md`) describe the intended architecture;
[`pipeline.md`](pipeline.md) traces the compute path **as built**, from a key
press to pixels in VIC-II memory. This one tracks what is actually built, what
is broken, and what happens next. [`README.md`](README.md) indexes all of them.

## Status

**Milestone 1 — walkable 3D demo: rendering.** The black-screen JAM is fixed;
`make shot` now produces a non-black frame (dithered ceiling, wall columns,
portal gap) instead of hanging. Walking/turning and the remaining visual
rough edges (see "Known issues" below) haven't been exercised yet.

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

## What fixed the black screen

The four steps from the earlier diagnosis are all applied:

1. **`spanFill` (`src/math.asm`) now bounds-checks both ends of the run**, not
   just the start: `zSY1` is clamped to 176 before the row count is computed
   (a span that starts in-bounds but runs long used to walk `spanNextCell`
   past `rowCell`'s 22 entries one full 8-row cell at a time), and `zSX >= 160`
   / `zSY0 >= 176` are rejected before either the `xOfs` or `rowCell` lookup.
   Clamping the start alone (the original step 1) built clean but still let
   `make debug` catch fresh stray writes at a different address — the end
   also had to be bounded.
2. **`zC0` is now clamped down to `zXR`** in `doWall` (`src/render/walls.asm`),
   not just up to `zXL`, so a wall with `sx0 = 160..255` can no longer store
   an out-of-range column index.
3. **`pStkSec`/`pStkXL`/`pStkXR`/`visitedSec` moved to `$0B20-$0B5F`**, free
   space below MATRIX, out of the page immediately after `colBot`.
4. `make shot` now produces a non-black frame instead of hanging.

Two more things had to be fixed before any of the above could even be
*verified*, both now folded into the tree:

- **The Makefile wrote `doom.prg` outside `build/`.** `-odir ../build -o doom.prg`
  resolved `-odir` relative to the source file's directory but `-o` relative to
  cwd, so the two disagreed and the PRG landed in the repo root — `make shot`/
  `make debug` were then running whatever stale binary happened to be sitting in
  `build/` from a previous manual build. Fixed by pointing `-o` straight at
  `$(PRG)` (`build/doom.prg`) instead of a bare filename.
- **`x64sc` was picking up this machine's saved `vicerc`** from other VICE
  projects (a freezer cartridge, IDE64 drives, JiffyDOS), which silently broke
  `-autostart`: the PRG got injected but the machine sat at a plain BASIC
  `READY.` prompt — CPU parked in the KERNAL input loop, nothing ever executed.
  That is a different failure from the black screen but produces an
  indistinguishable symptom (a screenshot with no rendered frame) and was
  giving `make debug` a false-clean 0-diffs result, since a program that never
  ran also never writes anything to diff. `VICEOPTS` now includes `-default`
  so `shot`/`debug` are hermetic regardless of what else has run `x64sc` on
  this machine. `tools/vicedbg/probe.py`'s `ALLOWED` list also needed `SCREEN1`
  added — it was flagging the converter's legitimate double-buffer writes at
  `$C000-$C3FF` as unexpected.

`make debug` now reports **zero unexpected differences**, with real traffic
(not zero) recorded against MATRIX, BITMAP0, both SCREEN buffers, and the
self-modifying code regions — i.e. it's confirmed the renderer actually ran a
full frame, not just that nothing crashed.

## Known issue: most of the frame is undrawn (separate bug, not yet fixed)

`build/shot.png` shows a clean wall band on the left of the screen; the rest
is black instead of the portal opening and the second solid wall segment.
This is a **different bug from the JAM**. A structured, hypothesis-by-
hypothesis investigation lives in `debug-notes/` (start at
`debug-notes/00-index.md`) — read that before re-investigating, it records
several ruled-out theories so a future session doesn't re-test them. Two
findings from the session before this one, plus this session's narrowing
and a tooling-reliability lesson, below.

**1. Confirmed and isolated: the B→C portal (wall 8) computes a collapsed
(zero-height) opening.** Per-wall instrumentation logging `(zWIdx2, zC0, zC1)`
at `!cols:` in `doWall` confirmed every wall's horizontal clip range is
*correct* for the whole frame — sector A's walls close [0,60), sector B's
open [61,98) with wall 7 solid at [61,70), wall 8 portal at [71,88), wall 9
solid at [89,98); sector C then renders again inside wall 8's own [71,88)
window. That's all as hand-calculated — traversal and horizontal clipping are
not the bug. But `zBT`/`zBB` (the portal opening's clamped top/bottom rows,
computed via `clampAcc` in the `!portal:` branch of `doWall`, walls.asm) come
out `(0, 0)` for every column in wall 8's range, instead of a real opening.
Since `colTop`/`colBot` get narrowed to that `(0,0)` window, the entire
column is subsequently seen as *closed* by everything downstream (sector C's
own walls skip it via the `!closed:` branch) — a razor-thin portal makes the
whole room behind it vanish. Concretely: `zBTop0/1`/`zBBot0/1` (sector C's
ceiling/floor projected through the portal, before clamping into
`[zTW,zBW]`) or the `clampAcc(Y=6)`/`clampAcc(Y=9)` clamp itself is producing
0 instead of a real row — worth a fresh instrumentation pass logging
`zBTop0/1`/`zBBot0/1` directly (unclamped) to see whether the bug is in that
projection or in the clamp.

**2. Reproduced but *not* isolated, and contradicts everything else checked:
some columns *inside wall 2's own [0,60) range* — a plain solid wall, no
portal involved — also end up `(0,0)` instead of the expected `(176,0)`**
(e.g. columns 12–15, 19, 52–60, stable across repeated frame-1 captures).
`(0,0)` is only ever written by the portal-narrow path in `doWall`, which
requires `zBack != $ff`. Two lines of evidence say that can't be happening
for wall 2:
  - A zero-page *store watchpoint* directly on `zBack` ($3b) for a whole
    frame showed it is written exactly once per wall, with values `$ff, $ff,
    $ff, $01, $ff, $ff, $ff, $02, $ff, $ff, $ff` for walls `2,3,4,5,7,8,9,e,f`
    (matching the map's `wBack` table exactly) — never `$00`/anything else
    mid-loop for wall 2.
  - Wall 2's own `zTop0`/`zBot0` (21/100) are sane, non-degenerate, and its
    `[zC0,zC1]` is exactly `[0,60)` (finding 1's instrumentation) — the solid
    branch's close (`lda #176 / sta colTop,x` / `lda #0 / sta colBot,x`,
    walls.asm) is unconditional once reached and cannot itself produce
    `(0,0)`.

  So by source-code reading this is provably impossible, yet reproduces
  every capture.

**3. This session (`debug-notes/`): the "impossible" contradiction is real,
narrowed further, and one leading theory is ruled out.** Two theories that
would unify findings 1 and 2 — a second, small portal wall inside sector A
whose columns overlap wall 2's (hand-derived geometry: sector A's own A→B
portal, wall 3, actually maps to columns `[60,100)`, adjacent to but not
overlapping wall 2's `[0,60)` — refuted, see `debug-notes/C-second-portal-overlap.md`)
and portal-stack slot corruption handing a child sector the wrong
`[zXL,zXR]` window (refuted — live capture confirms sectors B and C receive
*exactly* the windows their portal walls pushed, see
`debug-notes/F-stack-slot-corruption.md`) — were both eliminated. A
camera-locked, per-wall live capture (`debug-notes/A-front-body-clamp.md`)
placed the `(0,0)` collapse at columns 12-15/19 as already present
immediately after wall 2's *own* `doWall` call finishes, before any other
wall has run — so whatever's wrong is inside or upstream of wall 2's own
column loop, not a cross-wall stomp. The same pass also found a *new*,
previously-undocumented anomaly: columns 130-144 (inside wall 4's solid
`[99,159)` range) hold a garbage byte pattern that is byte-identical across
independent emulator relaunches — ruling out stale/uninitialized RAM, i.e.
it's a deterministic product of the program, not yet correlated to a
specific wall or instruction.

**Tooling lesson (important for the next session):** attempts to pin down
the exact faulty instruction via fine-grained exec/store checkpoints under
`-warp` produced self-contradictory results — a checkpoint armed at one
address sometimes reported a halt with the register-read `PC` pointing
elsewhere entirely (inside unrelated converter code), and a store
checkpoint on a page-2 byte that should fire every single frame (the
init loop alone writes it) produced zero hits in a generous window. Coarse
checkpoints (once per subroutine return, like `renderSector`'s `inc
zWIdx`) stayed internally consistent and are trusted; fine-grained
mid-routine ones under `-warp` are not. **Do not chase this further with
exec/store checkpoints under `-warp`.** The recommended next step is to add
single-step support to `tools/vicedbg/vicemon.py` (VICE binary-monitor
`advance`/`step`) and use it with `-warp` off — single-stepping is
synchronous by construction and immune to the race observed here. Full
method in `debug-notes/A-front-body-clamp.md`.

Useful commands for a debugging pass like this one:

    x64sc -reu -reusize 16384 -default +confirmonexit -autostartprgmode 1 \
        +sound -warp -binarymonitor -binarymonitoraddress ip4://127.0.0.1:6510 \
        -autostart build/doom.prg &
    python3 tools/vicedbg/probe.py dump build/doom.prg   # colTop/colBot occupancy

(`Mon.quit()` in `vicemon.py` sends the VICE *quit emulator* command, not
"close this monitor connection" — close the socket directly instead, or the
next probe call will find nothing listening.)

## Next steps

Beyond Milestone 1, in dependency order: `tools/wad2reu.py` → REU DMA streaming →
real map geometry replacing `testmap.asm` → textured walls → floors/ceilings →
sprites → music. `tools/u64push.py` is independent of all of it.
`pipeline.md` §12.1 gives the current frame budget (~52% at 48 MHz) and §14 the
full stage-by-stage gap list against the target architecture. `pipeline.md`
§11.2/§13.2 (the wall-5/zC0 worked example and the bounds-contract table) are
now historical — the gaps they documented are closed — but are left as-is
since they're useful worked traces of the geometry math.

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

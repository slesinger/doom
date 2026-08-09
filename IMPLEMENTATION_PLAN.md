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
This is a **different bug from the JAM** — traced partway, not fixed.

Hand-computing the expected screen columns for the three front-facing walls
at the spawn position (camera at (512,512), facing east into sector A) gives:

    wall 2 (solid)      sx  0 ..  60
    wall 3 (portal->B)  sx 60 .. 100
    wall 4 (solid)      sx 100 .. 160

Instrumenting `doWall` with an exec breakpoint at the `zC0` store (`$cc45` in
the current build; use `tools/vicedbg` + a checkpoint, see below) confirms
each wall's *own* projected screen range matches this almost exactly (0/61,
61/99, 99/160) — the trig, projection and division math are computing the
right numbers.

But dumping `colTop`/`colBot` for all 160 columns after a frame shows wall 2
does **not** cleanly close columns 0-60 to its solid-wall value: a handful of
columns inside its own range (12-15, 19, and everything from ~52 on) are
`(0, 0)` instead of `(176, 0)`. `(0, 0)` is not the frame-start state (that's
`(0, 176)`) and not the solid-close state (`(176, 0)`) — it's the value the
*portal* narrowing path (`clampAcc` into `[zBT, zBB]`) writes when the
opening it computes has collapsed to zero height. Wall 2's own back pointer
is solid (`wBack = -1`), so this path should be structurally unreachable for
it. Column 61+ (past wall 2's own `zC1 = 60`) showing the same `(0, 0)`
before wall 3 has even run rules out "wall 3 just computes a bad range" as
the sole explanation — something is making wall 2's column loop behave as if
some columns beyond its own bound are part of a degenerate portal, or is
touching columns past where it should stop.

Not yet isolated further: an exec breakpoint placed at the portal-branch
entry (`$cde6`, i.e. `!portal:` in `walls.asm`) to catch this live never
fired in a few minutes of `-warp` runtime, which is itself confusing given
wall 3 *is* a real portal and should hit that branch constantly — worth
double-checking the breakpoint/`-warp` interaction (or the target address)
before trusting that negative result. This needs a fresh, dedicated pass:
probably stepping one full column-loop iteration under the monitor rather
than free-running with exec checkpoints, to see which branch each column
actually takes and why the portal-narrow path executes for a wall whose
`zBack` should read `$ff` throughout.

Useful commands for that pass:

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

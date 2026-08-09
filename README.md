# Doom C64U

A Doom-like engine for the **Commodore 64 Ultimate** — a 6510-compatible CPU at
up to 64 MHz with 16 MB of REU, 64 KB of main RAM, and a VIC-II painting
160×200 multicolor pixels. Not a port: a hardware-aware reinterpretation,
fixed-point throughout, table-driven wherever a table is cheaper than a
computation.

**Current state: the test-map renderer runs at 50.0 fps on real C64 Ultimate
hardware, PAL vsync-locked, and `make check` is green** — floor, dithered
ceiling and a lit far room through a portal, with zero writes outside the
engine's own buffers.

**E1M1's geometry is now on the machine.** `tools/wad2reu.py` packs it out of
`DOOM1.WAD` into an REU image, and the engine loads its BSP nodes and sector
table into the 4 KB of RAM hiding under the I/O space at boot — verified
byte-for-byte in VICE and by checksum on hardware. What is left for Milestone 1
(walk around E1M1) is the BSP traversal that reads them and the player
collision that goes with it. See
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) for the phase plan and what
each phase has to prove.

---

## Documentation

The five documents divide along one axis: **what we intend to build** versus
**what is actually there**.

### Start here

| | |
|---|---|
| **[`pipeline.md`](pipeline.md)** | **The end-to-end compute path**, from a key press to pixels in VIC-II memory — as built, with formulas, cycle counts, a fully worked frame, and the reasoning behind each optimization. If you read one document, read this one. |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | What is built, what is missing, and the phase-by-phase route to Milestone 1 — with the session log of what each pass changed. |
| [`docs/reu-format.md`](docs/reu-format.md) | The frozen `assets.reu` map-image format: header, block layouts, the subsector slots streamed per frame, where it all lands in the machine, and how the image gets there on each of the two targets. |

### Target architecture

| | |
|---|---|
| [`design.md`](design.md) | *Why* the engine is shaped this way: the throughput-pipeline model, the REU-versus-RAM asymmetry, the stage-by-stage optimization strategy. |
| [`algorithm.md`](algorithm.md) | *What* the stages are, in abstract pseudo-code (`PipeScript`), with the determinism and budget rules. |
| [`data_structures.md`](data_structures.md) | *What the data looks like*: map container format, LUT banks, sprite assets, frame working sets. |
| [`3d-renderer-design.md`](3d-renderer-design.md) | *How the final raster stage works*: the chunky→multicolor converter, the ramp/intensity byte format, double buffering. |

> **Reading the design documents against the code.** `design.md`,
> `algorithm.md` and `data_structures.md` describe the **target** engine —
> REU streaming, PVS visibility, textured walls, sprites, music. Milestone 1
> implements a subset with deliberate simplifications (integer world
> coordinates instead of 16.16, an 8-bit angle instead of 16-bit, flat shading
> instead of textures). `pipeline.md` §2 and §14 map the differences
> explicitly, and each design document now carries a status note pointing at
> the relevant section.

[`debug-notes/`](debug-notes/00-index.md) holds the forensic write-ups from the
black-screen debugging passes — six hypotheses, the ones that were wrong, and
the three memory-safety fixes that ended it. Worth reading before re-deriving
any of it.

---

## Source layout

```
src/main.asm              VIC setup, spawn, main loop, HUD blanking
src/defs.asm              memory map + zero-page allocation (all .const live here)
src/math.asm              mul8 (quarter-square), umul16, smulTrig, ssmul32,
                          udiv, sdiv, spanFill
src/input.asm             WASD + QE strafe + joystick 2, convex-sector containment
src/reu.asm               REU DMA primitives + boot-time presence probe
src/mapload.asm           boot-time load of the resident map blocks from the REU
src/reuload.asm           standalone PRG: host-driven REU image upload
src/reubench.asm          standalone REU DMA throughput benchmark
src/testmap.asm           3 sectors, 16 walls, 2 portals (SoA layout)
src/render/walls.asm      portal traversal, near-plane clip, projection,
                          line interpolators, column spans
src/render/chunky2mc.asm  Bayer-dithered chunky -> multicolor converter,
                          double buffering, flip
tools/vicedbg/            VICE binary-monitor client + live-RAM diff probe
tools/checkshot.py        screenshot content assertion (coverage + colour count)
tools/u64.py              Ultimate REST + FTP client (stdlib only)
tools/u64config.py        applies the turbo settings the engine requires
tools/wad2reu.py          DOOM1.WAD -> build/assets.reu, with validator + map PNG
tools/u64push.py          push + run on hardware, REU upload, map + fps checks
tools/u64shot.py          DMA the chunky framebuffer off hardware, render a PNG
tools/reubench.py         run the REU benchmark and print the throughput table
tools/setup-dev-env.sh    VICE + C64 ROM setup
```

**Controls:** `W`/`S` walk, `A`/`D` turn, `Q`/`E` strafe; joystick 2 walks and
turns.

The frame loop is `main.asm:59`:

```
mainLoop:
        jsr readInput
        jsr movePlayer
        jsr renderFrame     ; 3D -> MATRIX (chunky, 1 byte/pixel)
        jsr convert         ; MATRIX -> back bitmap + screen + COLBUF
        jsr flip            ; wait vblank, swap banks, burst COLBUF -> $d800
        jmp mainLoop
```

`pipeline.md` walks every one of those five calls in detail.

---

## Building

```sh
sh tools/setup-dev-env.sh          # VICE + C64 ROMs
make                               # -> build/doom.prg   (needs KickAssembler)
make assets                        # DOOM1.WAD -> build/assets.reu (+ testmap.reu)
make run                           # VICE with the map image attached
make check VICEWRAP='xvfb-run -a'  # THE regression gate: build + shot + debug
make shot  VICEWRAP='xvfb-run -a'  # headless run, screenshot to build/shot.png
make debug VICEWRAP='xvfb-run -a'  # live-RAM vs PRG diff
```

### On real hardware

```sh
make u64-config                    # apply the required turbo settings
make run-u64                       # push over the network and run
make u64-fps                       # ... and measure the real frame rate
make u64-map                       # ... and verify the map image reached REU RAM
python3 tools/u64shot.py $HOST out.png --cam 512,512,0 --scale 2
```

`U64_HOST` defaults to the address of the machine on this LAN; override it with
`make run-u64 U64_HOST=1.2.3.4`.

**`u64-config` is not optional.** The engine selects its CPU speed by writing
`$D031`, and that register only exists when the Ultimate's *Turbo Control* is
set to `C64U Turbo Registers`. In any other mode the write is silently
discarded and the engine runs at 1 MHz — about 0.8 fps — with nothing on screen
to say so. `run-u64` and `u64-fps` therefore depend on it.

**KickAssembler** is only distributed from `theweb.dk` and is not vendored
here. Put `KickAss.jar` in `tools/kickass/` or set `KICKASS_JAR`.

**C64 ROMs**: the Debian/Ubuntu `vice` package ships without them, so `x64sc`
refuses to start until `tools/setup-dev-env.sh` restores them from VICE's
upstream tree.

`make check` is the important one. It asserts three independent things, and each
catches what the others cannot:

| | |
|---|---|
| the `.errorif` guards in `main.asm` | no segment has grown into its neighbour |
| `tools/checkshot.py` on `build/shot.png` | the viewport is not black and not a flat fill — i.e. the engine reached a *frame*, not merely the end of a frame loop |
| `tools/vicedbg/probe.py diff` | **zero** unexpected differences between live RAM and the loaded PRG — a stray pointer is caught on the frame it happens, not three frames later when the screen has already gone black |
| `reuOK == 1` in the same pass | the emulator actually attached an REU. A missing REU is invisible from inside the C64 — `$DFxx` reads back `$00` and every DMA silently succeeds while moving nothing — and it stayed missing for the whole life of the project because `-default` sat after `-reu` on VICE's command line |
| `mapOK == 1`, and every resident block compared against `build/assets.reu` | the map image reached REU RAM *and* the right bytes landed at the right addresses. Three separate silent failures have already been found on this path, each one letting every read "succeed" and return the wrong thing — `docs/reu-format.md` §9 lists them |

`make shot` deliberately ignores VICE's exit status: `-limitcycles` always ends
the run non-zero, so the artifact is the evidence, not the status code. Its
sibling `make debug` randomises the binary-monitor port because VICE binds it
without `SO_REUSEADDR` — see the comment on the `debug` target. See
`pipeline.md` §13 for the invariants behind all of this.

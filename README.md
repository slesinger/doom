# Doom C64U

A Doom-like engine for the **Commodore 64 Ultimate** — a 6510-compatible CPU at
up to 64 MHz with 16 MB of REU, 64 KB of main RAM, and a VIC-II painting
160×200 multicolor pixels. Not a port: a hardware-aware reinterpretation,
fixed-point throughout, table-driven wherever a table is cheaper than a
computation.

**Current state: the engine renders and walks Doom's E1M1**, out of a WAD, on
a BSP walk of the map's own nodes, with `make check` green — the spawn room's
ceiling, floor, wall band and the opening through it, and no writes outside
the engine's own buffers. You can walk out of the start room, down the two
steps, and into the courtyard, with eye height following the floor.

`tools/wad2reu.py` packs E1M1 out of `DOOM1.WAD` into an REU image; the engine
loads the BSP nodes and the sector table into the 4 KB of RAM hiding under the
I/O space at boot and streams each subsector's segs from the REU as it visits
it. The hand-built test map is gone — it goes through the same packer now, so
`make shot REUIMG=build/testmap.reu` runs the whole engine on three hand-
verifiable sectors.

**Frame time: a measured 25.05 fps on a C64 Ultimate at 64 MHz, with every one
of 502 consecutive frames on the deadline.** E1M1 started at 17.6 fps; two
culling passes — a world-space seg backface test, and bounding-sphere rejection
of whole BSP subtrees — took it to 22.2, and a further 9.4% off the frame
(`spanFill`'s cell step, a short path through `udiv`, the exact frustum test in
place of the axis-aligned box) is what locked it. A frame cap holds simple
views at 25 rather than letting them run at 50 and move the player twice as
fast.

`flip` is raster-synced, so frame time can only be a multiple of 19.95 ms, and
the engine now times its own compute against that boundary: **37.6 ms against a
39.90 ms deadline**, reported by `make u64-fps` along with a histogram of how
many raster frames each one spanned. Two milliseconds is not much margin, and
the point of measuring it is to notice when something spends it.
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) §16 has the reading — and
the run before it that said 22.7 fps and was wrong, because two 2.3-second
startup frames were hiding inside a 20-second average.

Every optimization in this project is verified **pixel-identical** against the
build before it — 0 of 104448 pixels differing — because the rendered frame is
the only oracle the engine has. See
[`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) §12-§16 for the
measurements, including one change that measured *slower* and was reverted, and
one hardware reading that was believed for half a session and was an artifact.

---

## Documentation

The documents divide along one axis: **what we intend to build** versus
**what is actually there**.

### Start here

| | |
|---|---|
| **[`pipeline.md`](pipeline.md)** | **The end-to-end compute path**, from a key press to pixels in VIC-II memory — as built, with formulas, cycle counts, a fully worked frame, and the reasoning behind each optimization. If you read one document, read this one. |
| [`IMPLEMENTATION_PLAN.md`](IMPLEMENTATION_PLAN.md) | Part I: Milestone 1 as built — the architecture, the memory constraints, and the findings that cost a session each. Part II: the phase-by-phase plan for Milestone 2 — textures, doors, sprites, HUD. |
| [`docs/reu-format.md`](docs/reu-format.md) | The frozen `assets.reu` map-image format: header, block layouts, the subsector slots streamed per frame, where it all lands in the machine, and how the image gets there on each of the two targets. |
| [`docs/intro.md`](docs/intro.md) | The title screen (`src/intro/`) — a separate program from the engine, its koala picture, and its music: the C64 Ultimate's hardware PCM sampler, not a SID player. |

### Target architecture

| | |
|---|---|
| [`design.md`](design.md) | *Why* the engine is shaped this way: the throughput-pipeline model, the REU-versus-RAM asymmetry, the stage-by-stage optimization strategy. |
| [`algorithm.md`](algorithm.md) | *What* the stages are, in abstract pseudo-code (`PipeScript`), with the determinism and budget rules. |
| [`3d-renderer-design.md`](3d-renderer-design.md) | *How the final raster stage works*: the chunky→multicolor converter, the ramp/intensity byte format, double buffering. |

> **Reading the design documents against the code.** `design.md` and
> `algorithm.md` describe the **target** engine — REU streaming, PVS
> visibility, textured walls, sprites, music. The engine implements a subset
> with deliberate simplifications (integer world coordinates instead of 16.16,
> an 8-bit angle instead of 16-bit, flat shading instead of textures).
> `pipeline.md` §2 and §14 map the differences explicitly, and each design
> document carries a status note pointing at the relevant section.
>
> There was a third, `data_structures.md`, describing a map container and asset
> layout the project ultimately did not build. It was deleted rather than
> reconciled (`IMPLEMENTATION_PLAN.md` §9.3): **`docs/reu-format.md` is the
> authority on every data format the engine actually reads**, and
> `pipeline.md` §12.2 on where it all sits in memory.

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
src/input.asm             WASD + QE strafe + SPACE jump + walk bob + joystick 2,
                          subsector containment and step/headroom collision
                          against the segs
src/reu.asm               REU DMA primitives + boot-time presence probe
src/mapload.asm           boot-time load of the resident map blocks from the REU
src/reuload.asm           standalone PRG: host-driven REU image upload
src/reubench.asm          standalone REU DMA throughput benchmark
src/render/bsp.asm        front-to-back BSP descent, subsector streaming,
                          point-to-subsector lookup, sector height reads
src/render/walls.asm      one seg: near-plane clip, projection, line
                          interpolators, column spans, occlusion
src/render/chunky2mc.asm  Bayer-dithered chunky -> multicolor converter,
                          double buffering, flip
src/clock.asm             CIA2 millisecond clock, the 25 fps cap, and the
                          per-frame compute timer read by make u64-fps
tools/vicedbg/            VICE binary-monitor client, live-RAM diff probe,
                          frame/workload stats, and profile.py (per-frame call
                          counts for the hot routines, via VICE checkpoints)
tools/checkshot.py        screenshot content assertion (coverage + colour count)
tools/u64.py              Ultimate REST + FTP client (stdlib only)
tools/u64config.py        applies the turbo settings the engine requires
tools/wad2reu.py          DOOM1.WAD -> build/assets.reu, with validator + map PNG
tools/u64push.py          push + run on hardware, REU upload, map + fps checks
tools/u64shot.py          DMA the chunky framebuffer off hardware, render a PNG
tools/reubench.py         run the REU benchmark and print the throughput table
tools/setup-dev-env.sh    VICE + C64 ROM setup
```

**Controls:** `W`/`S` walk, `A`/`D` turn, `Q`/`E` strafe, `SPACE` jump (and
open a door); joystick 2 walks and turns, and fire is `SPACE`. Walking bobs the
eye, as Doom's does.

The frame loop is [`main.asm:124`](src/main.asm#L124):

```
mainLoop:
        jsr readInput
        jsr movePlayer
        jsr renderFrame     ; 3D -> MATRIX (chunky, 1 byte/pixel)
        jsr convert         ; MATRIX -> back bitmap + screen + COLBUF
        jsr framePace       ; hold the rate at 25 fps, and time the frame
        jsr flip            ; wait vblank, swap banks, burst COLBUF -> $d800
        jsr frameMark       ; which raster frame did it land on
        jmp mainLoop
```

`pipeline.md` walks every one of those calls in detail.

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
make walktest VICEWRAP='xvfb-run -a'   # movement: slide along a wall, wedge in
                                       # a corner, cross nothing
```

`make walktest` is the movement counterpart of `make check`: it drives the
running engine over the binary monitor along two scripted paths and judges the
path it took against E1M1's own linedefs, so "the player slid along the wall"
and "the player did not end up inside one" are separate, checkable claims
rather than something to squint at on screen (`IMPLEMENTATION_PLAN.md` §9.2).

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
| all 25 SID registers against the music stream | the tune is playing and is *in step*. The chip's state is reconstructed by replaying `build/assets.reu`'s own stream up to wherever the engine's pointer has reached, so a replay head half a record out of step is caught — which nothing else would see, because it still writes plausible bytes to the SID and merely sounds wrong (`docs/reu-format.md` §4.6) |

`make shot` deliberately ignores VICE's exit status: `-limitcycles` always ends
the run non-zero, so the artifact is the evidence, not the status code. Its
sibling `make debug` randomises the binary-monitor port because VICE binds it
without `SO_REUSEADDR` — see the comment on the `debug` target. See
`pipeline.md` §13 for the invariants behind all of this.

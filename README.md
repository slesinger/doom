# Doom C64U

A Doom-like engine for the **Commodore 64 Ultimate** — a 6510-compatible CPU at
up to 64 MHz with 16 MB of REU, 64 KB of main RAM, and a VIC-II painting
160×200 multicolor pixels. Not a port: a hardware-aware reinterpretation,
fixed-point throughout, table-driven wherever a table is cheaper than a
computation.

**Current state: the test-map renderer reaches a visible frame and `make check`
is green** — floor, dithered ceiling and a lit far room through a portal, with
zero writes outside the engine's own buffers. Milestone 1 (walk around real
E1M1 on Ultimate 64 hardware) is not there yet: there is no REU code, no WAD
converter and no BSP traversal. See
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
src/input.asm             WASD + joystick 2, convex-sector containment
src/testmap.asm           3 sectors, 16 walls, 2 portals (SoA layout)
src/render/walls.asm      portal traversal, near-plane clip, projection,
                          line interpolators, column spans
src/render/chunky2mc.asm  Bayer-dithered chunky -> multicolor converter,
                          double buffering, flip
tools/vicedbg/            VICE binary-monitor client + live-RAM diff probe
tools/checkshot.py        screenshot content assertion (coverage + colour count)
tools/setup-dev-env.sh    VICE + C64 ROM setup
```

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
make run                           # VICE with a 16 MB REU
make check VICEWRAP='xvfb-run -a'  # THE regression gate: build + shot + debug
make shot  VICEWRAP='xvfb-run -a'  # headless run, screenshot to build/shot.png
make debug VICEWRAP='xvfb-run -a'  # live-RAM vs PRG diff
```

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

`make shot` deliberately ignores VICE's exit status: `-limitcycles` always ends
the run non-zero, so the artifact is the evidence, not the status code. Its
sibling `make debug` randomises the binary-monitor port because VICE binds it
without `SO_REUSEADDR` — see the comment on the `debug` target. See
`pipeline.md` §13 for the invariants behind all of this.

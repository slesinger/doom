# Debug log index — "most of the frame is undrawn"

Investigation plan: `/home/honza/.claude/plans/tender-cuddling-wilkes.md`
(kept outside the repo; this index is the durable, repo-tracked record).

Background: `IMPLEMENTATION_PLAN.md` "Known issue: most of the frame is
undrawn" section has two prior findings — (1) confirmed: B→C portal (wall 8)
`clampAcc` opening collapses to `(zBT,zBB)=(0,0)`; (2) reproduced but
unreconciled: columns inside wall 2's own solid range also end up `(0,0)`
despite provably-unconditional close-write code.

Map in use: `src/testmap.asm` (3 sectors, 16 walls, see wall/sector table in
`B-map-data-audit.md`).

`build/shot.png` (regenerated this session via `make shot`) is direct visual
confirmation of the symptom: two adjacent wall bands on the screen's left
third (columns ~0-60, matching wall 2 + wall 3's ranges) with small notches
at their bottom edges lining up with the anomalous columns below, then
black for the rest of the screen (everything behind the B→A/B→C portals),
plus one stray thin vertical line far on the right.

## Status

| # | Hypothesis | Verdict | Notes file |
|---|---|---|---|
| A | Front wall's own clamped body (zTW/zBW) already (0,0) before portal clamp | **inconclusive** — tooling limits, but coarse capture places the defect inside/before wall 2's own `doWall` call | [A-front-body-clamp.md](A-front-body-clamp.md) |
| B | Map/sector data bug (inverted ceil/floor, bad wBack) | **refuted** | [B-map-data-audit.md](B-map-data-audit.md) |
| C | Second portal in sector A overlaps wall 2's columns | **refuted** (for this map) | [C-second-portal-overlap.md](C-second-portal-overlap.md) |
| F | Portal stack slot corruption (pStkSec/XL/XR) delivers wrong `[zXL,zXR]` to a B/C wall | **refuted** — live capture confirms B/C get exactly the windows their portals pushed | [F-stack-slot-corruption.md](F-stack-slot-corruption.md) |
| D | clampAcc/lineSetup numeric fault (accumulator wraparound / sdiv saturation) | not tested — needs single-step tooling (see A's notes) | [D-accumulator-wraparound.md](D-accumulator-wraparound.md) |
| E | KickAssembler anonymous-label misresolution | not tested (last resort) — one partial data point against it | [E-label-misresolution.md](E-label-misresolution.md) |

## Log

- Static map-data audit (`src/testmap.asm`): sectors are all sane
  (ceil > floor by 128-352 units, no inversions), every `wBack` points at a
  geometrically-consistent neighbor. **B refuted.**
- Hand-derived screen geometry (camera at spawn, `camA=0`) for sector A's
  walls: wall 2 → columns `[0,60)`, wall 3 (the sector's own A→B portal) →
  columns `[60,100)` — adjacent, not overlapping wall 2's interior. Wall 1
  (north wall) contributes zero columns (its far endpoint projects to
  `sx=0` exactly, hit by `doWall`'s `!reject2` edge case). **C refuted**
  for the specific "sibling portal stomps wall 2" mechanism.
- Live per-wall capture (`wallwalk2.py`, camera locked to true spawn,
  checkpoint at `renderSector`'s `inc zWIdx`) walked all 14 real walls of
  one frame in traversal order; `[zXL,zXR]` handed to sectors B and C
  matched exactly what their portal walls pushed. **F refuted.**
- The same capture placed the two symptoms precisely: columns 12-15/19
  already show the `(0,0)` collapse signature immediately after wall 2's
  *own* `doWall` call (before any other wall has run) — ruling out
  cross-wall stomping as the mechanism for finding 2 and pointing back at
  wall 2's own column loop. A second, previously-undocumented anomaly was
  found: columns 130-144 (inside wall 4's solid range) show a garbage byte
  pattern that is byte-identical across independent emulator relaunches —
  ruling out stale/uninitialized RAM, meaning it's a deterministic product
  of the program's own execution. Not yet correlated to a specific wall or
  instruction.
- Follow-up attempts to pin down the *exact* instruction (fine-grained exec
  checkpoint at the renderFrame init-loop boundary; store checkpoints on
  individual `colTop`/`colBot` bytes) ran into **tooling unreliability**
  under `-warp`: register/memory readback after a reported halt sometimes
  didn't match the armed checkpoint address (PC read back inside unrelated
  converter code), and a store checkpoint on a page-2 byte produced zero
  hits in a window where it should fire every frame. This looks like a
  race between VICE's warp-mode checkpoint notifications and the binary-
  monitor query round-trip, not a new game-logic clue. Coarse,
  once-per-subroutine-return checkpoints (like `wallwalk2.py`'s) stayed
  internally consistent (matched hand-derived geometry closely) and are
  trusted; fine-grained mid-routine ones are not, in this environment.
- **Recommendation for next session**: don't chase this further with
  exec/store checkpoints under `-warp`. Add single-step support to
  `tools/vicedbg/vicemon.py` (VICE binary-monitor `advance`/`step`
  commands) and use it, with `-warp` off, to walk wall 2's column loop
  instruction-by-instruction for columns 10-20 — single-stepping is
  synchronous by construction and immune to the race observed here. See
  `A-front-body-clamp.md` for the detailed method.

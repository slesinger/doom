# Hypothesis C — second sector-A portal overlaps wall 2's columns

**Prediction**: sector A contains a portal wall (other than wall 2) whose
clipped `[zC0,zC1]` overlaps columns 12-15/19/52-60, and that portal's
known `clampAcc` collapse (finding 1) writes `(0,0)` there after wall 2
already closed them correctly.

**Method**: sector A's wall list is walls 0-5 (`secWFirst=0, secWCount=6`,
`testmap.asm:53-54`). Wall 3 `(1024,640)-(1024,384)`, `wBack=1` (→B), is
exactly such a sibling portal. Derive its screen-column range by hand from
the same camera-space transform `doWall`/`transformPoint` use
(`walls.asm:715-778`), using the known spawn (`defs.asm`
`START_X=512,START_Y=512,START_A=0`):

At `camA=0`: `sin(0)=0`, `cos(0)=16384` (2.14 fixed = 1.0), so
`ry = tx*cos + ty*sin ≈ tx`, `rx = tx*sin - ty*cos ≈ -ty`, where
`tx = worldX-camX`, `ty = worldY-camY`.

- **Wall 2** `(1024,1024)→(1024,640)`: `tx=512` both ends (planar wall at
  x=1024) → `ry=512` both ends. `ty0=512→rx0=-512`, `ty1=128→rx1=-128`.
  `sx = 80 + rx*80/512`: `sx0 = 80-80 = 0`, `sx1 = 80-20 = 60`. **→ columns
  [0,60)** — matches the live-captured `[zC0,zC1]` from finding 1 exactly,
  confirming this hand-transform is right.
- **Wall 3** `(1024,640)→(1024,384)`: same `tx=512`→`ry=512`. `ty0=128→
  rx0=-128`, `ty1=-128→rx1=128`. `sx0 = 80-20 = 60`, `sx1 = 80+20 = 100`.
  **→ columns [60,100)** — matches the live-captured B-sector range
  `[61,98)` from finding 1 (small diff is near-plane/rounding, not a
  discrepancy).

So wall 2 → `[0,60)` and wall 3 → `[60,100)` are **adjacent, not
overlapping**, except at the shared boundary column ~60 itself (both walls'
clip math can independently round to include column 59 or 60 — a 1-column
edge case, not a wide overlap). This does **not** explain columns
**12-15 or 19**, which sit well inside wall 2's interior, nowhere near any
wall boundary. It plausibly *does* explain part of the reported **52-60**
range if the true corruption is narrower than originally reported (worth
re-measuring precisely which columns in 52-60 are affected — the seam
column(s) near 60 vs. the rest).

Also checked: wall 1 (north wall, processed just before wall 2 in sector
A's list) shares its far corner with wall 2 at the exact same point
`(1024,1024)`, which projects to `sx=0` exactly for wall 1's near-camera
endpoint too (wall 1 is horizontal at `y=1024`, so `ty=512`/`rx=-512`
constant along its whole length, and its far/camera-side endpoint hits
`sx=0` exactly) — `doWall`'s `!reject2` path explicitly drops any wall
whose far-endpoint `sx` computes to exactly 0 (`walls.asm:324-325`,
`beq !reject2+`), so wall 1 contributes **zero columns**, confirmed by
hand-transform, not just by absence of evidence. No other sector-A wall's
geometry reaches columns 0-60 at all (walls 0/4/5 are on the far/west/south
sides, off-screen or behind-camera from this spawn).

## Verdict

**Refuted as stated** — no sibling portal's column range overlaps wall 2's
*interior* columns (12-15, 19). The ~1-column seam at 59/60 remains a minor
open question (folded into hypothesis A/live-capture below) but cannot
account for the bulk of finding 2.

This rules out "another wall's legitimate-but-buggy write lands on wall 2's
columns" as the mechanism. Finding 2 must come from something that
corrupts columns *interior* to wall 2's own loop — either wall 2's own
per-column state (hypothesis A/D, executed with wrong data) or a write from
a completely different part of the traversal whose column range is itself
wrong (hypothesis F, stack corruption) rather than a legitimate portal
whose true range happens to reach there. Both remain open; proceeding to
live capture to disambiguate directly rather than more hand-tracing.

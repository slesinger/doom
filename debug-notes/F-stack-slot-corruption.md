# Hypothesis F — portal stack corruption hands a child sector a wrong column window

**Prediction**: if this is the mechanism, some wall belonging to sector B
or C ends up with `zXL`/`zXR` (and therefore a computed `[zC0,zC1]`) that
falls inside `[0,60)` even though its true on-screen position is
elsewhere — i.e. `pStkXL`/`pStkXR` popped for that sector don't match what
was pushed for it.

**Status after hypothesis C**: promoted to leading theory for finding 2
once C was refuted — with wall 3 (the only nearby sibling portal) proven
not to overlap wall 2's interior columns, and wall 1 proven to contribute
zero columns, nothing in sector A's own wall list can legitimately write to
columns 12-15/19. If the corruption isn't from wall 2's own state
(hypothesis A/D), the write must come from *outside* sector A's normal
column range, which only reaches columns 0-60 if the stack handed it a
wrong window.

**Method (live, to be run alongside hypothesis A)**: single exec checkpoint
at `renderSector`'s `inc zWIdx` (`walls.asm:118`), which fires once after
*every* `doWall` call for *every* sector, in traversal order. On each hit,
dump: `zWIdx2` (which wall just finished), `zSecId`, `zXL`/`zXR` (the
window it was given), and the full `colTop`/`colBot` arrays for columns
0-99. Stepping through the hits in order shows, wall by wall, the exact
moment columns 12-15/19 (and the 52-60 seam) change value — which
immediately says whether the writer was wall 2 itself (hypothesis A/D) or
some other `zSecId`/`zWIdx2` (confirming F, and identifying exactly which
wall and what `[zXL,zXR]` it was given).

This single capture pass (see `A-front-body-clamp.md` for the shared
instrumentation) is designed to resolve *both* hypotheses A and F in one
shot rather than run them separately, since they're two candidate answers
to the same "who wrote it, and why" question.

**Result**: the combined capture (`wallwalk2.py`) ran successfully, camera
locked to the exact spawn frame. Per-wall `[zXL,zXR]` (the window handed to
`renderSector`) was:

| sector | zXL | zXR | matches push from |
|---|---|---|---|
| A (root) | 0 | 159 | full-screen seed |
| B | 61 | 98 | wall 3's `[zC0,zC1]` (hand-derived `[61,100)`, live `[61,98]`) |
| C | 71 | 88 | wall 8's `[zC0,zC1]` (live `[71,88]`, matches exactly) |

Both child sectors received *exactly* the window their portal pushed —
no stale/wrong stack slot, no mismatch.

**Verdict: refuted.** The portal stack itself is not corrupted; `pStkXL`/
`pStkXR` are read back correctly for every sector. See `A-front-body-clamp.md`
for where the investigation went instead (columns 12-15/19 turn out to be
wrong immediately after wall 2's own `doWall` call, not from any other
sector's traversal).

# Hypothesis D — clampAcc/lineSetup numeric fault

**Status**: not directly tested this session — superseded in priority by
the tooling-reliability problem documented in `A-front-body-clamp.md`
(fine-grained live capture proved unreliable under `-warp`, so per-column
raw-accumulator tracing, which this hypothesis needs, was not attempted).

**Still plausible**: nothing in this session's static re-reading of
`AddStep`/`lineSetup`/`sdiv` found a structural bug (sign-extension,
saturation, and 24-bit accumulator math all checked out algebraically —
see the reasoning in the investigation plan,
`/home/honza/.claude/plans/tender-cuddling-wilkes.md`), but static reading
also didn't find a bug in `clampAcc`'s addressing (hypothesis A/F's target)
and yet the symptom is real and reproducible, so "looks correct on paper"
carries limited weight here.

**Next step**: once single-stepping is available (see recommendation in
`A-front-body-clamp.md`), dump `accTop`/`stepTop` (and, if A is refuted,
`accBT`/`stepBT`) raw 24-bit values for columns 8-22 of wall 2's loop and
compare against the hand-interpolated expected value at each column (linear
from the known endpoint values). A mismatch that grows with distance from
`zC0` points at step-magnitude/rounding; a mismatch that appears suddenly
at one column points at a one-off corruption (more likely E, or a data-
dependent branch bug in `clampAcc` itself).

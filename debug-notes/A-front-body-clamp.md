# Hypothesis A — front wall's own clamped body already (0,0)

**Resolved in a later session: see `00-index.md`.** The root cause was
`renderFrame`'s init loops never clearing `colTop`/`colBot` (a `bpl`
countdown loop from 159, broken for a 160-entry range). Everything below
was a real, correctly-observed symptom of *that* bug, not of anything in
`doWall`'s own clamp math — this hypothesis's "inconclusive" verdict was
right to stay open rather than force a conclusion from unreliable tooling.

**Prediction**: `zTW`/`zBW` (the front wall's own clamped top/bottom,
`walls.asm:491-497`) are already `(0,0)` before the portal clamp runs for
wall 8, meaning the defect is in the wall's *own* `zTop0`/`zBot0`/
`lineSetup`, not the back-sector projection.

## What was actually tested

Live per-wall capture (`wallwalk2.py`, camera locked to the exact spawn
frame via `camX==512 && camY==512 && camA==0` before arming an exec
checkpoint at `renderSector`'s `inc zWIdx` — `walls.asm:118`, address
`$cad4` in the current build) walked all 14 real walls of one frame in
order (2,3,4,5,6,7,8,9,10,11,12,13,14,15 — walls 0/1/10-13 reject via
near-plane/backface culling, confirmed separately via a `zBack`
store-watchpoint capture, `backwatch.py`) and snapshotted `colTop`/`colBot`
after every `doWall` return.

Result: `zC0`/`zC1` for every real wall matched the hand-derived geometry
in `C-second-portal-overlap.md` closely (wall 2 → `[0,60)`, wall 3 →
`[61,98]`, wall 8 → `[71,88]`), which is strong evidence this particular
capture (coarse, once per `doWall` return, not mid-routine) is trustworthy.

The two anomalies already described in `IMPLEMENTATION_PLAN.md` are both
present in the very first hit (right after wall 2, before any other wall
has run):

- Columns 12-15, 19 (and part of 52-60): `colTop=0, colBot=0` — the
  portal-collapse signature — despite wall 2 being solid (`zBack=$ff`,
  confirmed via two independent captures) and covering exactly `[0,60)`.
- Columns 130-144 (inside wall 4's `[99,159)` solid range): a **byte-exact,
  reproducible-across-independent-emulator-launches** garbage pattern —
  `8,0,160,0,14,14,4,10,0,4,10,0,0,72,235` — instead of the expected
  `176` (closed). Being identical across separate `x64sc` launches rules
  out "uninitialized RAM"; something in the program deterministically
  produces these bytes. Not yet correlated with a specific wall or
  instruction.

## What could NOT be resolved this pass, and why

A follow-up attempt to pin down the exact moment/instruction that produces
either anomaly (fine-grained exec checkpoint at the renderFrame init-loop
boundary, `$ca44`; store checkpoints on individual `colTop`/`colBot` bytes)
ran into a **tooling reliability problem, not a new game-logic clue**:

- Repeated exec-checkpoint captures at `$ca44` reported a halt with `PC`
  read back as `$ca44` on some attempts (register readback matched) but
  the **memory state didn't match a fresh post-init frame** (already showed
  the fully-closed pattern) — while other attempts reported `PC` values
  deep inside unrelated converter code (`$9900-$9a40` range) despite having
  armed a checkpoint elsewhere entirely.
- A store checkpoint on `colTop[12]`/`colBot[12]` (`$020c`/`$030c`) that
  should fire on literally the very next frame (the init loop alone writes
  every column every frame) produced **zero hits** in a 15s window under
  `-warp`.
- A zero-page store checkpoint (`zBack`, `$3b`) worked reliably both this
  session (`backwatch.py`) and the prior one; a page-2 (`$02xx`/`$03xx`)
  store checkpoint did not, in the one test run this session. Not
  conclusively isolated as a `-warp`-mode-specific or address-range-specific
  VICE binary-monitor limitation — just observed and not chased further,
  given time spent.

**Verdict: inconclusive on the precise instruction, but the coarse capture
(once-per-`doWall`-return, camera-locked) is trusted, and it places the
`(0,0)` collapse for columns 12-15/19 as happening *during or before*
wall 2's own single `doWall` call — not from a later wall's write.**

## Recommended method for next time (avoids the race entirely)

Don't rely on exec/store checkpoints firing precisely alongside a register/
memory readback under `-warp` — that combination produced self-contradictory
results in this session (`PC` readback not matching the armed address).
Instead:

1. Drop `-warp` for precision passes (keep it only for bulk `make shot`/
   `make debug` runs where exact cycle timing doesn't matter).
2. Use VICE's **single-step** protocol command (not currently wrapped in
   `tools/vicedbg/vicemon.py` — would need adding, e.g. `advance`/`step`,
   VICE binary-monitor command `0x71`/`0x72`) to walk wall 2's column loop
   one instruction at a time from a known-good exec checkpoint at
   `doWall`'s entry (`walls.asm:126`, easy to re-derive per build), logging
   `zSX`/`zWT`/`zWB`/branch-taken at the `!open`/`!closed` decision
   (`walls.asm:486-490`) for columns 10-20 specifically. Single-stepping is
   synchronous by construction — no race between "halted" and "read state"
   — so it should settle the A vs. D question definitively.
3. Independently, treat the columns-130-144 garbage as a *second*,
   possibly-related lead: it's deterministic and reproducible, so it is
   very likely a real write from the program (not boot-time RAM noise).
   Worth a store-watchpoint sweep across `$0282`-`$0290` (its address range)
   with `-warp` off, once the single-step tooling above exists.

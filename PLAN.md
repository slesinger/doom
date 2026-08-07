# Session log — black-screen investigation (2026-08)

> Archived notes from the debugging session that diagnosed the first-frame hang.
> Kept for the forensic detail. **`IMPLEMENTATION_PLAN.md` supersedes this** as
> the current status and fix list, and `pipeline.md` §13 explains the failure in
> terms of which pipeline stage's invariant is being violated.

Published to claude/fable-5-progress-review-2xjdpc (commit 7243611). No PR opened — say the word if you want one.
What the previous session was chasing, and what it actually is
Their instinct was right. build/mon.txt (break cd76 if .X > $a0) was watching for a column index past 159 — at the hang, X = $B5 (181).
I got VICE running here, reproduced the failure, and traced it: the program hangs with a CPU JAM at $CDD7. That address is the second operand byte of sta colTop,x at $CDD5, and $02 is the 6510 JAM opcode — execution was landing mid-instruction.
The cause is spanFill writing outside MATRIX. It builds its destination as xOfs[zSX] + rowCell[zSY0>>3], and neither index is bounds-checked — xOfs has exactly 160 entries, rowCell exactly 22. An out-of-range index reads past the table (rowCellHi is followed at $CA30 by the walls code itself). Diffing live RAM against the PRG shows 317 corrupted bytes — in checkSector, in the map wall table, past MATRIX's end, and in the converter's dither tables — all written with sector A's floor/ceiling bytes in 29-byte runs at stride 4, repeating every $500: spanFill's cell loop and spanNextCell, unmistakably. The corruption feeds back into the geometry, so it escalates into a dead machine rather than a glitchy frame.
Your projection math is not implicated — at the hang the interpolators held exactly the values a hand-trace of sector A predicts (zTop=21, zBot=100, zDX=61, zC0=0, zC1=60).
What's in the commit
tools/vicedbg/ (monitor client + the diff probe that found this), tools/setup-dev-env.sh, IMPLEMENTATION_PLAN.md, Makefile fixes, .gitignore, and removal of src/.source.txt (byte-identical to math.asm) and src/main.sym.
Three Makefile bugs worth knowing: +confirmexit is not a VICE option — make shot bails out immediately on VICE 3.7, so that target cannot have worked recently; PRG autostart needs -autostartprgmode 1 or it demands 1541 drive ROMs; and sound must be off headless. Also, the Debian vice package ships without C64 ROMs, so x64sc won't start until the setup script restores them.
What I did not do
The actual asm fix. KickAssembler isn't in this container and its only distribution host (theweb.dk) is blocked by the egress proxy — I didn't route around that. So I can't assemble or verify a source change, and I'd rather not push unbuildable asm against a bug this subtle. The three fixes are specified in IMPLEMENTATION_PLAN.md: bound both lookups in spanFill, clamp zC0 to zXR in doWall, and move the portal stack off page $0300 where colBot[160..] currently aliases it.
Drop KickAss.jar into tools/kickass/ (or set KICKASS_JAR) and I can implement and verify all three — make debug will confirm zero stray writes.
# Hypothesis E — KickAssembler anonymous-label misresolution

**Status**: not tested this session (last resort, per the plan — only
pursued if A-D are all refuted; they weren't all refuted, they were mostly
left inconclusive by the tooling problem, so this wasn't reached).

**Partial static evidence against it**: this session's disassembly
cross-check of the *unrelated* `renderFrame` init loops (`walls.asm:38-47`,
two separate `!:` / `!-` pairs back to back) confirmed KickAssembler
resolved each `bpl !-` to its own, immediately-preceding loop label
correctly (verified byte-for-byte: `$ca38: 10 fa` branches to `$ca34`,
`$ca42: 10 fa` branches to `$ca3e` — no cross-contamination between the two
loops). This doesn't rule out a misresolution somewhere in `doWall`'s much
denser nesting, but it's one data point that this KickAssembler version
handles adjacent anonymous-label pairs correctly in at least one place in
this file.

**Next step if reached**: static disassembly diff of the compiled
`!open:`/`!closed:`/`!portal:` block byte ranges against intended control
flow, same technique as the prior session's successful check of wall 2's
solid-close path (read `build/doom.prg` directly, no emulator needed).

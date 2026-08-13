//============================================================
//  instrument.asm — renderer workload counters
//
//  Zero cost in a shipping build; set INSTRUMENT to 1 to count what the
//  traversal actually touches, then read the counters with
//  `tools/vicedbg/stats.py`. The counters are free-running 24-bit
//  accumulators, never reset, so a host divides two readings by the
//  frameCnt delta between them and gets per-frame averages without
//  having to catch a frame boundary.
//
//  This exists because the first attempt at the frame-time problem --
//  doWall's occlusion early-out -- measured no gain at all
//  (IMPLEMENTATION_PLAN.md §12), and no counter in the engine could say
//  why. Guessing cost a session; the counters cost 27 bytes of RAM in a
//  build nobody ships. What they then said (§13) contradicted the plan.
//
//  WHY THIS IS NOT IN defs.asm
//
//  It was, and that broke the two standalone PRGs. `reuload.asm` and
//  `reubench.asm` import defs.asm for the REU register constants and
//  nothing else -- they have no renderer, no clock.asm and therefore no
//  `cntBump`. KickAssembler resolves the symbols inside a macro *body*
//  whether or not the macro is ever invoked, and whether or not the
//  `.if` around them is false, so a dangling `jsr cntBump` in defs.asm
//  failed those builds at parse time with an error pointing into a macro
//  neither of them uses.
//
//  So the rule this file exists to enforce: defs.asm is shared by three
//  PRGs and may not name a symbol that only one of them defines. Anything
//  that emits code belongs in a module, and the module is imported by
//  whoever needs it -- here, main.asm alone.
//============================================================

.const INSTRUMENT     = 0

// In the tail of TABLES_FREE, after the BSP node test. Written at runtime and
// inside the PRG image, so an INSTRUMENT build is not `make check` clean --
// probe.py's live-RAM diff reports these 27 bytes as unexpected. That is the
// trade: a shipping build has INSTRUMENT = 0 and this space is untouched.
// Nine 24-bit counters, and nine is what fits: TABLES_FREE ends at $98ff.
.const cntNode        = $98e4      // interior nodes the descent stepped through
.const cntSsec        = $98e7      // subsectors whose segs were fetched
.const cntSeg         = $98ea      // segs considered
.const cntSegNear     = $98ed      // segs rejected: wholly behind the near plane
.const cntSegBack     = $98f0      // segs rejected: back-facing or off-screen
.const cntSegFace     = $98f3      // segs skipped by the world-space backface
.const cntNodeRej     = $98f6      // subtrees the sphere test rejected
.const cntSsecRej     = $98f9      // subsectors the sphere test rejected
.const cntPix         = $98fc      // spanFill pixels written
.const CNT_FIRST      = cntNode
.const CNT_LAST       = cntPix + 2
.errorif CNT_LAST > TABLES_FREE_END, "instrumentation counters overrun TABLES_FREE"

// cntBump used to live in the 21-byte gap between the converter code and
// MATHCODE. §12's symmetric viewport cut spent that gap: flip's colour-RAM
// burst has to reach a fourth page of $d8xx once the view starts at cell 80,
// and that fourth loop is nine bytes the gap did not have. cntBump moves here
// cntBump lives in the 21-byte gap between the converter code and MATHCODE,
// which is the only free block big enough that nothing else wants. It is
// pushed to the *top* of that gap now rather than the bottom: §12's symmetric
// viewport cut made flip's colour-RAM burst reach a fourth page of $d8xx, and
// the converter needs five of the gap's bytes for the extra loop. Sixteen
// bytes ending flush against MATHCODE is what is left, so the two blocks
// between them spend the gap exactly; both .errorifs below hold the line.
//
// TABLES_FREE is not an alternative despite the name: SEGBUF ($9740-$97bf),
// the BSP node test ($97c0-$98e3) and these counters ($98e4-$98fe) have taken
// all of it.
.const CNTCODE        = MATHCODE - 16

// Counter indices, i.e. the byte offset of each 3-byte record from cntNode.
// The Count macro passes one in X rather than inlining the increment: the
// inline form is 12 bytes a site and doWall's block has 19 bytes of headroom
// in total, so an instrumented build did not assemble.
.const CNT_NODE     = 0
.const CNT_SSEC     = 3
.const CNT_SEG      = 6
.const CNT_SEGNEAR  = 9
.const CNT_SEGBACK  = 12
.const CNT_SEGFACE  = 15
.const CNT_NODEREJ  = 18
.const CNT_SSECREJ  = 21
// The indices and the addresses are two spellings of one layout, and they have
// disagreed once already -- silently, because a wrong index just bumps the
// neighbouring counter and every number stays plausible.
.errorif cntNode + CNT_SSECREJ != cntSsecRej, "counter indices and addresses disagree"

// Bump counter `idx`. Costs 5 bytes and clobbers X and the flags, so it may
// only go where both are dead: an `rts` path, or immediately before the `ldx`
// that sets up the call it is counting. A is preserved.
.macro Count(idx) {
    .if (INSTRUMENT != 0) {
        ldx #idx
        jsr cntBump
    }
}

// cntPix += A (unsigned), used where spanFill already has the run length in A.
.macro CountA(addr) {
    .if (INSTRUMENT != 0) {
        clc
        adc addr
        sta addr
        bcc done
        inc addr+1
        bne done
        inc addr+2
done:
    }
}

//------------------------------------------------------------
// cntBump — X = counter index (a byte offset from cntNode), bump that
// 24-bit counter. Preserves A; clobbers X and the flags. Every call site
// either has X dead already or loads it back afterwards.
//
// Out of line because the sites that need it are in doWall, whose block has
// 19 bytes of headroom against the BSP traversal that follows it.
//
// Assembled unconditionally, even though only an INSTRUMENT build calls it:
// a `.if` block is a scope in KickAssembler, so a label inside one is not
// visible to the Count macro expanding in another file. Sixteen bytes off the
// top of TABLES_FREE, which has 400 spare either way, is the cheaper answer.
//------------------------------------------------------------
.pc = CNTCODE "instrumentation"
cntBump:
        pha
        inc cntNode,x
        bne !done+
        inc cntNode+1,x
        bne !done+
        inc cntNode+2,x
!done:  pla
        rts
.errorif * > MATHCODE, "cntBump overflows into the math code"

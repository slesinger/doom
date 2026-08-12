//============================================================
//  tex.asm — Stage A wall texturing (IMPLEMENTATION_PLAN.md §10.2)
//
//  A textured wall pixel is `ramp << 4 | intensity` where the ramp is the
//  surface's, unchanged, and the intensity is the depth shading biased by
//  an 8x8 tile of texels:
//
//      final = clamp(depthIntensity + texel - 8, 2, 15)
//
//  so a texel of 8 reproduces M1's flat wall exactly. The ramp is never
//  touched, which is the whole reason this form of texture is safe: a 4x8
//  multicolor cell holds three colours plus background, and a surface's
//  cells stay legal only while the surface keeps one ramp (§10.1).
//
//  u and v are world-space planar -- u is the seg's dominant world axis and
//  v is z, both >> 4, so one texel is 16 world units and the mapping is
//  continuous across a BSP seg split (docs/reu-format.md §4.7). Nothing here
//  reads a texture offset, because the seg record does not carry one.
//
//  WHERE THE WORK GOES
//
//  Per seg: one 32-byte DMA of the family's tile, the shading byte split into
//  a ramp and a bias, u handed to lineSetup as its fifth line, and v's step
//  and anchor.
//
//  Per column: u's accumulator steps, and when its texel index changes, four
//  packed bytes are unpacked into texStrip -- eight finished chunky bytes,
//  bias and clamp and ramp already applied, so the inner loop is one indexed
//  load per pixel.
//
//  Per pixel: v's accumulator steps and texStrip is indexed by it. That is
//  spanTex, and it is where the phase's frame cost lives.
//
//  WHAT IS AFFINE HERE AND WHAT IS NOT
//
//  u is exact: lineSetup divides once per seg and the accumulator is linear in
//  screen x, which is what u/z is. v's *step* is not -- it is taken at the
//  seg's mid ry and held across the seg, so v's vertical scale drifts towards
//  a seg's ends. v's *anchor* is exact at every column, because the row where
//  the ceiling projects is the row where v is the ceiling height whatever the
//  column. Making the step exact means ry per column, i.e. the perspective
//  divide, and that is the §10.3 subspan work this phase deliberately defers.
//
//  THE CODE IS SCATTERED ON PURPOSE. There is no 600-byte hole anywhere in
//  this machine; there are a dozen small ones, and defs.asm's TX_* say which
//  block is the tail of what. Every routine here is entered by jsr and
//  returns, so where each one lands costs nothing but the naming.
//============================================================

//------------------------------------------------------------
.pc = TX_UENDS "tex: u endpoints"
//------------------------------------------------------------
// texUEnds — zU0/zU1 = the world coordinate u runs along, at the seg's two
// endpoints, after any near-plane clipping. lineSetup then treats them as its
// fifth line's endpoints and does the rest.
//
// The axis is the seg's dominant one, |dx| vs |dy|. Per seg rather than per
// linedef costs a stretch of up to sqrt(2) on a diagonal wall and nothing
// else, and it is what lets u stay a plain world coordinate -- no offset in
// the seg record, and continuity across a BSP split for free.
//------------------------------------------------------------
texUEnds:
        ldx zWIdx2
        lda sgX1,x                  // zA = |dx|
        sec
        sbc sgX0,x
        sta zA
        lda sgX1+1,x
        sbc sgX0+1,x
        sta zA+1
        bpl !+
        jsr negA
!:      lda sgY1,x                  // zB = |dy|
        sec
        sbc sgY0,x
        sta zB
        lda sgY1+1,x
        sbc sgY0+1,x
        sta zB+1
        bpl !+
        jsr negB
!:      lda zA
        cmp zB
        lda zA+1
        sbc zB+1
        txa                         // x0,y0,x1,y1 are two bytes apart in the
        bcs !+                      // record, so the axis is +2 on the index
        adc #2                      // (carry is clear on this path)
!:      tax
        lda sgX0,x
        sta zU0
        lda sgX0+1,x
        sta zU0+1
        lda sgX1,x
        sta zU1
        lda sgX1+1,x
        sta zU1+1
        // A clipped endpoint moved along the seg by the same parameter t the
        // clip used, so u moves with it: u[a] += (u[b] - u[a]) * t. Without
        // this the texture on a seg crossing the near plane is both offset and
        // stretched -- and those are the segs filling the screen. X indexes the
        // endpoint that moved, Y the one that did not.
        ldy zClipW
        beq !done+
        ldx #0
        ldy #2
        bpl !both+                  // zClipW = $01: endpoint 0 moved
!c1:    ldx #2
        ldy #0
!both:  stx zTexAx                  // texMulT clobbers both index registers
        lda zU0,y
        sec
        sbc zU0,x
        sta zA
        lda zU0+1,y
        sbc zU0+1,x
        sta zA+1
        jsr texMulT
        ldx zTexAx
        clc
        adc zU0,x
        sta zU0,x
        tya
        adc zU0+1,x
        sta zU0+1,x
!done:  rts

// mulT takes its multiplier where clipT left it, and texFetch has since used
// that byte as scratch.
texMulT:
        lda zClipT
        sta zT+2
        jmp mulT

//------------------------------------------------------------
// spanTex — spanFill's textured sibling: column zSX, rows [zSY0, zSY1),
// texels from texStrip stepped by zVStep from zVAcc.
//
// The same walk spanFill makes (a cell is four bytes per row and 1280 bytes
// per cell-row) with the constant fill byte replaced by an indexed load. It
// does NOT preserve X -- X is v's integer part for the whole run, which is
// what keeps the per-pixel cost at one load. doWall reloads X from zSX after
// every wall span, so there is nothing to preserve.
//------------------------------------------------------------
spanTex:
        jsr spanPrep                // shared with spanFill -- math.asm
        bcc !rts+
        ldx zVAcc+1                 // X = v, masked to 0-7 by vSeed
!px:    lda texStrip,x
        sta (zSPtr),y
        lda zVAcc                   // v += vStep, mod 8 texels: masking the
        clc                         // integer part every step is exact, and
        adc zVStep                  // holds for the negative step vStep always
        sta zVAcc                   // is -- v falls as the row rises
        txa
        adc zVStep+1
        and #7
        tax
        dec zSCnt
        beq !rts+
        iny
        iny
        iny
        iny
        cpy #32
        bcc !px-
        :NextCell()                 // clobbers A; X and Y are what matter here
        ldy #0
        beq !px-                    // always
!rts:   rts

.errorif * > TX_UENDS_END, "tex: u endpoints + spanTex overflow into SCREEN1"

//------------------------------------------------------------
.pc = BOOTCODE4 "boot: texture code relocator"
//------------------------------------------------------------
// Three of tex.asm's eleven blocks run below $0801, in the free tails of
// colTop, colBot and COLBUF. A PRG image starts at $0801 and cannot load
// anything under it, so those three are assembled here -- in MATRIX, which is
// scratch until the first frame -- with .pseudopc at their run addresses, and
// texBoot copies them down. src/music.asm does the same thing in the other
// direction for the IRQ handler at $ff40.
//
// 245 bytes of RAM that the engine has no other way to reach. The alternative
// was not fitting: the eight in-image holes total 431 bytes against 653 of
// code, and there is no ninth.
//------------------------------------------------------------
texBoot:
        ldx #0
!:      lda txSeedSrc,x
        sta TX_SEED,x
        inx
        cpx #txSeedEnd-txSeedSrc
        bne !-
        ldx #0
!:      lda txFetchSrc,x
        sta TX_FETCH,x
        inx
        cpx #txFetchEnd-txFetchSrc
        bne !-
        ldx #0
!:      lda txVSetSrc,x
        sta TX_VSET,x
        inx
        cpx #txVSetEnd-txVSetSrc
        bne !-
        rts

txSeedSrc:
.pseudopc TX_SEED {
//------------------------------------------------------------
// vSeed — v at the first row of the span about to be drawn.
//
//   vAcc = vTop + (sy0 - ceilRow) * vStep
//
// vTop is v at the front ceiling and ceilRow is where the ceiling projects in
// this column, *unclamped* -- accTop's own integer part, before clampAcc got
// at it. So the delta is zero whenever the span starts at the ceiling, which
// is every solid and upper wall the column window did not cut into, and the
// common case costs two stores.
//
// All three wall spans anchor here, including the lower wall, which starts far
// below: any row whose v is known will do, and the ceiling's is the one that
// is free. That is worth two mul8 calls per lower-wall span and saves the
// second anchor, which is 40 bytes this machine does not have.
//------------------------------------------------------------
vSeed:
        lda zSY0
        sec
        sbc accTop+1
        sta zA
        lda #0
        sbc accTop+2
        sta zA+1
        ora zA
        beq !zero+
        lda zA                      // delta * vStep, low 16 bits: two's
        ldy zVStep                  // complement multiplication is congruent
        jsr mul8                    // mod 65536, so vStep's sign needs no
        sta zVAcc                   // handling here
        stx zVAcc+1
        lda zA
        ldy zVStep+1
        jsr mul8
        clc
        adc zVAcc+1
        sta zVAcc+1
        lda zA+1                    // a delta past 255 -- the ceiling is more
        beq !add+                   // than a screen height above the span --
        ldy zVStep                  // reaches bits 8-15 and nowhere else
        jsr mul8
        clc
        adc zVAcc+1
        sta zVAcc+1
!add:   lda zVAcc
        clc
        adc zVTop
        sta zVAcc
        lda zVAcc+1
        adc zVTop+1
        and #7
        sta zVAcc+1
        rts
!zero:  lda zVTop
        sta zVAcc
        lda zVTop+1
        sta zVAcc+1
        rts

//------------------------------------------------------------
// texSetup — everything the column loop needs, or zTexOn = 0 for a seg that
// has to be drawn flat. Called after the back sector's rows and the four
// lineSetup calls, so zDzC and zRY0/zRY1 are this seg's.
//------------------------------------------------------------
texSetup:
        lda #0
        sta zTexOn
        lda miTexBase               // an image with no WALLTEX block draws
        ora miTexBase+1             // flat, exactly as M1 did
        ora miTexBase+2
        beq !off+
        ldx zWIdx2
        lda sgRamp,x
        and #$0f
        beq !off+                   // family 0 is uniform: flat is the same
        jsr texFetch                // picture, for a third of E1M1's segs
        jsr texUEnds
        ldx #4                      // u is lineSetup's fifth line
        jsr lineSetup
        jsr texVSet
        lda #$ff
        sta zCurU                   // no column unpacked yet
        inc zTexOn
!off:   rts

//------------------------------------------------------------
// wallSpan — what doWall calls instead of spanFill for the three spans that
// are wall rather than floor or ceiling.
//
// It lived at $83e8, in the gap behind SCREEN0's video matrix, until the walk
// bob needed a hole twenty-three bytes wide and that gap was the only one left
// (BOBCODE, defs.asm). Thirteen bytes into COLBUF's tail, next to the vSeed
// it calls, is a pure address change and costs nothing: every block here is
// entered by jsr or jmp, and both are absolute wherever the block lands.
//------------------------------------------------------------
wallSpan:
        lda zTexOn
        beq !flat+
        jsr vSeed
        jmp spanTex
!flat:  jmp spanFill

.errorif * > TX_SEED_END, "tex: v seed block overflows COLBUF's tail"
}
txSeedEnd:

txFetchSrc:
.pseudopc TX_FETCH {
//------------------------------------------------------------
// texFetch — A = texture family 1-15. DMA its tile into TEXBUF and split the
// shading byte into the ramp and the bias the unpack applies.
//
// Requires I/O banked in, which is doWall's own state. The music interrupt may
// land in the middle of the register writes below and issue a DMA of its own;
// it saves and restores $DF02-$DF0A for exactly that reason (defs.asm's
// MUSREU), so this needs no `sei` around it.
//------------------------------------------------------------
texFetch:
        sta zT+2                    // family << 5 -> (zT hi : zT+2 lo)
        lda #0
        sta zT
        ldx #5
!:      asl zT+2
        rol zT
        dex
        bne !-
        lda zT+2
        clc
        adc miTexBase
        sta REU_REUADDR
        lda zT
        adc miTexBase+1
        sta REU_REUADDR+1
        lda #0
        adc miTexBase+2
        sta REU_BANK
        lda #<TEXBUF
        sta REU_C64ADDR
        lda #>TEXBUF
        sta REU_C64ADDR+1
        lda #32
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        lda zWallByte               // the ramp goes back on every texel
        and #$f0
        sta zTexRamp
        lda zWallByte               // and the depth intensity becomes the bias
        and #$0f                    // that a texel of 8 leaves alone
        sec
        sbc #8
        sta zTexBias
        rts

.errorif * > TX_FETCH_END, "tex: tile fetch overflows colBot's tail"
}
txFetchEnd:

txVSetSrc:
.pseudopc TX_VSET {
//------------------------------------------------------------
// texVSet — v's step and the anchor every span in this seg measures from.
//
//   v(row) = z(row) / 16,  z(row) = camZ + (88 - row) * ry / VFOCAL
//
// so v falls by ry/2560 texels per row, which in 8.8 is ry/10, negative. Taken
// at the seg's mid ry and held for the seg -- see the file header on what that
// costs and what fixing it would.
//
// The anchor is v at the front ceiling, in 8.8 and mod 8 texels: one texel is
// 16 world units, so v in 8.8 is z << 4, and mod 8 is the low eleven bits.
//------------------------------------------------------------
texVSet:
        lda camZ
        clc
        adc zDzC
        sta zVTop
        lda camZ+1
        adc zDzC+1
        sta zVTop+1
        ldx #4
!:      asl zVTop
        rol zVTop+1
        dex
        bne !-
        lda zVTop+1
        and #7
        sta zVTop+1
        lda zRY0                    // zA = (ry0 + ry1) >> 1, 17 bits wide
        clc
        adc zRY1
        sta zA
        lda zRY0+1
        adc zRY1+1
        ror
        sta zA+1
        ror zA
        lda #<6554                  // 6554/65536 = 0.1000: ry/10
        sta zB
        lda #>6554
        sta zB+1
        jsr umul16
        lda #0
        sec
        sbc zP+2
        sta zVStep
        lda #0
        sbc zP+3
        sta zVStep+1
        rts

.errorif * > TX_VSET_END, "tex: v step overflows colTop's tail"
}
txVSetEnd:
.errorif * > BOOTCODE4 + $200, "boot block 4 overflows its 512 bytes"

//------------------------------------------------------------
.pc = TX_SHADE "tex: wall shading"
//------------------------------------------------------------
// wallShade — the seg's flat shading byte, from the mid distance.
//
// M1's code, moved out of doWall unchanged. It is out here because doWall's
// segment ends at BSPCODE with five bytes to spare and the texture hooks
// needed a dozen; a routine that runs once per seg is the cheapest thing to
// pay a jsr for.
//
//   light = (ry0 + ry1) >> 7, intensity = 15 - light, floored at 2
//------------------------------------------------------------
wallShade:
        lda zRY0
        clc
        adc zRY1
        sta zNum
        lda zRY0+1
        adc zRY1+1
        lsr
        ror zNum
        lsr
        ror zNum
        lsr
        ror zNum
        lsr
        ror zNum
        lsr
        ror zNum
        lsr
        ror zNum
        lsr
        ror zNum
        // A is the high byte of (ry0+ry1)>>7 and zNum the low one. Test A with
        // tax, not with an sta: sta sets no flags, so the bne read the last
        // `ror zNum` instead and every wall past 128 units came out at minimum
        // intensity. Depth shading did not actually work until this was fixed.
        tax
        bne !dark+
        lda #15
        sec
        sbc zNum
        bcs !+
!dark:  lda #1
!:      cmp #2
        bcs !+
        lda #2                      // minimum visibility
!:      ldx zWIdx2
        // sgRamp is %rrrrtttt as of format 4: the low nibble is the texture
        // family, not part of the shading byte, so it has to be masked off
        // before the depth intensity goes in.
        sta zWallByte
        lda sgRamp,x
        and #$f0
        ora zWallByte
        sta zWallByte
        rts

.errorif * > TX_SHADE_END, "tex: wall shading overflows udiv's short path"

//------------------------------------------------------------
.pc = TX_UADV "tex: u advance"
//------------------------------------------------------------
// uAdvance — one column's step of u, skipped entirely on a flat seg. Called
// from colAdvance, which runs for closed columns too: u has to keep pace with
// the screen x it is a function of, whether or not anything was drawn.
//------------------------------------------------------------
uAdvance:
        lda zTexOn
        beq !rts+
        :AddStep(accU, stepU)
!rts:   rts

.errorif * > TX_UADV_END, "tex: u advance overflows into the I/O space"

//------------------------------------------------------------
.pc = TX_PIX "tex: texel unpack"
//------------------------------------------------------------
// texPix — A = texel 0-15, Y = index into texStrip. Applies the bias, clamps,
// puts the ramp back and stores the finished chunky byte, then advances Y.
//------------------------------------------------------------
texPix:
        clc
        adc zTexBias                // depthIntensity - 8, signed
        bmi !lo+
        cmp #2
        bcc !lo+
        cmp #16
        bcc !ok+
        lda #15
        bne !ok+                    // always
!lo:    lda #2                      // the minimum visibility M1 also enforces
!ok:    ora zTexRamp
        sta texStrip,y
        iny
        rts

.errorif * > TX_PIX_END, "tex: texel unpack overflows into BITMAP0"

//------------------------------------------------------------
.pc = TX_COL "tex: strip unpack"
//------------------------------------------------------------
// texCol — A = u (0-7): unpack that column of the packed tile into texStrip.
//
// The tile is column-major (docs/reu-format.md §4.7) precisely so that this is
// four consecutive bytes: byte u*4+k holds v=2k in its high nibble and v=2k+1
// in its low one.
//------------------------------------------------------------
texCol:
        asl
        asl
        tax                         // X = u*4, the column's first packed byte
        ldy #0
!b:     lda TEXBUF,x
        lsr
        lsr
        lsr
        lsr
        jsr texPix                  // even v
        lda TEXBUF,x
        and #$0f
        jsr texPix                  // odd v
        inx
        cpy #8
        bcc !b-
        rts

.errorif * > TX_COL_END, "tex: strip unpack overflows into the BSP traversal"

//------------------------------------------------------------
.pc = TX_UPD "tex: column update"
//------------------------------------------------------------
// texUpd — per column: derive u's texel index and reload texStrip if it moved.
// Called from doWall's column loop with X free (it reloads from zSX after).
//------------------------------------------------------------
texUpd: lda zTexOn
        beq !rts+
        lda accU+1                  // u's integer part is world units, and one
        and #$70                    // texel is 16 of them: (u >> 4) & 7
        lsr
        lsr
        lsr
        lsr
        cmp zCurU
        beq !rts+
        sta zCurU
        jmp texCol
!rts:   rts

.errorif * > TX_UPD_END, "tex: column update overflows into MAPINFO"

//------------------------------------------------------------
.pc = TX_CLIP "tex: clip parameter"
//------------------------------------------------------------
// texClip0 / texClip1 — remember which endpoint the near plane moved, and by
// how far along the seg. Called from doWall's two clip paths, where clipT has
// just left t in zT+2.
//------------------------------------------------------------
texClip0:
        lda #$01
        .byte $2c                   // bit $80a9: skips the `lda #$80` below
texClip1:
        lda #$80
        sta zClipW
        lda zT+2
        sta zClipT
        rts

.errorif * > TX_CLIP_END, "tex: clip parameter overflows the BSP stack"

//============================================================
//  math.asm — fixed-point math core + span fill primitive
//
//  Formats:
//    world coords : signed 16-bit integers (map units)
//    angles       : 8-bit (0..255 = full turn), 0 = east, CCW
//    trig         : signed 2.14 (16384 = 1.0), cos(a) = sin(a+64)
//============================================================

//------------------------------------------------------------
// zero page (math): $02-$0F
//------------------------------------------------------------

// span fill: $60-$67

//------------------------------------------------------------
// Tables
//------------------------------------------------------------
.pc = MATHTAB "math tables"
sqrLo: .fill 512, <floor(i*i/4)
sqrHi: .fill 512, >floor(i*i/4)
// sin in 2.14, 256 steps/turn; cos(a) = sin((a+64) & 255)
sinLo: .fill 256, <round(16383*sin(i*2*PI/256))
sinHi: .fill 256, >round(16383*sin(i*2*PI/256))
// matrix row-of-cells base addresses: MATRIX + cellrow*1280
// VIEWCELLROWS entries (176 -> 160 -> 144 rows, IMPLEMENTATION_PLAN.md §14a.1
// then §12): the freed tail of MATRIX past the last row is permanent RAM once
// the first frame has run. spanPrep's two clamps below are what keep a bad row
// from stepping the cell pointer off the end of this table.
rowCellLo: .fill VIEWCELLROWS, <[MATRIX + i*1280]
rowCellHi: .fill VIEWCELLROWS, >[MATRIX + i*1280]

.pc = MATHCODE "math+span code"

//------------------------------------------------------------
// mul8: A * Y -> A(lo), X(hi). Preserves Y. Quarter-square:
// a*b = f(a+b) - f(|a-b|), f(x) = floor(x*x/4)
//------------------------------------------------------------
mul8:
        sta m8a+1                   // table base lo := a (tables page-aligned)
        sta m8b+1
        sty zT
        sec
        sbc zT                      // A = a - b
        bcs !+
        eor #$ff                    // negate (carry clear: adc #1 = +1)
        adc #1
!:      tax                         // X = |a-b| (0-255)
m8a:    lda sqrLo,y                 // f(a+b) lo  (self-mod base = sqrLo+a)
        sec
        sbc sqrLo,x
        sta zT+1
m8b:    lda sqrHi,y                 // f(a+b) hi  (self-mod base = sqrHi+a)
        sbc sqrHi,x
        tax
        lda zT+1
        rts

//------------------------------------------------------------
// umul16: zA * zB (unsigned 16x16) -> zP (32-bit)
//------------------------------------------------------------
umul16:
        lda zA
        ldy zB
        jsr mul8                    // ll
        sta zP+0
        stx zP+1
        lda zA+1
        ldy zB+1
        jsr mul8                    // hh
        sta zP+2
        stx zP+3
        lda zA
        ldy zB+1
        jsr mul8                    // lh -> add at byte 1
        clc
        adc zP+1
        sta zP+1
        txa
        adc zP+2
        sta zP+2
        bcc !+
        inc zP+3
!:      lda zA+1
        ldy zB
        jsr mul8                    // hl -> add at byte 1
        clc
        adc zP+1
        sta zP+1
        txa
        adc zP+2
        sta zP+2
        bcc !+
        inc zP+3
!:      rts

//------------------------------------------------------------
// smulTrig: zA (signed 16) * zB (signed 2.14) >> 14 -> zA (signed 16)
// |result| must fit 16 bits (holds for map-scale coords).
//------------------------------------------------------------
smulTrig:
        lda zA+1
        eor zB+1
        sta zSign
        lda zA+1                    // abs(zA)
        bpl !+
        jsr negA
!:      lda zB+1                    // abs(zB)
        bpl !+
        jsr negB
!:      jsr umul16
        asl zP+1                    // result = (P << 2) >> 16
        rol zP+2
        rol zP+3
        asl zP+1
        rol zP+2
        rol zP+3
        lda zP+2
        sta zA
        lda zP+3
        sta zA+1
        bit zSign
        bpl !+
        jsr negA
!:      rts

negA:   sec
        lda #0
        sbc zA
        sta zA
        lda #0
        sbc zA+1
        sta zA+1
        rts

negB:   sec
        lda #0
        sbc zB
        sta zB
        lda #0
        sbc zB+1
        sta zB+1
        rts

//------------------------------------------------------------
// ssmul32: zA * zB (both signed 16) -> zP (signed 32)
//------------------------------------------------------------
ssmul32:
        lda zA+1
        eor zB+1
        sta zSign
        lda zA+1
        bpl !+
        jsr negA
!:      lda zB+1
        bpl !+
        jsr negB
!:      jsr umul16
        bit zSign
        bpl !+
        sec                         // negate 32-bit product
        lda #0
        sbc zP+0
        sta zP+0
        lda #0
        sbc zP+1
        sta zP+1
        lda #0
        sbc zP+2
        sta zP+2
        lda #0
        sbc zP+3
        sta zP+3
!:      rts

//------------------------------------------------------------
// udiv: zD (24-bit unsigned) / zV (16-bit, >0) -> zD+0..1 (16-bit)
// Saturates to $ffff if the quotient would not fit.
//
// Two loops, and which one runs is decided by one 16-bit compare. This is the
// hottest routine in the engine -- profiling the spawn frame counted 512 calls,
// about 18% of it, from projSX, projRow, clipT and sdiv -- and most of those
// quotients are small: a screen row or a screen column, not a 16-bit number.
//
//   (zD+2:zD+1) < zV   <=>   zD < 256*zV   <=>   quotient < 256
//
// and when the quotient's top eight bits are all zero, the first eight
// iterations of the loop below cannot subtract, so all they do is shift the
// dividend's top byte into the remainder. Skipping them leaves the remainder at
// exactly (zD+2:zD+1), which is what udiv8 starts from. It is the same
// quotient, bit for bit, not an approximation -- see UDIV8 in defs.asm for
// where the second loop lives.
//------------------------------------------------------------
udiv:
        lda zV+1                    // quotient fits iff zD+2 < zV
        bne !ok+
        lda zD+2
        cmp zV
        bcc !ok+
        lda #$ff                    // saturate
        sta zD+0
        sta zD+1
        rts
!ok:    lda zD+1                    // quotient < 256 -> the short path
        cmp zV
        lda zD+2
        sbc zV+1
        bcs !long+                  // udiv8 is out of branch range: it is in
        jmp udiv8                   // the free low RAM, not in this segment
!long:  lda zD+2
        sta zT                      // remainder lo
        lda #0
        sta zT+1                    // remainder hi
        ldx #16
!loop:  asl zD+0
        rol zD+1
        rol zT
        rol zT+1
        bcs !sub+                   // remainder overflowed 16 bits -> subtract
        lda zT
        cmp zV
        lda zT+1
        sbc zV+1
        bcc !next+
!sub:   lda zT
        sbc zV                      // carry is set on both paths
        sta zT
        lda zT+1
        sbc zV+1
        sta zT+1
        inc zD+0                    // bit0 was just shifted in as 0
!next:  dex
        bne !loop-
        rts

//------------------------------------------------------------
// sdiv: zD (24-bit SIGNED) / zV (16-bit, >0) -> zD+0..1 signed
// Saturates to +/-$7fff.
//------------------------------------------------------------
sdiv:
        lda zD+2
        sta zSign
        bpl !+
        sec                         // negate 24-bit dividend
        lda #0
        sbc zD+0
        sta zD+0
        lda #0
        sbc zD+1
        sta zD+1
        lda #0
        sbc zD+2
        sta zD+2
!:      jsr udiv
        lda zD+1                    // clamp unsigned result to $7fff
        bpl !+
        lda #$ff
        sta zD+0
        lda #$7f
        sta zD+1
!:      bit zSign
        bpl !+
        sec
        lda #0
        sbc zD+0
        sta zD+0
        lda #0
        sbc zD+1
        sta zD+1
!:      rts

//------------------------------------------------------------
// spanFill: vertical run into MATRIX.
//   column zSX, rows [zSY0, zSY1), color zSCol.
// Preserves X. No-op when zSY0 >= zSY1.
//
// The step to the next cell down is inlined at both of its sites rather than
// called. It was a subroutine that saved A across itself, which cost 29 cycles
// -- jsr/rts plus a pha/pla -- against the 64 the eight stores it serves are
// worth; profiling the spawn frame put the cell loop at about 4600 iterations,
// so the call alone was ~2.5% of the frame. Inlined it is 10 cycles and needs
// no pha/pla: both callers reload A from zSCol immediately afterwards anyway.
//------------------------------------------------------------
.macro NextCell() {                 // ptr += 1280 ($500): lo unchanged.
        lda zSPtr+1                 // Clobbers A -- see the note above.
        clc
        adc #5
        sta zSPtr+1
}

spanFill:
        txa                         // X is the caller's; spanPrep wants it
        pha
        jsr spanPrep
        bcc spanEnd
        lda zSCol
        cpy #0
        beq spanCells               // aligned start: no head
!head:  sta (zSPtr),y               // head: up to cell boundary
        dec zSCnt
        beq spanEnd
        iny
        iny
        iny
        iny
        cpy #32
        bcc !head-
        :NextCell()
        lda zSCol                   // NextCell clobbered the fill byte
spanCells:                          // full 8-pixel cells
        ldx zSCnt
        cpx #8
        bcc spanTail
!cell:  ldy #0
        sta (zSPtr),y
        ldy #4
        sta (zSPtr),y
        ldy #8
        sta (zSPtr),y
        ldy #12
        sta (zSPtr),y
        ldy #16
        sta (zSPtr),y
        ldy #20
        sta (zSPtr),y
        ldy #24
        sta (zSPtr),y
        ldy #28
        sta (zSPtr),y
        :NextCell()                 // A is dead here: the count arithmetic
        txa                         // below clobbers it and reloads zSCol

        sec
        sbc #8
        tax
        lda zSCol
        cpx #8
        bcs !cell-
        stx zSCnt
spanTail:                           // remaining 0-7 pixels
        ldx zSCnt
        beq spanEnd
        ldy #0
!tail:  sta (zSPtr),y
        iny
        iny
        iny
        iny
        dex
        bne !tail-
spanEnd:
        pla
        tax
spanDone:
        rts

//------------------------------------------------------------
// spanPrep: everything both span fills need before their first store.
//
//   carry clear -> the run is empty, draw nothing
//   carry set   -> zSCnt = length, zSPtr = the cell the run starts in,
//                  Y = the in-cell byte offset of its first row
//
// Shared rather than duplicated because spanTex is otherwise the same sixty
// bytes of clamping, bounds checks and table lookups, and there is nowhere in
// this machine to put a second copy of them (src/render/tex.asm). It costs the
// flat path a jsr/rts -- 12 cycles against a span that averages eleven pixels
// at ~22 cycles each.
//
// Clobbers X, which is why spanFill saves the caller's before the call.
//------------------------------------------------------------
spanPrep:
        lda zSY1                    // clamp the run's far end to the last
        cmp #VIEWROWS+1             // valid row (VIEWROWS = VIEWCELLROWS * 8):
        bcc !+                      // otherwise the cell loop steps the
        lda #VIEWROWS               // pointer past rowCell's entries, one
        sta zSY1                    // full cell at a time, unbounded
!:      sec
        sbc zSY0
        beq !nul+
        bcs !go+
!nul:   clc
        rts
!go:    sta zSCnt
        :CountA(cntPix)             // A is still the run length
        ldx zSX                     // bounds-check before either table lookup:
        cpx #160                    // an out-of-range index would read past
        bcs !nul-                   // xOfs/rowCell into whatever follows them
        lda zSY0
        lsr
        lsr
        lsr
        cmp #VIEWCELLROWS
        bcs !nul-
        tay                         // Y = cell row of first pixel
        lda xOfsLo,x
        clc
        adc rowCellLo,y
        sta zSPtr
        lda xOfsHi,x
        adc rowCellHi,y
        sta zSPtr+1                 // ptr = cell base incl. x&3 offset
        lda zSY0
        and #7
        asl
        asl
        tay                         // Y = (row&7)*4, in-cell byte offset
        sec
        rts
mathCodeEnd:                        // main.asm asserts on this, not on `*`:
                                    // the block below assembles into low RAM.

//------------------------------------------------------------
//  udiv's short path, in the low RAM mapLoad's relocation freed.
//
//  Entered from udiv when (zD+2:zD+1) < zV, i.e. when the quotient is known to
//  fit in eight bits. The remainder starts at the dividend's top two bytes --
//  which is where the sixteen-iteration loop would have arrived after eight
//  shifts and no subtractions -- so this runs the remaining eight and produces
//  an identical quotient in half the iterations. zD+1, the quotient's high
//  byte, is zero by construction.
//
//  The loop body differs from the long one by a single instruction: there is no
//  `rol zD+1`, because zD+1 is no longer part of the shift chain. That is also
//  why the two cannot share a body.
//------------------------------------------------------------
.pc = UDIV8 "udiv short path"

udiv8:
        lda zD+1
        sta zT                      // remainder = zD >> 8
        lda zD+2
        sta zT+1
        lda #0
        sta zD+1                    // quotient high byte: zero by construction
        ldx #8
!loop:  asl zD+0
        rol zT
        rol zT+1
        bcs !sub+                   // remainder overflowed 16 bits -> subtract
        lda zT
        cmp zV
        lda zT+1
        sbc zV+1
        bcc !next+
!sub:   lda zT
        sbc zV                      // carry is set on both paths
        sta zT
        lda zT+1
        sbc zV+1
        sta zT+1
        inc zD+0                    // bit0 was just shifted in as 0
!next:  dex
        bne !loop-
        rts

.errorif * > SPHEND, "udiv's short path overflows into MAPINFO"

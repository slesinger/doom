//============================================================
//  input.asm — WASDQE keyboard + joystick port 2, player movement
//  with subsector containment and sliding collision
//
//  W/S   forward / back        A/D   turn left / right
//  Q/E   strafe left / right   joy 2 up/down/left/right = W/S/A/D
//
//  Collision is tested against the segs of the subsector the
//  player is standing in -- the same records the renderer streams,
//  in the same format -- so there is no BLOCKMAP and no second
//  copy of the geometry. Subsectors are convex, so the containment
//  test is the sign of one cross product per seg, unchanged from
//  when it was sectors that were convex.
//
//  A blocked move is not undone whole: what is left of the motion is
//  projected onto the seg it hit and tried again, so a wall passes
//  the player along it instead of stopping them (slideVec, and
//  IMPLEMENTATION_PLAN.md §9.2). `make walktest` is the test.
//============================================================



//------------------------------------------------------------
// Three matrix strobes cover all six keys. Row 1 alone yields four of
// them, so its column byte is cached in Y and tested four times off one
// read. A pressed key reads as 0.
//------------------------------------------------------------
readInput:
        lda #0
        sta zInput
        lda #%11111101              // row 1: W(1) A(2) S(5) E(6)
        sta $dc00
        lda $dc01
        tay
        and #%00000010
        bne !+
        lda #IN_FWD                 // W = forward
        ora zInput
        sta zInput
!:      tya
        and #%00100000
        bne !+
        lda #IN_BACK                // S = back
        ora zInput
        sta zInput
!:      tya
        and #%00000100
        bne !+
        lda #IN_LEFT                // A = turn left
        ora zInput
        sta zInput
!:      tya
        and #%01000000
        bne !+
        lda #IN_SRIGHT              // E = strafe right
        ora zInput
        sta zInput
!:      lda #%11111011              // row 2: D(2)
        sta $dc00
        lda $dc01
        and #%00000100
        bne !+
        lda #IN_RIGHT               // D = turn right
        ora zInput
        sta zInput
!:      lda #%01111111              // row 7: Q(6)
        sta $dc00
        lda $dc01
        and #%01000000
        bne !+
        lda #IN_SLEFT               // Q = strafe left
        ora zInput
        sta zInput
!:      lda #$ff                    // joystick port 2 (active low)
        sta $dc00
        lda $dc00
        eor #$ff
        and #%00001111              // up/down/left/right -> fwd/back/left/right
        ora zInput
        sta zInput
        rts

//------------------------------------------------------------
// 16-bit signed accumulate helpers for the displacement sum below.
//------------------------------------------------------------
.macro addWord(src, dst) {
        lda dst
        clc
        adc src
        sta dst
        lda dst+1
        adc src+1
        sta dst+1
}
.macro subWord(src, dst) {
        lda dst
        sec
        sbc src
        sta dst
        lda dst+1
        sbc src+1
        sta dst+1
}

//------------------------------------------------------------
// movePlayer
//
// Basis, with the camera facing angle a (see pipeline.md §8.1):
//     forward = ( cos a,  sin a)
//     right   = ( sin a, -cos a)
// so both axes are spanned by the same two scaled trig values. The two
// smulTrig calls are hoisted out and every direction key becomes a pair
// of 16-bit adds -- walking and strafing together cost what walking
// alone used to.
//
// Turning: increasing camA rotates the view counter-clockwise, which is
// a LEFT turn, so IN_LEFT increments. Fixing it here rather than in
// readInput keeps the joystick consistent with the keys -- both feed the
// same two bits.
//------------------------------------------------------------
movePlayer:
        lda camX                    // remember position for collision undo
        sta oldX
        lda camX+1
        sta oldX+1
        lda camY
        sta oldY
        lda camY+1
        sta oldY+1
        lda zInput                  // turning
        and #IN_LEFT
        beq !+
        lda camA
        clc
        adc #TURN_SPEED
        sta camA
!:      lda zInput
        and #IN_RIGHT
        beq !+
        lda camA
        sec
        sbc #TURN_SPEED
        sta camA
!:      lda zInput                  // walking or strafing?
        and #IN_MOVE
        bne !+
        jmp moveDone
!:      ldy camA                    // fetch fresh trig for the new angle
        lda sinLo,y
        sta camSin
        lda sinHi,y
        sta camSin+1
        tya
        clc
        adc #64
        tay
        lda sinLo,y
        sta camCos
        lda sinHi,y
        sta camCos+1
        lda #MOVE_SPEED             // zCosT = cos * speed >> 14
        sta zA
        lda #0
        sta zA+1
        lda camCos
        sta zB
        lda camCos+1
        sta zB+1
        jsr smulTrig
        lda zA
        sta zCosT
        lda zA+1
        sta zCosT+1
        lda #MOVE_SPEED             // zSinT = sin * speed >> 14
        sta zA
        lda #0
        sta zA+1
        lda camSin
        sta zB
        lda camSin+1
        sta zB+1
        jsr smulTrig
        lda zA
        sta zSinT
        lda zA+1
        sta zSinT+1
        lda #0                      // accumulate this frame's displacement
        sta zMvDX
        sta zMvDX+1
        sta zMvDY
        sta zMvDY+1
        lda zInput
        and #IN_FWD
        beq !+
        :addWord(zCosT, zMvDX)      // forward  += ( cos,  sin)
        :addWord(zSinT, zMvDY)
!:      lda zInput
        and #IN_BACK
        beq !+
        :subWord(zCosT, zMvDX)      // back     -= ( cos,  sin)
        :subWord(zSinT, zMvDY)
!:      lda zInput
        and #IN_SRIGHT
        beq !+
        :addWord(zSinT, zMvDX)      // strafe R += ( sin, -cos)
        :subWord(zCosT, zMvDY)
!:      lda zInput
        and #IN_SLEFT
        beq !+
        :subWord(zSinT, zMvDX)      // strafe L -= ( sin, -cos)
        :addWord(zCosT, zMvDY)
!:      :addWord(zMvDX, camX)
        :addWord(zMvDY, camY)
        jsr checkMove
moveDone:
        rts

//------------------------------------------------------------
// checkMove: the player has already been moved. Test the new point
// against the segs of the subsector they were standing in; slide
// along the wall it crossed, and undo the move only when sliding
// cannot save it.
//
// Interior test, unchanged from the convex-sector version: with the
// front sector on the right of each directed seg, inside means
// cross < 0 for every seg, where
//     cross = (x1-x0)*(py-y0) - (y1-y0)*(px-x0)
//
// A subsector's boundary also runs along BSP partition lines, and
// those edges have no seg. Not blocking there is correct -- they are
// interior boundaries between subsectors, not walls -- and it is why
// leaving the subsector is normal rather than exceptional.
//
// M1 undid a blocked move whole, so walking into a wall at a shallow
// angle stopped the player dead. Now a blocked attempt projects what
// is left of the motion onto the seg it hit (slideVec) and tests the
// new destination from the top -- up to SLIDETRY times, which is what
// lets an inside corner resolve against both of its walls in one
// frame rather than stopping on the first.
//
// The segs are streamed once, before the loop: the subsector does not
// change between attempts, so an attempt costs no REU traffic. That
// matters because the projection is exact enough to leave the
// destination a rounding error outside the seg it just slid along,
// and attempt 2 has to re-test it rather than trust it.
//------------------------------------------------------------
checkMove:
        lda camSsec                 // the segs the renderer will not have
        sta zChild                  // loaded yet this frame -- movePlayer
        lda camSsec+1               // runs before renderFrame
        sta zChild+1
        jsr ssecHdr
        lda zSegCnt
        bne !+
        jmp moveOK                  // a subsector with no segs blocks nothing
!:      jsr ssecSegs                // the sphere is the renderer's business:
                                    // collision wants the segs unconditionally
        lda #SLIDETRY
        sta zSlTry
!attempt:
        lda zSegCnt
        sta zWCnt
        lda #0
        sta zWIdx                   // seg cursor: a byte offset (SEGSZ)
!seg:   ldx zWIdx
        lda sgX1,x                  // zTx = x1-x0
        sec
        sbc sgX0,x
        sta zTx
        lda sgX1+1,x
        sbc sgX0+1,x
        sta zTx+1
        lda sgY1,x                  // zTy = y1-y0
        sec
        sbc sgY0,x
        sta zTy
        lda sgY1+1,x
        sbc sgY0+1,x
        sta zTy+1
        lda camY                    // zA = py-y0
        sec
        sbc sgY0,x
        sta zA
        lda camY+1
        sbc sgY0+1,x
        sta zA+1
        lda zTx                     // P1 = (x1-x0)*(py-y0)
        sta zB
        lda zTx+1
        sta zB+1
        jsr ssmul32
        lda zP+0                    // save P1
        sta zNum
        lda zP+1
        sta zNum+1
        lda zP+2
        sta zRXt                    // (borrow two scratch zp pairs)
        lda zP+3
        sta zRXt+1
        ldx zWIdx
        lda camX                    // zA = px-x0
        sec
        sbc sgX0,x
        sta zA
        lda camX+1
        sbc sgX0+1,x
        sta zA+1
        lda zTy                     // P2 = (y1-y0)*(px-x0)
        sta zB
        lda zTy+1
        sta zB+1
        jsr ssmul32
        lda zNum                    // cross = P1 - P2, need only the sign
        sec
        sbc zP+0
        lda zNum+1
        sbc zP+1
        lda zRXt
        sbc zP+2
        lda zRXt+1
        sbc zP+3
        bvc !+
        eor #$80
!:      bmi !inside+                // cross < 0: inside this seg
        ldx zWIdx
        jsr segNear                 // is this the edge actually crossed?
        bcc !inside+                // no -- a collinear seg further along
        ldy sgBack,x                // outside: one-sided seg, or a step?
        cpy #$ff
        beq moveSlide
        jsr stepOK
        bcc moveSlide
        jmp moveOK                  // through the opening: re-locate below
!inside:
        lda zWIdx
        clc
        adc #SEGSZ
        sta zWIdx
        dec zWCnt
        beq moveOK
        jmp !seg-

// The move crossed the seg at zWIdx and that seg blocks. Project what is left
// of this frame's motion onto it and test the whole thing again from the new
// destination; give up after SLIDETRY attempts, or when the seg is degenerate
// and there is no direction to slide along.
//
// The retry recomputes the destination from oldX/oldY rather than nudging
// camX/camY, because zMvDX/zMvDY is now the *projected* motion, not the
// motion that has already been applied.
moveSlide:
        dec zSlTry
        beq moveBlocked
        ldx zWIdx
        jsr slideVec
        bcc moveBlocked
        lda oldX
        clc
        adc zMvDX
        sta camX
        lda oldX+1
        adc zMvDX+1
        sta camX+1
        lda oldY
        clc
        adc zMvDY
        sta camY
        lda oldY+1
        adc zMvDY+1
        sta camY+1
        jmp !attempt-

moveBlocked:
        lda oldX                    // nothing survived the projection: undo
        sta camX
        lda oldX+1
        sta camX+1
        lda oldY
        sta camY
        lda oldY+1
        sta camY+1
        rts

// Still inside, or legally out: find the subsector the player is in
// now. Doing this unconditionally rather than only when the seg test
// said "left" also covers leaving across a partition-line edge, which
// no seg reports.
moveOK:
        jsr bspFindSsec
        lda zChild
        sta camSsec
        lda zChild+1
        sta camSsec+1
        jsr ssecHdr                 // the header alone carries the sector id
        lda zSecId
        sta camSec
        jmp setEyeZ

//------------------------------------------------------------
// stepOK: may the player cross into back sector Y?
//   carry set = yes. Blocking = a step up over MAXSTEP, or an
//   opening shorter than MINHEAD -- which is what makes a closed
//   door solid without the engine knowing what a door is.
//   Stepping *down* any distance is allowed.
//------------------------------------------------------------
stepOK:
        jsr secBack                 // -> zBackC, zBackF, eye-relative
        lda zBackC                  // headroom = backCeil - backFloor
        sec
        sbc zBackF
        sta zT
        lda zBackC+1
        sbc zBackF+1
        bmi !block+                 // ceiling below floor: sealed
        bne !head+                  // >= 256 units of headroom
        lda zT
        cmp #MINHEAD
        bcc !block+
!head:  lda zBackF                  // step = backFloor - frontFloor. Both are
        clc                         // eye-relative and the front floor is the
        adc #EYE                    // eye minus EYE, so the step is just
        sta zT                      // zBackF + EYE.
        lda zBackF+1
        adc #0
        bmi !ok+                    // stepping down
        bne !block+
        lda zT
        cmp #MAXSTEP+1
        bcs !block+
!ok:    sec
        rts
!block: clc
        rts

//------------------------------------------------------------
// slideVec: X = the blocking seg's byte offset in SEGBUF. Replaces
// zMvDX/zMvDY with their component along that seg. Carry set if it
// produced a direction, clear if the seg is degenerate and there is
// none.
//
//     d' = t-hat * (d . t-hat)
//
// which is the same vector as the plan's d - n(d.n), written in the
// seg's own direction instead of its normal -- one fewer sign to get
// wrong, and t is what SEGBUF already stores.
//
// t-hat is carried as 8.8 fixed point (256 = 1.0), so the dot product
// comes out scaled by 256 and the second multiply's >>16 takes both
// scalings out at once -- no shift chain, just the top half of the
// product. Both components stay well inside 16 bits: |t-hat| <= 1.0
// and |d| <= MOVE_SPEED, so 256*(d.t-hat) is at most ~5400.
//
// |t| is approximated as max + min/2 rather than computed: there is no
// square root in the engine, and the error only scales the slide -- it
// never turns it, which is the part that would let a slide push through
// the wall it is sliding along. Worst case (a 45-degree wall at
// max = 2*min) the player is passed along it about 20% slower than the
// true projection would; a wall on either axis is exact.
//
// Every step past the first runs twice, once per axis, and the three
// vectors it walks -- t, t-hat and the motion -- are each a pair of
// zero-page words two bytes apart. So the axis is an index rather than
// a copy of the code, at the cost of holding it in zSlAx across the
// calls that need X for themselves (mul8 and udiv both use it).
//------------------------------------------------------------
slideVec:
        txa                         // Y = the seg, X is the axis from here on
        tay
        lda sgX1,y                  // t = (x1-x0, y1-y0)
        sec
        sbc sgX0,y
        sta zSlTX
        lda sgX1+1,y
        sbc sgX0+1,y
        sta zSlTX+1
        lda sgY1,y
        sec
        sbc sgY0,y
        sta zSlTY
        lda sgY1+1,y
        sbc sgY0+1,y
        sta zSlTY+1
        ldx #0                      // zSlL = |tx|, zA = |ty|
        jsr slideAbs
        lda zA
        sta zSlL
        lda zA+1
        sta zSlL+1
        ldx #2
        jsr slideAbs
        lda zSlL                    // order them: zSlL = max, zA = min
        cmp zA
        lda zSlL+1
        sbc zA+1
        bcs !max+
        ldy zSlL
        lda zA
        sta zSlL
        sty zA
        ldy zSlL+1
        lda zA+1
        sta zSlL+1
        sty zA+1
!max:   lsr zA+1                    // zSlL = max + min/2
        ror zA
        lda zSlL
        clc
        adc zA
        sta zSlL
        lda zSlL+1
        adc zA+1
        sta zSlL+1
        ora zSlL
        bne !+
        clc                         // a zero-length seg: no direction
        rts
!:      lda #0                      // t-hat, 8.8, one axis at a time
        sta zSlAx
!norm:  ldx zSlAx
        lda zSlTX,x
        ldy zSlTX+1,x
        jsr slideNorm
        ldx zSlAx
        lda zA
        sta zSlUX,x
        lda zA+1
        sta zSlUX+1,x
        jsr slideNextAx
        bcc !norm-
        sta zSlDot                  // A = 0: 256*(d . t-hat) = dx*ux + dy*uy
        sta zSlDot+1
!dot:   ldx zSlAx
        lda zMvDX,x
        sta zA
        lda zMvDX+1,x
        sta zA+1
        lda zSlUX,x
        sta zB
        lda zSlUX+1,x
        sta zB+1
        jsr ssmul32
        lda zSlDot
        clc
        adc zP+0
        sta zSlDot
        lda zSlDot+1
        adc zP+1
        sta zSlDot+1
        jsr slideNextAx
        bcc !dot-
!proj:  ldx zSlAx                   // d' = t-hat * dot, both 8.8 -> >> 16
        lda zSlUX,x
        sta zA
        lda zSlUX+1,x
        sta zA+1
        jsr slideProj
        ldx zSlAx
        lda zA
        sta zMvDX,x
        lda zA+1
        sta zMvDX+1,x
        jsr slideNextAx
        bcc !proj-
        sec
        rts

//------------------------------------------------------------
// slideAbs: X = axis -> zA = |t[axis]|.
//------------------------------------------------------------
slideAbs:
        lda zSlTX,x
        sta zA
        lda zSlTX+1,x
        sta zA+1
        bpl !+
        jsr negA
!:      rts

//------------------------------------------------------------
// slideNextAx: step the axis index on by one word. Carry set when
// both axes are done, and A = 0 there -- which is what seeds zSlDot.
//------------------------------------------------------------
slideNextAx:
        lda zSlAx
        clc
        adc #2
        cmp #4
        bcs !+
        sta zSlAx
        clc
        rts
!:      lda #0
        sta zSlAx
        sec
        rts

//------------------------------------------------------------
// slideNorm: A/Y = one component of t (lo/hi) -> zA = that component
// over |t|, in 8.8. The dividend is the component shifted left eight
// bits, which is just where it is stored in zD -- no shifting.
//------------------------------------------------------------
slideNorm:
        sta zD+1
        sty zD+2
        lda #0
        sta zD+0
        lda zSlL
        sta zV
        lda zSlL+1
        sta zV+1
        jsr sdiv                    // signed: the component carries t's sign
        lda zD+0
        sta zA
        lda zD+1
        sta zA+1
        rts

//------------------------------------------------------------
// slideProj: zA (8.8 unit component) * zSlDot -> zA, the product's top
// sixteen bits, i.e. (8.8 * 8.8) >> 16 back in world units. The product
// is signed and its high half is the arithmetic shift, so there is
// nothing to correct.
//------------------------------------------------------------
slideProj:
        lda zSlDot
        sta zB
        lda zSlDot+1
        sta zB+1
        jsr ssmul32
        lda zP+2
        sta zA
        lda zP+3
        sta zA+1
        rts

//------------------------------------------------------------
//  Collision helpers, in the free RAM between SSECHDR and the
//  BSP stack. Out of line because the main segment ends 84 bytes
//  short of MAPINFO and these are 100.
//------------------------------------------------------------
.var mainSegPC = *
.pc = COLLCODE "collision helpers"

//------------------------------------------------------------
// segNear: X = seg offset. Carry set if the player is beside this
// seg -- inside its bounding box grown by the player's radius.
//
// Without this, containment across a *line* is mistaken for
// crossing a *seg*, and a subsector whose boundary contains two
// collinear segs blocks on the wrong one. E1M1's start-room exit is
// exactly that: subsector 105's edge at y = -3104 is a two-sided
// seg from x 928 to 1184 and a solid one from 1184 to 1216, the
// solid one comes first in the slot, and the player walks into it
// from 250 units away. The bbox is exact for an axis-aligned seg,
// which is nearly all of them, and conservative for a diagonal --
// it blocks slightly early there, never late.
//------------------------------------------------------------
segNear:
        lda camX                    // x against both endpoints
        sec
        sbc sgX0,x
        sta zA
        lda camX+1
        sbc sgX0+1,x
        sta zA+1
        jsr padClass
        sta zT+1
        lda camX
        sec
        sbc sgX1,x
        sta zA
        lda camX+1
        sbc sgX1+1,x
        sta zA+1
        jsr padClass
        cmp zT+1
        bne !yaxis+                 // straddles, or within a radius of an end
        cmp #0
        bne segFar                  // same side of both ends, and past them
!yaxis: lda camY
        sec
        sbc sgY0,x
        sta zA
        lda camY+1
        sbc sgY0+1,x
        sta zA+1
        jsr padClass
        sta zT+1
        lda camY
        sec
        sbc sgY1,x
        sta zA
        lda camY+1
        sbc sgY1+1,x
        sta zA+1
        jsr padClass
        cmp zT+1
        bne !near+
        cmp #0
        bne segFar
!near:  sec
        rts
segFar: clc
        rts

//------------------------------------------------------------
// padClass: zA (signed 16) -> A = $ff below -PLRAD, 0 within, 1 above.
// Preserves X.
//------------------------------------------------------------
padClass:
        lda zA+1
        bmi !neg+
        bne !hi+
        lda zA
        cmp #PLRAD+1
        bcc !zero+
!hi:    lda #1
        rts
!neg:   cmp #$ff
        bne !lo+
        lda zA
        cmp #256-PLRAD
        bcs !zero+
!lo:    lda #$ff
        rts
!zero:  lda #0
        rts

.errorif * > bspStkLo, "collision helpers overflow into the BSP stack"
.pc = mainSegPC "main code (cont)"

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
!:      lda #%01111111              // row 7: Q(6) = strafe left, SPACE(4) = use.
        sta $dc00                   // Both keys sit on their own zInput bit
        lda $dc01                   // (defs.asm), so this row is a mask, not a
        eor #$ff                    // pair of tests.
        and #IN_ROW7
        ora zInput
        sta zInput
        lda #$ff                    // joystick port 2 (active low)
        sta $dc00
        lda $dc00
        eor #$ff
        and #%00011111              // up/down/left/right/fire, in that order,
        ora zInput                  // are zInput's low five bits
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
!:      jmp moveSteps               // apply it in MOVESUBS tested pieces, and
                                    // return through the last of them
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
        lda zNum                    // cross = P1 - P2, kept whole: the sign
        sec                         // answers "is the point inside", and the
        sbc zP+0                    // value answers "is the body clear" (below)
        sta zCrs
        lda zNum+1
        sbc zP+1
        sta zCrs+1
        lda zRXt
        sbc zP+2
        sta zCrs+2
        lda zRXt+1
        sbc zP+3
        sta zCrs+3
        bvs !inside+                // no 32-bit value: too far outside to be a
                                    // seg of the subsector the player is in
        bmi !body+                  // cross < 0: the point is inside this seg
        ldx zWIdx
        jsr segNear                 // is this the edge actually crossed?
        bcc !inside+                // no -- a collinear seg further along
        ldy sgBack,x                // outside: one-sided seg, or a step?
        cpy #$ff
        beq moveSlide
        jsr stepOK
        bcc moveSlide
        jmp moveOK                  // through the opening: re-locate below

// The point is inside, but the player is a disc of radius PLRAD and part of
// it may not be. Three things have to hold before that blocks, and the order
// is cheapest first:
//
//   - the player is beside this seg at all (segNear -- otherwise the infinite
//     line every seg lies on would block from across the room);
//   - the seg is one the player could not walk through anyway. A *passable*
//     two-sided seg must never be padded: a portal the body may not overlap
//     is a portal the player can never cross, and every doorway in the game
//     is one of those;
//   - the motion is pushing into the seg (segPush). Without that last test a
//     player who is already inside the band -- carried there through a portal,
//     since only the segs of the subsector he was in were ever tested -- would
//     be frozen, with every direction blocked including the way out.
!body:  ldx zWIdx
        jsr segNear
        bcc !inside+
        ldy sgBack,x
        cpy #$ff
        beq !solid+
        jsr stepOK
        bcs !inside+                // a portal he may cross: no radius here
!solid: jsr segBody
        bcc !inside+
        jsr segPush
        bcs moveSlide
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
// slideAbs: X = axis -> zA = |t[axis]|. `sta` leaves the flags alone, so the
// sign tested is still the one the load of the high byte set.
//------------------------------------------------------------
slideAbs:
        lda zSlTX,x
        sta zA
        lda zSlTX+1,x
        sta zA+1
        bpl !+
        jmp negA                    // negA ends in the rts this needs
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

.errorif * > JUMPCODE, "collision helpers overflow into the jump"

//------------------------------------------------------------
//  Jumping — SPACE, the same key that opens a door.
//
//  What the player gets is 0.42 s off the floor and a peak of JUMPPEAK
//  world units, which is two thirds of eye height: enough that the room
//  visibly moves in a direction the walls cannot, which is the point.
//
//  The arc is a table (jumpTab, below) rather than a velocity and a gravity.
//  Doom integrates, and integrating here would cost an add, a subtract, a
//  sign test and a second zero-page byte for the velocity -- and would put
//  the peak at the mercy of rounding, which is exactly the number that must
//  not drift: nothing in the renderer or the collision test stops the eye
//  rising through a ceiling, so the peak is what keeps it below one.
//
//  camJZ is fed to setEyeZ (src/render/bsp.asm) and to nothing else. Two
//  things fall out of that, and both are wanted:
//
//    - the eye follows the floor while airborne, so jumping on a lift or in
//      a doorway does what it looks like it should;
//    - stepOK measures a step as `zBackF + EYE`, which is the step *below the
//      eye*. With the eye camJZ higher, a ledge is camJZ shorter, so a jump
//      climbs onto anything within MAXSTEP + camJZ. Ledge-jumping is free,
//      and it is the reason the feature is worth its 43 bytes.
//
//  Holding SPACE re-jumps on landing, because the take-off test is a level
//  and not an edge. That is bunny-hopping, it costs nothing, and the door
//  key it shares is edge-triggered on its own side (zLnUse, src/lines.asm),
//  so a held SPACE still opens a door exactly once.
//------------------------------------------------------------
.pc = JUMPCODE "jump: the frame hook"

//------------------------------------------------------------
// playerFrame — mainLoop's movement call. Walk, then step the arc, then set
// the eye. It replaces `jsr movePlayer` at the call site rather than being
// called after it because the main segment has one byte free and this way
// costs none of it.
//
// movePlayer ends in setEyeZ itself, on the path where the move succeeded;
// that one runs with the *previous* frame's camJZ and is overwritten here a
// few hundred cycles later. Leaving it is a byte cheaper than removing it.
//------------------------------------------------------------
playerFrame:
        jsr movePlayer
        lda zInput                  // SPACE, or an arc that has not landed:
        and #IN_USE                 // either one is a frame of the jump. The
        ora camJT                   // arc owns the key until it ends, so the
        beq !noJump+                // two tests fold into one branch -- which
        jmp jumpStep                // is what makes this block exactly 17 B
!noJump:
        jmp bobStep                 // on foot: the walk bob sets the eye

.errorif * > JUMPCODE_END, "the jump's frame hook overflows into the BSP stack"

//------------------------------------------------------------
.pc = JUMPBOOT "boot: jump arc relocator source"
//------------------------------------------------------------
// jumpStep — advance the arc by one frame.
//
// $ff ends it: the arc lands the player exactly, on the frame the table
// says, rather than when a velocity happens to cross zero.
//
// It runs at $ffe4, in the 22 bytes between the music IRQ handler and the
// CPU vectors, because below MATRIX there is no sixteen-byte hole left --
// the one this used to occupy, $0f40, turned out to be frameCnt and the map
// checksums, and boot overwrote the routine before the first frame. That
// address is RAM in both banking states the engine uses, for the same reason
// MUSCODE is (defs.asm), so nothing here has to touch $01.
//
// Like LINECODE* and MUSCODE it cannot be in the PRG image at all, so it is
// assembled here in MATRIX with .pseudopc and copied up by lineBoot
// (src/lines.asm) -- which is already called at boot and already sets the
// banking this needs, so the copy costs no main-segment bytes.
//------------------------------------------------------------
jmpStepSrc:
.pseudopc JUMPCODE2 {
jumpStep:
        ldx camJT                   // the cursor: 0 on the take-off frame, so
        inx                         // the first entry read is jumpTab's first
        lda jumpTab-1,x
        bpl !+
        ldx #0                      // the arc is over: both feet down again,
        txa                         // and A = 0 is the height that means it
!:      sta camJZ
        stx camJT
        jmp setEyeZ
}
jmpStepEnd:

// The Src/End pair is named for probe.py's relocated-block check (`make
// check`), which compares $ffe4 in live RAM against this image in the PRG
// file. That check is exactly what the $0f40 version of this block did not
// have, and it is why the bug survived a green build.
.errorif JUMPCODE2 + jmpStepEnd - jmpStepSrc > JUMPCODE2_END, "the jump arc overflows into the CPU vectors"
.errorif * > JUMPBOOT + $40, "the jump relocator source overflows its slack in MATRIX"

//------------------------------------------------------------
.pc = JUMPTAB "jump: the arc"
//------------------------------------------------------------
// Eye height above the sector floor, one entry per frame, $ff-terminated.
// Symmetric, because a Doom jump is: the shape is a parabola sampled at
// 16.7 fps, flattened at the top by one frame so the peak reads as a peak
// at this frame rate rather than as a single-frame spike.
//------------------------------------------------------------
jumpTab:
        .byte 12, 22, 28, 28, 22, 12, 4, $ff
.errorif * > JUMPTAB_END, "the jump arc overflows into the collision helpers"

//------------------------------------------------------------
.pc = BOBCODE "the walk bob"
//------------------------------------------------------------
// bobStep — the eye rises and falls while the player is moving, as Doom's
// does. playerFrame's on-foot path, so it ends in setEyeZ on its behalf.
//
// The wave is a triangle over the low three bits of frameCnt, reflected at 4
// and doubled: 0 2 4 6 6 4 2 0, one entry per frame, BOBPEAK at the top. It
// is computed rather than looked up because 23 bytes is what the hole holds
// (BOBCODE, defs.asm).
//
// The test is IN_MOVE and not "did the player actually move", which is what
// walking into a wall makes of it: the bob carries on against a wall, exactly
// as Doom's does, because Doom bobs on the *command* too.
//
// Turning is not movement -- IN_MOVE is the four translation bits -- so
// standing and looking around leaves the eye still, and the standing path
// costs three instructions to reach `sta camJZ` with A already zero.
//
// One thing it shares with the jump, and the reason the peak is 6 rather than
// Doom's 8: camJZ raises the eye, and stepOK measures a step as the drop
// below the eye, so a bobbing player climbs onto a ledge up to BOBPEAK units
// taller than MAXSTEP on the frames near the top of the wave. Six units of
// leniency against a 24-unit step is under the width of one texel; the jump
// already grants 28 deliberately.
//------------------------------------------------------------
bobStep:
        lda zInput
        and #IN_MOVE                // standing still: A = 0, and the eye is
        beq !zero+                  // the sector's floor plus EYE exactly
        lda frameCnt                // the phase. It is free: mainLoop counts
        and #7                      // frames anyway, and eight of them at
        cmp #4                      // 16.71 fps is very nearly Doom's own
        bcc !+                      // 20-tic bob period
        eor #7                      // reflect 4-7 back down to 3-0
!:      asl                         // 0-3 -> 0-BOBPEAK, in eye units
!zero:  sta camJZ
        jmp setEyeZ

.errorif * > BOBCODE_END, "the walk bob overflows into the converter tables"

//------------------------------------------------------------
.pc = MOVECODE "the substepped move"
//------------------------------------------------------------
//  moveSteps — apply this frame's displacement in MOVESUBS tested pieces.
//
//  checkMove is a *point* test against the segs of one subsector, and the
//  subsector it tests is the one the player started the step in. So the real
//  limit on a step is not how far the player may travel but how far they may
//  travel *unchecked*: cross a thin subsector whole and the seg on its far
//  side was never in SEGBUF, was never tested, and does not block.
//
//  E1M1's doors are exactly that geometry. Sector 76's door track is 16 units
//  deep and sector 75 in front of it is another 16, against MOVE_SPEED = 21:
//  walking south into the door from subsector 216, the step crossed 216's own
//  seg (two-sided, into 75, legally passable), jumped clean over subsector 217
//  and landed inside the closed door. The door's seg belongs to 217, the
//  player was never in 217, and so nothing ever asked whether the door was
//  shut. Four parts put the longest substep at 7.4 units, well under the
//  16-unit floor of E1M1's geometry -- see MOVESUBS in defs.asm for the cost.
//
//  Each substep is a whole move: its own undo point, its own containment
//  test, its own slide, and its own bspFindSsec at the end -- which is what
//  makes the *next* substep test the subsector the player has just entered
//  rather than the one they left. That is the whole fix; the arithmetic below
//  is only about splitting the motion without losing any of it.
//------------------------------------------------------------

//------------------------------------------------------------
// quarter: q = d >> MOVESHIFT (arithmetic), r = d & (MOVESUBS-1).
// `cmp #$80` puts the sign in carry, which is what makes the shift signed.
//------------------------------------------------------------
.macro quarter(d, q, r) {
        lda d
        and #MOVESUBS-1
        sta r
        lda d
        sta q
        lda d+1
        sta q+1
        ldx #MOVESHIFT
!:      lda q+1
        cmp #$80
        ror q+1
        ror q
        dex
        bne !-
}

//------------------------------------------------------------
// subStep: d = q, plus one of the r units the shift rounded away. Handing
// those out one substep at a time is what makes the parts sum to the frame's
// motion exactly -- floor() alone would make walking west up to 20% faster
// than walking east, since it rounds towards minus infinity in both.
//------------------------------------------------------------
.macro subStep(q, r, d) {
        lda q
        sta d
        lda q+1
        sta d+1
        lda r
        beq !+
        dec r
        inc d
        bne !+
        inc d+1
!:
}

moveSteps:
        :quarter(zMvDX, zSubX, zRemX)
        :quarter(zMvDY, zSubY, zRemY)
        lda #MOVESUBS
        sta zSubN
!sub:   lda camX                    // the undo point is this substep's start,
        sta oldX                    // not the frame's: moveBlocked and the
        lda camX+1                  // slide retry both measure from it
        sta oldX+1
        lda camY
        sta oldY
        lda camY+1
        sta oldY+1
        :subStep(zSubX, zRemX, zMvDX)
        :subStep(zSubY, zRemY, zMvDY)
        :addWord(zMvDX, camX)
        :addWord(zMvDY, camY)
        jsr checkMove               // leaves camSsec/camSec on the subsector
        dec zSubN                   // this substep ended in, so the next one
        bne !sub-                   // is tested against the right segs
        rts

.errorif * > MOVECODE_END, "the substepped move overflows into the wall tiles"

//------------------------------------------------------------
.pc = BODYCODE "the player's radius"
//------------------------------------------------------------
//  The player used to be a point, and a point can stand *on* a wall. Two
//  things went wrong with that, and only the second one is visible:
//
//   - a wall the eye is closer to than NEAR = 16 is dropped by the renderer's
//     near-plane clip, and a dropped seg leaves its columns open, so the room
//     behind a thin wall paints through it. Standing against a wall put one
//     side of the view inside the next room while the other stayed correct.
//   - the player could stand in geometry no real body fits in: inside corners,
//     door tracks, the far side of a one-unit-thick wall.
//
//  So the test point grows into a disc of radius PLRAD. The cross product is
//  *linear* in the point, which is what makes this cheap: for a seg direction
//  (dx, dy), moving the test point by (ex, ey) changes the cross by
//  dx*ey - dy*ex, and the corner of the player's box that maximises that is
//  worth exactly PLRAD*(|dx| + |dy|). So the most-outside point of the whole
//  body is the value already computed plus one term -- no second cross
//  product, no square root, and the same trick as Doom's P_BoxOnLineSide.
//
//  It is exact for an axis-aligned seg, which is most of them, and blocks up
//  to R*(sqrt(2)-1) early on a 45-degree one. Early is the safe direction.
//------------------------------------------------------------

//------------------------------------------------------------
// segBody: does the player's body reach the seg the cross in zCrs was
// computed for? Carry set = yes (cross + PLRAD*(|dx| + |dy|) >= 0).
// Call with zCrs negative -- the point itself inside -- and zTx/zTy still
// holding the seg's direction, which they do for the whole seg loop.
//
// zPad cannot overflow 24 bits: |dx| + |dy| is under 2^17 for any seg the
// map format can express and 24 * that is under 2^22. The final add cannot
// overflow either, because zCrs is negative here and zPad is not -- which is
// why the sign of the high byte is the whole answer.
//------------------------------------------------------------
segBody:
        lda zTx                     // zA = |dx|
        sta zA
        lda zTx+1
        sta zA+1
        bpl !+
        jsr negA
!:      lda zTy                     // zB = |dy|
        sta zB
        lda zTy+1
        sta zB+1
        bpl !+
        jsr negB
!:      lda #0                      // zPad = |dx| + |dy|, in 24 bits
        sta zPad+2
        clc
        lda zA
        adc zB
        sta zPad
        lda zA+1
        adc zB+1
        sta zPad+1
        bcc !+
        inc zPad+2
!:      ldx #3                      // zPad *= 24, as (L << 4) + (L << 3)
!:      asl zPad
        rol zPad+1
        rol zPad+2
        dex
        bne !-
        lda zPad                    // keep 8L
        sta zP
        lda zPad+1
        sta zP+1
        lda zPad+2
        sta zP+2
        asl zPad                    // 16L
        rol zPad+1
        rol zPad+2
        clc
        lda zPad
        adc zP
        sta zPad
        lda zPad+1
        adc zP+1
        sta zPad+1
        lda zPad+2
        adc zP+2
        sta zPad+2
        clc                         // cross + pad: negative = the body is clear
        lda zCrs
        adc zPad
        lda zCrs+1
        adc zPad+1
        lda zCrs+2
        adc zPad+2
        lda zCrs+3
        adc #0
        bmi segBodyNo
        sec
        rts
segBodyNo:
        clc
        rts

//------------------------------------------------------------
// segPush: is this substep's motion pushing the body into the seg?
// Carry set = yes. The quantity is the same cross product taken over the
// displacement instead of the position -- d = dx*mvDY - dy*mvDX -- because
// cross is linear, so d is exactly how much the seg's cross product grew
// this substep, and "inside" is cross < 0.
//
// Blocking only when d > 0 is what keeps the radius from being a trap. A
// player can legitimately end up inside the band: only the segs of the
// subsector he is standing in are ever tested, so stepping through a portal
// can land him next to a wall belonging to the subsector he just entered.
// Without this test every direction out of that band would be blocked too,
// and he would be stuck for good. With it, the band is a wall he can leave
// and slide along -- and sliding is exactly the d = 0 case.
//------------------------------------------------------------
segPush:
        lda zTx
        sta zA
        lda zTx+1
        sta zA+1
        lda zMvDY
        sta zB
        lda zMvDY+1
        sta zB+1
        jsr ssmul32
        lda zP+0
        sta zNum
        lda zP+1
        sta zNum+1
        lda zP+2
        sta zRXt
        lda zP+3
        sta zRXt+1
        lda zTy
        sta zA
        lda zTy+1
        sta zA+1
        lda zMvDX
        sta zB
        lda zMvDX+1
        sta zB+1
        jsr ssmul32
        lda zNum                    // d = P1 - P2, and zSign accumulates the
        sec                         // low bytes so that d = 0 (motion parallel
        sbc zP+0                    // to the seg) can be told from d > 0
        sta zSign
        lda zNum+1
        sbc zP+1
        ora zSign
        sta zSign
        lda zRXt
        sbc zP+2
        ora zSign
        sta zSign
        lda zRXt+1
        sbc zP+3
        bvc !+
        eor #$80
!:      bmi segPushNo               // d < 0: the motion is away from the seg
        ora zSign
        beq segPushNo               // d = 0: along it -- a slide, not a push
        sec
        rts
segPushNo:
        clc
        rts

//------------------------------------------------------------
// nearFix: doWall's near-plane fail-safe, jumped to (not called) from
// walls.asm's !reject with both endpoints nearer than ry = NEAR.
//
// Dropping such a seg leaves its columns open, and an open column paints
// whatever the BSP visits next -- which is the subsector *behind* the wall.
// That is the see-through: stand against a thin wall and the room on the far
// side comes through the part of the screen the wall should have covered.
//
// Only one case is genuinely invisible: both endpoints behind the eye. Then
// the seg is dropped exactly as before. Otherwise the seg is in front and
// simply too close for the projection to divide by, so both endpoints are
// pushed out to the near plane and the seg is drawn from there. The span that
// gives is narrower than the truth -- a wall at ry = 8 subtends twice what the
// same rx does at 16 -- so a sliver can still leak at the edges, but the wall
// is drawn, it closes its columns, and nothing divides by a depth of zero.
//
// The radius (PLRAD = 24 > NEAR) already keeps every seg of the subsector the
// player is standing in outside the near plane. What it cannot reach is segs
// of *neighbouring* subsectors: collision only ever tests the subsector the
// player is in, so a wall a few units away that belongs to the subsector next
// door is still reachable, and that is the case this covers. E1M1 has 538
// standable grid cells within 16 units of an occluding seg's vertex.
//------------------------------------------------------------
nearFix:
        lda zRY0+1                  // both high bytes negative: the whole seg
        and zRY1+1                  // is behind the eye and cannot be seen
        bmi !drop+
        lda #NEAR
        sta zRY0
        sta zRY1
        lda #0
        sta zRY0+1
        sta zRY1+1
        jmp wallNearDone
!drop:  :Count(CNT_SEGNEAR)
        rts

.errorif * > BODYCODE_END, "the radius test overflows into the video matrix"

.pc = mainSegPC "main code (cont)"

//============================================================
//  input.asm — WASDQE keyboard + joystick port 2, player movement
//  with subsector containment (slide-free blocking collision)
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
// against the segs of the subsector they were standing in; undo the
// move if it crossed a blocking one, otherwise re-locate them.
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
// The limitation is pipeline.md §5.3's, inherited unchanged: one
// frame's motion that crosses two boundaries at once is only tested
// against the first.
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
!:      sta zWCnt
        jsr ssecSegs                // the sphere is the renderer's business:
                                    // collision wants the segs unconditionally
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
        beq moveBlocked
        jsr stepOK
        bcc moveBlocked
        jmp moveOK                  // through the opening: re-locate below
!inside:
        lda zWIdx
        clc
        adc #SEGSZ
        sta zWIdx
        dec zWCnt
        beq moveOK
        jmp !seg-

moveBlocked:
        lda oldX                    // undo: no sliding in M1
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

//============================================================
//  input.asm — WASDQE keyboard + joystick port 2, player movement
//  with convex-sector containment (slide-free blocking collision)
//
//  W/S   forward / back        A/D   turn left / right
//  Q/E   strafe left / right   joy 2 up/down/left/right = W/S/A/D
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
        jsr checkSector
moveDone:
        rts

//------------------------------------------------------------
// checkSector: if the player left the current convex sector,
// either follow a portal or undo the move (solid wall).
// Interior test: CW winding -> inside means cross <= 0 for all
// walls, where cross = (x1-x0)*(py-y0) - (y1-y0)*(px-x0).
//------------------------------------------------------------
checkSector:
        ldy camSec
        lda secWFirst,y
        sta zWIdx
        lda secWCount,y
        sta zWCnt
!wall:  ldx zWIdx
        lda wX1Lo,x                 // zTx = x1-x0
        sec
        sbc wX0Lo,x
        sta zTx
        lda wX1Hi,x
        sbc wX0Hi,x
        sta zTx+1
        lda wY1Lo,x                 // zTy = y1-y0
        sec
        sbc wY0Lo,x
        sta zTy
        lda wY1Hi,x
        sbc wY0Hi,x
        sta zTy+1
        lda camY                    // zA = py-y0
        sec
        sbc wY0Lo,x
        sta zA
        lda camY+1
        sbc wY0Hi,x
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
        sbc wX0Lo,x
        sta zA
        lda camX+1
        sbc wX0Hi,x
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
!:      bmi !inside+                // cross < 0: inside this wall
        ldx zWIdx                   // outside: portal or solid?
        lda wBack,x
        cmp #$ff
        beq !blocked+
        sta camSec                  // follow portal
        tay
        lda secFloorLo,y            // eye z follows new floor
        clc
        adc #EYE
        sta camZ
        lda secFloorHi,y
        adc #0
        sta camZ+1
        rts
!blocked:
        lda oldX                    // solid wall: undo the move
        sta camX
        lda oldX+1
        sta camX+1
        lda oldY
        sta camY
        lda oldY+1
        sta camY+1
        rts
!inside:
        inc zWIdx
        dec zWCnt
        beq !+
        jmp !wall-
!:      rts

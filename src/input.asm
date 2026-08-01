//============================================================
//  input.asm — WASD keyboard + joystick port 2, player movement
//  with convex-sector containment (slide-free blocking collision)
//============================================================



//------------------------------------------------------------
readInput:
        lda #0
        sta zInput
        lda #%11111101              // keyboard row 1: W(bit1) A(bit2) S(bit5)
        sta $dc00
        lda $dc01
        tay
        and #%00000010
        bne !+
        lda #1                      // W = forward
        ora zInput
        sta zInput
!:      tya
        and #%00100000
        bne !+
        lda #2                      // S = back
        ora zInput
        sta zInput
!:      tya
        and #%00000100
        bne !+
        lda #4                      // A = turn left
        ora zInput
        sta zInput
!:      lda #%11111011              // row 2: D(bit2)
        sta $dc00
        lda $dc01
        and #%00000100
        bne !+
        lda #8                      // D = turn right
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
        and #4
        beq !+
        lda camA
        sec
        sbc #TURN_SPEED
        sta camA
!:      lda zInput
        and #8
        beq !+
        lda camA
        clc
        adc #TURN_SPEED
        sta camA
!:      lda zInput                  // movement
        and #3
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
        lda #MOVE_SPEED             // dx = cos * speed >> 14
        sta zA
        lda #0
        sta zA+1
        lda camCos
        sta zB
        lda camCos+1
        sta zB+1
        jsr smulTrig
        lda zInput
        and #2
        bne !back1+
        lda camX                    // forward
        clc
        adc zA
        sta camX
        lda camX+1
        adc zA+1
        sta camX+1
        jmp !+
!back1: lda camX
        sec
        sbc zA
        sta camX
        lda camX+1
        sbc zA+1
        sta camX+1
!:      lda #MOVE_SPEED             // dy = sin * speed >> 14
        sta zA
        lda #0
        sta zA+1
        lda camSin
        sta zB
        lda camSin+1
        sta zB+1
        jsr smulTrig
        lda zInput
        and #2
        bne !back2+
        lda camY
        clc
        adc zA
        sta camY
        lda camY+1
        adc zA+1
        sta camY+1
        jmp !+
!back2: lda camY
        sec
        sbc zA
        sta camY
        lda camY+1
        sbc zA+1
        sta camY+1
!:      jsr checkSector
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

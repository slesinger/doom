//============================================================
//  walls.asm — portal wall renderer into the chunky MATRIX
//
//  Convex sectors, clockwise winding (interior on the right of
//  each directed wall). Front-to-back portal traversal with
//  per-column clip windows colTop/colBot.
//
//  Camera space: ry = forward, rx = rightward.
//    sx  = 80 + rx*HFOCAL/ry          (HFOCAL = 80, 90 deg FOV)
//    row = 88 - dz*VFOCAL/ry          (VFOCAL = 160)
//
//  Screen y lines (wall top/bottom edges) are linear in screen x,
//  so per-column work is pure 24-bit accumulator stepping.
//============================================================

// 24-bit acc += sign-extended 16-bit step
.macro AddStep(acc, step) {
        lda acc
        clc
        adc step
        sta acc
        lda acc+1
        adc step+1
        sta acc+1
        lda acc+2
        bit step+1
        bmi neg
        adc #0
        jmp done
neg:    adc #$ff
done:   sta acc+2
}

.pc = WALLSCODE "walls code"

//------------------------------------------------------------
renderFrame:
        ldx #159                    // open all column windows
        lda #0
!:      sta colTop,x
        dex
        bpl !-
        ldx #159
        lda #176
!:      sta colBot,x
        dex
        bpl !-
        ldy camA                    // camera trig
        lda sinLo,y
        sta camSin
        lda sinHi,y
        sta camSin+1
        tya
        clc
        adc #64                     // cos(a) = sin(a+64), 8-bit wrap
        tay
        lda sinLo,y
        sta camCos
        lda sinHi,y
        sta camCos+1
        ldx #NUMSEC-1               // clear per-frame visited flags
        lda #0
!:      sta visitedSec,x
        dex
        bpl !-
        lda camSec                  // seed traversal with camera sector
        sta pStkSec
        tax
        lda #1
        sta visitedSec,x            // never re-enter the start sector
        sta stackN
        lda #0
        sta pStkXL
        lda #159
        sta pStkXR
popLoop:
!pop:   dec stackN
        ldx stackN
        lda pStkSec,x
        sta zSecId
        lda pStkXL,x
        sta zXL
        lda pStkXR,x
        sta zXR
        jsr renderSector
        lda stackN
        bne !pop-
        rts

//------------------------------------------------------------
renderSector:
        ldy zSecId
        lda secCeilLo,y             // dzC = ceil - eyeZ
        sec
        sbc camZ
        sta zDzC
        lda secCeilHi,y
        sbc camZ+1
        sta zDzC+1
        lda secFloorLo,y            // dzF = floor - eyeZ
        sec
        sbc camZ
        sta zDzF
        lda secFloorHi,y
        sbc camZ+1
        sta zDzF+1
        lda secCByte,y
        sta zCeilByte
        lda secFByte,y
        sta zFloorByte
        lda secWFirst,y
        sta zWIdx
        lda secWCount,y
        sta zWCnt
wallLoopHead:
!walls: ldx zWIdx
        jsr doWall
        inc zWIdx
        dec zWCnt
        bne !walls-
        rts

//------------------------------------------------------------
// doWall: render wall X within window [zXL, zXR]
//------------------------------------------------------------
doWall:
        stx zWIdx2
        // ---- endpoint 0 -> camera space
        lda wX0Lo,x
        sec
        sbc camX
        sta zTx
        lda wX0Hi,x
        sbc camX+1
        sta zTx+1
        lda wY0Lo,x
        sec
        sbc camY
        sta zTy
        lda wY0Hi,x
        sbc camY+1
        sta zTy+1
        jsr transformPoint
        lda zRXt
        sta zRX0
        lda zRXt+1
        sta zRX0+1
        lda zRYt
        sta zRY0
        lda zRYt+1
        sta zRY0+1
        // ---- endpoint 1 -> camera space
        ldx zWIdx2
        lda wX1Lo,x
        sec
        sbc camX
        sta zTx
        lda wX1Hi,x
        sbc camX+1
        sta zTx+1
        lda wY1Lo,x
        sec
        sbc camY
        sta zTy
        lda wY1Hi,x
        sbc camY+1
        sta zTy+1
        jsr transformPoint
        lda zRXt
        sta zRX1
        lda zRXt+1
        sta zRX1+1
        lda zRYt
        sta zRY1
        lda zRYt+1
        sta zRY1+1
        // ---- near-plane rejection / clipping
        lda zRY0+1                  // ry0 < NEAR ?
        bmi !r0behind+
        bne !r0front+
        lda zRY0
        cmp #NEAR
        bcc !r0behind+
!r0front:
        lda zRY1+1                  // ry1 < NEAR ?
        bmi !toClip1+
        bne !toDone+
        lda zRY1
        cmp #NEAR
        bcc !toClip1+
!toDone:
        jmp !nearDone+
!toClip1:
        jmp !clip1+
!r0behind:                          // ry0 behind: if ry1 too -> reject
        lda zRY1+1
        bmi !reject+
        bne !clip0+
        lda zRY1
        cmp #NEAR
        bcs !clip0+
!reject:
        rts
!clip0:                             // clip endpoint 0 against ry=NEAR
        lda #NEAR                   // num = NEAR - ry0
        sec
        sbc zRY0
        sta zNum
        lda #0
        sbc zRY0+1
        sta zNum+1
        lda zRY1                    // den = ry1 - ry0
        sec
        sbc zRY0
        sta zA
        lda zRY1+1
        sbc zRY0+1
        sta zA+1
        jsr clipT                   // zT+2 = t (0.8 fixed)
        lda zRX1                    // rx0 += (rx1-rx0)*t >> 8
        sec
        sbc zRX0
        sta zA
        lda zRX1+1
        sbc zRX0+1
        sta zA+1
        jsr mulT
        clc
        adc zRX0
        sta zRX0
        tya
        adc zRX0+1
        sta zRX0+1
        lda #NEAR
        sta zRY0
        lda #0
        sta zRY0+1
        jmp !nearDone+
!clip1:                             // clip endpoint 1 against ry=NEAR
        lda #NEAR                   // num = NEAR - ry1
        sec
        sbc zRY1
        sta zNum
        lda #0
        sbc zRY1+1
        sta zNum+1
        lda zRY0                    // den = ry0 - ry1
        sec
        sbc zRY1
        sta zA
        lda zRY0+1
        sbc zRY1+1
        sta zA+1
        jsr clipT
        lda zRX0                    // rx1 += (rx0-rx1)*t >> 8
        sec
        sbc zRX1
        sta zA
        lda zRX0+1
        sbc zRX1+1
        sta zA+1
        jsr mulT
        clc
        adc zRX1
        sta zRX1
        tya
        adc zRX1+1
        sta zRX1+1
        lda #NEAR
        sta zRY1
        lda #0
        sta zRY1+1
!nearDone:
        // ---- project screen x at both ends
        lda zRX0
        sta zA
        lda zRX0+1
        sta zA+1
        lda zRY0
        sta zV
        lda zRY0+1
        sta zV+1
        jsr projSX
        lda zD
        sta zSXW0
        lda zD+1
        sta zSXW0+1
        lda zRX1
        sta zA
        lda zRX1+1
        sta zA+1
        lda zRY1
        sta zV
        lda zRY1+1
        sta zV+1
        jsr projSX
        lda zD
        sta zSXW1
        lda zD+1
        sta zSXW1+1
        // ---- backface / zero width: require sx0 < sx1 (signed)
        lda zSXW0
        cmp zSXW1
        lda zSXW0+1
        sbc zSXW1+1
        bvc !+
        eor #$80
!:      bpl !reject2+               // sx0 >= sx1 -> back-facing
        // ---- clamp to column range [zXL, zXR]
        lda zSXW0+1
        bmi !useXL+                 // sx0 < 0
        bne !reject2+               // sx0 > 255 -> fully right of screen
        lda zSXW0
        cmp zXL
        bcs !+
!useXL: lda zXL
!:      cmp zXR                     // clamp down to zXR too: sx0 may be
        bcc !+                      // 160..255, inside the byte but past
        lda zXR                     // the column-window's right edge
!:      sta zC0
        lda zSXW1+1                 // c1 = min(sx1-1, zXR)
        bmi !reject2+               // sx1 <= 0 -> fully left
        bne !useXR+                 // sx1 > 255 -> use right edge
        ldy zSXW1
        beq !reject2+               // sx1 == 0
        dey
        tya
        cmp zXR
        bcc !+
!useXR: lda zXR
!:      sta zC1
        cmp zC0
        bcs !cols+
!reject2:
        rts
!cols:
        // ---- wall shading byte from mid distance: light = (ry0+ry1)>>7
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
        sta zNum+1
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
        ora wRamp,x
        sta zWallByte
        // ---- rows at both ends: top (ceil) and bot (floor) lines
        lda zDzC
        sta zA
        lda zDzC+1
        sta zA+1
        jsr useRY0
        jsr projRow
        sta zTop0
        sty zTop0+1
        lda zDzC
        sta zA
        lda zDzC+1
        sta zA+1
        jsr useRY1
        jsr projRow
        sta zTop1
        sty zTop1+1
        lda zDzF
        sta zA
        lda zDzF+1
        sta zA+1
        jsr useRY0
        jsr projRow
        sta zBot0
        sty zBot0+1
        lda zDzF
        sta zA
        lda zDzF+1
        sta zA+1
        jsr useRY1
        jsr projRow
        sta zBot1
        sty zBot1+1
        // ---- dx = sx1 - sx0 (>= 1)
        lda zSXW1
        sec
        sbc zSXW0
        sta zDX
        lda zSXW1+1
        sbc zSXW0+1
        sta zDX+1
        // ---- portal back-sector lines (before lineSetup: fills zBTop/zBBot)
        ldx zWIdx2
        lda wBack,x
        sta zBack
        cmp #$ff
        beq !solidSetup+
        tay
        lda secCeilLo,y             // back dzC -> zNum
        sec
        sbc camZ
        sta zNum
        lda secCeilHi,y
        sbc camZ+1
        sta zNum+1
        lda zNum
        sta zA
        lda zNum+1
        sta zA+1
        jsr useRY0
        jsr projRow
        sta zBTop0
        sty zBTop0+1
        lda zNum
        sta zA
        lda zNum+1
        sta zA+1
        jsr useRY1
        jsr projRow
        sta zBTop1
        sty zBTop1+1
        ldy zBack
        lda secFloorLo,y            // back dzF -> zNum
        sec
        sbc camZ
        sta zNum
        lda secFloorHi,y
        sbc camZ+1
        sta zNum+1
        lda zNum
        sta zA
        lda zNum+1
        sta zA+1
        jsr useRY0
        jsr projRow
        sta zBBot0
        sty zBBot0+1
        lda zNum
        sta zA
        lda zNum+1
        sta zA+1
        jsr useRY1
        jsr projRow
        sta zBBot1
        sty zBBot1+1
        ldx #0                      // set up all 4 line interpolators
!:      jsr lineSetup
        inx
        cpx #4
        bne !-
        jmp !colloop+
!solidSetup:
        ldx #0                      // top + bot lines only
        jsr lineSetup
        ldx #1
        jsr lineSetup
        // ---- per-column loop
!colloop:
        ldx zC0
colLoopHead:
!col:   stx zSX
        lda colTop,x
        sta zWT
        lda colBot,x
        sta zWB
        cmp zWT
        bcc !closed+                // window closed
        bne !open+
!closed:
        jmp !advance+
!open:  ldy #0                      // clamp top line -> zTW
        jsr clampAcc
        sta zTW
        sta zWT                     // bot line clamps below wall top
        ldy #3
        jsr clampAcc
        sta zBW
        ldx zSX
        lda colTop,x                // ceiling span [window top, zTW)
        sta zSY0
        lda zTW
        sta zSY1
        lda zCeilByte
        sta zSCol
        jsr spanFill
        lda zBW                     // floor span [zBW, window bottom)
        sta zSY0
        lda zWB
        sta zSY1
        lda zFloorByte
        sta zSCol
        jsr spanFill
        lda zBack
        cmp #$ff
        bne !portal+
        lda zTW                     // solid wall span [zTW, zBW)
        sta zSY0
        lda zBW
        sta zSY1
        lda zWallByte
        sta zSCol
        jsr spanFill
        ldx zSX
        lda #176                    // close column
        sta colTop,x
        lda #0
        sta colBot,x
        jmp !advance+
!portal:
        lda zTW                     // clamp portal lines into [zTW, zBW]
        sta zWT
        lda zBW
        sta zWB
        ldy #6
        jsr clampAcc                // portal opening top -> zBT
        sta zBT
        sta zWT
        ldy #9
        jsr clampAcc                // portal opening bottom -> zBB
        sta zBB
        lda zTW                     // upper wall [zTW, zBT)
        sta zSY0
        lda zBT
        sta zSY1
        lda zWallByte
        sta zSCol
        jsr spanFill
        lda zBB                     // lower wall [zBB, zBW)
        sta zSY0
        lda zBW
        sta zSY1
        lda zWallByte
        sta zSCol
        jsr spanFill
        ldx zSX
        lda zBT                     // narrow window to the opening
        sta colTop,x
        lda zBB
        sta colBot,x
!advance:
colAdvance:
        :AddStep(accTop, stepTop)
        :AddStep(accBot, stepBot)
        lda zBack
        cmp #$ff
        beq !+
        :AddStep(accBT, stepBT)
        :AddStep(accBB, stepBB)
!:      ldx zSX
        cpx zC1
        beq !colsDone+
        inx
        jmp !col-
!colsDone:
        lda zBack                   // portal: queue back sector
        cmp #$ff
        beq !done+
        tay
        lda visitedSec,y            // once per frame only
        bne !done+
        lda #1
        sta visitedSec,y
        ldx stackN
        cpx #PSTKMAX
        bcs !done+
        tya
        sta pStkSec,x
        lda zC0
        sta pStkXL,x
        lda zC1
        sta pStkXR,x
        inc stackN
!done:  rts

.errorif * > $d000, "walls main code overflows into IO"

//------------------------------------------------------------
// helper routines live in the gap after the math code
//------------------------------------------------------------
.pc = WALLS2 "walls helpers"

//------------------------------------------------------------
// useRY0/useRY1: load ry into divisor zV
//------------------------------------------------------------
useRY0: lda zRY0
        sta zV
        lda zRY0+1
        sta zV+1
        rts
useRY1: lda zRY1
        sta zV
        lda zRY1+1
        sta zV+1
        rts

//------------------------------------------------------------
// clampAcc: clamp integer part of accumulator Y (0=top, 3=bot,
// 6=btop, 9=bbot) into [zWT, zWB]. Returns A. Preserves X.
//------------------------------------------------------------
clampAcc:
        lda accTop+2,y              // int hi byte
        bmi !lo+
        bne !hi+
        lda accTop+1,y              // int lo byte
        cmp zWT
        bcc !lo+
        cmp zWB
        bcs !hi+
        rts
!lo:    lda zWT
        rts
!hi:    lda zWB
        rts

//------------------------------------------------------------
// lineSetup: X = line index 0-3 (top/bot/btop/bbot).
//   step_i = ((y1_i - y0_i) << 8) / dx        (signed, saturating)
//   acc_i  = y0_i << 8  +  step_i * (c0 - sx0)
// Preserves X.
//------------------------------------------------------------
lineSetup:
        stx zLineI
        txa
        asl
        asl
        tay                         // Y = i*4: y0 at zTop0+Y, y1 at zTop0+2+Y
        lda zTop0+2,y               // dy = y1 - y0
        sec
        sbc zTop0,y
        sta zD+1
        lda zTop0+3,y
        sbc zTop0+1,y
        sta zD+2
        lda #0
        sta zD                      // dividend = dy << 8 (signed 24)
        lda zDX
        sta zV
        lda zDX+1
        sta zV+1
        jsr sdiv                    // zD+0..1 = step
        lda zLineI
        asl
        tax                         // X = i*2
        lda zD
        sta stepTop,x
        sta zB
        lda zD+1
        sta stepTop+1,x
        sta zB+1
        sta zSign                   // remember step sign
        bpl !+
        jsr negB                    // zB = |step|
!:      lda zC0                     // zA = skip = c0 - sx0 (>= 0)
        sec
        sbc zSXW0
        sta zA
        lda #0
        sbc zSXW0+1
        sta zA+1
        jsr umul16                  // zP = |step| * skip
        lda zLineI
        asl
        adc zLineI
        tax                         // X = i*3 (acc offset)
        lda zLineI
        asl
        asl
        tay                         // Y = i*4 (y0 offset)
        bit zSign
        bmi !neg+
        lda zP+0                    // acc = (0, y0lo, y0hi) + P
        sta accTop,x
        lda zTop0,y
        clc
        adc zP+1
        sta accTop+1,x
        lda zTop0+1,y
        adc zP+2
        sta accTop+2,x
        jmp !fin+
!neg:   sec                         // acc = (0, y0lo, y0hi) - P
        lda #0
        sbc zP+0
        sta accTop,x
        lda zTop0,y
        sbc zP+1
        sta accTop+1,x
        lda zTop0+1,y
        sbc zP+2
        sta accTop+2,x
!fin:   ldx zLineI
        rts

//------------------------------------------------------------
// transformPoint: (zTx,zTy) world-relative -> camera space
//   zRYt = (tx*cos + ty*sin) >> 14
//   zRXt = (tx*sin - ty*cos) >> 14
//------------------------------------------------------------
transformPoint:
        lda zTx
        sta zA
        lda zTx+1
        sta zA+1
        lda camCos
        sta zB
        lda camCos+1
        sta zB+1
        jsr smulTrig                // tx*cos
        lda zA
        sta zRYt
        lda zA+1
        sta zRYt+1
        lda zTy
        sta zA
        lda zTy+1
        sta zA+1
        lda camSin
        sta zB
        lda camSin+1
        sta zB+1
        jsr smulTrig                // ty*sin
        lda zA
        clc
        adc zRYt
        sta zRYt
        lda zA+1
        adc zRYt+1
        sta zRYt+1
        lda zTx
        sta zA
        lda zTx+1
        sta zA+1
        lda camSin
        sta zB
        lda camSin+1
        sta zB+1
        jsr smulTrig                // tx*sin
        lda zA
        sta zRXt
        lda zA+1
        sta zRXt+1
        lda zTy
        sta zA
        lda zTy+1
        sta zA+1
        lda camCos
        sta zB
        lda camCos+1
        sta zB+1
        jsr smulTrig                // ty*cos
        lda zRXt
        sec
        sbc zA
        sta zRXt
        lda zRXt+1
        sbc zA+1
        sta zRXt+1
        rts

//------------------------------------------------------------
// clipT: t = (zNum << 8) / zA, unsigned, result 0-255 in zT+2
//------------------------------------------------------------
clipT:
        lda zA
        sta zV
        lda zA+1
        sta zV+1
        lda #0
        sta zD
        lda zNum
        sta zD+1
        lda zNum+1
        sta zD+2
        jsr udiv
        lda zD
        sta zT+2
        rts

//------------------------------------------------------------
// mulT: (signed zA * unsigned zT+2) >> 8 -> A (lo) : Y (hi), signed
//------------------------------------------------------------
mulT:
        lda zA+1
        sta zSign
        bpl !+
        jsr negA
!:      lda zT+2
        sta zB
        lda #0
        sta zB+1
        jsr umul16
        bit zSign
        bmi !neg+
        lda zP+1
        ldy zP+2
        rts
!neg:   sec                         // negate 16-bit (P>>8)
        lda #0
        sbc zP+1
        pha
        lda #0
        sbc zP+2
        tay
        pla
        rts

//------------------------------------------------------------
// projSX: sx = 80 + (zA * HFOCAL)/zV  (zA signed, zV > 0)
// result signed 16 in zD+0..1
//------------------------------------------------------------
projSX:
        lda zA+1
        sta zSign
        bpl !+
        jsr negA
!:      lda #HFOCAL
        sta zB
        lda #0
        sta zB+1
        jsr umul16
        lda zP+0
        sta zD+0
        lda zP+1
        sta zD+1
        lda zP+2
        sta zD+2
        jsr udiv
        lda zD+1                    // clamp quotient to $7fff
        bpl !+
        lda #$ff
        sta zD+0
        lda #$7f
        sta zD+1
!:      bit zSign
        bmi !neg+
        lda zD+0                    // sx = 80 + q
        clc
        adc #80
        sta zD+0
        bcc !+
        inc zD+1
!:      rts
!neg:   lda #80                     // sx = 80 - q
        sec
        sbc zD+0
        pha
        lda #0
        sbc zD+1
        sta zD+1
        pla
        sta zD+0
        rts

//------------------------------------------------------------
// projRow: row = 88 - (zA * VFOCAL)/zV  (zA = dz signed, zV > 0)
// result signed 16: A = lo, Y = hi
//------------------------------------------------------------
projRow:
        lda zA+1
        sta zSign
        bpl !+
        jsr negA
!:      lda #<VFOCAL
        sta zB
        lda #>VFOCAL
        sta zB+1
        jsr umul16
        lda zP+0
        sta zD+0
        lda zP+1
        sta zD+1
        lda zP+2
        sta zD+2
        jsr udiv
        lda zD+1                    // clamp quotient to $7fff
        bpl !+
        lda #$ff
        sta zD+0
        lda #$7f
        sta zD+1
!:      bit zSign
        bmi !neg+
        lda #88                     // row = 88 - q
        sec
        sbc zD+0
        pha
        lda #0
        sbc zD+1
        tay
        pla
        rts
!neg:   lda zD+0                    // row = 88 + q
        clc
        adc #88
        pha
        lda zD+1
        adc #0
        tay
        pla
        rts

// size check moved to main.asm

.errorif * > BITMAP0, "walls helpers overflow into BITMAP0"

//============================================================
//  walls.asm — seg renderer into the chunky MATRIX
//
//  One seg of one subsector, drawn into the per-column clip
//  windows colTop/colBot. The traversal that decides which
//  subsectors get here, and in what order, is bsp.asm; this file
//  is what it calls per seg.
//
//  Winding is clockwise, front sector on the right of each
//  directed seg -- Doom's own convention and the test map's, so
//  the backface test is still the single signed compare sx0 < sx1
//  (docs/reu-format.md §5.1).
//
//  Camera space: ry = forward, rx = rightward.
//    sx  = 80 + rx*HFOCAL/ry          (HFOCAL = 80, 90 deg FOV)
//    row = HORIZON - dz*VFOCAL/ry     (VFOCAL = 160, HORIZON = VIEWROWS/2)
//
//  Screen y lines (wall top/bottom edges) are linear in screen x,
//  so per-column work is pure 24-bit accumulator stepping.
//
//  Occlusion: a column is closed when colTop[x] >= colBot[x]. A
//  one-sided seg closes every column it covers; a two-sided one
//  narrows them to its opening. openCols counts the columns still
//  open and is what ends the frame early -- there are no inherited
//  [xL,xR] windows any more, because with BSP order there is no
//  portal to inherit one through.
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
// doWall: render the seg at byte offset X in SEGBUF.
//
// X is an offset, not an index: seg records are 10 bytes, so the
// alternative is a multiply per seg to save nothing.
//------------------------------------------------------------
doWall:
        stx zWIdx2
        lda #0                      // no endpoint has been clipped yet; texUEnds
        sta zClipW                  // reads this to decide whether u needs the
                                    // same correction rx0/rx1 got below
        // ---- endpoint 0 -> camera space
        lda sgX0,x
        sec
        sbc camX
        sta zTx
        lda sgX0+1,x
        sbc camX+1
        sta zTx+1
        lda sgY0,x
        sec
        sbc camY
        sta zTy
        lda sgY0+1,x
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
        lda sgX1,x
        sec
        sbc camX
        sta zTx
        lda sgX1+1,x
        sbc camX+1
        sta zTx+1
        lda sgY1,x
        sec
        sbc camY
        sta zTy
        lda sgY1+1,x
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
        jmp wallNearDone
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
        jmp nearFix                 // both ends are nearer than the near plane
                                    // -- which is only safe to drop if they
                                    // are also *behind* the eye. src/input.asm
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
        jsr texClip0                // u's endpoint 0 moves by the same t
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
        jmp wallNearDone
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
        jsr texClip1                // u's endpoint 1 moves by the same t
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
wallNearDone:
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
        // ---- clamp to the screen, [0, 159]. Under BSP order there is no
        // inherited window to clamp against: what a nearer subsector already
        // covered is recorded per column in colTop/colBot, not in an x range.
        lda zSXW0+1                 // c0 = max(sx0, 0)
        bmi !c0zero+                // sx0 < 0
        bne !reject2+               // sx0 > 255 -> fully right of screen
        lda zSXW0
        cmp #160
        bcs !reject2+
        jmp !c0set+
!c0zero:
        lda #0
!c0set: sta zC0
        lda zSXW1+1                 // c1 = min(sx1-1, 159)
        bmi !reject2+               // sx1 <= 0 -> fully left of screen
        bne !c1max+                 // sx1 > 255
        ldy zSXW1
        beq !reject2+               // sx1 == 0
        dey
        tya
        cmp #160
        bcc !c1set+
!c1max: lda #159
!c1set: sta zC1
        cmp zC0
        bcs !cols+
!reject2:
        :Count(CNT_SEGBACK)
        rts
!cols:
        // ---- is any column in [zC0, zC1] still open?
        //
        // Everything below this point -- the shading, four projRow calls, up
        // to four more for the back sector, and four lineSetup slope
        // divisions -- is a dozen 16-bit divisions, and all of it is wasted
        // if a nearer subsector has already closed every column this seg
        // covers. Under BSP order that is the common case on real geometry:
        // E1M1's walk reaches most of its segs after the near ones have
        // closed the screen. The scan costs about ten cycles per column
        // against roughly six hundred per division skipped.
        ldx zC0
!scan:  lda colTop,x
        cmp colBot,x
        bcc !visible+               // colTop < colBot -> still open
        inx
        cpx zC1
        bcc !scan-
        beq !scan-
        rts
!visible:
        // ---- wall shading byte from mid distance: light = (ry0+ry1)>>7.
        // Out of line at TX_SHADE since M2's texturing: it runs once per seg,
        // and this segment ran out of room for the texture hooks (tex.asm).
        jsr segShade                // wallShade + this seg's quantised depth
                                    // for sprite z-clipping (§12.1, sprite.asm)
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
        // ---- two-sided seg: the opening's lines (before lineSetup, which
        // reads zBTop/zBBot). secBack banks the sector table in and out once
        // for both heights -- see bsp.asm.
        ldx zWIdx2
        lda sgBack,x
        sta zBack
        cmp #$ff
        beq !solidSetup+
        tay
        jsr secBack                 // -> zBackC, zBackF, eye-relative
        lda zBackC
        sta zA
        lda zBackC+1
        sta zA+1
        jsr useRY0
        jsr projRow
        sta zBTop0
        sty zBTop0+1
        lda zBackC
        sta zA
        lda zBackC+1
        sta zA+1
        jsr useRY1
        jsr projRow
        sta zBTop1
        sty zBTop1+1
        lda zBackF
        sta zA
        lda zBackF+1
        sta zA+1
        jsr useRY0
        jsr projRow
        sta zBBot0
        sty zBBot0+1
        lda zBackF
        sta zA
        lda zBackF+1
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
        // The texture's tile, u's line and v's step and anchor -- or zTexOn = 0
        // and every wall span below falls through to the flat spanFill M1 used.
        // After the lineSetup calls: u is line 4 and texSetup makes that call
        // itself, and it needs zDzC, which is this seg's.
        jsr texSetup
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
!open:  jsr texUpd                  // reload texStrip if u's texel moved
        ldy #0                      // clamp top line -> zTW
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
        jsr wallSpan
        ldx zSX
        jsr colClose                // closes for good; colTop[x] <- this seg's
                                    // quantised depth, not a sentinel (§12.1)
        jmp !advance+
!portal:
        lda zTW                     // clamp portal lines into [zTW, zBW]
        sta zWT
        lda zBW
        sta zWB
        ldy #6
        jsr clampAcc                // opening top -> zBT
        sta zBT
        sta zWT
        ldy #9
        jsr clampAcc                // opening bottom -> zBB
        cmp zBT                     // a closed door has none: back ceiling at
        bcs !+                      // or below back floor. Collapse the
        lda zBT                     // opening rather than let the two spans
!:      sta zBB                     // below overlap in reverse order.
        lda zTW                     // upper wall [zTW, zBT)
        sta zSY0
        lda zBT
        sta zSY1
        lda zWallByte
        sta zSCol
        jsr wallSpan
        lda zBB                     // lower wall [zBB, zBW)
        sta zSY0
        lda zBW
        sta zSY1
        lda zWallByte
        sta zSCol
        jsr wallSpan
        ldx zSX
        lda zBT                     // narrow the window to the opening
        sta colTop,x
        lda zBB
        sta colBot,x
        cmp zBT                     // an empty opening closes the column
        bne !advance+
        jsr colClose                // empty opening: closes for good, and
                                    // colTop[x] <- depth overwrites the zBT
                                    // just stored above (§12.1)
!advance:
colAdvance:
        :AddStep(accTop, stepTop)
        :AddStep(accBot, stepBot)
        lda zBack
        cmp #$ff
        beq !+
        :AddStep(accBT, stepBT)
        :AddStep(accBB, stepBB)
!:      jsr uAdvance                // u keeps pace with screen x on closed
        ldx zSX                     // columns too -- it is a function of x
        cpx zC1
        beq !colsDone+
        inx
        jmp !col-
!colsDone:
        rts                         // nothing to queue: bsp.asm owns the order

// bsp.asm's traversal starts at BSPCODE, immediately after this.
.errorif * > BSPCODE, "doWall overflows into the BSP traversal"

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
// projRow: row = HORIZON - (zA * VFOCAL)/zV  (zA = dz signed, zV > 0)
// HORIZON is the eye level in MATRIX rows (defs.asm), not in raster rows --
// the converter shifts the whole buffer down by VIEWTOP on the way out.
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
        lda #HORIZON                // row = HORIZON - q
        sec
        sbc zD+0
        pha
        lda #0
        sbc zD+1
        tay
        pla
        rts
!neg:   lda zD+0                    // row = HORIZON + q
        clc
        adc #HORIZON
        pha
        lda zD+1
        adc #0
        tay
        pla
        rts

.errorif * > BITMAP0, "walls helpers overflow into BITMAP0"

//------------------------------------------------------------
//  Third piece: the backface test, in the free RAM between the BSP
//  stack and MATRIX. Called by bsp.asm's renderSsec, one seg ahead of
//  doWall.
//------------------------------------------------------------
.pc = BFACECODE "backface test"

//------------------------------------------------------------
// segFacing — is the seg at byte offset X in SEGBUF facing the camera?
//   carry set   -> front-facing, draw it
//   carry clear -> back-facing or edge-on, skip it
//
// doWall already rejects a back-facing seg, with the signed compare
// sx0 < sx1 (pipeline.md §8.5) -- but only after two transformPoint
// calls and two projSX divisions, because it needs the projected x of
// both endpoints to make the comparison. That is about six thousand
// cycles to learn that a seg is pointing away, and instrumenting the
// spawn frame said 219 of its 319 segs -- 69% -- end exactly there
// (IMPLEMENTATION_PLAN.md §13).
//
// Facing is a world-space property, though, and needs no projection:
//
//   cross = dx*(camY - y0) - dy*(camX - x0),   dx,dy = seg delta
//
// is Doom's R_PointOnSide with the seg for the partition line, and
// cross < 0 means the camera is on the seg's *right*, which is where
// its front sector is by the winding rule (docs/reu-format.md §5.1).
// So the whole test is the sign of one cross product -- two ssmul32
// calls, no divisions -- and it is the same arithmetic sideOf already
// runs on nodes.
//
// cross == 0 is the camera exactly on the seg's line, which projects
// to zero width. Rejecting it matches doWall, whose test is `sx0 <
// sx1` and so drops the equal case too.
//
// doWall's own test stays. It costs nothing that is not already paid
// by then, and it still catches what this one cannot see: a seg that
// faces the camera but lands entirely off the side of the screen.
//
// Clobbers A, X, Y, zA, zB, zP, zSign and zTop0..zTop0+3 -- the same
// borrow of doWall's line endpoints that sideOf makes, and safe for
// the same reason: doWall has not filled them yet.
//------------------------------------------------------------
segFacing:
        lda sgX1,x                  // zA = dx = x1 - x0
        sec
        sbc sgX0,x
        sta zA
        lda sgX1+1,x
        sbc sgX0+1,x
        sta zA+1
        lda camY                    // zB = pdy = camY - y0
        sec
        sbc sgY0,x
        sta zB
        lda camY+1
        sbc sgY0+1,x
        sta zB+1
        jsr ssmul32                 // zP = dx*pdy
        lda zP+0
        sta zTop0
        lda zP+1
        sta zTop0+1
        lda zP+2
        sta zTop0+2
        lda zP+3
        sta zTop0+3
        ldx zWIdx                   // ssmul32 runs through mul8, which
        lda sgY1,x                  // clobbers X. zA = dy = y1 - y0
        sec
        sbc sgY0,x
        sta zA
        lda sgY1+1,x
        sbc sgY0+1,x
        sta zA+1
        lda camX                    // zB = pdx = camX - x0
        sec
        sbc sgX0,x
        sta zB
        lda camX+1
        sbc sgX0+1,x
        sta zB+1
        jsr ssmul32                 // zP = dy*pdx
        lda zTop0                   // cross = dx*pdy - dy*pdx, sign only
        sec
        sbc zP+0
        lda zTop0+1
        sbc zP+1
        lda zTop0+2
        sbc zP+2
        lda zTop0+3
        sbc zP+3
        bvc !+
        eor #$80
!:      bmi !front+
        clc                         // cross >= 0: facing away, or edge-on
        rts
!front: sec
        rts

.errorif * > $1000, "the backface test overflows into MATRIX"

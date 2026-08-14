//============================================================
//  sprite.asm — §12's sprites (IMPLEMENTATION_PLAN.md §12, §12.1)
//
//  Three pieces, built up in the order the plan's phases land:
//
//    segShade/colClose   depth capture. doWall closes a column two
//                         ways (a solid wall, a collapsed portal
//                         opening); both now leave the closing
//                         seg's quantised depth in colTop[x] and 0
//                         in colBot[x], instead of a fixed sentinel.
//                         Neither byte is ever read again once a
//                         column is closed (only the closed
//                         predicate colBot[x] < colTop[x] is
//                         re-tested), so this is free: colTop[]
//                         *is* the depth array after renderFrame
//                         returns, and colBot[x] != 0 marks a
//                         column nothing ever closed, where a
//                         sprite is always visible.
//
//    sprPick              the per-subsector thing pickup, called
//                         from bsp.asm's renderSsec once a
//                         subsector has passed the sphere test.
//
//    sprFrame/sprDraw      the visible-list sort and the masked,
//                         scaled blit, called from mainLoop between
//                         renderFrame and wpnFrame.
//
//  Two pieces, SPRCODE2 (the tail of WPNCODE, freed by moving
//  wpnFrame out to WPNBLIT) and SPRCODE (SPRART's own tail) --
//  bin-packed the way tex.asm's eleven pieces are, because that is
//  what the machine has room for, not because either routine wants
//  to be split.
//============================================================

.pc = SPRCODE2 "sprite pick + sort"

//------------------------------------------------------------
// segShade — wallShade (tex.asm), plus the seg's quantised depth
// for §12.1's sprite z-test. Same call site (walls.asm), one jsr
// further out: A is dead across the tail call so wallShade's own
// A-in-X-out contract to its caller is unchanged.
//
//   q = clamp((ry0+ry1) >> 5, 1, 255)   -- 16 world units/step
//
// Floored at 1, not 0: 0 is not ambiguous with "open" (both closed
// predicates treat colBot==colTop as closed -- see colClose below),
// the floor exists so SPR_BIAS can subtract one step from a
// sprite's own depth without underflowing a wall already at q=0.
//------------------------------------------------------------
segShade:
        lda zRY0
        clc
        adc zRY1
        sta zSegQ                   // low byte of the sum, reused as scratch
        lda zRY0+1
        adc zRY1+1
        bcs !far+                   // ry0+ry1 carried out of 16 bits: far
        lsr
        ror zSegQ
        lsr
        ror zSegQ
        lsr
        ror zSegQ
        lsr
        ror zSegQ
        lsr
        ror zSegQ                   // A:zSegQ >> 5 -- take A (bits 5-... of
        cmp #0                      // the sum) as the overflow check: nonzero
        beq !low+                   // means beyond 255 steps (4080+ units)
!far:   lda #255
        sta zSegQ
        jmp !st+
!low:   lda zSegQ
        bne !st+
        lda #1                      // floor at 1
        sta zSegQ
!st:    jmp wallShade                // wallShade re-sets zNum itself; A is
                                     // dead into it either way

//------------------------------------------------------------
// colClose — X = zSX. Closes column X for good, depth-first: the
// wall pass never reads colTop[x]/colBot[x] again once closed, so
// this doubles as §12.1's per-column depth array. Called from both
// of doWall's full-close sites (walls.asm).
//------------------------------------------------------------
colClose:
        lda zSegQ
        sta colTop,x
        lda #0
        sta colBot,x
        dec openCols
        rts

//------------------------------------------------------------
// sprPick — called from bsp.asm's renderSsec right after secFront, while
// zDzF/zDzC are still this subsector's own sector's. zChild's low byte is
// the subsector index (bspLeaf clears bit 15 into zChild+1, and MAXSSEC=237
// < 256, so it is a plain 0-236 index -- no mask needed).
//
// For each thing in sprSsecFirst[ssec] .. sprSsecFirst[ssec+1]): world ->
// camera space via transformPoint, frustum-rejected via sphereTest with the
// type's own world half-width as the test radius (same call sphereVisible
// makes on a subsector's bounding sphere, one call further in), then an
// explicit ry > 0 guard -- sphereTest only guarantees ry + r >= 0, and
// projSX/projRow (walls.asm) both divide by ry assuming it is positive.
// Survivors are appended to the sprVis* SoA arrays, capped at MAXVIS for
// the whole frame (not per subsector -- sprVisN is reset once, in
// renderFrame). zDzF is captured now because sprDraw walks the sorted list
// long after the BSP walk that made it valid has moved on.
//
// Clobbers A, X, Y and everything transformPoint/sphereTest do. Nothing it
// touches needs to survive its own rts (see sprPickI/sprPickEnd, defs.asm).
//------------------------------------------------------------
sprPick:
        lda zChild
        tax
        lda sprSsecFirst,x
        sta sprPickI
        inx
        lda sprSsecFirst,x
        sta sprPickEnd
        cmp sprPickI
        beq !rts+                   // empty subsector: nothing to pick

!loop:  lda sprVisN
        cmp #MAXVIS
        bcs !rts+                   // this frame's visible-list budget is spent

        ldx sprPickI
        lda thingXlo,x
        sec
        sbc camX
        sta zTx
        lda thingXhi,x
        sbc camX+1
        sta zTx+1
        lda thingYlo,x
        sec
        sbc camY
        sta zTy
        lda thingYhi,x
        sbc camY+1
        sta zTy+1
        lda thingType,x
        tay
        lda sprTypHW,y               // zRad = this type's world half-width,
        sta zRad                    // zero-extended (a byte, always positive)
        lda #0
        sta zRad+1
        jsr transformPoint           // -> zRXt, zRYt (walls.asm)
        jsr sphereTest                // carry set = possibly visible
        bcc !skip+
        lda zRYt+1                   // ry <= 0: behind or on the eye plane --
        bmi !skip+                   // projSX/projRow both need ry > 0
        bne !store+
        lda zRYt
        beq !skip+

!store: ldy sprVisN
        lda zRXt
        sta sprVisRXlo,y
        lda zRXt+1
        sta sprVisRXhi,y
        lda zRYt
        sta sprVisRYlo,y
        lda zRYt+1
        sta sprVisRYhi,y
        lda zDzF
        sta sprVisDZlo,y
        lda zDzF+1
        sta sprVisDZhi,y
        lda sprPickI
        sta sprVisIdx,y
        inc sprVisN

!skip:  inc sprPickI
        lda sprPickI
        cmp sprPickEnd
        bne !loop-
!rts:   rts

//------------------------------------------------------------
// sprSort — insertion sort of sprVisPerm[0..sprVisN-1] so that
// sprVisRY[perm[0]] >= sprVisRY[perm[1]] >= ... : farthest first,
// nearest last. Painter's algorithm -- a nearer prop overdraws a
// farther one exactly the way doWall's own draw order does. sprVisN
// <= MAXVIS = 10, so this is cheap wherever it runs; it does not need
// to be fast, only right, and runs once a frame.
//
// zSign is the outer index i (persists across the inner shifts, which
// use sprSortI as the insert-position cursor). Both are dead here:
// nothing between sprPick's last use and this call touches them.
//------------------------------------------------------------
sprSort:
        ldx #0
!init:  txa
        sta sprVisPerm,x
        inx
        cpx sprVisN
        bne !init-
        lda sprVisN
        cmp #2
        bcc !done+
        lda #1
        sta zSign
!outer: ldx zSign
        lda sprVisPerm,x
        sta sprSortT                 // T = value being inserted
        stx sprSortI                 // insert-position cursor, starts at i
!inner: lda sprSortI
        beq !insert+
        tay
        dey                          // Y = j = cursor-1 (a position)
        lda sprVisPerm,y
        sta sprSortJ                 // value v = perm[j]
        tax                          // X = v, to index RY[v]
        lda sprVisRYhi,x
        ldy sprSortT                 // Y = T, to index RY[T]
        cmp sprVisRYhi,y
        bne !cmpdone+
        lda sprVisRYlo,x
        cmp sprVisRYlo,y
!cmpdone:
        bcs !insert+                 // RY[v] >= RY[T]: already in order, stop
        lda sprSortJ                 // shift v right one slot, keep looking
        ldx sprSortI
        sta sprVisPerm,x
        dec sprSortI
        jmp !inner-
!insert:
        ldx sprSortI
        lda sprSortT
        sta sprVisPerm,x
        inc zSign
        lda zSign
        cmp sprVisN
        bne !outer-
!done:  rts

//------------------------------------------------------------
// sprBlit — sprC1 = starting column, sprC0 = columns left (both set by
// sprSetupUV), sprR0/sprRows rows, sprSrc = the current source column
// (SPRIMG, column-major). Column-outer so the per-column occlusion test
// (colTop/colBot, §12.1) runs once per column instead of once per pixel.
// Every column's v accumulator starts at 0 -- there is no vAccStart to
// carry, since sprDraw already rejected any box a screen edge clips
// (Opus-advised, §12 sizing pass). Lives here, not in SPRCODE with the
// rest of the draw path, because this is where the free bytes were.
//------------------------------------------------------------
sprBlit:
        lda sprC1
        sta sprX
!col:   ldx sprX
        lda colBot,x
        bne !draw+                   // column still open: always visible
        lda sprQ
        cmp colTop,x
        bcs !skip+                   // sprQ >= the wall's depth: wall wins
!draw:
        // ---- column term of the cell address, fixed for every row in this
        // column: (col>>2)*32 == (col & $fc) << 3 ----
        lda sprX
        and #$fc
        sta zP
        lda #0
        sta zP+1
        asl zP
        rol zP+1
        asl zP
        rol zP+1
        asl zP
        rol zP+1                     // zP = (col & $fc) << 3

        lda #0
        sta zTy                      // zTy:zTy+1 = this column's v accumulator
        sta zTy+1
        lda sprR0
        sta zA                       // zA(lo) = current screen row
        ldx sprRows
!row:   ldy zTy+1
        lda (sprSrc),y
        beq !nextRow+                // transparent: no store, still steps v
        sta zB                       // stash the pixel (%rrrriiii, ramp baked in)
        lda zA
        lsr
        lsr
        lsr
        tay
        lda rowCellLo,y
        clc
        adc zP
        sta zD
        lda rowCellHi,y
        adc zP+1
        sta zD+1
        lda zA
        and #7
        asl
        asl
        clc
        adc zD
        sta zD
        bcc !+
        inc zD+1
!:      lda sprX
        and #3
        tay
        lda zB
        sta (zD),y
!nextRow:
        lda zTy
        clc
        adc sprVStep
        sta zTy
        lda zTy+1
        adc sprVStep+1
        sta zTy+1
        inc zA
        dex
        bne !row-
!skip:
        jsr sprAdvU                  // step sprUAcc, advance sprSrc if its
                                     // integer column rolled over -- in
                                     // SPRCODE (Opus-advised, §12 sizing
                                     // pass: SPRCODE2 had no bytes left)
        inc sprX
        dec sprC0
        beq !colDone+
        jmp !col-                    // out of branch range: the column body is
!colDone:                           // long, same as wpnFrame's own row jmp
        rts

.errorif * > SPRCODE2 + 432, "sprite pick/sort overflows SPRCODE2"

.pc = SPRCODE3 "sprite draw setup"

//------------------------------------------------------------
// sprScale — A = a focal constant (HFOCAL or VFOCAL, both < 256), zA(2B) =
// a world length, zero-extended if it came from a byte -> zD(2B) = that
// length in screen units, unsigned. zV is set here from zRYt (ry_used,
// live for the whole of sprDraw's call into this) -- callers never set it.
// The tail of projSX/projRow with no sign handling (a length is never
// negative) and no +80/HORIZON offset; shared between the X half-width and
// (via subtraction, see sprDraw) the vertical extent, one focal constant
// apart (Opus-advised, §12 sizing pass).
//------------------------------------------------------------
sprScale:
        sta zB
        lda #0
        sta zB+1
        lda zRYt
        sta zV
        lda zRYt+1
        sta zV+1
        jsr umul16
        lda zP+0
        sta zD+0
        lda zP+1
        sta zD+1
        lda zP+2
        sta zD+2
        jmp udiv

//------------------------------------------------------------
// sprStep — A = an art dimension (art_w or art_h, a byte), zV(lo) = the
// matching screen extent in pixels (a byte, set by the caller; hi left at
// 0 here) -> zD(2B) = the 8.8 fixed-point step, art units per screen unit.
// Shared by sprSetupUV's two divides.
//------------------------------------------------------------
sprStep:
        sta zD+1                     // dividend = A*256, in zD (udiv's own
        lda #0                       // input), not zA -- zA is not what
        sta zD                       // udiv reads; leaving it there made
        sta zD+2                     // both steps divide whatever zD
        sta zV+1                     // sprScale's last call happened to
        jmp udiv                     // leave behind instead

//------------------------------------------------------------
// sprSetupUV — the screen box is entirely on screen (sprDraw's inline
// reject test already ran). zRad/zTy still hold the box's unclipped top/
// bottom rows, zTx/zRYt its unclipped left/right columns -- this reads
// them once more to get sprR0/sprRows (rows) and the column count (left
// in sprC0, box start in sprC1, both consumed by sprBlit), then the two
// 8.8 fixed-point u/v steps. No partial clipping and hence no skip*step
// re-sync multiply (Phase 5 note, defs.asm) -- both accumulators start at
// exactly 0, so vAccStart is never stored (dropped, Opus-advised).
//------------------------------------------------------------
sprSetupUV:
        lda zRad
        sta sprR0                    // top row (0..VIEWROWS-1, confirmed by
                                     // the reject test in sprDraw)
        lda zTy
        sec
        sbc zRad
        adc #0                      // +1: sbc left C=1 (top <= bottom always)
        sta sprRows
        sta zV                       // A is still the row count -- no reload
        ldx sprType
        lda sprTypH,x
        sta sprH                     // art_h persists: sprBlit's column stride
        jsr sprStep                 // vStep = art_h*256 / sprRows; sta left
                                     // art_h in A, so no reload here either
        lda zD
        sta sprVStep
        lda zD+1
        sta sprVStep+1

        lda zTx
        sta sprC1                    // left column (0..159), sprBlit's start
        lda zRYt
        sec
        sbc zTx
        adc #0                       // +1, same idiom
        sta sprC0                    // columns left, sprBlit's countdown
        sta zV
        ldx sprType
        lda sprTypArtLo,x            // sprSrc BEFORE the divide, not after:
        clc                          // udiv exits with X = 0 (its loop counter)
        adc #<SPRIMG                 // on every path but the saturate one, so
        sta sprSrc                   // an indexed load after jsr sprStep reads
        lda sprTypArtHi,x            // type 0's art, whatever sprType says.
        adc #>SPRIMG                 // Costs nothing here; reloading X after
        sta sprSrc+1                 // the call would cost 2 B.
        lda sprTypW,x
        jsr sprStep                  // uStep = art_w*256 / sprC0
        lda zD
        sta sprUStep
        lda zD+1
        sta sprUStep+1
        lda #0
        sta sprUAcc                  // initial column = art column 0 exactly
        sta sprUAcc+1
        rts

//------------------------------------------------------------
// sprDrawX — the second half of sprDraw (X projection, the box's column
// reject test, then the setup+blit calls), split out purely for code-size
// packing across the three sprite slots -- see sprDraw's own header.
// Entry/exit exactly where sprDraw left off: zRXt = rx, zRYt = ry_used,
// zTy/zRad = the row box already computed and passed the row reject.
//------------------------------------------------------------
sprDrawX:
        // ---- halfW = sprScale(HFOCAL, hw) -> zNum. This runs BEFORE the
        // projSX below, not after, because sprScale sets zV from zRYt itself
        // and projSX wants that same zV -- and nothing between the two
        // touches it (umul16/mul8/udiv/negA all read zV or leave it alone).
        // So projSX's own four-instruction zV setup is simply dropped: -8 B
        // (Opus-advised, §12 sizing pass). ----
        ldx sprType
        lda sprTypHW,x
        sta zA
        lda #0
        sta zA+1
        lda #HFOCAL
        jsr sprScale
        lda zD
        sta zNum
        lda zD+1
        sta zNum+1

        // ---- cx = projSX(rx, ry_used) -> zTx; zV is already ry_used ----
        lda zRXt
        sta zA
        lda zRXt+1
        sta zA+1
        jsr projSX
        lda zD
        sta zTx
        lda zD+1
        sta zTx+1

        // ---- C1u = cx+halfW -> zRYt ; C0u = cx-halfW -> zTx (overwrites cx) ----
        lda zTx
        clc
        adc zNum
        sta zRYt
        lda zTx+1
        adc zNum+1
        sta zRYt+1
        lda zTx
        sec
        sbc zNum
        sta zTx
        lda zTx+1
        sbc zNum+1
        sta zTx+1

        lda zTx+1
        bne !reject+                  // left < 0 or left >= 256: a negative
                                      // high byte is a nonzero one, so bne
                                      // covers both and the bmi is dropped
        lda zRYt+1
        bne !reject+                  // right >= 256
        lda zRYt
        cmp #160
        bcs !reject+                  // right >= 160

        jsr sprSetupUV                 // -> sprR0/sprRows/sprC0/sprC1/steps/sprSrc/sprH
        jsr sprBlit
!reject:
        rts

//------------------------------------------------------------
// mouseTurn — a 1351 in proportional mode, port 1. jumpStep and bobStep
// (src/input.asm) both end in `jmp setEyeZ` on playerFrame's behalf; both
// now say `jmp mouseTurn` instead, which costs neither of those packed
// blocks a byte -- only the operand of an existing jmp changed -- and still
// runs unconditionally once a frame, same as they did. See IMPLEMENTATION_
// PLAN.md §11c/16 for why this lives here: it is the only code-capable gap
// MAXVIS's trim (above) left in the machine.
//
// $dc00 bits 6/7 mux the SID's POTX/POTY between the two control ports; port
// 1 is selected in readInput's own joystick-port-2 read, not here (input.asm's
// tail, %01011111 in place of the old $ff) -- that leaves the mux parked on
// port 1 for the whole rest of the frame instead of switching to it the same
// instant it gets read, so POTX has had a full frame to settle by the time
// the lda below runs instead of zero cycles. This closed one source of
// glitching but not all of it -- watched against the U64's own USB-to-1351
// converter, turning still snaps hard partway through a slow, steady sweep,
// so something (most likely the converter's own internal counter, not this
// code's frame timing) occasionally hands back a POTX sample that is not a
// small step from the last one.
//
// The delta is an 8-bit wraparound subtract against last frame's raw
// sample -- exact as long as one frame's motion stays under ~128 units of
// POTX, same assumption §11c made. Subtracting new from old (not old from
// new) is what makes turning right (mouse moves right, POTX rises) rotate
// camA the way TURN_SPEED's own D-key path does.
//
// Glitch guard: a real one-frame mouse motion, even a fast flick, does not
// swing POTX by more than about half its range -- the observed jump does.
// So any |delta| >= 64 is treated as a bad sample and dropped (zeroed)
// rather than applied. delta+64, as an unsigned add with the overflow left
// to fall where it lands, is >=$80 exactly when delta was >=64 or <-64 (the
// two halves of "large" wrap to meet at $80 from opposite sides) and <$80
// for every delta in between -- so testing bit 7 of that sum after the add
// is the whole check, no second compare needed. X holds the pre-add delta
// so the small/valid path can recover it with a plain txa instead of a
// zero-page round trip.
//------------------------------------------------------------
mouseTurn:
        ldy $d419                    // this frame's raw POTX
        lda zMousePX                 // last frame's raw POTX
        sec
        sty zMousePX                 // stash this frame's for next time --
        sbc zMousePX                 // old - new: wraparound delta, sign
                                     // flipped from a plain new - old
        tax                          // hold the real delta across the test
        clc
        adc #64                      // bit 7 of delta+64 <=> |delta| >= 64
        bpl !small+
        lda #0                       // bad sample: this frame contributes 0
        beq !shift+
!small: txa                          // restore the real delta
!shift: .for (var i = 0; i < MOUSE_SHIFT; i++) {   // sign-extending shift right
        cmp #$80
        ror
        }
        clc
        adc camA                     // camA wraps the same way TURN_SPEED does
        sta camA
        jmp setEyeZ

.print "SPRCODE3 end = " + toHexString(*) + "  SPRIMG = " + toHexString(SPRIMG) + "  overflow by " + (*-SPRIMG) + " bytes"
.errorif * > SPRIMG, "sprite draw setup overflows SPRCODE3 into SPRIMG"

.pc = SPRCODE "sprite sort + draw"

//------------------------------------------------------------
// sprFrame — draws every entry sprPick found this frame, farthest
// first, then resets sprVisN for the next one and chains into
// wpnFrame (mainLoop's jsr renderFrame falls all the way through:
// bspDone -> sprFrame -> wpnFrame -> rts, zero extra jsr/rts pairs --
// see main.asm and bsp.asm's bspDone).
//------------------------------------------------------------
sprFrame:
        lda sprVisN
        beq !done+
        jsr sprSort
        lda #0
        sta sprI
!loop:  ldx sprI
        ldy sprVisPerm,x
        lda sprVisIdx,y
        sta sprIdx
        lda sprVisRXlo,y
        sta zRXt
        lda sprVisRXhi,y
        sta zRXt+1
        lda sprVisRYlo,y
        sta zRYt
        lda sprVisRYhi,y
        sta zRYt+1
        lda sprVisDZlo,y
        sta zNum
        lda sprVisDZhi,y
        sta zNum+1
        ldx sprIdx
        lda thingType,x
        sta sprType
        jsr sprDraw
        inc sprI
        lda sprI
        cmp sprVisN
        bne !loop-
!done:  lda #0
        sta sprVisN                  // reset for next frame's sprPick
        jmp wpnFrame                  // §12: draw order, zero-byte-cost -- see
                                     // mainLoop's jsr renderFrame (main.asm)

//------------------------------------------------------------
// sprDraw — one visible thing. Entry: zRXt = rx, zRYt = ry (both
// signed 16, camera space), zNum = dz (eye-relative floor Z, signed
// 16), sprType/sprIdx already set. Every zero-page name used below
// that is not one of the persistent spr* fields is renderer scratch
// (zA/zB/zP/zD/zV/zSign/zT/zTx/zTy/zRad/zNum/zRXt/zRYt), dead between
// renderFrame returning and wpnFrame starting -- see defs.asm.
//------------------------------------------------------------
sprDraw:
        // ---- ry_used = max(ry, SPR_NEAR); qd = clamp(ry_used>>4,1,255) - SPR_BIAS ----
        lda zRYt+1
        bne !near+
        lda zRYt
        cmp #SPR_NEAR
        bcs !near+
        lda #SPR_NEAR
        sta zRYt
        lda #0
        sta zRYt+1
!near:
        lda zRYt
        sta zA
        lda zRYt+1
        sta zA+1
        lsr zA+1
        ror zA
        lsr zA+1
        ror zA
        lsr zA+1
        ror zA
        lsr zA+1
        ror zA                       // zA = ry_used >> 4
        lda zA+1
        beq !q1+
        lda #255
        jmp !qgot+
!q1:    lda zA
        bne !qgot+
        lda #1                       // floor at 1
!qgot:  sec
        sbc #SPR_BIAS                // ties favour the sprite (defs.asm)
        sta sprQ

        // ---- R1u (floor/bottom row) = projRow(dz_floor, ry_used) -> zTy ----
        lda zNum
        sta zA
        lda zNum+1
        sta zA+1
        lda zRYt
        sta zV
        lda zRYt+1
        sta zV+1
        jsr projRow
        sta zTy
        sty zTy+1

        // ---- R0u (top row) = R1u - world_height*VFOCAL/ry_used. row(dz) is
        // linear in dz, so this is exact and needs no second projRow/divide
        // (Opus-advised, §12 sizing pass) ----
        ldx sprType
        lda sprTypWH,x
        sta zA
        lda #0
        sta zA+1
        lda #<VFOCAL
        jsr sprScale                 // zD = world_height * VFOCAL / ry_used
        lda zTy
        sec
        sbc zD
        sta zRad
        lda zTy+1
        sbc zD+1
        sta zRad+1

        // ---- reject if the box misses any screen edge (no partial
        // clipping): top<=bottom always, so checking bottom's far side
        // covers the case where top alone is already past it too ----
        lda zRad+1
        bmi !reject+                  // top < 0
        bne !reject+                  // top >= 256
        lda zTy+1
        bne !reject+                  // bottom >= 256
        lda zTy
        cmp #VIEWROWS
        bcs !reject+                  // bottom >= VIEWROWS

        jmp sprDrawX                  // the X half, in SPRCODE3 -- SPRCODE has
                                      // no room for both (Opus-advised, §12
                                      // sizing pass). Its own rts returns
                                      // straight to sprFrame, same as ours.
!reject:
        rts

//------------------------------------------------------------
// sprAdvU — one column's worth of sprBlit's u accumulator: step it, and
// walk sprSrc forward by sprH (the art's column stride) once per integer
// column crossed. Pulled out of sprBlit purely for code-size packing --
// SPRCODE2 had no bytes left for it (Opus-advised, §12 sizing pass).
//------------------------------------------------------------
sprAdvU:
        lda sprUAcc+1
        sta zSign                    // old integer column (zSign: sort's outer
                                     // index, long dead by now)
        lda sprUAcc
        clc
        adc sprUStep
        sta sprUAcc
        lda sprUAcc+1
        adc sprUStep+1
        sta sprUAcc+1
!advSrc:
        cmp zSign
        beq !advDone+
        pha
        lda sprSrc
        clc
        adc sprH
        sta sprSrc
        bcc !+
        inc sprSrc+1
!:      inc zSign
        pla
        jmp !advSrc-
!advDone:
        rts

.errorif * > SPRCODE + 256, "sprite sort/draw overflows SPRCODE"

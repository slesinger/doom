//============================================================
//  bsp.asm — BSP traversal, subsector streaming, point lookup
//
//  This replaces the portal walker. The engine descends the WAD's
//  own NODES front-to-back from the camera, exactly as Doom does,
//  and the only occlusion state is the per-column window
//  colTop/colBot plus openCols, the count of columns still open.
//  A subsector is convex, so at most one of its segs is front
//  facing in any given column and the segs inside one subsector
//  need no depth sort among themselves.
//
//  Three things are worth knowing before changing this file.
//
//  1. Banking. The node and sector tables live under the I/O space
//     ($D000 and $DC00), so every read of them is bracketed by
//     $01 = BANK_RAM / BANK_IO (docs/reu-format.md §6.1). REU
//     transfers need I/O banked *in*, so the two windows must never
//     overlap -- and they don't: a subsector's segs are fetched
//     first, then its sector heights are read. This is only safe
//     because interrupts are masked for the whole run.
//
//  2. Node bounding boxes are not carried (docs/reu-format.md §4.2),
//     so nothing is rejected before it is visited. What keeps the
//     frame affordable is that the walk is front-to-back and stops
//     dead when openCols hits zero, which in a corridor happens a
//     few subsectors in. That is the whole culling strategy;
//     IMPLEMENTATION_PLAN.md risk #3 is the fallback if it is not
//     enough on real geometry.
//
//  3. There is no visplane machinery. A subsector's floor and
//     ceiling are filled per seg, over that seg's own columns only.
//     Where a subsector's boundary runs along a BSP partition line
//     there is no seg, so those columns are filled by whichever
//     neighbouring subsector does own a seg there. That is the
//     accuracy this trades for speed: it costs a column of flat
//     colour at some silhouettes, and it saves the whole visplane
//     pass, which on a byte-per-pixel buffer is not affordable.
//============================================================

.pc = BSPCODE "bsp traversal"

//------------------------------------------------------------
// renderFrame — one frame of E1M1 into MATRIX.
//------------------------------------------------------------
renderFrame:
        // Open all column windows. NOTE: 160 columns means X ranges
        // 159..0, and 128..159 all have bit 7 set -- a bpl-terminated
        // countdown from #159 stops after one iteration. Count 160..1
        // and test with cpx/bne, which doesn't care about the sign bit.
        ldx #160
        lda #0
!:      dex
        sta colTop,x
        cpx #0
        bne !-
        ldx #160
        lda #176
!:      dex
        sta colBot,x
        cpx #0
        bne !-
        lda #160
        sta openCols
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
        lda #0
        sta stackN
        lda miRoot                  // start at the root child word
        sta zChild
        lda miRoot+1
        sta zChild+1

//  The descent. Interior node: visit the near child now and push the
//  far one. Leaf: render it, then pop. Nothing is ever visited twice,
//  so no visited-flag array survives from the portal walker.
bspLoop:
        lda zChild+1
        bmi bspLeaf                 // bit 15 set -> subsector index
        ldx zChild                  // node index; numNodes <= MAXNODES
        jsr nodeStep                // zChild = near child, zFar = far
        ldx stackN
        cpx #BSPSTKMAX
        bcs bspLoop                 // stack full: drop the far subtree
        lda zFar
        sta bspStkLo,x
        lda zFar+1
        sta bspStkHi,x
        inc stackN
        jmp bspLoop
bspLeaf:
        and #$7f                    // A still holds the high byte
        sta zChild+1
        jsr renderSsec
        lda openCols
        beq bspDone                 // every column closed: frame is finished
        lda stackN
        beq bspDone
        dec stackN
        ldx stackN
        lda bspStkLo,x
        sta zChild
        lda bspStkHi,x
        sta zChild+1
        jmp bspLoop
bspDone:
        rts

//------------------------------------------------------------
// renderSsec — draw the subsector whose index is in zChild.
//------------------------------------------------------------
renderSsec:
        jsr ssecFetch               // -> zSegCnt, zSecId, SEGBUF
        lda zSegCnt
        beq !rts+                   // a leaf with nothing to draw is legal
        ldy zSecId
        jsr secFront
        lda #0
        sta zWIdx                   // seg cursor: a byte offset, not an index
        lda zSegCnt
        sta zWCnt
!segs:  ldx zWIdx
        jsr doWall
        lda openCols
        beq !rts+
        lda zWIdx
        clc
        adc #SEGSZ
        sta zWIdx
        dec zWCnt
        bne !segs-
!rts:   rts

//------------------------------------------------------------
// ssecFetch — stream subsector zChild's slot out of the REU.
//
// Slot address is ssecReuBase + (index << 7): one shift, no
// multiply, no offset table (docs/reu-format.md §5). Two transfers,
// because the second one's length is what the first one reports --
// at E1M1's 3.09 segs per subsector that is 2 + 31 bytes instead of
// a fixed 122, and every byte transferred halts the CPU for a
// microsecond.
//
// -> zSegCnt, zSecId, SEGBUF. Requires I/O banked in.
//------------------------------------------------------------
ssecFetch:
        lda #0                      // zD = index << 7 = (index << 8) >> 1
        sta zD
        lda zChild
        sta zD+1
        lda zChild+1
        sta zD+2
        lsr zD+2
        ror zD+1
        ror zD+0
        lda zD                      // += ssecReuBase, 24-bit
        clc
        adc miSsecBase
        sta zD
        sta REU_REUADDR
        lda zD+1
        adc miSsecBase+1
        sta zD+1
        sta REU_REUADDR+1
        lda zD+2
        adc miSsecBase+2
        sta zD+2
        sta REU_BANK
        lda #<SSECHDR
        sta REU_C64ADDR
        lda #>SSECHDR
        sta REU_C64ADDR+1
        lda #2
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        lda SSECHDR+1
        sta zSecId
        lda SSECHDR+0
        sta zSegCnt
        beq !rts+
        cmp #13                     // the slot holds at most 12 segs; clamp
        bcc !+                      // rather than let a bad image overrun
        lda #12                     // SEGBUF and the tables past it
        sta zSegCnt
!:      asl                         // length = segCount * 10
        sta zT
        asl
        asl
        clc
        adc zT
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda zD                      // the segs start two bytes into the slot
        clc
        adc #2
        sta REU_REUADDR
        lda zD+1
        adc #0
        sta REU_REUADDR+1
        lda zD+2
        adc #0
        sta REU_BANK
        lda #<SEGBUF
        sta REU_C64ADDR
        lda #>SEGBUF
        sta REU_C64ADDR+1
        lda #REU_FETCH
        sta REU_COMMAND
!rts:   rts

//------------------------------------------------------------
// secFront — Y = sector id -> the front sector's ceiling and floor
// as offsets from the eye, plus their shading bytes.
//------------------------------------------------------------
secFront:
        lda #BANK_RAM
        sta $01
        lda mapSecCeilLo,y
        sec
        sbc camZ
        sta zDzC
        lda mapSecCeilHi,y
        sbc camZ+1
        sta zDzC+1
        lda mapSecFloorLo,y
        sec
        sbc camZ
        sta zDzF
        lda mapSecFloorHi,y
        sbc camZ+1
        sta zDzF+1
        lda mapSecCByte,y
        sta zCeilByte
        lda mapSecFByte,y
        sta zFloorByte
        lda #BANK_IO
        sta $01
        rts

//------------------------------------------------------------
// secBack — Y = sector id -> zBackC / zBackF, also eye-relative.
//------------------------------------------------------------
secBack:
        lda #BANK_RAM
        sta $01
        lda mapSecCeilLo,y
        sec
        sbc camZ
        sta zBackC
        lda mapSecCeilHi,y
        sbc camZ+1
        sta zBackC+1
        lda mapSecFloorLo,y
        sec
        sbc camZ
        sta zBackF
        lda mapSecFloorHi,y
        sbc camZ+1
        sta zBackF+1
        lda #BANK_IO
        sta $01
        rts

//------------------------------------------------------------
// setEyeZ — eye height follows camSec's floor.
//------------------------------------------------------------
setEyeZ:
        ldy camSec
        lda #BANK_RAM
        sta $01
        lda mapSecFloorLo,y
        clc
        adc #EYE
        sta camZ
        lda mapSecFloorHi,y
        adc #0
        sta camZ+1
        lda #BANK_IO
        sta $01
        rts

.errorif * > $d000, "bsp traversal overflows into I/O"

//------------------------------------------------------------
//  Second piece: the node test and the descent that uses it on
//  its own, below MATRIX. Split from the block above only because
//  the free RAM is.
//------------------------------------------------------------
.pc = BSPCODE2 "bsp node test"

//------------------------------------------------------------
// nodeStep — X = node index. Picks the near child into zChild and
// leaves the far one in zFar. Banks the node table in for the whole
// test, so sideOf's arithmetic runs with $D000 as RAM.
//------------------------------------------------------------
nodeStep:
        lda #BANK_RAM
        sta $01
        jsr sideOf
        beq !front+
        lda ndLeftLo,x              // camera is behind: near = left child
        sta zChild
        lda ndLeftHi,x
        sta zChild+1
        lda ndRightLo,x
        sta zFar
        lda ndRightHi,x
        sta zFar+1
        jmp !done+
!front: lda ndRightLo,x             // camera is in front: near = right child
        sta zChild
        lda ndRightHi,x
        sta zChild+1
        lda ndLeftLo,x
        sta zFar
        lda ndLeftHi,x
        sta zFar+1
!done:  lda #BANK_IO
        sta $01
        rts

//------------------------------------------------------------
// sideOf — which side of node X's partition line is the camera on?
//   A = 0 (Z set) -> right/front child,  A = 1 -> left/back child
//
// This is Doom's R_PointOnSide and the same cross product the old
// checkSector computed, with the wall delta swapped for the node
// delta (docs/reu-format.md §4.2, tools/wad2reu.py point_on_side):
//
//   cross = dx*(py - y0) - dy*(px - x0);   cross < 0 -> front
//
// Getting this sign backwards mirrors the world, which is why the
// image carries a precomputed spawn subsector for main.asm to check
// the first descent against.
//
// The two axis-aligned cases are not an optimisation of the general
// one, they are the same predicate with a factor known to be zero --
// and most of E1M1's partitions are axis aligned, so they carry the
// traversal and the 32-bit multiply pair is the minority path.
//
// Must be entered with BANK_RAM already in. X is preserved.
//------------------------------------------------------------
sideFront:
        ldx zNodeI                  // ldx sets Z, so load the result last
        lda #0
        rts
sideBack:
        ldx zNodeI
        lda #1
        rts

sideOf:
        stx zNodeI
        lda camX                    // pdx = px - x0
        sec
        sbc ndPxLo,x
        sta zTx
        lda camX+1
        sbc ndPxHi,x
        sta zTx+1
        lda camY                    // pdy = py - y0
        sec
        sbc ndPyLo,x
        sta zTy
        lda camY+1
        sbc ndPyHi,x
        sta zTy+1

        // ---- vertical partition (dx == 0): cross = -dy*pdx
        // pdx <= 0 -> side = (dy > 0); pdx > 0 -> side = (dy < 0)
        lda ndDxLo,x
        ora ndDxHi,x
        bne !notVert+
        lda zTx+1
        bmi !le+
        ora zTx
        beq !le+
        lda ndDyHi,x                // pdx > 0
        bmi sideBack                // dy < 0
        bpl sideFront
!le:    lda ndDyHi,x                // pdx <= 0
        bmi sideFront               // dy < 0
        ora ndDyLo,x
        beq sideFront               // dy == 0 -- a degenerate node
        bne sideBack                // dy > 0

        // ---- horizontal partition (dy == 0): cross = dx*pdy
        // pdy <= 0 -> side = (dx < 0); pdy > 0 -> side = (dx > 0)
!notVert:
        lda ndDyLo,x
        ora ndDyHi,x
        bne !gen+
        lda zTy+1
        bmi !le+
        ora zTy
        beq !le+
        lda ndDxHi,x                // pdy > 0
        bmi sideFront               // dx < 0
        bpl sideBack
!le:    lda ndDxHi,x                // pdy <= 0
        bmi sideBack                // dx < 0
        bpl sideFront

        // ---- general case: cross = dx*pdy - dy*pdx, sign only
!gen:   lda ndDxLo,x
        sta zA
        lda ndDxHi,x
        sta zA+1
        lda zTy
        sta zB
        lda zTy+1
        sta zB+1
        jsr ssmul32
        lda zP+0                    // park dx*pdy in doWall's line endpoints
        sta zTop0
        lda zP+1
        sta zTop0+1
        lda zP+2
        sta zTop0+2
        lda zP+3
        sta zTop0+3
        ldx zNodeI
        lda ndDyLo,x
        sta zA
        lda ndDyHi,x
        sta zA+1
        lda zTx
        sta zB
        lda zTx+1
        sta zB+1
        jsr ssmul32
        lda zTop0
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
!:      bmi !front+                 // too far from sideFront/sideBack for a
        jmp sideBack                // relative branch to reach
!front: jmp sideFront

//------------------------------------------------------------
// bspFindSsec — descend to the subsector containing (camX, camY),
// leaving its index in zChild. This is what replaces checkSector's
// convex containment walk: sector lookup is now a property of the
// tree rather than of the sector the player was in last frame.
//
// Capped at 64 descents. A child index that pointed back up the
// tree would otherwise hang the machine with nothing on screen to
// say why; falling back to subsector 0 renders wrongly, which is
// visible.
//------------------------------------------------------------
bspFindSsec:
        lda miRoot
        sta zChild
        lda miRoot+1
        sta zChild+1
        lda #64
        sta zWCnt                   // nodeStep clobbers X and Y
!:      lda zChild+1
        bmi !done+
        ldx zChild
        jsr nodeStep
        dec zWCnt
        bne !-
        lda #0
        sta zChild
        sta zChild+1
        rts
!done:  and #$7f
        sta zChild+1
        rts

.errorif * > TABLES_FREE_END+1, "bsp node test overflows past TABLES_FREE"

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
//  2. Culling happens in three places, cheapest first. A node's
//     bounding sphere and a subsector's are tested against the view
//     frustum before either is descended into or has its segs
//     fetched (sphereVisible, below); a seg that survives that is
//     backface-tested in world space before any projection
//     (segFacing, walls.asm); and the walk stops dead when openCols
//     hits zero, which in a corridor happens a few subsectors in.
//     Only the last of those is required for correctness -- the two
//     rejections are conservative, so switching either off changes
//     the frame time and not a single pixel.
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
        //
        // One loop for both windows now, where it used to be two. colBot is
        // seeded from a *table* rather than from VIEWROWS, so the weapon view
        // can seal the columns it covers before a single wall is drawn
        // (wpnPrep, §12a) -- with no weapon loaded every entry is VIEWROWS and
        // this is the old constant seed. Merging the loops is what paid for
        // the extra load: this block had no bytes left at all.
        ldx #160
!:      dex
        lda #0
        sta colTop,x
        lda colBotSeed,x
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
        :Count(CNT_NODE)            // before the ldx: Count clobbers X
        ldx zChild                  // node index; numNodes <= MAXNODES
        jsr nodeSphere              // fetch this subtree's bounding sphere and
        bcs !visible+               // test it -- nodeSphere ends in sphereVisible
        :Count(CNT_NODEREJ)
        jmp bspPop                  // outside the frustum: skip the whole subtree
!visible:
        ldx zChild
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
bspPop:
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
        jmp sprFrame                 // §12: draw order, zero-byte-cost -- see
                                     // mainLoop's jsr renderFrame (main.asm)

//------------------------------------------------------------
// renderSsec — draw the subsector whose index is in zChild.
//------------------------------------------------------------
renderSsec:
        jsr ssecHdr                 // -> zSegCnt, zSecId, the slot's sphere
        lda zSegCnt
        beq !rts+                   // a leaf with nothing to draw is legal
        jsr sphereVisible           // ... and one outside the view is drawn
        bcs !visible+               // without its segs ever being fetched
        :Count(CNT_SSECREJ)
        rts
!visible:
        jsr ssecSegs                // -> SEGBUF
        :Count(CNT_SSEC)
        ldy zSecId
        jsr secFront
        jsr sprPick                  // §12: this subsector's static props,
                                     // while zDzF/zDzC are still this sector's
        lda #0
        sta zWIdx                   // seg cursor: a byte offset, not an index
        lda zSegCnt
        sta zWCnt
!segs:  :Count(CNT_SEG)             // counted here, not at doWall's entry:
        ldx zWIdx                   // that block has 19 bytes of headroom
        jsr segFacing               // one cross product; skips ~2/3 of the
        ldx zWIdx                   // segs before any projection -- walls.asm.
        bcs !draw+                  // It runs through mul8, so X is gone and
                                    // doWall needs it back. ldx spares carry.
        :Count(CNT_SEGFACE)
        jmp !next+                  // a skipped seg closes nothing, so
!draw:  jsr doWall                  // openCols cannot have changed
        lda openCols
        beq !rts+
!next:
        lda zWIdx
        clc
        adc #SEGSZ
        sta zWIdx
        dec zWCnt
        bne !segs-
!rts:   rts

//------------------------------------------------------------
// ssecHdr — stream subsector zChild's slot header out of the REU.
//
// Slot address is ssecReuBase + (index << 7): one shift, no
// multiply, no offset table (docs/reu-format.md §5). It is left in
// zD for ssecSegs, which is the second half of this and reads it.
//
// Two transfers, because the second one's length is what the first
// one reports -- at E1M1's 3.09 segs per subsector that is 8 + 31
// bytes instead of a fixed 128, and every byte transferred halts
// the CPU for a microsecond regardless of the CPU's clock. Since
// the header grew to carry the slot's bounding sphere the split
// buys more than that: a subsector outside the view never reaches
// the second transfer at all.
//
// -> zSegCnt, zSecId, sphCX/sphCY/sphR. Requires I/O banked in.
//------------------------------------------------------------
ssecHdr:
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
        lda #SSECHDRSZ
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
        bcc !rts+                   // rather than let a bad image overrun
        lda #12                     // SEGBUF and the tables past it
        sta zSegCnt
!rts:   rts

//------------------------------------------------------------
// ssecSegs — the second transfer: zSegCnt segs from the slot whose
// base ssecHdr left in zD, into SEGBUF. Requires I/O banked in.
//------------------------------------------------------------
ssecSegs:
        lda zSegCnt
        asl                         // length = segCount * 10
        sta zT
        asl
        asl
        clc
        adc zT
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda zD                      // the segs follow the slot header
        clc
        adc #SSECHDRSZ
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
        rts

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
// setEyeZ — eye height follows camSec's floor, plus the jump arc.
//
// camJZ is 0 for every frame the player is on the floor, so this is the M2
// formula with two more bytes in it (src/input.asm). The first add cannot
// carry -- EYE + JUMPPEAK is 69 -- so the sum reaches the floor's low byte
// with the carry the 16-bit add needs.
//------------------------------------------------------------
setEyeZ:
        ldy camSec
        lda #BANK_RAM
        sta $01
        lda camJZ
        clc
        adc #EYE
        adc mapSecFloorLo,y
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

//============================================================
//  The bounding-sphere visibility test.
//
//  wad2reu.py gives every node and every subsector a sphere that
//  contains all the geometry below it (docs/reu-format.md §4.3).
//  Rejecting one against the view frustum costs a transformPoint
//  and three compares, and it removes a whole subtree -- or a
//  subsector's seg fetch -- from the frame.
//
//  The test is deliberately the *box* test, not the sphere test.
//  The exact one wants the distance from the centre to each frustum
//  plane, and at 90 degrees those planes are rx = +/-ry, whose
//  normals carry a 1/sqrt(2). Treating the sphere as the axis-
//  aligned camera-space box [rx-r, rx+r] x [ry-r, ry+r] needs no
//  such factor: the box contains the sphere, so the test stays
//  conservative, and every compare is a 16-bit add and a subtract.
//  It keeps a band of about 41% of r beyond each frustum edge, and
//  a sphere is already a loose bound on a subtree, so the exact
//  version would be paying multiplies for a fraction of a fraction.
//
//  Nothing here may reject something visible. If it does, geometry
//  disappears -- which is why `make check`'s screenshot comparison
//  against a build without it is the test that matters.
//
//  It lands in three pieces because the free RAM below MATRIX is in
//  two pieces (SPHCODE/SPHCODE3 in defs.asm), each with
//  its own .errorif.
//============================================================

//------------------------------------------------------------
// sphereVisible — is the sphere in sphCX/sphCY/sphR inside the view
// frustum?
//   carry set   -> possibly visible, go on
//   carry clear -> certainly outside, reject
//
// The centre goes through the same transformPoint doWall uses for
// seg endpoints, so "camera space" means exactly what it means
// there: zRYt forward, zRXt rightward.
//
// A cheaper transform was tried here and measured *slower* -- see
// IMPLEMENTATION_PLAN.md §15. The short version: this call is 153 of the
// frame's 326 transformPoints and an 8x8 version of it does save about
// 680 cycles a call, but a coarse transform has to inflate the radius to
// stay conservative, and the frame turns out to be far more sensitive to
// a sphere's radius than to what the transform costs. 128 units of slop
// cost 6.7% of the frame; the transform saved 4.4%. Accuracy here is
// worth more than speed, which is not where the cost model said to look.
//
// Clobbers A, X, Y and everything transformPoint does (zA, zB, zP,
// zT, zSign, zTx, zTy, zRXt, zRYt). Callers reload X.
//------------------------------------------------------------
.pc = SPHCODE "sphere test: transform"

sphereVisible:
        lda sphCX
        sec
        sbc camX
        sta zTx
        lda sphCX+1
        sbc camX+1
        sta zTx+1
        lda sphCY
        sec
        sbc camY
        sta zTy
        lda sphCY+1
        sbc camY+1
        sta zTy+1
        lda sphR
        sta zRad
        lda sphR+1
        sta zRad+1
        jsr transformPoint          // -> zRXt, zRYt  (walls.asm)
        jmp sphereTest

//------------------------------------------------------------
//  The compares themselves, in the same block: sphereVisible falls
//  straight into them and nothing else calls them.
//------------------------------------------------------------
//------------------------------------------------------------
// sphereTest — the sphere at (zRXt, zRYt) of radius zRad against the
// three frustum planes.
//
//   ry + r      <  0   -> wholly behind the camera
//   rx - ry     >= k   -> wholly right of the plane rx = ry
//   rx + ry + k <  0   -> wholly left of the plane rx = -ry
//
// where k = r + (r >> 1) = 1.5r.
//
// THE 1.5 IS THE POINT. This used to treat the sphere as the axis-
// aligned box [rx +/- r] x [ry +/- r], which makes the side tests
// `ry + r < rx - r`, i.e. `rx - ry >= 2r`. The box contains the
// sphere, so that was conservative -- but loose by 0.59r on both side
// planes, because the exact distance from the centre to a 45-degree
// plane is (rx -+ ry)/sqrt(2), and a sphere clears it at sqrt(2)*r
// rather than at 2r.
//
// 1.5 >= sqrt(2) = 1.41421, so the test still never rejects anything
// visible -- and 1.5r is r plus one shift, where the exact constant
// would want a multiply. The margin recovered is half a radius on two
// of the three planes, and IMPLEMENTATION_PLAN.md §15 measured what a
// sphere's radius is worth: 128 units of slop on E1M1's spheres cost
// 6.7% of the frame. This is that lever pulled the other way.
//
// The plane at ry = 0 is exact already: a sphere is behind the eye
// exactly when ry < -r. It is tested first and unchanged.
//
// The intermediate sums are 16-bit signed. They hold because the
// camera-relative coordinates transformPoint produces are bounded
// by the map's own extent (E1M1 fits in about 6000 units) and the
// largest sphere wad2reu.py will emit has radius 8000 -- the packer
// raises rather than write one larger. Worst case here is
// |rx| + |ry| + 1.5r = 6000 + 6000 + 12000, inside a signed 16.
//------------------------------------------------------------
sphereTest:
        lda zRYt                    // ry + r < 0: entirely behind the eye
        clc
        adc zRad
        lda zRYt+1
        adc zRad+1
        bmi !reject+
        lda zRad+1                  // zA = k = r + (r >> 1)
        lsr
        sta zA+1
        lda zRad
        ror
        clc
        adc zRad
        sta zA
        lda zA+1
        adc zRad+1
        sta zA+1
        lda zRXt                    // zT = rx - ry
        sec
        sbc zRYt
        sta zT
        lda zRXt+1
        sbc zRYt+1
        sta zT+1
        lda zT                      // rx - ry >= k -> off the right edge
        cmp zA
        lda zT+1
        sbc zA+1
        bvc !+
        eor #$80
!:      bpl !reject+
        lda zRXt                    // zT = rx + ry
        clc
        adc zRYt
        sta zT
        lda zRXt+1
        adc zRYt+1
        sta zT+1
        lda zT                      // rx + ry + k < 0 -> off the left edge
        clc
        adc zA
        lda zT+1
        adc zA+1
        bmi !reject+
        sec
        rts
!reject:
        clc
        rts

.errorif * > UDIV8, "the sphere test overflows into udiv's short path"

//------------------------------------------------------------
//  Third piece: the per-node fetch.
//------------------------------------------------------------
.pc = SPHCODE3 "sphere test: node fetch"

//------------------------------------------------------------
// nodeSphere — X = node index. DMAs that node's sphere record out
// of block 4 into NODESPH, which is the same six bytes the
// subsector slot header's sphere occupies, and falls straight
// through into sphereVisible: the two are never wanted apart, and
// chaining them keeps three bytes out of the traversal segment,
// which is the one with no room left.
//   carry set -> possibly visible,  carry clear -> reject
//
// The record's stride is 8 and not 6 for exactly one reason: it
// makes the offset three shifts instead of a multiply. Six bytes
// of every eight are used and 480 of block 4's 1920 are padding,
// which costs nothing -- the block is streamed, never resident.
//
// Requires I/O banked in.
//------------------------------------------------------------
nodeSphere:
        txa                         // reu addr = miSphBase + (index << 3)
        asl
        asl
        asl
        clc
        adc miSphBase
        sta REU_REUADDR
        php                         // the lsr chain below eats the carry
        txa
        lsr                         // index >> 5 = the high byte of index*8
        lsr
        lsr
        lsr
        lsr
        plp
        adc miSphBase+1
        sta REU_REUADDR+1
        lda #0
        adc miSphBase+2
        sta REU_BANK
        lda #<NODESPH
        sta REU_C64ADDR
        lda #>NODESPH
        sta REU_C64ADDR+1
        lda #NODESPHSZ
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        jmp sphereVisible

.errorif * > SSECHDR, "the node sphere fetch overflows into SSECHDR"

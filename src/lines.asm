//============================================================
//  lines.asm — doors, lifts and moving floors (IMPLEMENTATION_PLAN.md §11)
//
//  THE RENDERER IS NOT INVOLVED. A door is a sector whose ceiling height
//  changes; doWall reads sector heights out of SECTAB every frame and draws
//  the upper step against them, and checkMove reads the same two words for its
//  step and headroom tests. So this file writes two bytes in SECTAB and the
//  door opens, renders, and stops blocking. Nothing in render/ has to know --
//  the bounding spheres are 2D and a sector moves in z.
//
//  WHERE IT ALL RUNS
//
//  In the RAM under the I/O space, with $01 = BANK_RAM. Not for want of
//  anywhere else so much as because that is where the data is: SECTAB is at
//  $DC00 and only exists in that banking state, so every routine here had to
//  bank anyway (defs.asm, LINECODE/LINECODE2/LINECODE3). It is also the only
//  RAM left -- tex.asm took the low holes down to a few bytes each, and these
//  640 bytes were the largest free block in the machine.
//
//  Two things follow from that and are easy to get wrong:
//
//  1. The window is `sei`'d, not merely survived. With I/O banked out the
//     music IRQ writes its SID registers into the RAM underneath them,
//     silently. The CIA latch keeps running below the window, so the tick is
//     late by a few hundred cycles rather than lost.
//  2. Nothing in here may touch the REU, because unbanking to reach it would
//     make this code itself disappear from under the program counter. The one
//     transfer the use path needs -- the player's own segs -- happens in
//     lineTramp, before the bank switch.
//
//  ACTIVATION IS BY SECTOR (IMPLEMENTATION_PLAN.md §11.2a)
//
//  Doom asks whether the player's motion crossed the line. That is four cross
//  products per line and ~660 bytes of code, against the 640 this phase has
//  for everything, so the question asked here is a sector one instead:
//
//    use key    a seg of the player's own subsector has a door sector behind
//               it, and the seg faces the player
//    walkover   the player's sector became the line's trigger sector
//
//  Both are looser than Doom at the edges -- a trigger fires on entering the
//  sector rather than on crossing the line -- and both are exact enough for
//  E1M1's eleven special lines. The geometric test is M3's, alongside §12.1's
//  per-seg opening list, which is deferred for the same reason.
//============================================================

//------------------------------------------------------------
.pc = LINETRAMP "lines: the trampoline"
//------------------------------------------------------------
// lineFrame — the only part of the doors feature that runs in ordinary RAM,
// and the reason it has to: everything past the bank switch runs with I/O
// banked out, so two things must happen on this side of it.
//
//   - the REU transfer. lnUse walks the player's own segs, and fetching them
//     needs $df01, which does not exist once the bank flips (lineSegs, below).
//   - the `sei`. With I/O banked out the music IRQ would write its SID
//     registers into the RAM under them and the tune would carry on silently
//     wrong. The window is a few hundred cycles; the CIA latch runs underneath
//     it, so the tick is late rather than lost.
//
// The fetch runs while the key is *held*, not on the press: the edge is tested
// by lineTick, on the other side of the switch, because there is no room for
// it here. That costs two DMAs a frame for as long as the key is down, which
// is what checkMove already spends every frame regardless.
//
// Twenty-three bytes, and they are not in the main segment because that
// segment has one spare byte -- see LINETRAMP in defs.asm for what these two
// fragments are wedged into.
//------------------------------------------------------------
lineFrame:
        lda zInput
        and #IN_USE
        beq !+
        jsr lineSegs
!:      sei
        lda #BANK_RAM
        sta $01
        jsr lineTick
        lda #BANK_IO
        sta $01
        cli
        rts

.errorif * > SCREEN1 + $400, "lineFrame overflows past SCREEN1"

//------------------------------------------------------------
.pc = LINESEGS "lines: the use fetch"
//------------------------------------------------------------
// lineSegs — the player's own subsector into SEGBUF, for lnUse to walk.
//------------------------------------------------------------
lineSegs:
        lda camSsec
        sta zChild
        lda camSsec+1
        sta zChild+1
        jsr ssecHdr
        jmp ssecSegs

.errorif * > BSPCODE, "the use fetch overflows into the BSP walk"

//------------------------------------------------------------
.pc = BOOTCODE5 "boot: doors code relocator"
//------------------------------------------------------------
// The three blocks below run under I/O and so cannot be in the PRG image at
// all: the image is one span from $0801 to its highest byte, so a block at
// $dbd0 would extend it over $d000-$dfff and make *loading* it a 4 KB write
// across the I/O space -- harmless under VICE's RAM injection, and untested on
// the Ultimate's DMA path (defs.asm, above MUSCODE). So they are assembled
// here in MATRIX with .pseudopc at their run addresses and copied down at
// boot, the same way tex.asm reaches the RAM below $0801 and music.asm reaches
// $ff40. `make check` compares all three against the PRG (probe.py).
//
// lineBoot leaves the banking as it found it, and is called inside the boot
// `sei` -- see main.asm.
//------------------------------------------------------------
lineBoot:
        lda #BANK_RAM
        sta $01
        ldx #0
!:      lda lnThinkSrc,x
        sta LINECODE,x
        inx
        cpx #lnThinkEnd-lnThinkSrc
        bne !-
        ldx #0
!:      lda lnStepSrc,x
        sta LINECODE2,x
        inx
        cpx #lnStepEnd-lnStepSrc
        bne !-
        ldx #0
!:      lda lnActSrc,x
        sta LINECODE3,x
        inx
        cpx #lnActEnd-lnActSrc
        bne !-
        lda #BANK_IO
        sta $01
        rts

// The copy loops count in one byte, so a block of exactly 256 would copy none
// of itself. The activation block is within a byte or two of that.
.errorif lnThinkEnd-lnThinkSrc > 255, "the thinker block is too big to copy"
.errorif lnStepEnd-lnStepSrc > 255, "the state machine is too big to copy"
.errorif lnActEnd-lnActSrc > 255, "the activation block is too big to copy"

lnThinkSrc:
.pseudopc LINECODE {
//------------------------------------------------------------
// lineThink — one frame of every active moving sector. Runs unconditionally,
// so a free slot costs a load and a branch, and eight free slots cost 48
// cycles.
//------------------------------------------------------------
lineThink:
        ldx #MAXTHINK-1
!loop:  lda thState,x
        beq !next+
        jsr lnStep
!next:  dex
        bpl !loop-
        rts

//------------------------------------------------------------
// lnGetH / lnPutH — read and write the height that sector zLnSec is moving,
// through the pointer lnHPtr left in zLnHPtr. The high byte of a height is the
// same pointer indexed at y + MAXSEC, which is in range because a sector id is
// under MAXSEC and MAXSEC is 96. lnPutH returns with carry clear, which is
// lnMove's "still moving".
//
// Here, three blocks away from their only callers, because the state machine
// filled $de40-$deff and this block had 34 bytes spare. The whole feature is
// laid out by which hole a routine fits, not by what calls what -- see the
// header.
//------------------------------------------------------------
lnGetH: ldy zLnSec
        lda (zLnHPtr),y
        sta zTmpH
        tya
        clc
        adc #MAXSEC
        tay
        lda (zLnHPtr),y
        sta zTmpH+1
        rts

lnPutH: ldy zLnSec
        lda zTmpH
        sta (zLnHPtr),y
        tya
        clc
        adc #MAXSEC
        tay
        lda zTmpH+1
        sta (zLnHPtr),y
        clc
        rts

.errorif * > LINECODE_END, "lines: the thinker overflows into SECTAB"
}
lnThinkEnd:

lnStepSrc:
.pseudopc LINECODE2 {
//------------------------------------------------------------
// lnStep — advance thinker X by one frame.
//
//   TH_GOING  move towards the target; on arrival, wait or finish
//   TH_WAIT   count down
//   TH_BACK   move home; on arrival, free the slot
//
// A door is its sector's *ceiling* and everything else is its floor, which is
// the only place in this file that cares which kind it is.
//------------------------------------------------------------
lnStep: lda thSec,x
        sta zLnSec
        lda thKind,x
        jsr lnHPtr
        lda thState,x
        cmp #TH_WAIT
        beq lnWait
        cmp #TH_BACK
        beq lnBack
        // ---- TH_GOING ----
        lda thTgtLo,x
        sta zA
        lda thTgtHi,x
        sta zA+1
        jsr lnMove
        bcc lnDone                  // still moving
        ldy thKind,x                // how long it holds there, if at all: a
        lda lnWaitTab,y             // W1 floor has no return phase and its
        beq lnFree                  // entry in the table is zero
        sta thWait,x
        lda #TH_WAIT
        sta thState,x
lnDone: rts

lnWait: dec thWait,x
        bne lnDone
        lda #TH_BACK
        sta thState,x
        rts

lnBack: lda thHomeLo,x
        sta zA
        lda thHomeHi,x
        sta zA+1
        jsr lnMove
        bcc lnDone
lnFree: lda #TH_FREE
        sta thState,x
        rts

//------------------------------------------------------------
// lnMove — step thinker X's height towards zA by its speed. Carry set when it
// arrives, and the height is clamped to the target rather than overshooting:
// a door that stops one unit past its lintel is a door that never matches its
// closed height again.
//
// Y indexes SECTAB; zLnKind is 0 for a floor and 4 for a ceiling, which is the
// distance between mapSecFloorLo and mapSecCeilLo in units of MAXSEC.
//------------------------------------------------------------
lnMove: ldy thKind,x
        lda lnSpeed,y
        sta zB                      // zB = speed
        jsr lnGetH                  // zTmpH = the height now
        // delta = target - now
        lda zA
        sec
        sbc zTmpH
        sta zTmpD
        lda zA+1
        sbc zTmpH+1
        sta zTmpD+1
        bpl !up+
        // Downwards: negate both the distance and the step, so the compare
        // and the add below are the same code for either direction. zB+1 is
        // the step's high byte, $ff when it is negative.
        lda #0
        sec
        sbc zTmpD
        sta zTmpD
        lda #0
        sbc zTmpD+1
        sta zTmpD+1
        lda #0
        sec
        sbc zB
        sta zB
        lda #$ff
        .byte $2c                   // bit $00a9: skips the `lda #0` below
!up:    lda #0
        sta zB+1
        // ---- less than one step left? then land exactly on the target ----
        lda zTmpD+1
        bne !+
        lda zTmpD
        cmp zB
        bcc lnArrive
!:      lda zTmpH
        clc
        adc zB
        sta zTmpH
        lda zTmpH+1
        adc zB+1
        sta zTmpH+1
        jmp lnPutH

lnArrive:
        lda zA                      // land exactly on the target
        sta zTmpH
        lda zA+1
        sta zTmpH+1
        jsr lnPutH
        sec
        rts

// Units per frame, and frames held at the target, both indexed by kind.
// LK_NONE is never a thinker's kind; a zero wait means "no return phase",
// which is what makes Doom's W1 floor a one-way move.
lnSpeed:
        .byte 0, DOOR_SPEED, LIFT_SPEED, FLOOR_SPEED
lnWaitTab:
        .byte 0, DOOR_WAIT, LIFT_WAIT, 0

.errorif * > LINECODE2_END, "lines: the state machine overflows into $df00"
}
lnStepEnd:

lnActSrc:
.pseudopc LINECODE3 {
//------------------------------------------------------------
// lineTick — one frame, with I/O already banked out by lineFrame (main.asm).
// Everything the phase does per frame is here and in what it calls.
//------------------------------------------------------------
lineTick:
        ldx zLnUse                  // the use key, edge-triggered: a held key
        lda zInput                  // opens the door in front of you once.
        and #IN_USE                 // Tested here rather than in lineFrame
        sta zLnUse                  // only because there was no room there.
        beq !+                      // `ldx` sets Z too, so it has to come
        txa                         // before the `and` whose result this
        bne !+                      // branch is reading
        jsr lnUse                   // lineFrame has already fetched the segs
!:      lda camSec                  // did the player walk into a new sector?
        cmp camSecOld
        beq !+
        sta camSecOld
        sta zLnSec
        jsr lnEnter
!:      jmp lineThink

//------------------------------------------------------------
// lnFire — sector zLnSec's line was triggered. Start a thinker for it.
//
// A sector already moving is left alone rather than restarted: walking back
// and forth over a lift line would otherwise hold the lift at its start
// height forever, and pressing use against an opening door would re-seed its
// home ceiling from the half-open one and lower the door a step per press.
//------------------------------------------------------------
lnFire: ldy zLnI
        lda ldKind,y
        and #LK_MASK
        cmp #LK_EXIT
        beq lnNope                  // M2 draws the exit switch and no more
        sta zLnKind
        lda ldSec,y
        sta zLnSec

        ldx #MAXTHINK-1
!:      lda thState,x
        beq !next+
        lda thSec,x
        cmp zLnSec
        beq lnNope
!next:  dex
        bpl !-

        ldx #MAXTHINK-1
!:      lda thState,x
        beq lnStart
        dex
        bpl !-
lnNope: rts                         // eight already running: drop it

lnStart:
        lda zLnKind
        sta thKind,x
        lda zLnSec
        sta thSec,x
        ldy zLnI
        lda ldTgtLo,y
        sta thTgtLo,x
        lda ldTgtHi,y
        sta thTgtHi,x
        // Home is the height it has *now*, read rather than precomputed, so a
        // door re-triggered after something else moved its sector still
        // returns to where it actually was.
        lda zLnKind
        jsr lnHPtr
        jsr lnGetH
        lda zTmpH
        sta thHomeLo,x
        lda zTmpH+1
        sta thHomeHi,x
        lda #TH_GOING
        sta thState,x
        rts

//------------------------------------------------------------
// lnUse — the use key. The player's own subsector is in SEGBUF (lineTramp
// fetched it), so walk its segs: a two-sided seg whose back sector carries a
// non-walkover line, and which faces the player, is the door in front of them.
//
// segFacing is the renderer's world-space backface test -- it lives in low RAM
// and touches no I/O, so it is one of the few things this file may call. What
// it rejects is a seg the player is *behind*, on the far side of its line,
// which is how a door already open above the player's head stays out of it.
//
// What it does not test is where the player is looking: facing is a property
// of the seg and the camera's position, not of camA. So a door sharing the
// player's subsector opens whichever way they are turned. That is the
// sector-based activation model §11.2a chose, and its visible cost -- the
// direction test needs the forward vector and two more multiplies, and this
// block is within a byte or two of full. M3, with the geometric line test.
//
// The seg cursor is checkMove's zWIdx and not a variable of this file's own,
// because segFacing reloads X from zWIdx halfway through -- ssmul32 clobbers
// it, and the renderer's caller keeps the offset there. Passing the offset in
// X alone makes the second half of that test read whatever seg checkMove
// stopped on, which is a door that opens when you face away from it.
//------------------------------------------------------------
lnUse:  lda zSegCnt
        beq lnNope
        sta zLnCnt
        lda #0
        sta zWIdx
        sta zLnFlag                 // use fires the non-walkover lines
!seg:   ldx zWIdx
        lda sgBack,x
        cmp #$ff                    // one-sided: nothing behind it to open
        beq !next+
        sta zLnSec
        jsr lnFind                  // is that sector a use-activated line?
        bcc !next+
        ldx zWIdx
        jsr segFacing               // clobbers X, zA, zB, zP, zTop0
        bcc !next+
        jsr lnFire
        rts                         // one door per press
!next:  lda zWIdx
        clc
        adc #SEGSZ
        sta zWIdx
        dec zLnCnt
        bne !seg-
        rts

//------------------------------------------------------------
// lnEnter — the player's sector changed to zLnSec. Fire any walkover line
// triggered by it.
//
// The change, not the presence: a W1 floor would otherwise re-fire every
// frame the player stands in the room, and a WR lift would never settle.
//------------------------------------------------------------
lnEnter:
        lda #LF_WALK
        sta zLnFlag
        jsr lnFind
        bcc !+
        jsr lnFire
!:      rts

//------------------------------------------------------------
// lnFind — the first line whose trigger sector is zLnSec and whose LF_WALK
// matches zLnFlag. Carry set and zLnI is its index; carry clear if none.
//------------------------------------------------------------
lnFind: ldy #MAXLINES-1
!:      lda ldKind,y
        beq !next+
        and #LF_WALK
        cmp zLnFlag
        bne !next+
        lda ldTrig,y
        cmp zLnSec
        bne !next+
        sty zLnI
        sec
        rts
!next:  dey
        bpl !-
        clc
        rts

//------------------------------------------------------------
// lineInit — clear the thinker list, and seed camSecOld so that the sector
// the player spawns in does not read as a sector they just walked into.
//------------------------------------------------------------
lineInit:
        lda #TH_FREE
        ldx #MAXTHINK-1
!:      sta thState,x
        dex
        bpl !-
        lda camSec
        sta camSecOld
        rts

//------------------------------------------------------------
// lnHPtr — point zLnHPtr at the SECTAB array whose height this kind moves:
// the floors, or the ceilings 2*MAXSEC further on, since a door is its
// sector's ceiling and everything else is its floor. Asking that question at
// each of the four use sites cost more than the pointer does.
//
// A = kind on entry. **X is preserved**, and must be: both callers are holding
// a thinker index in it, and the version of this that built the pointer in X
// wrote a whole thinker record at the wrong offset -- which reads exactly like
// a door that will not open, because the state byte lands outside the array.
//------------------------------------------------------------
lnHPtr: ldy #<mapSecFloorLo
        cmp #LK_DOOR
        bne !+
        ldy #<mapSecCeilLo
!:      sty zLnHPtr
        lda #>mapSecFloorLo
        sta zLnHPtr+1
        rts

// Both arrays are in the same page, so the pointer's high byte is a constant.
.errorif [mapSecCeilLo & $ff00] != [mapSecFloorLo & $ff00], "SECTAB's floors and ceilings are no longer in one page -- lnHPtr assumes they are"

.errorif * > LINECODE3_END, "lines: activation overflows past $dfff"
}
lnActEnd:

.errorif * > BOOTCODE5 + $300, "boot block 5 overflows its 768 bytes"

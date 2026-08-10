//============================================================
//  geobench.asm — GeoRAM window probe and access-cost benchmark
//
//  Settles docs/georam-vs-reu.md §9.1, the one measurement that
//  decides whether a GeoRAM migration is worth anything:
//
//      Does an access to I/O space run at the CPU turbo clock, or
//      is it synchronised down to the 1 MHz bus?
//
//  If `lda $de00,x` costs 4 cycles at 64 MHz (0.063 us) the whole
//  case in that document holds. If it costs ~1 us it is exactly REU
//  DMA's per-byte rate, GeoRAM buys nothing, and the migration is
//  dead. There is no middle case that changes the recommendation.
//
//  §9.1 proposed measuring open I/O1 as a stand-in because no
//  GeoRAM was configured. One is now ("RAM Expansion Unit" =
//  "GeoRAM Mode"), so this measures the real device, which the
//  document warned is not the same timing path as open bus.
//
//  Method is reubench.asm's, unchanged: time a fixed loop with CIA 2
//  timer A -- which ticks at 1 us regardless of the turbo setting --
//  then time the identical loop with the access removed and
//  subtract, so what is reported is the cost of the access alone.
//  Every loop is run at 1 MHz and at 64 MHz; the plain-RAM loops are
//  the control and *must* show the full turbo spread, otherwise the
//  measurement is not measuring what it thinks it is.
//
//  Results are left at RESULTS for the host to DMA out;
//  tools/geobench.py prints the table.
//============================================================

#import "defs.asm"

.const RESULTS  = $0c00
.const RAMBUF   = $c000         // plain-RAM control target

// Outer repeats of the 256-iteration inner loop. One pass of one
// loop is 256*reps iterations; at 1 MHz the slowest plausible body
// (~1 us for a synchronised I/O access, plus 5 cycles of loop) must
// still fit in the 16-bit timer:
//   256 * 8 * (1.0 + 5.0) us = 12.3 ms  <  65.5 ms.   Fits.
// At 64 MHz with a fast window it is 288 us, which is 288 timer
// ticks -- coarse, but a 3-decimal-place answer is not needed to
// tell 4 cycles from 1 microsecond.
.const REPS = 8

// GeoRAM registers and window. Deliberately spelled out here rather
// than taken from defs.asm: this file has to be able to run before
// anything in the engine believes in GeoRAM.
.const GEO_WIN   = $de00        // 256-byte window
.const GEO_PAGE  = $dffe        // page within block, write-only
.const GEO_BLOCK = $dfff        // 16 KB block, write-only

.pc = $0801 "basic"
:BasicUpstart2(bench)

.pc = $0810 "bench code"
bench:
        sei
        lda #0
        sta $d020
        sta $d021
        lda #$0b                    // blank the screen: the VIC steals cycles
        sta $d011                   // from the CPU, and would from the timing
        lda #BANK_IO
        sta $01

        ldx #0                      // clear the results block
        txa
!:      sta RESULTS,x
        inx
        cpx #64
        bne !-
        lda #'G'
        sta RESULTS+0
        lda #'B'
        sta RESULTS+1
        lda #1
        sta RESULTS+2

        jsr geoProbe
        sta RESULTS+3               // probe verdict, whatever it was
        cmp #1
        beq !+
        lda #2                      // no usable window: red border, and say so
        sta $d020
        jmp done
!:
        ldx #0                      // slot index into the results table
        stx slot

        lda #TURBO_1MHZ             // ---- pass 1: 1 MHz ----
        sta TURBOREG
        jsr runPass

        lda #TURBO_1MHZ             // ---- pass 2: 64 MHz ----
        sta TURBOREG                // disable-then-enable, see main.asm
        lda #TURBO_MAX
        sta TURBOREG
        jsr runPass

        lda #TURBO_1MHZ             // leave the machine as it was found
        sta TURBOREG
        lda #$ff
        sta RESULTS+5               // done flag, written last
done:
        lda #$1b                    // screen back on so it is not a dead machine
        sta $d011
        jmp *

//------------------------------------------------------------
// geoProbe — is there a GeoRAM window at $de00?  A = verdict.
//
//   1  yes: two pages hold two different signatures
//   0  nothing there: reads did not come back
//   2  something answers, but changing $dffe does not change what
//      comes back -- an aliased register, a cartridge answering at
//      I/O1, or a stuck window. Not usable either way.
//
// docs/georam-vs-reu.md §7 is the reason this is shaped as it is:
// an absent cartridge leaves an open bus, and open I/O reads on a
// C64 do not reliably return zero, so "I read back what I wrote"
// is not a test. Writing *different* signatures to two pages and
// requiring that the page register selects between them is one
// that open bus cannot pass.
//------------------------------------------------------------
geoProbe:
        lda #0
        sta GEO_BLOCK

        lda #0                      // page 0 := sigA
        sta GEO_PAGE
        ldx #3
!:      lda sigA,x
        sta GEO_WIN,x
        dex
        bpl !-

        lda #1                      // page 1 := sigB
        sta GEO_PAGE
        ldx #3
!:      lda sigB,x
        sta GEO_WIN,x
        dex
        bpl !-

        lda #0                      // page 0 must still be sigA: if the
        sta GEO_PAGE                // page register does nothing, the
        ldx #3                      // second write overwrote the first
!:      lda GEO_WIN,x
        cmp sigA,x
        bne geoProbeBad
        dex
        bpl !-

        lda #1                      // and page 1 must still be sigB
        sta GEO_PAGE
        ldx #3
!:      lda GEO_WIN,x
        cmp sigB,x
        bne geoProbeBad
        dex
        bpl !-

        lda #1                      // both hold: the window pages
        rts

geoProbeBad:
        lda #1                      // did *anything* come back?
        sta GEO_PAGE
        lda GEO_WIN
        cmp #$ff
        bne !+
        lda GEO_WIN+1
        cmp #$ff
        bne !+
        lda #0                      // all ones: open bus, nothing there
        rts
!:      lda #2                      // answers, but does not page
        rts

sigA:   .byte $d0, $0e, $c6, $41    // arbitrary, just not $00 or $ff
sigB:   .byte $6e, $65, $6f, $21    // and different from sigA in every byte

//------------------------------------------------------------
// runPass — every loop at whatever speed is currently set.
//
// Order matters only in that the host table below must match it.
//------------------------------------------------------------
runPass:
        jsr loopEmpty               // 0: the control to subtract
        jsr loopRamRead             // 1: lda $c000,x   -- turbo control
        jsr loopRamWrite            // 2: sta $c000,x   -- turbo control
        jsr loopWinRead             // 3: lda $de00,x   -- THE measurement
        jsr loopWinWrite            // 4: sta $de00,x
        jsr loopPageReg             // 5: sta $dffe     -- cost of a page change
        rts

//------------------------------------------------------------
// The timed loops.
//
// Written out one by one rather than parameterised: a benchmark
// whose body arrives through an indirect jump measures the
// indirect jump. Each is REPS * 256 iterations, timer across the
// whole thing, elapsed appended to the results table.
//
// The inner loops are deliberately identical in shape -- ldx #0 /
// body / inx / bne -- so that subtracting loopEmpty leaves exactly
// one instruction's cost and nothing else.
//------------------------------------------------------------
loopEmpty:
        jsr timerStart
        ldy #REPS
!outer: ldx #0
!:      inx
        bne !-
        dey
        bne !outer-
        jmp timerStop

loopRamRead:
        jsr timerStart
        ldy #REPS
!outer: ldx #0
!:      lda RAMBUF,x
        inx
        bne !-
        dey
        bne !outer-
        jmp timerStop

loopRamWrite:
        jsr timerStart
        ldy #REPS
!outer: ldx #0
!:      sta RAMBUF,x
        inx
        bne !-
        dey
        bne !outer-
        jmp timerStop

loopWinRead:
        jsr timerStart
        ldy #REPS
!outer: ldx #0
!:      lda GEO_WIN,x
        inx
        bne !-
        dey
        bne !outer-
        jmp timerStop

loopWinWrite:
        jsr timerStart
        ldy #REPS
!outer: ldx #0
!:      sta GEO_WIN,x
        inx
        bne !-
        dey
        bne !outer-
        jmp timerStop

// The page register is write-only and absolute-only in practice --
// `sta $dffe,x` would spray 256 different page selects and is not
// what any real code does. This times the store the engine would
// actually issue, once per page change.
loopPageReg:
        jsr timerStart
        ldy #REPS
!outer: ldx #0
!:      sta GEO_PAGE
        inx
        bne !-
        dey
        bne !outer-
        jmp timerStop

//------------------------------------------------------------
// timerStart / timerStop — CIA 2 timer A, 1 us ticks at any turbo
// setting (established in IMPLEMENTATION_PLAN.md §10).
//------------------------------------------------------------
timerStart:
        lda #0                      // stop timer A
        sta $dd0e
        lda #$ff                    // preload $ffff
        sta $dd04
        sta $dd05
        lda #%00010001              // force load + start, continuous
        sta $dd0e
        rts

timerStop:
        lda #0                      // stop, then read: no rollover race
        sta $dd0e
        sec                         // elapsed = $ffff - timer
        lda #$ff
        sbc $dd04
        sta elapsed
        lda #$ff
        sbc $dd05
        sta elapsed+1
        // fall through to storeResult

//------------------------------------------------------------
// storeResult — append `elapsed` to the results table.
//------------------------------------------------------------
storeResult:
        ldx slot
        lda elapsed
        sta RESULTS+8,x
        inx
        lda elapsed+1
        sta RESULTS+8,x
        inx
        stx slot
        inc RESULTS+4               // progress, so the host can see it move
        rts

elapsed:  .word 0
slot:     .byte 0

.errorif * > RESULTS, "bench code overflows the results block"

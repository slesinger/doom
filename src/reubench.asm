//============================================================
//  reubench.asm — standalone REU DMA throughput benchmark
//
//  Answers IMPLEMENTATION_PLAN.md Phase 1.3 / the open item in
//  3d-renderer-design.md §REU usage:
//
//      Does REU DMA throughput scale with the CPU turbo clock, or
//      does it stay at the 1541-Ultimate's ~1 byte/us?
//
//  The answer decides whether the Milestone-1 plan can stream one
//  subsector's segs per visit (~30 bytes, ~40 times a frame) or
//  has to batch them per node subtree.
//
//  Method: fire N transfers of a given size back to back and time
//  the loop with CIA 2 timer A, which ticks at 1 MHz regardless of
//  the CPU turbo setting -- the same loop is then timed with the
//  DMA removed and subtracted, so what is reported is the transfer
//  cost alone. Repeated at 1 MHz and at 64 MHz: if the two agree,
//  DMA is independent of the CPU clock.
//
//  Results are left in RAM at RESULTS for the host to DMA out;
//  tools/reubench.py prints the table. Nothing is displayed on the
//  C64 screen -- the machine this runs on is not the machine
//  anyone is looking at.
//============================================================

#import "defs.asm"

.const RESULTS  = $0c00
.const DMABUF   = $2000         // 4 KB destination for the transfers

// Fixed repeat counts per size, chosen so the timed interval is
// long relative to the CIA's 1 us tick but cannot overflow the
// 16-bit timer even if DMA turns out to be as slow as 0.5 B/us.
//   32 B x 128 =  4 KB      256 B x 32 = 8 KB      4096 B x 4 = 16 KB
.const REPS_32   = 128
.const REPS_256  = 32
.const REPS_4096 = 4

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

        ldx #0                      // clear the results block
        lda #0
!:      sta RESULTS,x
        inx
        cpx #64
        bne !-
        lda #'R'
        sta RESULTS+0
        lda #'B'
        sta RESULTS+1
        lda #1
        sta RESULTS+2

        jsr reuProbe
        bcs !+
        lda #2                      // no REU: red border, and say so
        sta $d020
        lda #0
        sta RESULTS+3
        jmp done
!:      lda #1
        sta RESULTS+3

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

        lda #$ff
        sta RESULTS+5               // done flag, written last
done:
        lda #$1b                    // screen back on so it is not a dead machine
        sta $d011
        jmp *

//------------------------------------------------------------
// runPass — the three sizes at whatever speed is currently set.
//------------------------------------------------------------
runPass:
        lda #<32
        sta xferLen
        lda #>32
        sta xferLen+1
        lda #REPS_32
        sta reps
        jsr measure

        lda #<256
        sta xferLen
        lda #>256
        sta xferLen+1
        lda #REPS_256
        sta reps
        jsr measure

        lda #<4096
        sta xferLen
        lda #>4096
        sta xferLen+1
        lda #REPS_4096
        sta reps
        jsr measure
        rts

//------------------------------------------------------------
// measure — time `reps` transfers of `xferLen`, then time the
// same loop with the command store replaced by a no-op, and store
// both. The caller subtracts; storing both keeps the raw numbers
// visible in case the overhead is the interesting part.
//------------------------------------------------------------
measure:
        lda #REU_FETCH
        sta cmdByte
        jsr timedLoop
        jsr storeResult

        lda #0                      // $00 has bit 7 clear: no execute
        sta cmdByte
        jsr timedLoop
        jsr storeResult

        inc RESULTS+4               // progress, so the host can see it move
        rts

//------------------------------------------------------------
// timedLoop — `reps` iterations, timer A across the whole thing.
//------------------------------------------------------------
timedLoop:
        lda #0                      // stop timer A
        sta $dd0e
        lda #$ff                    // preload $FFFF
        sta $dd04
        sta $dd05
        lda #%00010001              // force load + start, continuous
        sta $dd0e

        ldx reps
!loop:  lda #<DMABUF
        sta REU_C64ADDR
        lda #>DMABUF
        sta REU_C64ADDR+1
        lda #0                      // always REU address 0, bank 0: this
        sta REU_REUADDR             // measures transfer cost, not locality
        sta REU_REUADDR+1
        sta REU_BANK
        lda xferLen
        sta REU_LENGTH
        lda xferLen+1
        sta REU_LENGTH+1
        lda cmdByte
        sta REU_COMMAND             // <- the DMA happens here, CPU halted
        dex
        bne !loop-

        lda #0                      // stop, then read: no rollover race
        sta $dd0e
        sec                         // elapsed = $FFFF - timer
        lda #$ff
        sbc $dd04
        sta elapsed
        lda #$ff
        sbc $dd05
        sta elapsed+1
        rts

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
        rts

xferLen:  .word 0
reps:     .byte 0
cmdByte:  .byte 0
elapsed:  .word 0
slot:     .byte 0

#import "reu.asm"
.errorif * > DMABUF, "bench code overflows the DMA buffer"

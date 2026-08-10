//============================================================
//  irqtest.asm — can the engine take interrupts at all?
//
//  Everything about audio downstream of this: a music player has to tick at
//  50 Hz and the main loop runs at 25 fps, so the player belongs in an
//  interrupt. The engine has never taken one. `main.asm` opens with `sei`
//  and never clears it, and defs.asm says why: the BSP walk flips $01
//  between BANK_IO ($35) and BANK_RAM ($34) to read the node and sector
//  tables under the I/O space, and an interrupt landing inside one of those
//  windows would return to code that believes $01 is something it is not.
//
//  Three things have to be true before a player can be written, and none of
//  them is true by argument:
//
//    1. With HIRAM = 0 the KERNAL is banked out, so the CPU fetches its IRQ
//       vector from RAM at $fffe. That RAM has to be reachable and stable in
//       BOTH banking states. It is above BITMAP1's last byte ($ff3f) --
//       $ff40-$ffff is 192 bytes nothing in the memory map claims.
//    2. A handler that saves $01, forces BANK_IO, does its work and restores
//       what it found has to be airtight against landing mid-window.
//    3. None of it may cost a surprising amount at 64 MHz.
//
//  Method. The main loop spends most of its time inside a BANK_RAM window,
//  reading a canary pattern written into the RAM under $d000 and checking
//  every byte. CIA 1 timer A raises an IRQ every IRQ_PERIOD phi2 cycles --
//  about 2000 a second -- so thousands of interrupts land inside those
//  windows. If banking is not restored correctly the loop reads the VIC's
//  registers instead of its canary and the mismatch counter moves.
//
//  The host drives four modes through a mailbox byte, and the third of them
//  is the point:
//
//    0  correct handler          expect: mismatches stay at 0
//    1  handler restores $35     expect: mismatches climb immediately --
//                                the positive control. Without it, "zero
//                                mismatches" might only mean the test is
//                                blind
//    2  interrupts off           the loop rate with nothing interrupting it,
//                                which is what makes mode 0's rate mean
//                                something
//    3  correct handler + a 25-register SID burst, i.e. what a player call
//       actually costs -- and specifically whether the Ultimate stalls the
//       64 MHz CPU on writes to a 1 MHz device
//
//  Counters are free-running; the host samples them twice over a known
//  interval and divides. tools/irqtest.py does the arithmetic.
//============================================================

#import "defs.asm"

.const RESULTS   = $0c00

// The RAM under the I/O space -- the same 4 KB the engine keeps its node and
// sector tables in, and the reason $01 gets flipped at all.
.const CANARY    = $d000
.const CANARYN   = 64               // bytes checked per loop pass. Bigger means
                                    // more of the loop is spent under BANK_RAM,
                                    // which is where interrupts need to land.

// CIA 1 timer A period in phi2 cycles. 500 gives ~1970 interrupts a second,
// which is 40x the rate a player would actually ask for -- deliberately, so
// that a rare failure has a chance to show up inside a short run.
.const IRQ_PERIOD = 500

.const CIA1_TALO = $dc04
.const CIA1_TAHI = $dc05
.const CIA1_ICR  = $dc0d
.const CIA1_CRA  = $dc0e

// zero page
.const zSaved    = $02              // $01 as the handler found it
.const zChk      = $03              // canary byte under test
.const zMode     = $04              // mode currently applied

// result block
.const rMagic    = RESULTS + 0      // 'I','Q',1
.const rMode     = RESULTS + 3      // mailbox: the host writes the mode here
.const rIrq      = RESULTS + 4      // 24-bit: interrupts taken
.const rLoop     = RESULTS + 8      // 24-bit: main-loop passes completed
.const rBad      = RESULTS + 12     // 24-bit: canary mismatches
.const rBadVal   = RESULTS + 16     // the byte that did not match
.const rBadIdx   = RESULTS + 17     // where in the canary
.const rInWin    = RESULTS + 20     // 24-bit: interrupts that landed with
                                    // $01 = BANK_RAM, i.e. inside a window
.const rCurMode  = RESULTS + 24     // the mode the machine has actually applied
.const rReady    = RESULTS + 25     // $ff once the loop is running

.pc = $0801 "basic"
:BasicUpstart2(irqtest)

.pc = $0810 "code"
irqtest:
        sei
        lda #BANK_IO
        sta $01
        lda #TURBO_1MHZ             // engage turbo: disable then enable, the
        sta TURBOREG                // transition is what takes (main.asm)
        lda #TURBO_MAX
        sta TURBOREG
        lda #0
        sta $d020
        sta $d021
        lda #$0b                    // screen off: no badlines in the loop rate
        sta $d011

        ldx #0                      // clear the result block
        txa
!:      sta RESULTS,x
        inx
        cpx #32
        bne !-
        lda #'I'
        sta rMagic+0
        lda #'Q'
        sta rMagic+1
        lda #1
        sta rMagic+2

        //------------------------------------------------------------
        // The canary: 256 bytes of RAM under the I/O space, holding a
        // pattern no VIC register will match by accident.
        //------------------------------------------------------------
        lda #BANK_RAM
        sta $01
        ldx #0
!:      txa
        eor #$5a
        sta CANARY,x
        inx
        bne !-
        lda #BANK_IO
        sta $01

        //------------------------------------------------------------
        // Vectors. $fffa-$ffff is RAM whenever HIRAM = 0, which both of the
        // engine's banking states are -- so one write serves both. The NMI
        // vector is pointed at an rti as well: sei does not mask NMI, and a
        // machine that took one into whatever the KERNAL left behind would
        // fail this test for a reason that has nothing to do with it.
        //------------------------------------------------------------
        lda #<irqEntry
        sta $fffe
        lda #>irqEntry
        sta $ffff
        lda #<nmiEntry
        sta $fffa
        lda #>nmiEntry
        sta $fffb

        lda #$7f                    // no NMI from CIA 2, and clear anything
        sta CIA2_ICR                // already pending
        lda CIA2_ICR
        lda #0                      // no IRQ from the VIC either
        sta $d01a
        lda #$ff
        sta $d019

        lda #$7f                    // CIA 1: all sources off, then timer A
        sta CIA1_ICR                // as the one interrupt in the machine
        lda CIA1_ICR
        lda #<IRQ_PERIOD
        sta CIA1_TALO
        lda #>IRQ_PERIOD
        sta CIA1_TAHI
        lda #%00010001              // force load, start, continuous, phi2
        sta CIA1_CRA
        lda #%10000001              // enable: timer A underflow raises IRQ
        sta CIA1_ICR

        lda #$ff
        sta zMode                   // nothing applied yet, so mode 0 in the
                                    // mailbox counts as a change
        lda #$ff
        sta rReady
        cli

//------------------------------------------------------------
// The main loop. Most of its time is spent under BANK_RAM, on purpose:
// that is the window an interrupt has to survive.
//------------------------------------------------------------
loop:
        lda rMode                   // the host's mailbox -- always RAM, so it
        cmp zMode                   // reads the same under either banking
        beq loopRun
        jsr applyMode

loopRun:
        lda #BANK_RAM
        sta $01
        ldx #0
lpChk:  lda CANARY,x
        sta zChk
        txa
        eor #$5a
        cmp zChk
        bne lpBad
        inx
        cpx #CANARYN
        bne lpChk
        lda #BANK_IO
        sta $01

        inc rLoop                   // 24-bit
        bne loop
        inc rLoop+1
        bne loop
        inc rLoop+2
        jmp loop

// A mismatch means the read did not come from the RAM under $d000 -- i.e.
// $01 was not BANK_RAM when it should have been, which is exactly the
// failure mode 1 induces on purpose.
lpBad:
        lda #BANK_IO
        sta $01
        lda zChk
        sta rBadVal
        stx rBadIdx
        inc rBad
        bne loop
        inc rBad+1
        bne loop
        inc rBad+2
        jmp loop

//------------------------------------------------------------
// applyMode — A holds the mode the host asked for.
//
// The correct/broken switch is two bytes of self-modification rather than a
// branch in the handler: `lda zSaved` is $a5 zz and `lda #BANK_IO` is $a9 ii,
// so the two forms are the same length and the handler's cost does not depend
// on which one is in place.
//------------------------------------------------------------
applyMode:
        sei
        sta zMode
        sta rCurMode
        lda #0
        sta doSid

        lda zMode
        cmp #2
        bne amIrqOn
        lda #$7f                    // mode 2: interrupts off
        sta CIA1_ICR
        lda CIA1_ICR
        jmp amCorrect

amIrqOn:
        lda #%10000001
        sta CIA1_ICR
        lda zMode
        cmp #1
        bne amNotBroken
        lda #$a9                    // lda #BANK_IO -- restores the wrong bank
        sta restoreLd
        lda #BANK_IO
        sta restoreLd+1
        jmp amDone
amNotBroken:
        cmp #3
        bne amCorrect
        lda #1                      // mode 3: play a player-sized SID burst
        sta doSid
amCorrect:
        lda #$a5                    // lda zSaved -- restores what it found
        sta restoreLd
        lda #zSaved
        sta restoreLd+1
amDone:
        cli
        rts

//------------------------------------------------------------
// irqEntry — the handler the whole test exists to justify.
//
// It saves $01, forces BANK_IO so that the I/O it needs is reachable, and
// puts back what it found. Nothing else in it may assume a banking state:
// $0c00 and the zero page are RAM under both.
//------------------------------------------------------------
irqEntry:
        pha
        txa
        pha
        tya
        pha

        lda $01
        sta zSaved
        cmp #BANK_RAM               // did this land inside a bank window?
        bne ieNotInWin
        inc rInWin
        bne ieNotInWin
        inc rInWin+1
        bne ieNotInWin
        inc rInWin+2
ieNotInWin:
        lda #BANK_IO
        sta $01

        lda CIA1_ICR                // acknowledge, or it fires again at once

        inc rIrq
        bne ieCounted
        inc rIrq+1
        bne ieCounted
        inc rIrq+2
ieCounted:

        lda doSid
        beq ieNoSid
        jsr sidBurst
ieNoSid:

restoreLd:
        lda zSaved                  // patched: `lda #BANK_IO` in mode 1
        sta $01
        pla
        tay
        pla
        tax
        pla
        rti

nmiEntry:
        rti

//------------------------------------------------------------
// sidBurst — 25 registers written back to back, which is what a player call
// looks like from the bus's point of view. Master volume stays 0, so mode 3
// is silent; the point is the cost, not the sound.
//------------------------------------------------------------
sidBurst:
        ldx #0
sbLoop: lda sidTab,x
        sta $d400,x
        inx
        cpx #25
        bne sbLoop
        rts

sidTab:
        .byte $10, $20, $00, $08, $41, $09, $00
        .byte $30, $30, $00, $08, $21, $09, $00
        .byte $00, $04, $00, $08, $20, $09, $00
        .byte $00, $00, $00
        .byte $00                   // volume 0: nothing comes out

doSid:  .byte 0

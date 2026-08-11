//============================================================
//  music.asm — the SID player: an interrupt, a pointer, and 400 KB of REU
//
//  There is no player code here in the usual sense. A `.sid` is 6502 code at
//  fixed absolute addresses -- DooM_Medley wants $0FF6-$3E6A -- and that lands
//  inside MATRIX, the chunky framebuffer. The engine's free RAM is about 360
//  bytes in four holes (IMPLEMENTATION_PLAN.md §14), so a resident player was
//  never going to happen.
//
//  So the player ran once, at build time, in tools/cpu6502.py: init called,
//  play called at the tune's own rate, and the 25 SID registers snapshotted
//  after every call. tools/sidstream.py delta-encodes those snapshots into the
//  stream that wad2reu.py puts in the image as block 5. What runs on the C64 is
//  a replay head -- fetch one record, write the registers it names, advance the
//  pointer -- which is chip-identical to the tune by construction, costs no
//  resident player code, and loops by rewinding a 24-bit pointer.
//
//  docs/reu-format.md §4.6 is the stream format; change it there first.
//
//  Three things about this file are load-bearing.
//
//  1. THE HANDLER LIVES AT $FF40 AND IS COPIED THERE, not loaded there.
//     The CPU fetches its IRQ vector from $FFFE, which is RAM in both banking
//     states the engine uses ($34 and $35 both have HIRAM = 0). $FF40-$FFF9 is
//     186 bytes above BITMAP1 that nothing claims and §15 deliberately kept
//     free for exactly this. But a PRG image reaching past $CFDA would write
//     4 KB of filler across the I/O space on load, and nobody has tested what
//     the Ultimate's DMA loader does with that. So the handler is assembled
//     with .pseudopc inside the boot segment and musInit copies it up. The PRG
//     still ends at $CFDA.
//
//  2. THE HANDLER SAVES AND RESTORES $01 AND NINE REU REGISTERS.
//     $01 because the BSP walk reads the node and sector tables with $34
//     banked in, and an interrupt landing inside one of those windows must not
//     return to code that believes $01 is something else. src/irqtest.asm
//     measured this on hardware, positive control included: 1.7 µs, and zero
//     mismatches over thousands of interrupts landing inside the windows.
//
//     The REU registers because the renderer's transfer is "fill in $DF02-$DF08,
//     then write $DF01", and an interrupt between those two writes would
//     otherwise return to a command register that transfers *the music's*
//     parameters. The DMA itself cannot be interrupted -- the REU halts the CPU
//     for the duration -- so the setup window is the whole hazard.
//     $DF00 is excluded on purpose: reading the status register clears it.
//
//  3. THE STREAM ASSUMES THE SID STARTS AT ZERO. The delta encoding emits a
//     register only when it changes from the previous tick, and the encoder's
//     "previous" begins as 25 zero bytes. musInit therefore clears $D400-$D418
//     before the first tick, or every register the tune never writes keeps
//     whatever the KERNAL's reset left in it.
//
//  Cost, at DooM_Medley's 100.25 Hz: four ticks per 39.9 ms frame, each one an
//  interrupt (1.7 µs), a 40-byte DMA (40 µs, and REU DMA does not get cheaper
//  at 64 MHz) and a mean of 3.3 register writes. About 0.17 ms a frame, ~0.4%
//  of the budget, and most of it is the DMA rather than the CPU.
//============================================================

// Stream format version -- tools/sidstream.py's STREAM_VERSION. Moves in
// lockstep with it; musInit refuses anything else rather than replaying a
// layout it does not understand as if it were register data.
.const MUSFMT_VERSION = 1
.const MUSHDRSZ       = 16

// Header field offsets. The header is DMA'd into musBuf, which is dead space
// until the first tick fetches a record over it.
.const msMagic  = musBuf + 0        // "MU"
.const msVer    = musBuf + 2
.const msWindow = musBuf + 3        // longest record + slack, in bytes
.const msLatch  = musBuf + 4        // CIA1 timer A latch, 16-bit
.const msLoop   = musBuf + 6        // 24-bit stream offset the tune repeats from
.const msEnd    = musBuf + 9        // 24-bit, one past the last record

//------------------------------------------------------------
// musInit — boot-only. Reads the stream header, copies the handler to
// MUSCODE, clears the SID and starts CIA1 timer A.
//
// Assembled into MATRIX like mapLoad, and for the same reason (BOOTCODE in
// defs.asm): it runs once, before the first frame, and spanFill writes over it
// afterwards. Nothing here may be called again.
//
// Leaves musOK = 1 if the tune is running. musOK = 0 with musErr = 0 means the
// image carries no music, which is not an error -- `make assets` without a tune
// produces one and the engine renders in silence. musErr non-zero means a
// stream was there and was rejected, which is a build mismatch and is what
// tools/vicedbg/probe.py asserts against.
//
// Interrupts must still be masked when this returns; main.asm does the `cli`.
//------------------------------------------------------------
.pc = MUSBOOT "boot: music player"

musInit:
        lda #0
        sta musOK
        sta musErr

        // --- FIRST, and unconditionally: make `cli` safe. ---
        //
        // Every exit from this routine is followed by main.asm's `cli`,
        // including the two that produce silence, so the machine must be left
        // with no interrupt it cannot handle *before* anything here can decide
        // to give up. The KERNAL leaves CIA 1 timer A free-running with its
        // IRQ enabled -- that is its own 60 Hz jiffy source -- and the engine
        // has never noticed because it has never cleared the mask. Returning
        // early with that still enabled and $FFFE still holding whatever the
        // reset left in it vectors the first jiffy into nowhere: the engine
        // hangs before frame 1, on an image that is merely silent. Measured,
        // not reasoned about -- build/testmap.reu did exactly that.
        //
        // So: the handler goes up, the vectors point at it, and every source
        // is turned off here. Only a stream that checks out switches one back
        // on, at the bottom of this routine.
        ldx #0
!:      lda musSrc,x
        sta MUSCODE,x
        inx
        cpx #musSrcEnd-musSrc
        bne !-

        lda #<musIrq
        sta IRQVEC
        lda #>musIrq
        sta IRQVEC+1
        // `sei` does not mask NMI, and RESTORE is still wired to one. A machine
        // that took it into whatever the KERNAL left behind would crash for a
        // reason unrelated to anything here.
        lda #<musNmi
        sta NMIVEC
        lda #>musNmi
        sta NMIVEC+1

        lda #$7f                        // CIA2: no NMI. Its timers are the
        sta CIA2_ICR                    // millisecond clock and keep running.
        lda CIA2_ICR                    // read to clear anything pending
        lda #0                          // the VIC does not interrupt either
        sta $d01a
        lda #$ff
        sta $d019
        lda #$7f                        // CIA1: every source off, the KERNAL's
        sta CIA1_ICR                    // jiffy timer included
        lda CIA1_ICR

        // No music block? MAPINFO's offset is zero, and zero is not a legal
        // stream offset -- the image header itself is there. Silence is not an
        // error: `make assets` without a tune produces such an image, and
        // build/testmap.reu is one.
        lda miMusBase
        ora miMusBase+1
        ora miMusBase+2
        bne miHaveStream
        rts

miHaveStream:
        // --- the 16-byte stream header, straight into musBuf ---
        lda #<musBuf
        sta REU_C64ADDR
        lda #>musBuf
        sta REU_C64ADDR+1
        lda miMusBase
        sta REU_REUADDR
        lda miMusBase+1
        sta REU_REUADDR+1
        lda miMusBase+2
        sta REU_BANK
        lda #MUSHDRSZ
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND

        lda msMagic
        cmp #'M'
        bne miBadMagic
        lda msMagic+1
        cmp #'U'
        beq !+
miBadMagic:
        lda #MUSERR_MAGIC
        jmp miFail
!:      lda msVer
        cmp #MUSFMT_VERSION
        beq !+
        lda #MUSERR_VERSION
        jmp miFail
!:
        // The handler DMAs a fixed MUSWINDOW bytes per tick and only then
        // learns how long the record was, so the window has to cover the
        // longest record in this stream. Checked rather than assumed: a tune
        // that changes more registers per tick than DooM_Medley does would
        // otherwise be replayed from a truncated record, i.e. as noise.
        lda msWindow
        beq miBadWindow
        cmp #MUSWINDOW+1
        bcc !+
miBadWindow:
        lda #MUSERR_WINDOW
        jmp miFail
!:
        // --- the three 24-bit pointers, all relative to the block's base ---
        lda miMusBase                   // musPtr = base + header size
        clc
        adc #MUSHDRSZ
        sta musPtr
        lda miMusBase+1
        adc #0
        sta musPtr+1
        lda miMusBase+2
        adc #0
        sta musPtr+2

        lda miMusBase                   // musLoop = base + header's loop offset
        clc
        adc msLoop
        sta musLoop
        lda miMusBase+1
        adc msLoop+1
        sta musLoop+1
        lda miMusBase+2
        adc msLoop+2
        sta musLoop+2

        lda miMusBase                   // musEnd = base + header's end offset
        clc
        adc msEnd
        sta musEnd
        lda miMusBase+1
        adc msEnd+1
        sta musEnd+1
        lda miMusBase+2
        adc msEnd+2
        sta musEnd+2

        // --- the chip, to the state the encoder's first delta assumes ---
        lda #0
        ldx #24
!:      sta SID,x
        dex
        bpl !-

        // --- the one interrupt in the machine, and it is the music ---
        lda msLatch                     // the tune's own rate, from the header
        sta CIA1_TALO
        lda msLatch+1
        sta CIA1_TAHI
        lda #%00010001                  // force load, start, continuous, phi2
        sta CIA1_CRA
        lda #%10000001                  // enable: timer A underflow -> IRQ
        sta CIA1_ICR

        lda #1
        sta musOK
        rts

miFail:
        sta musErr
        rts

//------------------------------------------------------------
// musIrq — one tick. Assembled here, executed at MUSCODE.
//
// Order inside it is not arbitrary: the pointer is advanced *before* the
// registers are written, so that the play loop can use musBuf's own count byte
// as its counter and destroy it. musBuf is re-fetched by DMA every tick, so
// there is nothing there worth preserving -- which is what buys the loop its
// temporary in a block that has no room for one.
//
// Nothing here touches the zero page or the stack beyond A/X/Y, and nothing
// assumes a banking state until $01 has been forced.
//------------------------------------------------------------
musSrc:
.pseudopc MUSCODE {

musIrq:
        pha
        txa
        pha
        tya
        pha

        lda $01                     // whatever the interrupted code was using
        sta musBank
        lda #BANK_IO                // the SID and the REU are both I/O
        sta $01
        lda CIA1_ICR                // acknowledge, or it fires again at once

        // --- the renderer may be mid-setup: save $DF02-$DF0A ---
        ldx #8
!:      lda REU_C64ADDR,x
        sta MUSREU,x
        dex
        bpl !-

        // --- one record, MUSWINDOW bytes, into musBuf ---
        lda #<musBuf
        sta REU_C64ADDR
        lda #>musBuf
        sta REU_C64ADDR+1
        lda musPtr
        sta REU_REUADDR
        lda musPtr+1
        sta REU_REUADDR+1
        lda musPtr+2
        sta REU_BANK
        lda #MUSWINDOW
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND

        ldx #8                      // put the renderer's transfer back
!:      lda MUSREU,x
        sta REU_C64ADDR,x
        dex
        bpl !-

        // --- advance: a record is 1 count byte + 2 bytes per register ---
        lda musBuf
        asl                         // 2 * count; count <= 25, so no carry out
        sec                         // ... + the count byte itself
        adc musPtr
        sta musPtr
        bcc miAdvDone
        inc musPtr+1
        bne miAdvDone
        inc musPtr+2
miAdvDone:

        // --- past the end? rewind to the loop point. 24-bit compare, high
        // byte first: the first differing byte decides, and all-equal falls
        // out of the loop with carry set, which is also a rewind (musEnd is
        // one past the last record).
        ldx #2
!:      lda musPtr,x
        cmp musEnd,x
        bne miCmpDone
        dex
        bpl !-
miCmpDone:
        bcc miPlay
        ldx #2
!:      lda musLoop,x
        sta musPtr,x
        dex
        bpl !-

        // --- write the registers this tick names, destroying the count ---
miPlay:
        lda musBuf
        beq miExit                  // a tick that changes nothing is legal
        ldy #1
!:      ldx musBuf,y                // register index, 0-24
        iny
        lda musBuf,y                // value
        iny
        sta SID,x
        dec musBuf
        bne !-

miExit:
        lda musBank
        sta $01
        pla
        tay
        pla
        tax
        pla
        rti

musNmi:
        rti

musCodeEnd:
}
musSrcEnd:

.errorif musCodeEnd > MUSCODE_END + 1, "the music IRQ handler overruns the CPU vectors at $fffa"
.errorif * > MATRIX + $5000, "music boot code overflows its slack inside MATRIX"

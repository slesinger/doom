//============================================================
//  reu.asm — REU (1750-style RAM expansion) transfer primitives
//
//  The REU is a DMA engine, not a memory window: it halts the
//  6510 and moves bytes itself. So a transfer is "fill in six
//  registers, write the command, and by the time the next
//  instruction executes the data is there". There is nothing to
//  poll and no completion interrupt to wait for.
//
//  Registers, $DF00-$DF0A:
//    $DF00  status   (read; clears on read)
//    $DF01  command  bit7 execute, bit5 autoload,
//                    bit4 disable the $FF00 trigger,
//                    bits1-0 type: 0 stash, 1 fetch, 2 swap, 3 compare
//    $DF02  C64 address lo/hi
//    $DF04  REU address lo/hi
//    $DF06  REU bank
//    $DF07  length lo/hi   (0 means 65536)
//    $DF09  interrupt mask
//    $DF0A  address control  bit7 fix C64 addr, bit6 fix REU addr
//
//  The register and command constants live in defs.asm, with
//  every other .const in the project.
//
//  This module places no .pc of its own -- the importer decides
//  where it lands, so the engine and the standalone benchmark can
//  share it.
//============================================================

//------------------------------------------------------------
// reuSet(ram, reu, bank, len) — load the transfer registers.
//
// A macro rather than a subroutine because every operand is a
// compile-time constant at every call site that uses it; the
// dynamic case (per-subsector seg streaming) writes the four
// registers it actually needs and leaves the rest standing.
//------------------------------------------------------------
.macro reuSet(ram, reu, bank, len) {
        lda #<ram
        sta REU_C64ADDR
        lda #>ram
        sta REU_C64ADDR+1
        lda #<reu
        sta REU_REUADDR
        lda #>reu
        sta REU_REUADDR+1
        lda #bank
        sta REU_BANK
        lda #<len
        sta REU_LENGTH
        lda #>len
        sta REU_LENGTH+1
}

//------------------------------------------------------------
// reuInit — put the controller in a known state.
//
// Both address-increment modes on (the default is fine, but the
// REU keeps its registers across a reset, so a program that
// inherits a fixed-address setting from whatever ran before would
// read one byte 4096 times and never know).
//------------------------------------------------------------
reuInit:
        lda #0
        sta REU_ADDRCTL
        sta REU_IRQMASK
        rts

//------------------------------------------------------------
// reuProbe — is there an REU?  carry set = yes.
//
// Round-trips a signature through REU address 0 rather than
// trusting the status register: with no REU present the $DFxx
// stores go nowhere and the reads return $FF, so the fetch is a
// no-op and the cleared buffer stays cleared. That is a positive
// test for a working data path, which reading $DF00 is not.
//
// Clobbers the first 4 bytes of REU bank 0, and reuScratch. Call
// it before loading anything.
//------------------------------------------------------------
reuProbe:
        jsr reuInit
        ldx #3                      // buffer := signature
!:      lda reuSig,x
        sta reuScratch,x
        dex
        bpl !-
        :reuSet(reuScratch, $0000, 0, 4)
        lda #REU_STASH
        sta REU_COMMAND
        lda #0                      // wipe it, so a dead fetch is visible
        ldx #3
!:      sta reuScratch,x
        dex
        bpl !-
        :reuSet(reuScratch, $0000, 0, 4)
        lda #REU_FETCH
        sta REU_COMMAND
        ldx #3
!:      lda reuScratch,x
        cmp reuSig,x
        bne reuAbsent
        dex
        bpl !-
        sec
        rts
reuAbsent:
        clc
        rts

reuSig:  .byte $d0, $0e, $c6, $41   // arbitrary, just not $00 or $ff

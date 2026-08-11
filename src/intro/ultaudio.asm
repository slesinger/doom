//============================================================
//  ultaudio.asm — the C64 Ultimate's "Ultimate Audio" sampler.
//
//  Real hardware only: seven independent 8/16-bit PCM channels, DMA'd
//  straight out of REU/SDRAM by the Ultimate's own FPGA. The 6502 spends
//  no time feeding it -- there is no REU_STASH/FETCH involved at all
//  (src/reu.asm's DMA controller is a different piece of hardware); a
//  channel is just pointed at a REU address and gated on. Documented in
//  "Ultimate Audio, Register API" v0.2 (Gideon Zweijtzer, 2012),
//  cartridge I/O $DF20-$DFFF.
//
//  VICE does not emulate this block: $DF20 upward reads back open bus,
//  same as any unmapped cartridge I/O. So this program's audio can only
//  be heard on real hardware (`make run-intro-u64`) -- `make shot-intro`
//  only ever checks the picture. Same split as sidtest/irqtest
//  (src/sidtest.asm, src/irqtest.asm), and for the same reason: some
//  questions only the machine can answer.
//
//  Must be enabled on the machine first -- "Ultimate Audio" under C64
//  and Cartridge Settings, plus the "Sampler Left"/"Sampler Right" audio
//  routing under Audio settings. tools/introconfig.py applies both.
//============================================================

.const UA_BASE   = $df20
.const UA_STRIDE = $20              // 7 channels, 32 bytes apart

// per-channel offsets from the channel base ($DF20 + chan*UA_STRIDE)
.const UA_CTRL   = $00
.const UA_VOL    = $01
.const UA_PAN    = $02
.const UA_ADDR   = $04               // 4 bytes, big-endian; high byte = $01
.const UA_LEN    = $09               // 3 bytes, big-endian
.const UA_RATE   = $0e               // 2 bytes, big-endian: divider @ 6.25 MHz
.const UA_REPA   = $11               // 3 bytes, big-endian
.const UA_REPB   = $15               // 3 bytes, big-endian
.const UA_IRQCLR = $1f

.const UA_GATE       = %00000001
.const UA_REPEAT     = %00000010
.const UA_IRQEN      = %00000100
.const UA_INTERLEAVE = %01000000

// The address, length and repeat-point registers are all relative to the
// channel's own sample start (register API §2.4.7's diagram runs 0 ..
// length, not REU-absolute), which is what lets both title-music channels
// share one uaLoad shape while starting one byte apart.

//------------------------------------------------------------
// uaLoad(chan, reuOfs, len, rateDiv, vol, pan, interleave, repeat)
//
// Programs one channel and gates it on. reuOfs/len are byte offsets and
// byte counts within REU memory (the channel's address register becomes
// $01,000000 + reuOfs); rateDiv is the 6.25 MHz divider (register API
// §2.4.6's table: 8000 Hz -> 781, 48000 Hz -> 130, ...). Repeat point A
// is always 0 and B is always `len`, i.e. the whole sample loops -- there
// is nothing else this program plays yet.
//
// Every operand is a compile-time constant at both call sites (the title
// music's left and right channels), so this is a macro, not a subroutine
// -- the same reasoning as reu.asm's reuSet.
//------------------------------------------------------------
.macro uaLoad(chan, reuOfs, len, rateDiv, vol, pan, interleave, repeat) {
    .const cb   = UA_BASE + chan*UA_STRIDE
    .const ctrl = UA_GATE | (interleave*UA_INTERLEAVE) | (repeat*UA_REPEAT)

    lda #vol
    sta cb+UA_VOL
    lda #pan
    sta cb+UA_PAN

    lda #$01                         // REU space; base is $01000000
    sta cb+UA_ADDR+0
    lda #((reuOfs>>16)&$ff)
    sta cb+UA_ADDR+1
    lda #((reuOfs>>8)&$ff)
    sta cb+UA_ADDR+2
    lda #(reuOfs&$ff)
    sta cb+UA_ADDR+3

    lda #((len>>16)&$ff)
    sta cb+UA_LEN+0
    lda #((len>>8)&$ff)
    sta cb+UA_LEN+1
    lda #(len&$ff)
    sta cb+UA_LEN+2

    lda #0                            // repeat point A = 0 (the start)
    sta cb+UA_REPA+0
    sta cb+UA_REPA+1
    sta cb+UA_REPA+2
    lda #((len>>16)&$ff)              // repeat point B = len -- loop the lot
    sta cb+UA_REPB+0
    lda #((len>>8)&$ff)
    sta cb+UA_REPB+1
    lda #(len&$ff)
    sta cb+UA_REPB+2

    lda #((rateDiv>>8)&$ff)
    sta cb+UA_RATE+0
    lda #(rateDiv&$ff)
    sta cb+UA_RATE+1

    lda #ctrl                         // gate last: this is what starts it
    sta cb+UA_CTRL
}

//------------------------------------------------------------
// uaStop(chan) — clear the gate bit. The sample stops where it is.
//------------------------------------------------------------
.macro uaStop(chan) {
    lda #0
    sta UA_BASE + chan*UA_STRIDE + UA_CTRL
}

//============================================================
//  sidtest.asm — do SID register writes survive a 64 MHz CPU?
//
//  The question, from IMPLEMENTATION_PLAN.md's audio discussion: the SID
//  is a 1 MHz device on a bus the engine drives at 64 MHz. A music player
//  writes ~25 registers back to back; at speed index 15 that whole burst
//  takes under half a microsecond of bus time. If the Ultimate does not
//  stretch or queue those writes, some of them are lost, and the failure
//  looks like "the tune is subtly wrong" rather than like an error.
//
//  Method, and the reason it needs no ears and no capture card: voice 3's
//  oscillator is READABLE at $d41b (the top 8 bits of its 24-bit phase
//  accumulator), while bit 7 of $d418 disconnects voice 3 from the audio
//  output. So the chip can be interrogated in silence.
//
//  The oscillator's accumulator advances by the programmed frequency once
//  per phi2 cycle. With freq = $0400:
//
//      $d41b = (($0400 * t) >> 16) & $ff = (t >> 6) & $ff
//
//  and CIA 2 timer B ticks once per MS_TICKS = 1000 phi2 cycles, so
//
//      $d41b advances 1000/64 = 15.625 per tick, exactly.
//
//  That prediction contains no clock constant: CIA and SID are both fed
//  from phi2, so it holds at 985248 Hz (PAL) as written and does not care
//  what the CPU is doing.
//
//  The oscillator is released at some unknown phase within a timer B tick,
//  so the ABSOLUTE samples carry an offset of up to 15.6 units that is not a
//  fault. Their DIFFERENCES do not: each sample is taken at the instant the
//  tick counter reaches its target, so consecutive samples are a whole number
//  of ticks apart. Sampling at 1, 2, 4 and 8 ticks therefore has to step by
//  16, 31 and 63, on any machine whose SID got the frequency it was sent.
//  That is what tools/sidtest.py checks, and why it samples four times
//  instead of once.
//
//  The TEST bit ($d412 bit 3) zeroes the accumulator and holds it there, so
//  each pass has an exact t = 0: the write that clears TEST. Everything the
//  burst does before that is invisible to the measurement, which is what
//  makes the four variants comparable.
//
//  Four write patterns, each run at 1 MHz and again at 64 MHz:
//
//      0  spaced     one register at a time with a delay between -- the
//                    baseline, the way that cannot fail
//      1  tight      freq lo, freq hi, control, back to back
//      2  burst      all 25 registers in one run, as a player writes them
//      3  hammer     that burst eight times over, TEST released only on
//                    the last -- the overload case
//
//  A 64 MHz row that matches its 1 MHz row means the writes landed. A row
//  that reads ~0 means the frequency never reached the chip. A row that
//  reads 64x the prediction would mean the SID is clocked from the turbo
//  clock, which would be its own kind of interesting.
//
//  Results are left in RAM at RESULTS for the host to DMA out;
//  tools/sidtest.py prints the table. After the measurement the program
//  plays two seconds of audible tone, so that "the SID answers" and "sound
//  comes out of the machine" are two separate observations.
//============================================================

#import "defs.asm"

.const RESULTS   = $0c00

.const SIDBASE   = $d400
.const V3FREQLO  = $d40e
.const V3FREQHI  = $d40f
.const V3CTRL    = $d412
.const SIDMODE   = $d418            // bit 7 = voice 3 off, low nibble = volume
.const OSC3      = $d41b

// Voice 3's test frequency. $0400 puts 15.625 $d41b steps in a timer B tick,
// so the eight-tick sample lands at 125 -- a big number, well clear of the
// noise floor, and still short of the 256 that would wrap.
.const F_LO      = $00
.const F_HI      = $04
.const SAW       = $20              // sawtooth, gate off (the envelope is not
.const SAW_TEST  = $28              // in play), TEST set = accumulator held

// Eight consecutive ticks rather than a spread of 1/2/4/8. Consecutive
// samples make the per-tick advance directly readable and repeated eight
// times over, so "the SID got the frequency" and "the sample landed where
// the wait says it did" are separable. A spread was tried first and could
// not tell those apart.
.const NSAMPLE   = 8                // samples per pass
.const NVARIANT  = 6

// zero page — nothing else is running
.const zSlot     = $02              // result slot being filled
.const zVar      = $03              // variant index
.const zRefLo    = $04              // timer B at t = 0
.const zRefHi    = $05
.const zNowLo    = $06
.const zNowHi    = $07
.const zK        = $08              // sample index
.const zFLo      = $09              // the frequency this pass writes
.const zFHi      = $0a

.pc = $0801 "basic"
:BasicUpstart2(sidtest)

.pc = $0810 "code"
sidtest:
        sei
        lda #BANK_IO
        sta $01
        lda #0
        sta $d020
        sta $d021
        lda #$0b                    // blank the screen: no badlines, so the
        sta $d011                   // 1 MHz pass is not sampled through the
                                    // VIC's cycle stealing

        ldx #0                      // clear the results block
        txa
!:      sta RESULTS,x
        inx
        bne !-                      // the whole $0c00 page: 8 slots x 8 samples
                                    // plus the same again for the tick log
        lda #'S'
        sta RESULTS+0
        lda #'T'
        sta RESULTS+1
        lda #1
        sta RESULTS+2

        jsr ciaInit
        jsr sidSilence

        lda #TURBO_1MHZ             // ---- pass 1: 1 MHz ----
        sta TURBOREG
        lda #0
        sta zSlot
        jsr runVariants

        lda #TURBO_1MHZ             // ---- pass 2: 64 MHz ----
        sta TURBOREG                // disable then enable; see main.asm
        lda #TURBO_MAX
        sta TURBOREG
        lda #NVARIANT
        sta zSlot
        jsr runVariants

        lda #TURBO_1MHZ             // the trace is a 1 MHz measurement: it
        sta TURBOREG                // needs the oscillator to move a unit or
        jsr traceAll                // two between consecutive reads

        lda #$ff
        sta RESULTS+3               // done flag, written last

        jsr tone                    // audible proof of life, then silence
        lda #$1b                    // screen back on: not a dead machine
        sta $d011
        jmp *

//------------------------------------------------------------
// runVariants — the four write patterns at whatever speed is set now,
// filling four result slots from zSlot upwards.
//------------------------------------------------------------
runVariants:
        lda #0
        sta zVar
rvLoop:
        jsr onePass
        inc zSlot
        inc zVar
        lda zVar
        cmp #NVARIANT
        bne rvLoop
        rts

//------------------------------------------------------------
// onePass — freeze the oscillator, run variant zVar's write burst, then
// sample $d41b at 1, 2, 4 and 8 timer B ticks after TEST was released.
//
// The samples go to RESULTS + 8 + zSlot*4 + k. Four slots per speed, so the
// host reads two four-row tables and compares them.
//------------------------------------------------------------
onePass:
        lda #SAW_TEST               // accumulator to zero and held there
        sta V3CTRL
        lda #0
        sta V3FREQLO
        sta V3FREQHI

        lda zVar                    // this pass's frequency, into both the
        asl                         // direct writers and the register table
        tax
        lda freqTab,x
        sta zFLo
        sta regTab+14
        lda freqTab+1,x
        sta zFHi
        sta regTab+15

        lda vtabLo,x                // dispatch: the burst is the experiment
        sta vJsr+1
        lda vtabLo+1,x
        sta vJsr+2
vJsr:   jsr burst0                  // patched above

        jsr tbRead                  // t = 0 is the write that cleared TEST
        lda zNowLo
        sta zRefLo
        lda zNowHi
        sta zRefHi

        lda #0
        sta zK
opSample:
        ldy zSlot                   // destination = RESULTS + 16 + slot*8 + k,
        lda slotBase,y              // worked out before the wait so that the
        clc                         // sample follows the deadline immediately
        adc zK
        sta opDest+1
        clc
        adc #128                    // the elapsed-tick log, half a page up --
        sta opDest2+1               // clear of the samples, which now reach 111
        ldx zK
        lda tickTab,x
        jsr waitTicks               // returns with X = elapsed ticks, low byte
        lda OSC3
opDest: sta RESULTS                 // low byte patched above
        txa                         // and what the wait actually waited: a
opDest2:                            // sample is only worth as much as the
        sta RESULTS                 // interval it was taken over
        inc zK
        lda zK
        cmp #NSAMPLE
        bne opSample
        rts

// Byte offset of each slot's first sample from RESULTS, so the inner loop
// needs no multiply. Samples occupy RESULTS+16 to RESULTS+111; the matching
// elapsed-tick log sits 128 bytes above each, at RESULTS+144 upwards. Twelve
// slots: six write patterns at 1 MHz, the same six at 64 MHz.
slotBase:
        .byte 16, 24, 32, 40, 48, 56          // 1 MHz:  variants 0-5
        .byte 64, 72, 80, 88, 96, 104         // 64 MHz: the same six

tickTab:
        .byte 1, 2, 3, 4, 5, 6, 7, 8

vtabLo: .word burst0, burst1, burst2, burst3, burst0, burst0

// Variants 0-3 are four ways of writing the SAME frequency, which is the
// experiment: does the write pattern change what the chip receives?
//
// Variants 4 and 5 are the control. They are the same spaced writes as
// variant 0 at half and at double the frequency, and the oscillator has to
// respond in proportion. Without them a run in which every write was dropped
// would show four identical rows and be reported as a pass -- the failure
// this whole file exists to catch is precisely one that leaves no trace.
//
// The proportionality, not the absolute rate, is what is checked. The rate
// depends on the tick period and on the SID's clock, and a test that has to
// get both of those right to be believed is a test with two more ways to be
// wrong than it needs.
freqTab:
        .word $0400, $0400, $0400, $0400, $0200, $0800

//------------------------------------------------------------
// The four write patterns. Every one must end by releasing TEST, because
// that write is the measurement's t = 0; anything it does before then is
// invisible to the oscillator and therefore free.
//------------------------------------------------------------

// 0 — spaced. One register at a time, with a delay long enough that even a
// SID bus with no write buffering at all has settled between them. This is
// the row every other row is compared against.
burst0:
        lda zFLo
        sta V3FREQLO
        jsr sidDelay
        lda zFHi
        sta V3FREQHI
        jsr sidDelay
        lda #SAW
        sta V3CTRL
        rts

// 1 — tight. The same three writes with nothing between them. At 64 MHz
// this is three stores in ~0.1 us.
burst1:
        lda zFLo
        sta V3FREQLO
        lda zFHi
        sta V3FREQHI
        lda #SAW
        sta V3CTRL
        rts

// 2 — burst. All 25 registers in ascending order, which is what a player
// does. TEST clears at register 18 ($d412); the six writes after it are
// still inside the measurement, but at 1 MHz they cost 30 us = 0.03 of a
// tick and at 64 MHz effectively nothing.
burst2:
        ldx #0
b2Loop: lda regTab,x
        sta SIDBASE,x
        inx
        cpx #25
        bne b2Loop
        rts

// 3 — hammer. That burst eight times back to back. The first seven passes
// write control with TEST still set, so the oscillator stays at zero and
// only the last pass starts the clock; without that the earlier releases
// would each start a measurement of their own.
burst3:
        ldy #8
b3Loop: lda #SAW_TEST
        cpy #1
        bne b3Set
        lda #SAW
b3Set:  sta regTab+18
        ldx #0
b3Inner:
        lda regTab,x
        sta SIDBASE,x
        inx
        cpx #25
        bne b3Inner
        dey
        bne b3Loop
        rts                         // the last pass left SAW in the table,
                                    // which is what burst2 needs to find

// A plausible player's-eye view of the chip: two voices set up and audible-
// looking, voice 3 carrying the test frequency, master volume 0 and voice 3
// disconnected so the whole measurement is silent. Offsets 14-20 are voice 3
// (freq lo/hi, pw lo/hi, control, attack-decay, sustain-release); 24 is the
// filter mode and volume register.
regTab:
        .byte $10, $20               // v1 freq
        .byte $00, $08               // v1 pulse width
        .byte $41                    // v1 control: pulse, gate on
        .byte $09, $00               // v1 ad, sr
        .byte $30, $30               // v2 freq
        .byte $00, $08               // v2 pw
        .byte $21                    // v2 control: saw, gate on
        .byte $09, $00               // v2 ad, sr
        .byte F_LO, F_HI             // v3 freq -- the one being measured
        .byte $00, $08               // v3 pw
        .byte SAW                    // v3 control -- patched by burst3, which
                                     // leaves it as it found it
        .byte $09, $00               // v3 ad, sr
        .byte $00, $00               // filter cutoff lo/hi
        .byte $00                    // filter resonance/routing
        .byte $80                    // voice 3 off, volume 0

//------------------------------------------------------------
// traceAll — 64 consecutive reads of $d41b for each of the three
// frequencies, straight into TRACE, with a fixed delay between reads.
//
// This is the diagnostic that has to come before any conclusion drawn from
// the tables above: those measure the oscillator's rate through a model of
// what the rate should be, and a model is exactly what cannot be trusted
// here. A trace is the waveform itself. A sawtooth at $0400 must show a
// slow ramp that wraps; $0800 must ramp twice as fast and $0200 half. If
// the three traces look alike, the frequency register is not reaching the
// chip and nothing else in this file means anything.
//
// At 1 MHz with freq $0400 the accumulator advances 0.0156 per cycle, so
// TRACE_DELAY's ~125 cycles put roughly two units between samples.
//------------------------------------------------------------
.const TRACE       = $0d00
.const TRACE_DELAY = 25

traceAll:
        lda #0                      // $0d00: freq $0400 (variant 0)
        ldy #0
        jsr traceOne
        lda #8                      // $0d40: freq $0200 (variant 4)
        ldy #64
        jsr traceOne
        lda #10                     // $0d80: freq $0800 (variant 5)
        ldy #128
        jsr traceOne
        rts

// A = the byte offset of the wanted entry in freqTab, Y = where in TRACE.
traceOne:
        sty trDest+1
        tax
        lda freqTab,x
        sta zFLo
        lda freqTab+1,x
        sta zFHi

        lda #SAW_TEST               // accumulator to zero and held
        sta V3CTRL
        lda zFLo
        sta V3FREQLO
        lda zFHi
        sta V3FREQHI
        lda #SAW                    // released here
        sta V3CTRL

        ldx #0
trLoop: lda OSC3
trDest: sta TRACE,x                 // low byte patched above
        ldy #TRACE_DELAY
trDly:  dey
        bne trDly
        inx
        cpx #64
        bne trLoop
        rts

//------------------------------------------------------------
// sidDelay — long enough that a SID write cannot still be in flight.
// ~1300 cycles, i.e. 1.3 ms at 1 MHz and 20 us at 64 MHz.
//------------------------------------------------------------
sidDelay:
        ldy #0
sdLoop: dey
        bne sdLoop
        rts

//------------------------------------------------------------
// sidSilence — every register zeroed, then volume 0 with voice 3
// disconnected. Nothing may be left over from the ROM or a previous run.
//------------------------------------------------------------
sidSilence:
        ldx #24
        lda #0
ssLoop: sta SIDBASE,x
        dex
        bpl ssLoop
        lda #$80
        sta SIDMODE
        rts

//------------------------------------------------------------
// tone — two seconds of audible sawtooth on voice 1, so that a silent
// machine and a machine whose SID is not wired to the output are
// distinguishable from the results table alone. Voice 3 stays disconnected.
//
// $1d45 is 440 Hz on PAL: 440 * 2^24 / 985248.
//------------------------------------------------------------
tone:
        lda #$45
        sta SIDBASE+0
        lda #$1d
        sta SIDBASE+1
        lda #$00
        sta SIDBASE+5               // attack 0, decay 0
        lda #$f0
        sta SIDBASE+6               // sustain 15, release 0
        lda #$8f                    // volume 15, voice 3 still disconnected
        sta SIDMODE
        lda #$21                    // sawtooth, gate on
        sta SIDBASE+4

        jsr tbRead
        lda zNowLo
        sta zRefLo
        lda zNowHi
        sta zRefHi
tnWait: jsr tbRead                  // ~2 s = 2000 ticks; the 16-bit wait below
        lda zRefLo                  // handles it without the byte-wide shortcut
        sec
        sbc zNowLo
        tax
        lda zRefHi
        sbc zNowHi
        cmp #>2000
        bcc tnWait
        bne tnDone
        cpx #<2000
        bcc tnWait
tnDone: jsr sidSilence
        rts

//------------------------------------------------------------
// CIA 2 as a tick counter — the same cascade clock.asm sets up in the
// engine, and for the same reason: it runs at phi2 whatever the CPU is
// doing, so it is the only timebase that means the same thing in both
// passes. Timer B counts down from $ffff, one tick per MS_TICKS phi2
// cycles.
//
// $dd0d is cleared first because sei does not mask NMI and CIA 2 is the
// C64's NMI source.
//------------------------------------------------------------
ciaInit:
        lda #$7f
        sta CIA2_ICR
        lda #<MS_TICKS
        sta CIA2_TALO
        lda #>MS_TICKS
        sta CIA2_TAHI
        lda #$ff
        sta CIA2_TBLO
        sta CIA2_TBHI
        lda #%00010001              // A: force load, start, continuous, phi2
        sta CIA2_CRA
        lda #%01010001              // B: force load, start, continuous,
        sta CIA2_CRB                //    counting A's underflows
        rts

// tbRead — timer B into zNow, retrying on a torn read.
tbRead:
!:      lda CIA2_TBHI
        sta zNowHi
        lda CIA2_TBLO
        sta zNowLo
        lda CIA2_TBHI
        cmp zNowHi
        bne !-
        rts

// waitTicks — spin until A ticks have elapsed since zRef. The timer counts
// down, so elapsed = zRef - now. Every wait here is under 256 ticks, so a
// nonzero high byte means the deadline is long past.
waitTicks:
        sta wtTarget
wtLoop: jsr tbRead
        lda zRefLo
        sec
        sbc zNowLo
        tax
        lda zRefHi
        sbc zNowHi
        bne wtDone
        cpx wtTarget
        bcc wtLoop
wtDone: rts
wtTarget:
        .byte 0

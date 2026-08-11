//============================================================
//  intro.asm — Doom C64U title screen.
//
//  Phase 1: show doom-title.kla (a Koala Painter multicolor bitmap,
//  assets/doom-title.kla) and loop "04 - Intermission From Doom" through
//  the Ultimate's hardware PCM sampler (ultaudio.asm) while the machine
//  waits for space.
//
//  Deliberately its own program in its own source directory (src/intro/),
//  separate from the engine in src/: it shares no memory map, no build
//  artifact and no REU image with build/doom.prg. The two are pushed to
//  hardware independently (see the Makefile's `intro` / `run-intro-u64`
//  targets), and the chain from this screen into the game -- press space,
//  load doom.prg and its REU image -- is the next phase, along with the
//  id Software and Hondani logos; this file stops at making space visible
//  and leaves the load for later.
//
//  The picture is small enough (10003 B) to sit in the PRG image
//  directly, at the addresses Koala Painter itself used for it. The
//  music is not: 173 seconds of 8-bit stereo PCM at 22050 Hz is ~7.6 MB,
//  decoded offline by tools/mp3topcm.py into build/intro.reu and read by
//  the Ultimate's own sampler hardware straight out of REU -- the 6502
//  never touches a sample (see ultaudio.asm).
//============================================================

#import "defs.asm"
#import "ultaudio.asm"
#import "intro-audio.asm"            // AUDIO_LEN, AUDIO_RATE -- generated
                                      // by tools/mp3topcm.py, found via
                                      // -libdir build (the Makefile)

.pc = $0801 "basic"
:BasicUpstart2(intro)

// The Koala file's own layout: bitmap $6000-$7F3F (8000 B), then screen
// and colour RAM immediately after it *in the file*, at $7F40 and $8328.
// Those file addresses are not display-ready, though: colour data has to
// reach the VIC's fixed $D800, and $7F40 falls *inside* the bitmap's own
// 8K span ($6000-$7FFF, offset $2000 of VIC bank 1) -- the bitmap takes
// the whole upper half of the bank, so a screen block has to live in the
// lower half instead, not merely at some other $400 boundary. So only the
// bitmap is imported to its native address; the screen goes to $4000
// (offset 0 of the same bank) and the colour+background bytes go to
// scratch RAM at $9000, copied into place by intro's startup code below.
.pc = $6000 "koala bitmap"
.import binary "../../assets/doom-title.kla", 2, 8000

.pc = $4000 "koala screen"
.import binary "../../assets/doom-title.kla", 8002, 1000

.pc = $9000 "koala colour + bg"      // 1000 B colour RAM, then 1 B background
koalaColor:
.import binary "../../assets/doom-title.kla", 9002, 1001

.pc = $0810 "code"
intro:
        sei
        lda #BANK_IO
        sta $01
        jsr turboOn

        lda $dd00                    // VIC bank 1 ($4000-$7fff): bitmap
        and #%11111100                // and screen both land inside it
        ora #%00000010
        sta $dd00

        lda #%00001000                // $D018: screen $4000 (bank offset
        sta $d018                     // 0), bitmap $6000 (bank offset
        lda #$3b                      // $2000, bit3=1)
        sta $d011                     // bitmap mode on
        lda #$18
        sta $d016                     // multicolor on
        lda #2
        sta $d020                     // border: red
        lda koalaColor+1000
        sta $d021                     // background, from the file's own byte

        ldx #0                        // colour RAM: $9000-$93E7 -> $D800,
!:      lda koalaColor,x              // 1000 bytes as 4 overlapping
        sta $d800,x                   // 250-byte strides (main.asm's
        lda koalaColor+250,x          // clearHudRows does the same trick)
        sta $d800+250,x
        lda koalaColor+500,x
        sta $d800+500,x
        lda koalaColor+750,x
        sta $d800+750,x
        inx
        cpx #250
        bne !-

        // Title music, looping. The sample is mono (tools/mp3topcm.py), so
        // both channels read the *same* bytes from the same REU offset and
        // differ only in pan -- hard left and hard right. The sampler's
        // "interleave" bit, which would let two channels share one stereo
        // buffer a byte apart, is therefore off: there is one stream here,
        // played twice, not two streams sharing a buffer. Mono halves the
        // image to 3.6 MB, which is a shorter wait whichever way it gets in.
        :uaLoad(0, 0, AUDIO_LEN, AUDIO_RATE, 63, 0,  0, 1)   // left
        :uaLoad(1, 0, AUDIO_LEN, AUDIO_RATE, 63, 15, 0, 1)   // right

waitSpace:
        lda #%01111111                // row 7 -- space is PA7/PB4 on the
        sta $dc00                     // standard C64 keyboard matrix
        lda $dc01
        and #%00010000
        bne waitSpace

        // Next phase: stop the music and chain-load doom.prg + its REU
        // image. Not implemented yet -- say so and stop, visibly.
        :uaStop(0)
        :uaStop(1)
        lda #0                        // border red -> black: space seen,
        sta $d020                     // nothing downstream of it yet
spaceHalt:
        jmp spaceHalt

//------------------------------------------------------------
// turboOn — see src/main.asm; duplicated rather than shared (see the
// header of defs.asm).
//------------------------------------------------------------
turboOn:
        lda #TURBO_1MHZ
        sta TURBOREG
        lda #TURBO_MAX
        sta TURBOREG
        rts

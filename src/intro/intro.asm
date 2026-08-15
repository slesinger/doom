//============================================================
//  intro.asm — Doom C64U launcher: Hondani logo, title screen, game.
//
//  Phase 1: a Hondani logo (assets/hondani-logo-placeholder.kla -- a
//  stand-in until Honza supplies the real artwork) wipes onto the screen
//  top-to-bottom over about a second, holds for a couple of seconds, and
//  auto-advances. There is no skip: this is deliberate (see below).
//
//  Phase 2: doom-title.kla and looping PCM music (ultaudio.asm), exactly
//  as before, until space is pressed.
//
//  Phase 3: NEW. Space no longer halts. It fetches the game's code out of
//  the merged REU image (build/game.reu, GAMECODE block -- see
//  tools/build_launcher_reu.py and build/game-layout.asm) straight into
//  RAM at $0810 and jumps in. The game is never present as a loadable
//  file of its own -- this program is the only door to it, and it always
//  opens onto the logo first. That is deliberate too: Honza wants it
//  "difficult to tear apart" (see IMPLEMENTATION_PLAN's launcher plan).
//
//  Still its own program in its own source directory (src/intro/): it
//  shares no memory map with build/doom.prg's *code*, only the merged
//  REU image the two are now built into together (see the Makefile's
//  `launcher` / `game.reu` targets). See also docs/reu-format.md's
//  "outer envelope" appendix.
//
//  Both pictures are small enough (10003 B each) to sit in the PRG image
//  directly, at addresses Koala Painter itself used for them. The title
//  music is not: 173 seconds of 8-bit mono PCM at 22050 Hz is ~3.6 MB,
//  decoded offline by tools/mp3topcm.py and read by the Ultimate's own
//  sampler hardware straight out of REU -- the 6502 never touches a
//  sample (see ultaudio.asm).
//============================================================

#import "defs.asm"
#import "ultaudio.asm"
#import "intro-audio.asm"            // AUDIO_LEN, AUDIO_RATE -- generated
                                      // by tools/mp3topcm.py, found via
                                      // -libdir build (the Makefile)
#import "game-layout.asm"            // GAMECODE_*, INTROMUSIC_* -- generated
                                      // by tools/build_launcher_reu.py, same
                                      // -libdir build

//------------------------------------------------------------
// Zero-page scratch pointers -- unused by anything else here (interrupts
// are masked for the whole run: `sei` below, never cleared), so no
// conflict with KERNAL/BASIC's own use of this range is possible.
//
// Plain .const addresses, like defs.asm's zRXt, not a `*=`-placed .word
// label: KickAssembler's PRG writer uses the *lowest* address touched by
// the Default segment as the file's own load-address header, and a real
// (data-emitting) segment down in zero page would hijack that header
// away from $0801 -- silently breaking :BasicUpstart2 and, with it,
// VICE's/the KERNAL's autostart (found the hard way: a JAM at $0008 from
// an autostart injector that trusted the corrupted header). A bare
// .const never emits a byte, so it can't do that -- these three are pure
// runtime scratch RAM, written only by the wipe/clear routines below.
//
// $f9-$fe, not $fb-$100: three word-pointers is 6 bytes, and $fb would
// run the last one off the end of zero page at $ff/$100 -- (zp),y
// addressing wraps *within* page 0 for the high byte, so a pointer
// straddling $ff/$100 would silently read its high byte from $00 instead.
.const srcPtr = $f9                  // + $fa
.const dstPtr = $fb                  // + $fc
.const clrPtr = $fd                  // + $fe
.const trampolineDest = $02          // 8 B, $02-$09 -- see chainToGame's
                                      // tail. $00/$01 are the CPU port
                                      // (banking control), never touched.

.pc = $0801 "basic"
:BasicUpstart2(intro)

//------------------------------------------------------------
// Hondani logo -- wipe-reveal.
//
// The Koala file's bitmap is imported to a *staging* address, not the VIC
// bank it will eventually display from: the wipe works by copying it into
// the display bank a cell-row (320 B) at a time, once every couple of
// frames, while the display bank's own copy starts all-zero (see
// clearLogoBitmap below). A bitmap byte of 0 is pixel-value 00 in
// multicolor mode, i.e. plain $D021 background -- so the not-yet-copied
// rows just look like a blank background colour, not garbage, and the
// screen/colour RAM (which select the *other* three pixel colours) can be
// in place from frame 1 with nothing to show yet.
//
// Bank 2 ($8000-$BFFF) rather than bank 1 (used by the title screen,
// below) because both pictures are baked into the same PRG at compile
// time and can't share addresses. $A000-$BFFF is ordinary RAM here, not
// BASIC ROM: BANK_IO ($01=$35, LORAM=1/HIRAM=0/CHAREN=1) banks it out,
// same config main.asm relies on for RAM at $E000+ (src/defs.asm).
//------------------------------------------------------------
.const LOGOSTAGE  = $1000            // 8000 B, plain RAM, not VIC-mapped
.const LOGOSCREEN = $8000            // bank 2 offset 0
.const LOGOFINAL  = $a000            // bank 2 offset $2000 -- final bitmap
.const LOGOROWS   = 25               // 320x200 multicolor = 25 cell-rows
.const LOGOROWBYTES = 320            // one cell-row of the bitmap
.const LOGOHOLD   = 250              // ~5s @ 50 Hz after the wipe finishes

.pc = LOGOSTAGE "hondani bitmap (staged)"
.import binary "../../assets/hondani-logo-placeholder.kla", 2, 8000

.pc = LOGOSCREEN "hondani screen"
.import binary "../../assets/hondani-logo-placeholder.kla", 8002, 1000

.pc = $9800 "hondani colour + bg"    // scratch, like koalaColor below --
hondaniColor:                        // deliberately outside $8000-$BFFF's
.import binary "../../assets/hondani-logo-placeholder.kla", 9002, 1001
                                      // bank-2 span so it can't collide
                                      // with LOGOSCREEN or LOGOFINAL

// The title Koala file's own layout: bitmap $6000-$7F3F (8000 B), then
// screen and colour RAM immediately after it *in the file*, at $7F40 and
// $8328. Those file addresses are not display-ready, though: colour data
// has to reach the VIC's fixed $D800, and $7F40 falls *inside* the
// bitmap's own 8K span ($6000-$7FFF, offset $2000 of VIC bank 1) -- the
// bitmap takes the whole upper half of the bank, so a screen block has to
// live in the lower half instead, not merely at some other $400 boundary.
// So only the bitmap is imported to its native address; the screen goes
// to $4000 (offset 0 of the same bank) and the colour+background bytes go
// to scratch RAM at $9000, copied into place by intro's startup code
// below.
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

        //------------------------------------------------------------
        // Phase 1: Hondani logo, wipe-reveal, auto-advancing, no skip.
        //------------------------------------------------------------
        jsr clearLogoBitmap           // blank the display bank first --
                                       // it's uninitialised RAM otherwise

        lda $dd00                     // VIC bank 2 ($8000-$bfff): screen
        and #%11111100                 // and bitmap both land inside it
        ora #%00000001
        sta $dd00

        lda #%00001000                // $D018: screen $8000 (bank offset
        sta $d018                     // 0), bitmap $a000 (bank offset
        lda #$3b                      // $2000, bit3=1)
        sta $d011                     // bitmap mode on
        lda #$18
        sta $d016                     // multicolor on
        lda #2
        sta $d020                     // border: red, same as the title
        lda hondaniColor+1000
        sta $d021                     // background, from the file's own byte

        ldx #0                         // colour RAM: $9800-$9BE7 -> $D800,
!:      lda hondaniColor,x              // same 4x250-byte-stride trick as
        sta $d800,x                    // the title screen, below
        lda hondaniColor+250,x
        sta $d800+250,x
        lda hondaniColor+500,x
        sta $d800+500,x
        lda hondaniColor+750,x
        sta $d800+750,x
        inx
        cpx #250
        bne !-

        lda #<LOGOSTAGE
        sta srcPtr
        lda #>LOGOSTAGE
        sta srcPtr+1
        lda #<LOGOFINAL
        sta dstPtr
        lda #>LOGOFINAL
        sta dstPtr+1
        ldx #LOGOROWS
logoWipeRow:
        ldy #0                         // copy 320 B: a 256 B page, then 64
!:      lda (srcPtr),y                 // more -- (zp),y can't span past
        sta (dstPtr),y                 // 256 in one pass
        iny
        bne !-
        inc srcPtr+1
        inc dstPtr+1
        ldy #0
!:      lda (srcPtr),y
        sta (dstPtr),y
        iny
        cpy #(LOGOROWBYTES-256)
        bne !-
        clc                            // advance both pointers the
        lda srcPtr                     // remaining 64 B for next row
        adc #(LOGOROWBYTES-256)
        sta srcPtr
        bcc !+
        inc srcPtr+1
!:      clc
        lda dstPtr
        adc #(LOGOROWBYTES-256)
        sta dstPtr
        bcc !+
        inc dstPtr+1
!:      jsr waitFrame                  // pace the reveal: one row every
        jsr waitFrame                  // two frames, ~1s total for 25 rows
        dex
        bne logoWipeRow

        ldx #LOGOHOLD                  // hold the finished logo a couple
!:      jsr waitFrame                  // of seconds before auto-advancing
        dex
        bne !-

        //------------------------------------------------------------
        // Phase 2: the title screen, unchanged from before this file
        // grew a logo -- just re-banks the VIC to bank 1 and switches
        // the bitmap/screen/colour source over to the title's own copy.
        //------------------------------------------------------------
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
        // reuOfs is INTROMUSIC_REUOFS, not 0: the PCM now lives inside the
        // merged game.reu at that offset, not in its own standalone image
        // (build/game-layout.asm, generated by tools/build_launcher_reu.py).
        :uaLoad(0, INTROMUSIC_REUOFS, AUDIO_LEN, AUDIO_RATE, 63, 0,  0, 1)   // left
        :uaLoad(1, INTROMUSIC_REUOFS, AUDIO_LEN, AUDIO_RATE, 63, 15, 0, 1)   // right

waitSpace:
        lda #%01111111                // row 7 -- space is PA7/PB4 on the
        sta $dc00                     // standard C64 keyboard matrix
        lda $dc01
        and #%00010000
        bne waitSpace

        //------------------------------------------------------------
        // Phase 3: chain into the game. Stop the music, fetch GAMECODE
        // out of the merged REU straight into RAM at $0810, and jump in.
        // No reset happens in between (main.asm's bootMain has been
        // audited for that -- see IMPLEMENTATION_PLAN's launcher plan,
        // §3), and there is no PRG file to load: the game only ever
        // exists as this REU payload, reachable only from here.
        //
        // chainToGame is a named entry point for tools/vicedbg/
        // launcherhash.py only: it drives the merged path under the VICE
        // monitor by jumping the emulated PC here directly, the automated
        // stand-in for a real space press, so `make framehash-launcher`
        // can prove the warm-jumped game matches the cold-booted one
        // without needing real keyboard input.
        //------------------------------------------------------------
chainToGame:
        :uaStop(0)
        :uaStop(1)
        lda #0
        sta $d020                     // border red -> black: space seen

        ldx #$ff                      // cheap insurance -- the game has
        txs                           // never run from anything but a
                                       // real reset before this

        // bootMain (main.asm) has plenty of zero-page scratch that is
        // written before it is ever read within a frame -- but not all of
        // it turns out to be, and this program has already been running in
        // zero page (the logo/title wipes' srcPtr/dstPtr/clrPtr, this very
        // chain-in's own scratch) long enough to leave it looking nothing
        // like a fresh boot's. A real cold reset doesn't clear RAM either
        // -- so this isn't papering over a VICE-only quirk, it's making
        // the warm path match the *documented* assumption bootMain already
        // runs on. Found the hard way: framehash-launcher and framehash
        // matched exactly once this went in, and differed in ~150 zero-page
        // bytes by the time mainLoop first ran without it.
        //
        // $0a-$ff only: $00/$01 are the CPU port, and $02-$09 are about to
        // hold the trampoline below, which bootMain's own zA/zB/zP (also
        // $02-$09) overwrite before use every time they're touched.
        lda #0
        ldx #$0a
!:      sta $00,x
        inx
        bne !-

        // reuProbe/reuInit (src/reu.asm) haven't run yet -- that's part of
        // bootMain, still ahead of us -- so REU_ADDRCTL is whatever the
        // hardware/emulator left it as, not guaranteed 0. A stale "fix REU
        // addr" bit there turns the fetch below into 51182 copies of one
        // byte (found the hard way: every byte in RAM came out as the
        // REU's very first byte, $4c). Zero it explicitly rather than
        // trust the power-on default, same as reuInit does.
        lda #0
        sta REU_ADDRCTL

        lda #<$0810
        sta REU_C64ADDR
        lda #>$0810
        sta REU_C64ADDR+1
        lda #<GAMECODE_REUADDR
        sta REU_REUADDR
        lda #>GAMECODE_REUADDR
        sta REU_REUADDR+1
        lda #GAMECODE_BANK
        sta REU_BANK
        lda #<GAMECODE_LEN
        sta REU_LENGTH
        lda #>GAMECODE_LEN
        sta REU_LENGTH+1

        // The trigger + jmp can't run from here: GAMECODE is 51182+ B
        // starting at $0810, which reaches well past this very code (the
        // "code" segment is only $0810-~$0a19) -- the DMA would overwrite
        // the instructions triggering it, including the jmp below, mid-
        // flight. So they run from a small copy in zero page instead,
        // safely outside anything GAMECODE reaches (its lowest address is
        // $0810). Everything above this comment only stores to REU I/O
        // registers, never to $0810+, so it stays intact either way.
        ldx #0
!:      lda trampoline,x
        sta trampolineDest,x
        inx
        cpx #(trampolineEnd-trampoline)
        bne !-
        jmp trampolineDest

trampoline:
        lda #REU_FETCH
        sta REU_COMMAND                // DMA runs now; CPU halts until it's
                                        // done (src/reu.asm's header) -- the
                                        // very next instruction (also part
                                        // of this copy) sees the game's
                                        // code already in place at $0810
        jmp $0810
trampolineEnd:

//------------------------------------------------------------
// clearLogoBitmap — zero LOGOFINAL's 8192 B (32 pages; the real bitmap
// is only 8000 of them, the rest is harmless spare RAM in the same bank)
// before the VIC is ever banked onto it, so the wipe never shows a frame
// of power-on garbage.
//------------------------------------------------------------
clearLogoBitmap:
        lda #0
        sta clrPtr
        lda #>LOGOFINAL
        sta clrPtr+1
        ldx #32
!page:  ldy #0
        lda #0
!:      sta (clrPtr),y
        iny
        bne !-
        inc clrPtr+1
        dex
        bne !page-
        rts

//------------------------------------------------------------
// waitFrame — block until the next vertical blank. Not cycle-exact (no
// badline/DMA-sensitive work happens during the logo wipe, unlike the
// engine's own raster discipline), just a once-per-frame pace for a
// cosmetic effect.
//------------------------------------------------------------
waitFrame:
!:      lda $d012
        cmp #$f8
        bne !-
!:      lda $d012
        cmp #$f8
        beq !-
        rts

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

//============================================================
//  intro.asm — Doom C64U launcher: Hondani logo, title screen, game.
//
//  Phase 1: the real Hondani logo (assets/ilogo6.art -- hires, not the
//  old multicolor placeholder), on screen at once (no wipe-reveal --
//  it's baked into VIC bank 2 at its final display address by the
//  .import below, so there's nothing to build up frame by frame). Holds
//  static for ~1s, then a left-to-right "lightning" brightens the
//  artwork's red linework (white -> yellow -> light red -> back to red,
//  see logoLightning/sweepColumn below) for ~1s, then holds again for
//  ~1s before auto-advancing. There is no skip: this is deliberate (see
//  below).
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
//  Both pictures are small enough (9009 B for the Hondani logo's Advanced
//  Art Studio hires format, 10003 B for the Koala title screen) to sit in
//  the PRG image directly, at addresses each painter program itself used
//  for them. The title music is not: 173 seconds of 8-bit mono PCM at
//  22050 Hz is ~3.6 MB,
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
// $f9-$fe, not $fb-$100: two word-pointers is 4 bytes, and $fb would run
// the second one off the end of zero page at $ff/$100 -- (zp),y
// addressing wraps *within* page 0 for the high byte, so a pointer
// straddling $ff/$100 would silently read its high byte from $00 instead.
.const srcPtr = $f9                  // + $fa -- sweepColumn's row walk
.const dstPtr = $fb                  // + $fc -- sweepColumn's row walk

// logoLightning/sweepColumn scratch, single bytes (never used as a (zp),y
// pointer, so the $ff wrap above doesn't apply to these).
.const rampColor = $f0               // this step's replacement colour
.const colIndex  = $f1               // column sweepColumn is working on
.const zTmp      = $f2               // holds the computed lo nibble
.const frameF    = $f3               // lightning step counter
.const colStart  = $f4               // first column touched this step
.const colEnd    = $f5               // last column touched this step
.const colCount  = $f6               // colEnd-colStart+1, loop counter
.const savedX    = $f7               // running column across colLoop

.const trampolineDest = $02          // 8 B, $02-$09 -- see chainToGame's
                                      // tail. $00/$01 are the CPU port
                                      // (banking control), never touched.

.pc = $0801 "basic"
:BasicUpstart2(intro)

//------------------------------------------------------------
// Hondani logo -- hires, static, with a left-to-right "lightning" flash.
//
// Unlike the old multicolor placeholder (which wiped top-to-bottom out of
// a staging copy), assets/ilogo6.art is imported straight to its final
// VIC-bank addresses: KickAssembler's PRG writer places these bytes at
// LOGOBITMAP/LOGOSCREEN the moment the file loads, so there is nothing to
// build up frame by frame -- the picture is simply switched on.
//
// A *second* copy of the screen RAM (video matrix), hondaniScreenOrig, is
// imported to scratch memory and never modified. logoLightning/
// sweepColumn (below waitFrame) recolour LOGOSCREEN's live copy from that
// original for the flash, column by column, so nothing needs restoring by
// hand once the wave has passed a column -- it's just re-derived from the
// untouched original with that step's ramp colour.
//
// Hires, not multicolor: ilogo6.art is Advanced Art Studio's own format
// (2 B load address, 8000 B bitmap, 1000 B screen RAM/video matrix --
// confirmed against vice-3.7's artstudiodrv.c, whose ARTSTUDIO_SIZE is
// 9002+7; the 7 trailing bytes are the real editor's own padding/
// signature, not colour data, and are never imported here). Each screen
// RAM byte packs two colours for its 8x8 cell -- high nibble where the
// bitmap bit is 1, low nibble where it's 0 -- unlike Koala's multicolor
// format, which needs a separate 1000 B colour-RAM block and a global
// background byte. Checked against the actual file: every cell in this
// picture is some mix of nibble $0 (black) and $2 (red), which is what
// lets sweepColumn (below) get away with a single "replace red" rule.
//
// Bank 2 ($8000-$BFFF) rather than bank 1 (used by the title screen,
// below) because both pictures are baked into the same PRG at compile
// time and can't share addresses. $A000-$BFFF is ordinary RAM here, not
// BASIC ROM: BANK_IO ($01=$35, LORAM=1/HIRAM=0/CHAREN=1) banks it out,
// same config main.asm relies on for RAM at $E000+ (src/defs.asm).
//------------------------------------------------------------
.const LOGOSCREEN = $8000            // bank 2 offset 0 -- video matrix
.const LOGOBITMAP = $a000            // bank 2 offset $2000 -- bitmap
.const LOGOCOLS   = 40               // 320 px / 8 = 40 cell-columns
.const LOGOROWS   = 25               // 200 px / 8 = 25 cell-rows
.const LOGOHOLD1  = 50               // ~1s @ 50 Hz, static, before the flash
.const LOGOHOLD2  = 50               // ~1s @ 50 Hz, static, after the flash
.const LOGOFLASHSTEPS = LOGOCOLS + 6 // 40 columns + rampTable's 6-step
                                      // cool-down tail, ~0.9s @ 50 Hz -- see
                                      // logoLightning

.pc = LOGOBITMAP "hondani bitmap"
.import binary "../../assets/ilogo6.art", 2, 8000

.pc = LOGOSCREEN "hondani screen (live)"
.import binary "../../assets/ilogo6.art", 8002, 1000

.pc = $9800 "hondani screen (original, for the lightning sweep)"
hondaniScreenOrig:                   // never written after load -- the
.import binary "../../assets/ilogo6.art", 8002, 1000
                                      // source sweepColumn recolours from.
                                      // Well clear of LOGOSCREEN/LOGOBITMAP
                                      // ($8000-$83e7 and $a000-$bf3f).

// rampTable -- indexed by (this step's frame number - the column's own
// index), 0-6: how many steps ago the wavefront reached that column.
// White/yellow/light red at the front, then back to the artwork's own
// red -- see sweepColumn, which only ever substitutes for nibble value 2
// (red), so black nibbles (the letters' own fill/outline) never light up.
rampTable:
.byte 1, 1, 7, 7, 10, 10, 2          // white, white, yellow, yellow,
                                      // light red, light red, red (original)

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
        // Phase 1: Hondani logo -- static, lightning flash, static,
        // auto-advancing, no skip. See the comment above LOGOSCREEN.
        //------------------------------------------------------------
        lda $dd00                     // VIC bank 2 ($8000-$bfff): screen
        and #%11111100                 // and bitmap both land inside it
        ora #%00000001
        sta $dd00

        lda #%00001000                // $D018: screen $8000 (bank offset
        sta $d018                     // 0), bitmap $a000 (bank offset
        lda #$3b                      // $2000, bit3=1)
        sta $d011                     // bitmap mode on
        lda #$08                      // hires: MCM=0 (the title screen's
        sta $d016                     // multicolor phase 2 below uses $18)
        lda #0
        sta $d020                     // border: black, matches the logo's
        sta $d021                     // own black background (in hires
                                       // bitmap mode $d021 isn't actually
                                       // used for pixels -- every cell's
                                       // own colours come from screen RAM --
                                       // but it's set to match anyway so
                                       // nothing else stays red-tinted)

        ldx #LOGOHOLD1                 // hold the logo, unlit, before the
!:      jsr waitFrame                  // flash
        dex
        bne !-

        jsr logoLightning              // left-to-right lightning flash,
                                        // ~1s -- see below waitFrame

        ldx #LOGOHOLD2                 // hold the logo again, back to
!:      jsr waitFrame                  // normal, before auto-advancing
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
        // zero page (the logo flash's and title wipe's srcPtr/dstPtr and
        // friends, this very chain-in's own scratch) long enough to leave
        // it looking nothing
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
// logoLightning — the left-to-right lightning flash. Walks a 7-column-
// wide window across the picture's 40 cell-columns, one column-step per
// frame; each column inside the window is recoloured by sweepColumn,
// indexed into rampTable by how many steps ago the wavefront reached it
// (0 = just arrived; 6 = rampTable's own "back to red", i.e. restored).
// LOGOFLASHSTEPS = LOGOCOLS+6 so the last column touched (39) also gets
// its full 6-step cool-down before this returns -- nothing is left
// mid-flash when phase 1's second hold begins.
//------------------------------------------------------------
logoLightning:
        lda #0
        sta frameF
lightningFrame:
        lda frameF                    // colStart = max(0, frameF-6) --
        sec                            // rampTable has 7 entries (0-6)
        sbc #6
        bcs !+
        lda #0
!:      sta colStart
        lda frameF                    // colEnd = min(LOGOCOLS-1, frameF)
        cmp #LOGOCOLS
        bcc !+
        lda #(LOGOCOLS-1)
!:      sta colEnd

        lda colEnd                    // colCount = colEnd-colStart+1
        sec
        sbc colStart
        clc
        adc #1
        sta colCount
        lda colStart
        sta savedX
lightningCol:
        lda frameF                    // rampTable index = frameF - column
        sec
        sbc savedX
        tay
        lda rampTable,y
        ldx savedX
        jsr sweepColumn                // clobbers X (its own row counter)
        inc savedX
        dec colCount
        bne lightningCol

        jsr waitFrame
        inc frameF
        lda frameF
        cmp #LOGOFLASHSTEPS
        bne lightningFrame
        rts

//------------------------------------------------------------
// sweepColumn — recolour one 8-pixel-wide column (25 cells, stride
// LOGOCOLS=40 through screen RAM) from hondaniScreenOrig into LOGOSCREEN,
// substituting A for any nibble equal to colour 2 (red) and leaving
// colour 0 (black) untouched -- see the comment above LOGOSCREEN for why
// that's the only substitution this picture ever needs.
// In: A = this step's ramp colour (0-15), X = column index (0-39).
//------------------------------------------------------------
sweepColumn:
        sta rampColor
        stx colIndex
        lda #<hondaniScreenOrig
        clc
        adc colIndex
        sta srcPtr
        lda #>hondaniScreenOrig
        adc #0
        sta srcPtr+1
        lda #<LOGOSCREEN
        clc
        adc colIndex
        sta dstPtr
        lda #>LOGOSCREEN
        adc #0
        sta dstPtr+1

        ldx #LOGOROWS
scRow:  ldy #0
        lda (srcPtr),y
        pha                            // keep the whole original byte
        and #$0f                       // lo nibble first
        cmp #2
        bne scLoOk
        lda rampColor
scLoOk: sta zTmp                       // computed lo nibble, parked
        pla
        lsr
        lsr
        lsr
        lsr                            // hi nibble, now in bits 0-3
        cmp #2
        bne scHiOk
        lda rampColor
scHiOk: asl
        asl
        asl
        asl                            // back to bits 4-7
        ora zTmp
        sta (dstPtr),y

        clc                            // advance both pointers one row
        lda srcPtr                     // down (LOGOCOLS = the screen's
        adc #LOGOCOLS                  // own byte stride)
        sta srcPtr
        bcc scS1
        inc srcPtr+1
scS1:   clc
        lda dstPtr
        adc #LOGOCOLS
        sta dstPtr
        bcc scS2
        inc dstPtr+1
scS2:   dex
        bne scRow
        rts

//------------------------------------------------------------
// waitFrame — block until the next vertical blank. Not cycle-exact (no
// badline/DMA-sensitive work happens during the logo flash, unlike the
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

//============================================================
//  geoprobe.asm — dump C64 I/O space as the CPU sees it
//
//  A diagnostic, not part of any build. geobench.asm's probe can
//  only report "the window pages / it does not"; when it says the
//  latter there is nothing to reason from. This dumps the raw
//  bytes so the host can look at them.
//
//  It performs the same two-signature page dance the real probe
//  does, then captures $de00-$deff twice (page 0 and page 1) and
//  $df00-$dfff once, so all three questions are answerable from one
//  run:
//
//    * is there a window at $de00 at all, or is it open bus?
//    * do the two captures differ -- i.e. does $dffe select?
//    * does anything else in I/O2 answer, which would say some
//      other device owns the registers GeoRAM wants?
//
//  There is no host script for this one; read the blocks out with
//  machine:readmem after the done flag at $0c03 turns $ff. Layout:
//    $0c00  'G','P',1, done($ff written last)
//    $0d00  $de00-$deff with block 0, page 0
//    $0e00  $de00-$deff with block 0, page 1
//    $0f00  $df00-$dfff, raw
//    $1000  $de00-$deff as found, before anything is written
//
//  The $1000 capture and the delay in front of it exist because the
//  window read as open bus from this PRG while memtest64, on the
//  same machine and the same config, found a 4 MB GeoRAM at $de00.
//  That difference has to be in how the program arrives, not in the
//  settings, and it leaves two candidates:
//
//    * runners:run_prg injects the PRG by DMA, and on the Ultimate
//      that path goes through the cartridge. If claiming it for the
//      load drops the GeoRAM emulation until something re-arms it,
//      a program delivered this way would never see the window --
//      and every result so far was delivered this way.
//    * the emulation comes up a moment after reset, and this probe
//      runs immediately after one.
//
//  A delay separates those two: it fixes the second and does
//  nothing for the first.
//
//  It was the first. The delay changed nothing, and delivering the
//  identical PRG through u64.py's run_prg_basic -- reset, DMA, then
//  RUN typed into the keyboard buffer -- made the window appear
//  immediately. run_prg is the trap; see that function's docstring
//  and docs/georam-vs-reu.md §11.
//
//  The pre-write capture settles a third question outright. "REU
//  Preload" is Enabled and points at /Usb0/doom.reu, so if the
//  window is alive its first bytes are that image's header -- the
//  magic "D64U" that mapload.asm checks. Finding it needs no write
//  to have worked, which removes the page registers, the write
//  path, and open-bus write residue from the argument in one go.
//============================================================

#import "defs.asm"

.const RESULTS = $0c00
.const DUMP_P0 = $0d00
.const DUMP_P1 = $0e00
.const DUMP_IO2 = $0f00
.const DUMP_RAW = $1000     // window as found, $01 as BASIC left it
.const DUMP_RAW2 = $1100    // window again, under $01 = BANK_IO

// Frames to wait before touching anything. PAL, so ~50 a second;
// this is about three seconds, which is long enough that "it was
// not up yet" stops being a credible explanation.
.const WAITFRAMES = 150

.const GEO_WIN   = $de00
.const GEO_PAGE  = $dffe
.const GEO_BLOCK = $dfff

.pc = $0801 "basic"
:BasicUpstart2(probe)

.pc = $0810 "probe code"
probe:
        sei

        lda #'G'
        sta RESULTS+0
        lda #'P'
        sta RESULTS+1
        lda #1
        sta RESULTS+2
        lda #0
        sta RESULTS+3

        // --- give the machine time to finish coming up after the
        // reset that run_prg performed. The VIC counts frames at PAL
        // rate whatever the CPU is clocked at, so this is 3 seconds
        // and not a cycle count that turbo would shrink.
        ldx #WAITFRAMES
!frame: lda #0
!:      cmp $d012                   // wait for the raster to reach 0
        bne !-
!:      cmp $d012                   // and to leave it again
        beq !-
        dex
        bne !frame-

        // --- read the window in the state BASIC left the machine in:
        // $01 = $37, screen still running, nothing touched. memtest64
        // finds the device from an ordinary BASIC start, and the only
        // things this probe was doing differently by the time it read
        // the window were forcing $01 = $35 and blanking the screen.
        // Capture here first, before either of those happens.
        lda $01
        sta RESULTS+6               // record what we actually read under
        ldx #0
!:      lda GEO_WIN,x
        sta DUMP_RAW,x
        inx
        bne !-

        // --- now the engine's banking, and the quiet screen the
        // timing work needs.
        lda #0
        sta $d020
        sta $d021
        lda #$0b                    // blank the screen; open-bus reads on a
        sta $d011                   // C64 return the last VIC fetch, and a
        lda #BANK_IO                // blanked screen makes that a constant
        sta $01

        // --- and the same window again, under $01 = $35. If these two
        // captures disagree, the banking is the whole story.
        ldx #0
!:      lda GEO_WIN,x
        sta DUMP_RAW2,x
        inx
        bne !-

        // --- the page dance: two different signatures, two pages ---
        lda #0
        sta GEO_BLOCK
        sta GEO_PAGE
        ldx #3
!:      lda sigA,x
        sta GEO_WIN,x
        dex
        bpl !-

        lda #1
        sta GEO_PAGE
        ldx #3
!:      lda sigB,x
        sta GEO_WIN,x
        dex
        bpl !-

        // --- capture, page 0 then page 1 ---
        lda #0
        sta GEO_BLOCK
        sta GEO_PAGE
        ldx #0
!:      lda GEO_WIN,x
        sta DUMP_P0,x
        inx
        bne !-

        lda #1
        sta GEO_PAGE
        ldx #0
!:      lda GEO_WIN,x
        sta DUMP_P1,x
        inx
        bne !-

        // --- and all of I/O2, to see who else is home ---
        ldx #0
!:      lda $df00,x
        sta DUMP_IO2,x
        inx
        bne !-

        lda #$ff
        sta RESULTS+3               // done, written last
        lda #$1b
        sta $d011
        jmp *

sigA:   .byte $d0, $0e, $c6, $41
sigB:   .byte $6e, $65, $6f, $21

.errorif * > RESULTS, "probe code overflows the results block"

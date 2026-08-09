//============================================================
//  main.asm — Doom C64U entry point
//
//  Milestone 1: walkable 3D demo — BSP renderer into the chunky
//  MATRIX, chunky2mc conversion, double buffering.
//
//  Memory map:
//    $0200-$02FF  colTop (renderer clip)      $0300-$03FF colBot
//    $0400-$076F  COLBUF (color RAM staging)
//    $0810-$0DB1  main / input / map loader
//    $0E00-$0E1F  MAPINFO            $0E20-$0E5F  MAPHDR
//    $0E60-$0E61  SSECHDR            $0E70-$0EEE  collision helpers
//    $0F00-$0F3F  BSP stack          $0F40-$0F50  frameCnt, reu/map status
//    $1000-$7DFF  MATRIX (28160 B, 110 pages)
//    $8000-$83FF  SCREEN0            (VIC bank 2)
//    $8400-$973F  converter tables
//    $9740-$97BF  SEGBUF             $97C0-$98E3  bsp node test
//    $9900-$9FFF  converter + math/span code
//    $A000-$BF3F  BITMAP0            (VIC bank 2)
//    $C000-$C3FF  SCREEN1            (VIC bank 3)
//    $C400-$CA2F  math tables (sqr, sin, rowCell)
//    $CA30-$CE0F  doWall             $CE10-$CFC2  bsp traversal
//    $D000-$DB3F  NODES              $DC00-$DE3F  SECTORS   (under I/O)
//    $E000-$FF3F  BITMAP1
//============================================================

#import "defs.asm"

.pc = $0801 "basic"
:BasicUpstart2(main)

.pc = $0810 "main code"
main:
        sei
        // RAM at $a000 and $e000, I/O at $d000. This is the engine's default
        // banking state and the one every routine may assume; mapload.asm and
        // the BSP walk flip to BANK_RAM briefly and always restore it. See
        // docs/reu-format.md §6.1. Safe because nothing calls the KERNAL after
        // this point and interrupts stay masked for the whole run.
        lda #BANK_IO
        sta $01
        jsr turboOn
        lda #$3b                    // bitmap mode on
        sta $d011
        lda #$18                    // multicolor on
        sta $d016
        lda #0                      // background + border black
        sta $d020
        sta $d021
        sta backBuf
        jsr clearHudRows
        lda #0
        sta frameCnt
        sta frameCnt+1
        // Is there an REU? This used to be advisory. The map now lives in it
        // and there is nothing else to draw, so both this and the load below
        // are fatal -- see mapHalt.
        jsr reuProbe
        lda #0
        rol                         // carry -> bit 0
        sta reuOK
        // Load the resident map blocks (MAPINFO, nodes, sectors) out of the
        // REU image. mapErr says why not; `make check` asserts mapOK through
        // tools/vicedbg/probe.py, and mapHalt makes it visible on a machine.
        jsr mapLoad
        bcc mapHalt
        lda miSpawnX                // spawn from the map's own THINGS entry
        sta camX
        lda miSpawnX+1
        sta camX+1
        lda miSpawnY
        sta camY
        lda miSpawnY+1
        sta camY+1
        lda miSpawnA
        sta camA
        lda miSpawnSec
        sta camSec
        jsr setEyeZ
        // The engine's own descent must agree with the one wad2reu.py did
        // offline. It is checked rather than trusted because a sign flip in
        // pointOnSide mirrors the world, and a mirrored world still renders
        // (docs/reu-format.md §4.1).
        jsr bspFindSsec
        lda zChild
        sta camSsec
        lda zChild+1
        sta camSsec+1
        cmp miSpawnSsec+1
        bne !mismatch+
        lda zChild
        cmp miSpawnSsec
        beq mainLoop
!mismatch:
        lda #MERR_SPAWN
        sta mapErr
        lda #0
        sta mapOK
        // fall through
mapHalt:
        // Nothing can be drawn. Hold the machine with the reason in the
        // border, which is the only output left: 1 no REU, 2 bad magic,
        // 3 wrong version, ... 9 the spawn descent disagreed (mapload.asm).
        lda mapErr
        sta $d020
        jmp mapHalt
mainLoop:
        jsr readInput
        jsr movePlayer
        jsr renderFrame             // 3D -> MATRIX
        jsr convert                 // MATRIX -> back buffer
        jsr flip                    // show it
        inc frameCnt                // host-visible frame counter (defs.asm)
        bne mainLoop
        inc frameCnt+1
        jmp mainLoop

//------------------------------------------------------------
// turboOn — engage the C64 Ultimate's turbo mode.
//
// Found on real hardware (C64 Ultimate, firmware 1.1.0, core 1.49):
// writing the target speed to $D031 on its own does not take effect.
// The register has to be walked down to 1 MHz first and then up to the
// wanted speed; only the transition engages the turbo. So: disable,
// then enable.
//
// Harmless on a stock C64 and in VICE, where $D031 is an unconnected
// VIC mirror -- see the TURBOREG notes in defs.asm.
//------------------------------------------------------------
turboOn:
        lda #TURBO_1MHZ
        sta TURBOREG
        lda #TURBO_MAX
        sta TURBOREG
        rts

//------------------------------------------------------------
// The converter only writes cells 0-879 (rows 0-21); rows 22-24
// are the HUD area. Blank them once in both buffers.
//------------------------------------------------------------
clearHudRows:
        lda #0
        tax
!:      sta BITMAP0+[22*320],x      // 960 bytes as 4 overlapping 256B strides
        sta BITMAP0+[22*320]+256,x
        sta BITMAP0+[22*320]+512,x
        sta BITMAP0+[22*320]+704,x
        sta BITMAP1+[22*320],x
        sta BITMAP1+[22*320]+256,x
        sta BITMAP1+[22*320]+512,x
        sta BITMAP1+[22*320]+704,x
        inx
        bne !-
!:      sta SCREEN0+880,x           // screen/color rows 22-24: 120 bytes
        sta SCREEN1+880,x
        sta COLBUF+880,x
        sta $d800+880,x
        inx
        cpx #120
        bcc !-
        rts

#import "input.asm"
#import "reu.asm"
#import "mapload.asm"
// MAPINFO is the first fixed allocation above the code, so it -- not the BSP
// stack at $0f00 -- is what the main segment has to clear. Before the stack
// moved to $0f00 the margin here was three bytes, and nothing would have said
// so. Deleting testmap.asm bought about 190 B of this back.
.errorif * > MAPINFO, "main code overflows into MAPINFO"

#import "render/chunky2mc.asm"
.errorif * > MATHCODE, "converter code overflows into math code"
.errorif tablesEnd > TABLES_FREE, "converter tables overflow into TABLES_FREE"

#import "math.asm"
.errorif * > BITMAP0, "math code overflows into BITMAP0"

#import "render/walls.asm"
#import "render/bsp.asm"

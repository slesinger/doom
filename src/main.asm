//============================================================
//  main.asm — Doom C64U entry point
//
//  Milestone 1: walkable 3D demo — portal renderer into the
//  chunky MATRIX, chunky2mc conversion, double buffering.
//
//  Memory map:
//    $0200-$02FF  colTop (renderer clip)      $0300-$03FF colBot
//    $0400-$076F  COLBUF (color RAM staging)
//    $0810-$0EFF  main / input / test map
//    $0F00-$0F41  portal stack, visitedSec, frameCnt
//    $1000-$7DFF  MATRIX (28160 B, 110 pages)
//    $8000-$83FF  SCREEN0            (VIC bank 2)
//    $8400-$973F  converter tables
//    $9740-$98FF  free (448 B, TABLES_FREE)
//    $9900-$9FFF  converter + math/span code
//    $A000-$BF3F  BITMAP0            (VIC bank 2)
//    $C000-$C3FF  SCREEN1            (VIC bank 3)
//    $C400-$CA2F  math tables (sqr, sin, rowCell)
//    $CA30-$CFFF  walls renderer code
//    $E000-$FF3F  BITMAP1 (under Kernal ROM — write-only)
//============================================================

#import "defs.asm"

.pc = $0801 "basic"
:BasicUpstart2(main)

.pc = $0810 "main code"
main:
        sei
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
        lda #<START_X               // player spawn
        sta camX
        lda #>START_X
        sta camX+1
        lda #<START_Y
        sta camY
        lda #>START_Y
        sta camY+1
        lda #START_A
        sta camA
        lda #START_SEC
        sta camSec
        ldy #START_SEC
        lda secFloorLo,y
        clc
        adc #EYE
        sta camZ
        lda secFloorHi,y
        adc #0
        sta camZ+1
        lda #0
        sta frameCnt
        sta frameCnt+1
        // Record whether there is an REU. Not fatal: nothing reads the
        // REU yet, so refusing to run would only make the engine useless
        // on machines it currently works on. This becomes a hard failure
        // in Phase 4, when the map lives there and a missing REU means
        // there is nothing to draw.
        jsr reuProbe
        lda #0
        rol                         // carry -> bit 0
        sta reuOK
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
#import "testmap.asm"
// The portal stack and its neighbours sit in the same free block, just
// above the code. Before they were moved to $0f00 the margin here was
// three bytes, and nothing would have said so.
.errorif * > pStkSec, "main code overflows into the portal stack"
.errorif * > MATRIX, "main code overflows into MATRIX"

#import "render/chunky2mc.asm"
.errorif * > MATHCODE, "converter code overflows into math code"
.errorif tablesEnd > TABLES_FREE, "converter tables overflow into TABLES_FREE"

#import "math.asm"
.errorif * > BITMAP0, "math code overflows into BITMAP0"

#import "render/walls.asm"

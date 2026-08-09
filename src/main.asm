//============================================================
//  main.asm — Doom C64U entry point
//
//  Milestone 1: walkable 3D demo — portal renderer into the
//  chunky MATRIX, chunky2mc conversion, double buffering.
//
//  Memory map:
//    $0200-$02FF  colTop (renderer clip)      $0300-$03FF colBot + portal stack
//    $0400-$076F  COLBUF (color RAM staging)
//    $0810-$0FFF  main / input / test map
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
mainLoop:
        jsr readInput
        jsr movePlayer
        jsr renderFrame             // 3D -> MATRIX
        jsr convert                 // MATRIX -> back buffer
        jsr flip                    // show it
        jmp mainLoop

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
#import "testmap.asm"
.errorif * > MATRIX, "main code overflows into MATRIX"

#import "render/chunky2mc.asm"
.errorif * > MATHCODE, "converter code overflows into math code"
.errorif tablesEnd > TABLES_FREE, "converter tables overflow into TABLES_FREE"

#import "math.asm"
.errorif * > BITMAP0, "math code overflows into BITMAP0"

#import "render/walls.asm"

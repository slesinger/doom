//============================================================
//  chunky2mc.asm — 160x160 chunky buffer -> VIC-II multicolor
//  (176 -> 160 rows, IMPLEMENTATION_PLAN.md §14a.1: a 320x200 frame with
//  rows 160-175 letterboxed black and the HUD unchanged at rows 176-199)
//  C64 Ultimate @ turbo, 25 fps double-buffered
//
//  Matrix byte format: %rrrriiii  (ramp 0-15, intensity 0-15)
//  Matrix layout: cell-major. cell n at MATRIX+n*32,
//                 within cell: offset = row*4 + px
//  See 3d-renderer-design.md for the full design rationale.
//============================================================

//------------------------------------------------------------
// Assembly-time tables
//------------------------------------------------------------
.var bayer = List().add(
    List().add( 0, 8, 2,10),
    List().add(12, 4,14, 6),
    List().add( 3,11, 1, 9),
    List().add(15, 7,13, 5))

// 16 ramps: 3 colors each, luminance-ascending. %00 is always black.
// code %01 -> screen hi nibble, %10 -> screen lo nibble, %11 -> color RAM
.var ramps = List()
.eval ramps.add(List().add($b,$c,$f))   //  0 stone   dgrey grey lgrey
.eval ramps.add(List().add($9,$8,$7))   //  1 wood    brown orange yellow
.eval ramps.add(List().add($2,$a,$7))   //  2 flesh   red lred yellow
.eval ramps.add(List().add($6,$e,$3))   //  3 sky     blue lblue cyan
.eval ramps.add(List().add($9,$5,$d))   //  4 moss    brown green lgreen
.eval ramps.add(List().add($6,$4,$a))   //  5 violet  blue purple lred
.eval ramps.add(List().add($b,$c,$1))   //  6 metal   dgrey grey white
.eval ramps.add(List().add($2,$8,$7))   //  7 fire    red orange yellow
.eval ramps.add(List().add($9,$8,$7))   //  8 hud     brown orange yellow --
                                        // IMPLEMENTATION_PLAN.md §13; one of
                                        // the spare slots below, claimed by
                                        // wad2reu.py's HUD_RAMP for STBAR and
                                        // STTNUM's own warm palette
.for (var r=9; r<16; r++) .eval ramps.add(List().add($b,$c,$f)) // spare

// intensity(0-15) + Bayer threshold -> 2-bit code 0..3
.function dcode(v, px, row) {
    .var t = bayer.get(row).get(px)
    .return min(floor(v/5.0 + (t+0.5)/16.0), 3)
}

.pc = TABLES "converter tables"
ditherTabs:                 // 16 x 256B: [px 0-3][bayer row 0-3]
.for (var px=0; px<4; px++) {
    .for (var row=0; row<4; row++) {
        .fill 256, dcode(i&15, px, row) << [6 - px*2]
    }
}
scrTab: .fill 256, ramps.get(i>>4).get(0)*16 + ramps.get(i>>4).get(1)
colTab: .fill 256, ramps.get(i>>4).get(2)

// rasterizer helpers: pixel(x,y) = rowCell[y>>3] + xOfsLo/Hi[x] + (y&7)*4
// (stepping x by 1: +1, except every 4th pixel: +29)
// The scanline-major rowLo/rowHi pair from 3d-renderer-design.md lived here
// and was never read — spanFill uses the cell-major rowCell pair in math.asm.
// Reclaimed; the 352 B it held are now part of TABLES_FREE (see defs.asm).
xOfsLo: .fill 160, <[floor(i/4)*32 + mod(i,4)]
xOfsHi: .fill 160, >[floor(i/4)*32 + mod(i,4)]
tablesEnd:

//------------------------------------------------------------
// Converter: ~415 cycles/cell, ~380k cycles total
//------------------------------------------------------------
.var fetchHiOps = List()    // operand hi-bytes patched per matrix page
.var bmpHiOps   = List()    // sta operand hi-bytes bumped per bitmap page

.pc = CONVERTER_CODE "converter code"

convert:
        jsr initFrame
        lda #>MATRIX
        sta matPage
        lda #100                    // 100 pages * 8 cells = 800 cells = 20
        sta pageCnt                 // cell-rows = 160 px (176 -> 160, was 110/880/22)
pageLoop:
        jsr patchMatrixPage         // 32+1 fetch hi-bytes := matPage
        ldx #0                      // X = (cell & 7) * 32
cellLoop:
        // ---- pack 8 bitmap bytes: 8 cycles/pixel, dither included ----
        .for (var s=0; s<8; s++) {
            .for (var j=0; j<4; j++) {
                .eval fetchHiOps.add(*+2)
                ldy MATRIX + s*4 + j, x
                .if (j==0) lda ditherTabs + [j*4 + mod(s,4)]*256, y
                .if (j!=0) ora ditherTabs + [j*4 + mod(s,4)]*256, y
            }
            sta zTmp+s
        }
        // ---- attributes: sample pixel (row 3, px 1) picks the ramp ----
        .eval fetchHiOps.add(*+2)
        ldy MATRIX + 13, x
        lda scrTab,y
scrSta: sta SCREEN0                 // self-mod, ++ per cell
        lda colTab,y
colSta: sta COLBUF                  // self-mod, ++ per cell
        // ---- store to bitmap: cell n -> BITMAP + n*8 ----
bmY:    ldy #0                      // self-mod imm: (cell*8) & $ff
        .for (var s=0; s<8; s++) {
            lda zTmp+s
            .eval bmpHiOps.add(*+2)
            sta BITMAP0 + s, y
        }
        // ---- advance self-modified pointers ----
        inc scrSta+1
        bne !+
        inc scrSta+2
!:      inc colSta+1
        bne !+
        inc colSta+2
!:      lda bmY+1
        clc
        adc #8
        sta bmY+1
        bcc !+
        jsr bumpBmpPage             // every 32 cells
!:      txa
        clc
        adc #32
        tax
        beq pageDone                // 8 cells done -> next matrix page
        jmp cellLoop
pageDone:
        inc matPage
        dec pageCnt
        beq convDone
        jmp pageLoop
convDone:
        rts

patchMatrixPage:
        lda matPage
        .for (var k=0; k<fetchHiOps.size(); k++) sta fetchHiOps.get(k)
        rts

bumpBmpPage:
        .for (var k=0; k<8; k++) inc bmpHiOps.get(k)
        rts

initFrame:                          // aim all self-mod ops at the back buffer
        lda #0
        sta bmY+1
        sta scrSta+1
        sta colSta+1
        lda #>COLBUF
        sta colSta+2
        lda backBuf
        bne !b1+
        lda #>SCREEN0
        sta scrSta+2
        lda #>BITMAP0
        jmp !set+
!b1:    lda #>SCREEN1
        sta scrSta+2
        lda #>BITMAP1
!set:   .for (var k=0; k<8; k++) sta bmpHiOps.get(k)
        rts

//------------------------------------------------------------
// Flip at vblank + burst color RAM (call after convert)
//------------------------------------------------------------
flip:
        lda #251                    // wait for bottom border
!:      cmp $d012
        bne !-
        lda $dd00                   // keep CIA2 serial bits intact
        and #%11111100              // bank 3 ($c000) = %00
        ldx backBuf                 // show the buffer we just filled
        bne !+
        ora #%01                    // bank 2 ($8000)
!:      sta $dd00
        lda #$08                    // both buffers: screen +$0000, bitmap +$2000
        sta $d018
        ldx #0                      // COLBUF -> $d800 (800 bytes, 176 -> 160
!:      lda COLBUF,x                // rows: 20 cell-rows * 40 cols)
        sta $d800,x
        lda COLBUF+$100,x
        sta $d900,x
        lda COLBUF+$200,x
        sta $da00,x
        inx
        bne !-
!:      lda COLBUF+$300,x
        sta $db00,x
        inx
        cpx #32
        bne !-
        lda backBuf                 // swap
        eor #1
        sta backBuf
        rts

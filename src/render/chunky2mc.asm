//============================================================
//  chunky2mc.asm — 160x144 chunky buffer -> VIC-II multicolor
//  (a 320x200 frame: rows 0-15 letterboxed black, the view at rows 16-159,
//  and the HUD flush against it at rows 160-199 -- IMPLEMENTATION_PLAN.md
//  §14a.1/§12 cut the view to 144 rows, and 2026-08-15 moved the HUD up one
//  cell-row (defs.asm's HUD_CELL_ROW) to close the 8-row gap that left
//  between the view and the bar)
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
// 9-13 claimed 2026-08-13 (IMPLEMENTATION_PLAN.md §10.7). A tile modulates the
// intensity nibble only — the ramp is one per 4x8 cell, fixed by the VIC — so
// the material's *colour* can only come from the ramp the seg carries. Seven of
// these sixteen slots were duplicates of stone while E1M1's 32 wall textures
// shared six ramps, which is the mush of M1 risk #5. Splitting the overloaded
// ones costs nothing at runtime: the table is assembled, not computed.
.eval ramps.add(List().add($9,$c,$f))   //  9 tan     brown grey lgrey  STARTAN
.eval ramps.add(List().add($5,$7,$d))   // 10 slime   green yellow lgreen
.eval ramps.add(List().add($6,$c,$1))   // 11 tech    blue grey white -- $e
                                        // (VIC "light blue") is violet in
                                        // Pepto and read as such on screen;
                                        // dgrey/grey/white would have been
                                        // METAL exactly
.eval ramps.add(List().add($b,$8,$f))   // 12 door    dgrey orange lgrey
.eval ramps.add(List().add($8,$7,$1))   // 13 lite    orange yellow white
// 14 claimed 2026-08-13 by the weapon view (IMPLEMENTATION_PLAN.md §12a;
// wad2reu.py's WPN_RAMP). Brown into dark grey into grey -- one step darker at
// both ends than the tan ramp it started as. E1M1 is mostly stone ($b/$c/$f)
// and tan ($9/$c/$f), so a gun topping out at light grey is a grey object in
// front of grey walls whatever its shape; capping it at $c and giving it black
// (dither code 0) for its dark half is the only contrast available, because the
// ramp is per 4x8 cell and the background's is not ours to choose. Paired with
// WPN_MIN/WPN_MAX in wad2reu.py -- the ramp sets which three colours, the range
// sets how often the top one is reached, and darkening needs both.
//
// Not shared with ramp 9 despite starting as its twin: the weapon is the one
// thing always in the foreground, and a tweak to it must not repaint every
// STARTAN wall in E1M1. This edit is exactly that case.
.eval ramps.add(List().add($9,$b,$c))   // 14 gun     brown dgrey grey
.eval ramps.add(List().add($b,$c,$f))   // 15 spare

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
        lda #VIEWCELLS/8            // pages * 8 cells = VIEWCELLS = VIEWCELLROWS
        sta pageCnt                 // cell-rows (176/22 -> 160/20 -> 144/18)
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

// Aim all self-mod ops at the back buffer -- and at the *top letterbox's far
// side*, not at byte 0. MATRIX row 0 is raster row VIEWTOP, so every output
// pointer starts VIEWCELLTOP cell-rows in (defs.asm). This is the only place
// the shift is applied: the renderer, spanFill and the sprite blits all work
// in MATRIX rows and know nothing about it.
initFrame:
        lda #<VIEWBMPOFS            // 640 = $0280: low byte into bmY's stride,
        sta bmY+1                   // the $02 folded into the hi-byte ops below
        lda #VIEWCELLOFS
        sta scrSta+1
        sta colSta+1
        lda #>[COLBUF + VIEWCELLOFS]
        sta colSta+2
        lda backBuf
        bne !b1+
        lda #>[SCREEN0 + VIEWCELLOFS]
        sta scrSta+2
        lda #>[BITMAP0 + VIEWBMPOFS]
        jmp !set+
!b1:    lda #>[SCREEN1 + VIEWCELLOFS]
        sta scrSta+2
        lda #>[BITMAP1 + VIEWBMPOFS]
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
        // COLBUF -> $d800, VIEWCELLS bytes starting at cell VIEWCELLOFS.
        // Source and destination carry the *same* offset -- initFrame aimed
        // colSta at COLBUF+VIEWCELLOFS for exactly this reason -- so every
        // byte's low address matches and the burst is three plain X loops:
        // a partial page in, two whole pages, then the tail. At 18 cell-rows
        // shifted down 2 that is 176 + 256 + 256 + 32 = 720, spanning
        // $0450-$071f, which stops short of TX_SEED at $0770 (defs.asm).
        //
        // The colour cells outside this window are the two letterbox bands and
        // the HUD, written once by clearHudRows/hudBoot straight to $d800 and
        // never re-burst.
        .errorif VIEWCELLOFS == 0 || VIEWCELLOFS >= 256, "the flip burst wants a sub-page top letterbox"
        .errorif VIEWCELLOFS + VIEWCELLS <= 768 || VIEWCELLOFS + VIEWCELLS > 1024, "the flip burst is shaped for a partial page, two whole pages and a tail"
        ldx #VIEWCELLOFS
!:      lda COLBUF,x
        sta $d800,x
        inx
        bne !-
!:      lda COLBUF+$100,x
        sta $d900,x
        lda COLBUF+$200,x
        sta $da00,x
        inx
        bne !-
!:      lda COLBUF+$300,x
        sta $db00,x
        inx
        cpx #VIEWCELLOFS+VIEWCELLS-768
        bcc !-
        lda backBuf                 // swap
        eor #1
        sta backBuf
        rts

//============================================================
//  weapon.asm — the weapon view (IMPLEMENTATION_PLAN.md §12a)
//
//  A screen-fixed sprite, not a world Thing: no transform, no
//  sort, no per-subsector pickup. What it does share with §12 is
//  the pixel format (4-bit intensity, 0 = transparent) and the
//  masked blit, and it is deliberately built first so that both
//  are proven on a fixed-size unscaled case before the scaled one.
//
//  Three pieces, in the order a frame runs them:
//
//    wpnPrep   before renderFrame. Bobs the gun and writes the 40
//              columns of colBotSeed the gun covers.
//    (render)  renderFrame seeds colBot from that table, so the
//              wall and floor passes never draw the rows the gun
//              is about to paint over. **This is what makes a big
//              weapon cheaper than a small one** -- the sealed
//              columns close early and openCols ends the traversal
//              sooner (§12a).
//    wpnFrame  after renderFrame. Streams the art a row at a time
//              into SEGBUF (dead by then) and blits it.
//
//  The blit writes only opaque pixels, and the seed closes only
//  the rows the blit definitely fills -- wad2reu.py's
//  _solid_from_bottom is where that invariant is built, and
//  validate() checks it against the art it ships. Break it and a
//  transparent gap the world is forbidden to draw comes out as a
//  black hole, because MATRIX is not cleared between frames: the
//  renderer's guarantee has always been that every column is
//  written top to bottom, and this is the first thing that carves
//  an exception into it.
//
//  Zero page: zA (the destination pointer), zB (row, rows left),
//  zD (the REU cursor) and zT. All renderer scratch, all dead
//  between renderFrame and convert.
//============================================================

.pc = WPNCODE "weapon view"

//------------------------------------------------------------
// wpnBoot — once, before mapLoad. Opens every column of the seed
// table and marks the weapon absent; weaponLoad (src/mapload.asm)
// is what turns it on, and only if the image carries block 10.
//------------------------------------------------------------
wpnBoot:
        lda #VIEWROWS
        ldx #160                    // 160 columns, counted down to 1 and
!:      dex                         // tested with cpx: bpl from #159 would
        sta colBotSeed,x            // stop after one pass (renderFrame's
        cpx #0                      // opening loop has the same note)
        bne !-
        lda #0
        sta wpnOK
        sta wpnArtBase
        sta wpnArtBase+1
        sta wpnArtBase+2
        rts

//------------------------------------------------------------
// wpnPrep — this frame's gun position, and the columns it seals.
//
// The bob is camJZ, the walk wave the eye already rides (bobStep,
// src/input.asm), halved: 0-6 eye units become 0-3 rows. The gun
// moves *down* as the eye rises, which is the direction the world
// moves, and the rows that fall off the bottom of the view are
// simply not drawn -- wpnRows is what is left. Bobbing it up
// instead would need no clipping but would open a gap under the
// gun, and a gap shows the floor through the player's hands.
//------------------------------------------------------------
wpnPrep:
        lda wpnOK
        beq !rts+
        lda camJZ
        lsr                         // 0-BOBPEAK eye units -> 0-3 rows
        clc
        adc #WPN_ROW0
        sta wpnRow0
        lda #VIEWROWS               // wpnRow0 + wpnRows == VIEWROWS always:
        sec                         // the gun is bottom-aligned by definition
        sbc wpnRow0
        sta wpnRows
        ldx #WPN_W-1
!col:   lda wpnSil,x                // the first row sealed to the bottom
        clc
        adc wpnRow0
        cmp #VIEWROWS               // a column whose seal is entirely below
        bcc !+                      // the view seals nothing: the clip and
        lda #VIEWROWS               // the bob together can push it past
!:      sta colBotSeed + WPN_COL0,x
        dex
        bpl !col-
!rts:   rts

.errorif * > WPNPREP_END, "wpnBoot/wpnPrep overrun the budget §12 left them"

//------------------------------------------------------------
// wpnFrame — stream and blit, one row at a time.
//
// Per-row DMA rather than one 1120-byte transfer, because there is
// nowhere to put 1120 bytes: SPRFREE is spent on §12's resident
// art and this is the block that had to stay streamed (§12a). It
// costs nothing to split it -- the REU moves a byte a microsecond
// whatever the transfer length, so the 1.12 ms is the same either
// way, and 56 register setups are ~2k cycles = 0.03 ms on top.
//
// Moved out to WPNBLIT (§12's defs.asm note) to free WPNCODE's tail
// as SPRCODE2 -- wpnBoot+wpnPrep alone fit the 128 B left for them
// with room to spare, and this routine is entered by jsr and
// returns, so relocating it costs nothing but the .pc line below.
//------------------------------------------------------------
.pc = WPNBLIT "weapon blit"
wpnFrame:
        lda wpnOK
        bne !+
        rts                         // no weapon block in the image
!:      lda wpnArtBase              // zD = the REU read cursor, row 0 of the
        sta zD                      // art. Art rows always start at 0: the
        lda wpnArtBase+1            // bob moves where rows land, not which
        sta zD+1                    // ones are read
        lda wpnArtBase+2
        sta zD+2
        lda wpnRow0
        sta zB                      // the MATRIX row being written
        lda wpnRows
        sta zB+1                    // rows left
wpnRow:
        lda zD                      // ---- one packed row into SEGBUF ----
        sta REU_REUADDR
        lda zD+1
        sta REU_REUADDR+1
        lda zD+2
        sta REU_BANK
        lda #<SEGBUF
        sta REU_C64ADDR
        lda #>SEGBUF
        sta REU_C64ADDR+1
        lda #WPN_ROW_BYTES
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        lda zD
        clc
        adc #WPN_ROW_BYTES
        sta zD
        bcc !+
        inc zD+1
        bne !+
        inc zD+2
!:
        // ---- zA = &MATRIX[row zB, column WPN_COL0] ----
        // MATRIX is cell-major: (row>>3)*1280 + (col>>2)*32 + (row&7)*4 +
        // (col&3). WPN_COL0 is cell-aligned, so the column term is the
        // constant below and there is no (col&3).
        lda zB
        lsr
        lsr
        lsr
        tax
        lda rowCellLo,x
        clc
        adc #<[WPN_COL0/4*32]
        sta zA
        lda rowCellHi,x
        adc #>[WPN_COL0/4*32]
        sta zA+1
        lda zB
        and #7
        asl
        asl
        clc
        adc zA
        sta zA
        bcc !+
        inc zA+1
!:
        // ---- 40 pixels, one 4-pixel cell per pass ----
        // A cell's four pixels are four consecutive bytes and the next cell
        // is +32, which is why the unroll is by cell and not by source byte:
        // the destination offsets are the constants 0-3 and the pointer moves
        // once per four pixels instead of once per pixel.
        ldx #0                      // source byte index, 0-19
wpnCell:
        lda SEGBUF,x
        sta zT
        and #$0f                    // even x is the LOW nibble (wad2reu.py's
        beq !p1+                    // _pack_nibbles)
        ora #WPN_RAMP*16
        ldy #0
        sta (zA),y
!p1:    lda zT
        lsr
        lsr
        lsr
        lsr
        beq !p2+
        ora #WPN_RAMP*16
        ldy #1
        sta (zA),y
!p2:    inx
        lda SEGBUF,x
        sta zT
        and #$0f
        beq !p3+
        ora #WPN_RAMP*16
        ldy #2
        sta (zA),y
!p3:    lda zT
        lsr
        lsr
        lsr
        lsr
        beq !p4+
        ora #WPN_RAMP*16
        ldy #3
        sta (zA),y
!p4:    inx
        lda zA
        clc
        adc #32                     // next cell of the same row
        sta zA
        bcc !+
        inc zA+1
!:      cpx #WPN_ROW_BYTES
        bne wpnCell
        inc zB
        dec zB+1
        beq !rts+
        jmp wpnRow                  // out of branch range: the row body is
!rts:   rts                         // ~180 bytes of unrolled cell blit

.errorif * > BODYCODE_END, "the weapon blit overflows the end of MATRIX"

//============================================================
//  mapload.asm — boot-time load of build/assets.reu
//
//  Reads the 64-byte image header from REU offset 0, checks its
//  magic and version, then walks the block descriptors and copies
//  every block marked resident to its home in RAM.
//
//  The format is frozen in docs/reu-format.md. tools/wad2reu.py
//  writes it; this file and src/render/bsp.asm read it.
//
//  Two things about this are worth knowing before changing it.
//
//  1. A resident block cannot be DMA'd straight to its home.
//     Two of the three land under the I/O space at $d000, and the
//     REU drives the C64 bus through the same PLA the CPU does:
//     with I/O banked in the transfer would overwrite the I/O
//     registers, and with I/O banked out the $df01 command
//     register needed to *start* the transfer is not reachable.
//     So every block is staged through MATRIX ($1000, 28 KB and
//     unused until the first frame) and then block-copied with
//     $01 = BANK_RAM. This is boot-time only.
//
//     The alternative is the $ff00 trigger mode, where the REU
//     snoops a write to $ff00 regardless of banking. It works on
//     real hardware and saves the copy, but it is one more thing
//     to verify on two REU implementations for a saving that is
//     invisible at boot. Not taken.
//
//  2. Failure is recorded, not fatal. Nothing reads the map yet
//     -- the engine still renders testmap.asm -- so halting here
//     would only break machines the engine currently works on.
//     `make check` asserts mapOK == 1 through tools/vicedbg, which
//     is the same arrangement that caught the REU being silently
//     absent for the whole life of the project
//     (IMPLEMENTATION_PLAN.md §10). It becomes fatal in Phase 4,
//     when the map is the only thing there is to draw.
//============================================================

// Number of block ids this build knows about. The tables at the end are
// indexed by id, so this and docs/reu-format.md §3 must stay in step.
.const MAPNBLK = 4

// The streamed blocks this file reads at boot itself -- see lineLoad and
// hudBgLoad/hudFontLoad.
.const BLK_LINEDEFS = 7
.const BLK_HUDBG    = 8
.const BLK_HUDFONT  = 9

.const MAPINFOSZ = 32
.const NODETABSZ = NODETAB_END - NODETAB
.const SECTABSZ  = SECTAB_END - SECTAB

// How many descriptors can physically fit in the 64-byte header.
.const MAXDESCS = [HDRSIZE - 8] / 8

// The mapErr values live in defs.asm with every other .const: main.asm
// reports one of them itself and is assembled before this file.

//------------------------------------------------------------
// mapLoad — carry set on success. Sets mapOK/mapErr either way.
//
// Assembled into MATRIX, not into the main segment -- see BOOTCODE in
// defs.asm. This code has one caller, main.asm's boot path, and by the time
// the first frame has been rendered it no longer exists: spanFill writes over
// it. Nothing here may be called after boot.
//------------------------------------------------------------
.pc = BOOTCODE "boot: map loader"

mapLoad:
        lda #0
        sta mapOK
        sta mapErr
        ldx #[MAPNBLK*2]-1              // a block that never loaded sums to 0
!:      sta mapSum,x
        dex
        bpl !-
        lda reuOK
        bne mapHaveReu
        lda #MERR_NOREU
        jmp mapFail

mapHaveReu:
        // --- header first. MAPHDR is ordinary RAM, so this one block can
        // be DMA'd straight to where it is used.
        :reuSet(MAPHDR, $0000, 0, HDRSIZE)
        lda #REU_FETCH
        sta REU_COMMAND

        ldx #3
!chk:   lda hdrMagic,x
        cmp mapMagicStr,x
        beq !+
        lda #MERR_MAGIC
        jmp mapFail
!:      dex
        bpl !chk-

        lda hdrVersion
        cmp #MAPFMT_VERSION
        beq !+
        lda #MERR_VERSION
        jmp mapFail
!:
        lda hdrBlocks
        beq !badCount+
        cmp #MAXDESCS+1
        bcc !+
!badCount:
        lda #MERR_BLOCKS
        jmp mapFail
!:      sta zMLCnt

        lda #<hdrDescs
        sta zMLDesc
        lda #>hdrDescs
        sta zMLDesc+1

mapBlockLoop:
        ldy #bdFlags
        lda (zMLDesc),y
        and #1
        bne !resident+
        // Streamed blocks are nobody's business at boot -- except block 7,
        // the special lines, which is streamed only because its home under
        // I/O does not start on a page and a descriptor carries a load *page*
        // (docs/reu-format.md §4.8). It is read here, once, like a resident
        // block, and split into place by lineLoad.
        ldy #bdId
        lda (zMLDesc),y
        cmp #BLK_LINEDEFS
        bne !notLines+
        jsr lineLoad
        jmp mapNextBlock
!notLines:
        cmp #BLK_HUDBG
        bne !notHudBg+
        jsr hudBgLoad
        jmp mapNextBlock
!notHudBg:
        cmp #BLK_HUDFONT
        bne mapNextBlock
        jsr hudFontLoad
        jmp mapNextBlock
!resident:

        ldy #bdId
        lda (zMLDesc),y
        cmp #MAPNBLK
        bcc !+
        lda #MERR_ID
        jmp mapFail
!:      tax                             // X = block id, indexes the tables below
        asl                             // and x2, the slot in mapSum
        sta zMLId

        // --- the load address in the image must be the one defs.asm expects.
        // Deliberate duplication: it is the only check that catches an
        // assets.reu built against a different memory map, and such an image
        // otherwise loads "successfully" over the wrong 3 KB of RAM.
        ldy #bdLoadHi
        lda (zMLDesc),y
        cmp mapLoadHi,x
        beq !+
        lda #MERR_ADDR
        jmp mapFail
!:      sta zMLDst+1
        lda #0
        sta zMLDst

        // --- length, against the space actually reserved for this block ---
        ldy #bdLen
        lda (zMLDesc),y
        sta zMLLen
        iny
        lda (zMLDesc),y
        sta zMLLen+1
        cmp mapMaxLenHi,x
        bcc !fits+
        bne !tooBig+
        lda zMLLen
        cmp mapMaxLenLo,x
        bcc !fits+
        beq !fits+
!tooBig:
        lda #MERR_SIZE
        jmp mapFail
!fits:
        // --- stage the block into MATRIX, then copy it home ---
        lda #<MATRIX
        sta REU_C64ADDR
        lda #>MATRIX
        sta REU_C64ADDR+1
        ldy #bdReuOfs
        lda (zMLDesc),y
        sta REU_REUADDR
        iny
        lda (zMLDesc),y
        sta REU_REUADDR+1
        iny
        lda (zMLDesc),y
        sta REU_BANK
        lda zMLLen
        sta REU_LENGTH
        lda zMLLen+1
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND

        jsr mapCopyStaged

mapNextBlock:
        lda zMLDesc                     // advance to the next descriptor
        clc
        adc #8
        sta zMLDesc
        bcc !+
        inc zMLDesc+1
!:      dec zMLCnt
        beq !+
        jmp mapBlockLoop            // the body is over a page long
!:

        // --- MAPINFO is resident now; its counts must fit the arrays ---
        lda miNumNodes+1
        bne !bad+
        lda miNumNodes
        cmp #MAXNODES+1
        bcs !bad+
        lda miNumSec
        cmp #MAXSEC+1
        bcs !bad+
        lda miSsecShift                 // bsp.asm shifts by a constant 7
        cmp #7
        bne !bad+

        lda #1
        sta mapOK
        sec
        rts
!bad:
        lda #MERR_COUNTS
        // fall through

mapFail:
        sta mapErr
        lda #0
        sta mapOK
        clc
        rts

//------------------------------------------------------------
// lineLoad — block 7 (the special lines) into LINESPEC, at $DB40.
//
// The same two-step every resident block makes, and for the same reason: the
// REU drives the bus through the same PLA the CPU does, so it cannot write
// under I/O, and $df01 is not reachable with I/O banked out. Stage into
// MATRIX, then copy with $01 = BANK_RAM.
//
// It is not a resident block because a descriptor carries only the *page* of
// its home and $DB40 is not one. Rather than widen the descriptor for one
// block -- and change the format, mapLoad's tables and probe.py with it --
// the block stays streamed and this reads it. The length is checked against
// LINEDEFSZ so that an image built with a different MAXLINES fails here
// rather than by writing over the thinker list.
//
// mapSum gets no entry: the sums are indexed by block id and the table is
// MAPNBLK wide. tools/vicedbg/probe.py checks these 80 bytes directly
// against the image instead, which is a stronger check than the sum anyway.
//------------------------------------------------------------
lineLoad:
        ldy #bdLen
        lda (zMLDesc),y
        cmp #LINEDEFSZ
        bne !bad+
        iny
        lda (zMLDesc),y
        bne !bad+
        lda #<MATRIX
        sta REU_C64ADDR
        lda #>MATRIX
        sta REU_C64ADDR+1
        ldy #bdReuOfs
        lda (zMLDesc),y
        sta REU_REUADDR
        iny
        lda (zMLDesc),y
        sta REU_REUADDR+1
        iny
        lda (zMLDesc),y
        sta REU_BANK
        lda #LINEDEFSZ
        sta REU_LENGTH
        lda #0
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        lda #BANK_RAM
        sta $01
        ldy #LINEDEFSZ-1
!:      lda MATRIX,y
        sta LINESPEC,y
        dey
        bpl !-
        lda #BANK_IO
        sta $01
        rts
!bad:   lda #MERR_SIZE
        jmp mapFail

//------------------------------------------------------------
// hudBgLoad / hudFontLoad — IMPLEMENTATION_PLAN.md §13, docs/reu-format.md
// §4.9. Streamed for the same reason LINEDEFS is (above): read exactly once,
// by their own loader, because nothing reads either block again after
// hudBoot (src/main.asm) has painted the bar. Unlike LINEDEFS there is no
// second copy into a final home -- the fetch lands straight in a fixed
// MATRIX offset (HUDBG_STAGE/HUDFONT_STAGE, ordinary RAM, no banking
// concern) and hudBoot reads it from there directly.
//
// Assembled into BOOTCODE6, not BOOTCODE: mapLoad's own block (above) had
// only ~96 B free before this and both routines together need more than
// that. There is no requirement that a block id's loader live in the same
// MATRIX region as the descriptor walk that calls it -- only that the
// address is known at assembly time, which .const already gives it -- and
// BOOTCODE6 is unclaimed (see defs.asm). hudBoot, which consumes what these
// two stage, follows directly below.
//------------------------------------------------------------
.pc = BOOTCODE6 "boot: hud load + blit"

hudBgLoad:
        ldy #bdLen
        lda (zMLDesc),y
        cmp #<HUD_BG_BYTES
        bne !bad+
        iny
        lda (zMLDesc),y
        cmp #>HUD_BG_BYTES
        bne !bad+
        lda #<HUDBG_STAGE
        sta REU_C64ADDR
        lda #>HUDBG_STAGE
        sta REU_C64ADDR+1
        ldy #bdReuOfs
        lda (zMLDesc),y
        sta REU_REUADDR
        iny
        lda (zMLDesc),y
        sta REU_REUADDR+1
        iny
        lda (zMLDesc),y
        sta REU_BANK
        lda #<HUD_BG_BYTES
        sta REU_LENGTH
        lda #>HUD_BG_BYTES
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        rts
!bad:   lda #MERR_SIZE
        jmp mapFail

hudFontLoad:
        ldy #bdLen
        lda (zMLDesc),y
        cmp #<HUD_FONT_BYTES
        bne !bad+
        iny
        lda (zMLDesc),y
        cmp #>HUD_FONT_BYTES
        bne !bad+
        lda #<HUDFONT_STAGE
        sta REU_C64ADDR
        lda #>HUDFONT_STAGE
        sta REU_C64ADDR+1
        ldy #bdReuOfs
        lda (zMLDesc),y
        sta REU_REUADDR
        iny
        lda (zMLDesc),y
        sta REU_REUADDR+1
        iny
        lda (zMLDesc),y
        sta REU_BANK
        lda #<HUD_FONT_BYTES
        sta REU_LENGTH
        lda #>HUD_FONT_BYTES
        sta REU_LENGTH+1
        lda #REU_FETCH
        sta REU_COMMAND
        rts
!bad:   lda #MERR_SIZE
        jmp mapFail

//------------------------------------------------------------
// hudBlitCell -- one MATRIX-format cell (zHudSrc, 32 bytes, offset =
// row*4+px, chunky2mc.asm's own layout) -> the bitmap, screen and colour RAM
// at cell index zHudN (n*8 is the bitmap byte offset, n is the screen/colour
// byte offset -- "cell n -> BITMAP + n*8", chunky2mc.asm's convert). Drives
// the SAME ditherTabs/scrTab/colTab tables the per-frame converter has
// resident, so a ramp+intensity byte means the same thing here as there.
//
// A real subroutine, not the per-frame unrolled hot path: BOOTCODE6 has no
// cycle budget to defend, called ~130 times total and never again.
//------------------------------------------------------------
hudBlitCell:
        // ---- copy the cell to a fixed buffer, so the dither chain below can
        // index it absolutely. convert() writes `ldy MATRIX+s*4+j,x`, and it
        // is load-bearing that the fetch lands in Y without going through A:
        // the four pixels of a row accumulate into A across three `ora`s. The
        // first version of this routine fetched indirectly instead --
        // `ldy #s*4+j / lda (zHudSrc),y / tay` -- which quietly overwrites
        // that accumulator between the ora's, so every packed byte came out
        // as the last pixel's source value ORed with its own dither code.
        // 32 bytes of buffer and 32 boot-time copies buy the same addressing
        // mode convert() has.
        ldy #HUD_CELL_BYTES-1
!:      lda (zHudSrc),y
        sta hudCell,y
        dey
        bpl !-

        // ---- pack 8 bitmap bytes: dither, one source row at a time ----
        .for (var s=0; s<8; s++) {
            .for (var j=0; j<4; j++) {
                ldy hudCell + s*4 + j
                .if (j==0) lda ditherTabs + [j*4 + mod(s,4)]*256,y
                .if (j!=0) ora ditherTabs + [j*4 + mod(s,4)]*256,y
            }
            sta zTmp+s
        }

        // ---- zHudOff8 = zHudN * 8 ----
        lda zHudN
        sta zHudOff8
        lda zHudN+1
        sta zHudOff8+1
        .for (var k=0; k<3; k++) {
            asl zHudOff8
            rol zHudOff8+1
        }

        // ---- BITMAP0 + off8, 8 bytes ----
        lda zHudOff8
        clc
        adc #<BITMAP0
        sta zHudPtr
        lda zHudOff8+1
        adc #>BITMAP0
        sta zHudPtr+1
        ldy #0
        .for (var s=0; s<8; s++) {
            lda zTmp+s
            sta (zHudPtr),y
            iny
        }

        // ---- BITMAP1 + off8, 8 bytes ----
        lda zHudOff8
        clc
        adc #<BITMAP1
        sta zHudPtr
        lda zHudOff8+1
        adc #>BITMAP1
        sta zHudPtr+1
        ldy #0
        .for (var s=0; s<8; s++) {
            lda zTmp+s
            sta (zHudPtr),y
            iny
        }

        // ---- attributes: sample pixel (row 3, px 1) picks the ramp ----
        ldx hudCell + 13
        ldy #0

        lda zHudN
        clc
        adc #<SCREEN0
        sta zHudPtr
        lda zHudN+1
        adc #>SCREEN0
        sta zHudPtr+1
        lda scrTab,x
        sta (zHudPtr),y

        lda zHudN
        clc
        adc #<SCREEN1
        sta zHudPtr
        lda zHudN+1
        adc #>SCREEN1
        sta zHudPtr+1
        lda scrTab,x
        sta (zHudPtr),y

        // $D800 directly, not COLBUF -- flip only ever copies COLBUF's first
        // 880 bytes (main.asm's clearHudRows makes the same choice).
        lda zHudN
        clc
        adc #<$d800
        sta zHudPtr
        lda zHudN+1
        adc #>$d800
        sta zHudPtr+1
        lda colTab,x
        sta (zHudPtr),y
        rts

//------------------------------------------------------------
// hudDrawDigit -- zHudDigit (0-9), zHudCol (leftmost cell column, 0-39) ->
// blits STTNUM's HUD_FONT_CELLS_W x _H (2x2) cells for that digit, row-major
// within the glyph (matching wad2reu.py's build_hudfont), at absolute cell
// rows 22+HUD_GLYPH_ROW .. +HUD_GLYPH_ROW+1.
//------------------------------------------------------------
hudDrawDigit:
        // zHudGlyphBase = HUDFONT_STAGE + digit * HUD_FONT_GLYPH_BYTES (128)
        lda zHudDigit
        lsr
        clc
        adc #>HUDFONT_STAGE
        sta zHudGlyphBase+1
        lda zHudDigit
        and #1
        beq !even+
        lda #$80
        jmp !setlo+
!even:  lda #$00
!setlo: clc
        adc #<HUDFONT_STAGE
        sta zHudGlyphBase
        bcc !+
        inc zHudGlyphBase+1
!:
        // Both addresses below are computed fresh from a stable base each
        // time, never incremented across unrolled iterations, on purpose:
        // a data-dependent branch (bcc/bne) inside a compile-time .for
        // unroll needs a uniquely-named target every time it appears, since
        // an anonymous !+/!- binds to the *textually nearest* anonymous
        // label and two branches a few bytes apart from separate unrolled
        // iterations is exactly the shape that resolves to the wrong one.
        // cellOffset and the row's cell-index base are compile-time
        // constants (cy, cx are .for variables), so adc #<const> / adc #0
        // carries the one possible overflow with no branch at all.
        .for (var cy=0; cy<HUD_FONT_CELLS_H; cy++) {
            .for (var cx=0; cx<HUD_FONT_CELLS_W; cx++) {
                .var cellOfs = [cy*HUD_FONT_CELLS_W + cx] * 32
                lda #<[[22+HUD_GLYPH_ROW+cy]*40]
                clc
                adc zHudCol
                adc #cx
                sta zHudN
                lda #>[[22+HUD_GLYPH_ROW+cy]*40]
                adc #0
                sta zHudN+1
                lda zHudGlyphBase
                clc
                adc #<cellOfs
                sta zHudSrc
                lda zHudGlyphBase+1
                adc #>cellOfs
                sta zHudSrc+1
                jsr hudBlitCell
            }
        }
        rts

//------------------------------------------------------------
// hudDrawField -- A = value (0-255), X = field's leftmost cell column
// (0-39). Draws HUD_DIGITS glyphs, most significant first, each
// HUD_FONT_CELLS_W cells wide.
//------------------------------------------------------------
hudDrawField:
        sta zHudVal
        stx zHudCol

        ldx #0
!:      lda zHudVal
        cmp #100
        bcc !d100+
        sbc #100
        sta zHudVal
        inx
        jmp !-
!d100:  stx zHudDigit
        jsr hudDrawDigit
        lda zHudCol
        clc
        adc #HUD_FONT_CELLS_W
        sta zHudCol

        ldx #0
!:      lda zHudVal
        cmp #10
        bcc !d10+
        sbc #10
        sta zHudVal
        inx
        jmp !-
!d10:   stx zHudDigit
        jsr hudDrawDigit
        lda zHudCol
        clc
        adc #HUD_FONT_CELLS_W
        sta zHudCol

        lda zHudVal
        sta zHudDigit
        jsr hudDrawDigit
        rts

//------------------------------------------------------------
// hudBoot -- IMPLEMENTATION_PLAN.md §13. Paints the status bar exactly once:
// the HUD_BG_CELLS_W x _H background, then three fixed-value digit fields.
// Called once from bootMain, after clearHudRows. There is no runtime update
// path -- M2 has no code RAM left for a dirty-flag mechanism -- so
// hudHealth/hudArmor/hudAmmo are read once, here, rather than every frame;
// M3 is what makes them live.
//------------------------------------------------------------
hudBoot:
        lda #<HUDBG_STAGE
        sta zHudSrc
        lda #>HUDBG_STAGE
        sta zHudSrc+1
        lda #<[22*40]                // cell 880, the bar's top-left cell
        sta zHudN
        lda #>[22*40]
        sta zHudN+1
        lda #0
        sta zHudCnt                  // NOT X -- hudBlitCell clobbers it
hudBgLoop:
        jsr hudBlitCell
        lda zHudSrc
        clc
        adc #32
        sta zHudSrc
        bcc !+
        inc zHudSrc+1
!:      inc zHudN
        bne !+
        inc zHudN+1
!:      inc zHudCnt
        lda zHudCnt
        cmp #HUD_BG_CELLS_W*HUD_BG_CELLS_H
        bne hudBgLoop

        lda hudAmmo
        ldx #HUD_AMMO_COL
        jsr hudDrawField
        lda hudHealth
        ldx #HUD_HEALTH_COL
        jsr hudDrawField
        lda hudArmor
        ldx #HUD_ARMOR_COL
        jsr hudDrawField
        rts

// hudBlitCell's working copy of the cell it is packing. Lives here, in
// boot-only MATRIX, for the same reason everything else in BOOTCODE6 does.
hudCell:
        .fill HUD_CELL_BYTES, 0

//------------------------------------------------------------
// mapCopyStaged — MATRIX -> (zMLDst), zMLLen bytes, with RAM
// banked in at $d000. Leaves a 16-bit sum of the block in
// mapSum[zMLId].
//
// Whole pages first, then the tail; Y indexes both halves.
//
// The sum is here rather than in a separate pass because this is
// the only code that ever has the block in front of it with $d000
// banked as RAM, and it is the only way a host can check that the
// node and sector tables arrived: machine:readmem on the Ultimate
// DMAs the bus as the engine has it banked, so $d000 reads back
// the I/O registers.
//
// It is a plain sum of bytes, so it is blind to a reordering. That
// is the right weight for what it has to catch -- "nothing
// arrived", "half of it arrived", "the previous image is still
// there" -- and it costs 8 cycles a byte at boot, once.
//------------------------------------------------------------
mapCopyStaged:
        lda #<MATRIX
        sta zMLSrc
        lda #>MATRIX
        sta zMLSrc+1
        lda #0
        sta zMLSum
        sta zMLSum+1
        lda #BANK_RAM
        sta $01

        ldy #0
        ldx zMLLen+1
        beq mapCopyTail
mapCopyPage:
        lda (zMLSrc),y
        sta (zMLDst),y
        clc
        adc zMLSum
        sta zMLSum
        bcc !+
        inc zMLSum+1
!:      iny
        bne mapCopyPage
        inc zMLSrc+1
        inc zMLDst+1
        dex
        bne mapCopyPage

mapCopyTail:
        ldx zMLLen
        beq mapCopyDone
        ldy #0
mapCopyByte:
        lda (zMLSrc),y
        sta (zMLDst),y
        clc
        adc zMLSum
        sta zMLSum
        bcc !+
        inc zMLSum+1
!:      iny
        dex
        bne mapCopyByte

mapCopyDone:
        lda #BANK_IO
        sta $01
        ldx zMLId                   // publish the sum for the host to check
        lda zMLSum
        sta mapSum,x
        lda zMLSum+1
        sta mapSum+1,x
        rts

//------------------------------------------------------------
// Per-block-id tables, indexed by the id byte out of the image.
//------------------------------------------------------------
mapMagicStr: .text "D64U"

mapLoadHi:   .byte >MAPINFO,   >NODETAB,   >SECTAB,   $00
mapMaxLenLo: .byte <MAPINFOSZ, <NODETABSZ, <SECTABSZ, $00
mapMaxLenHi: .byte >MAPINFOSZ, >NODETABSZ, >SECTABSZ, $00

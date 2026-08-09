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

.const MAPINFOSZ = 32
.const NODETABSZ = NODETAB_END - NODETAB
.const SECTABSZ  = SECTAB_END - SECTAB

// How many descriptors can physically fit in the 64-byte header.
.const MAXDESCS = [HDRSIZE - 8] / 8

// The mapErr values live in defs.asm with every other .const: main.asm
// reports one of them itself and is assembled before this file.

//------------------------------------------------------------
// mapLoad — carry set on success. Sets mapOK/mapErr either way.
//------------------------------------------------------------
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
        beq mapNextBlock                // streamed: nothing to do at boot

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

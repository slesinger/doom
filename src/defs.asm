//============================================================
//  defs.asm — shared constants: memory map + zero page
//  Imported first; keep ALL .const here so every module sees them.
//============================================================

//------------------------------------------------------------
// memory map
//------------------------------------------------------------
.const MATRIX  = $1000
.const SCREEN0 = $8000
.const TABLES  = $8400
.const BITMAP0 = $a000
.const SCREEN1 = $c000
.const BITMAP1 = $e000
.const COLBUF  = $0400

// The viewport, in rows and in cell-rows. IMPLEMENTATION_PLAN.md §14a.1 cut
// 176 -> 160 and §12 cut 160 -> 144: sprites and the weapon view need ~2 KB of
// *contiguous, code-capable* RAM and this is the only lever in the machine that
// produces any (§14a.7). It also returns ~1.1 ms of compute, on the same
// measured basis as the last cut -- a quarter of what the row percentage
// predicts, because renderFrame's cost is per-seg and per-column, not per-row.
//
// **The 32 rows come off symmetrically: 16 from the top and 16 from the
// bottom.** Taking them all off the bottom would have been cheaper to write --
// the buffer starts at row 0 either way -- but it drops the camera's eye level
// from the middle of the picture to two thirds of the way down it, which reads
// as permanently looking at the ceiling. Symmetric keeps the horizon where the
// player's eye already expects it, at physical raster row 88, and splits the
// letterbox into two 16-row bands instead of one 32-row band at the bottom.
//
// Two separate coordinate systems fall out of that, and mixing them is the
// bug this comment exists to prevent:
//
//   * MATRIX rows 0..VIEWROWS-1 are what the renderer writes. The horizon in
//     *this* space is HORIZON = 72, the middle of the buffer -- that is the
//     number projRow subtracts from (src/render/walls.asm).
//   * Physical raster rows 0..199 are what the VIC shows. The view is shifted
//     down by VIEWTOP = 16, so MATRIX row 0 lands on raster row 16 and the
//     horizon lands back on raster 88. The converter applies the shift once,
//     as a constant offset added to its three output pointers (initFrame,
//     src/render/chunky2mc.asm) -- nothing downstream of MATRIX knows about it.
//
// Everything that indexes the buffer vertically must read these and not a
// literal: rowCellLo/Hi's length and spanPrep's clamps (src/math.asm),
// renderFrame's colBot seed (src/render/bsp.asm), projRow's horizon
// (src/render/walls.asm), the converter's page count, initFrame's origin and
// flip's colour-RAM burst (src/render/chunky2mc.asm), and clearHudRows' two
// letterbox bands (src/main.asm). 160 appears in walls.asm too and is
// *columns* -- leave it.
.const VIEWROWS     = 144
.const VIEWCELLROWS = VIEWROWS / 8          // 18
.const VIEWCELLS    = VIEWCELLROWS * 40     // 720: colour bytes flip copies
.const HORIZON      = VIEWROWS / 2          // 72, eye level in MATRIX rows
.const VIEWTOP      = 16                    // first raster row the view occupies
.const VIEWCELLTOP  = VIEWTOP / 8           // 2 cell-rows of top letterbox
.const VIEWCELLOFS  = VIEWCELLTOP * 40      // 80: screen/colour cells to skip
.const VIEWBMPOFS   = VIEWCELLTOP * 320     // 640: bitmap bytes to skip
.errorif VIEWROWS != VIEWCELLROWS * 8, "the viewport must be a whole number of cell-rows"
.errorif VIEWTOP != VIEWCELLTOP * 8, "the top letterbox must be a whole number of cell-rows"
// The HUD's four cell-rows are fixed at raster 168; the view plus both bands
// must fit above them, or the converter writes over the bar.
.errorif VIEWTOP + VIEWROWS > 168, "the view and its top letterbox overrun the HUD"

// Wall texture tiles, resident, in the tail the 160-row viewport freed.
//
// MATRIX is 28160 B ($1000-$7dff) and the renderer now writes only the first
// MATRIX_LIVE ($1000-$69ff) -- IMPLEMENTATION_PLAN.md §14a.1 cut 176 rows to
// 160 and nothing had claimed what that freed. This is the claim: sixteen
// families of 128 bytes, loaded once by texLoad (src/mapload.asm) and never
// moved. §12's further cut to 144 opened the block below it (SPRFREE).
//
// **Residency is not an optimisation here, it is the phase.** A 16x16 tile is
// 128 B against Stage A's 32, and Stage A re-fetched the tile *per seg*: at
// ~68 walls a frame that would be 8.7 KB of REU DMA per frame, i.e. 8.7 ms on
// hardware at the REU's flat 1 byte/us (§5 risk 1), against a 13 ms budget.
// Resident, the per-frame DMA is zero -- which also deletes Stage A's own
// 2.2 KB/frame and is worth ~2.2 ms before the finer tile costs anything.
//
// It is safe under the first frame for the same reason BOOTCODE is not: boot
// staging reaches MATRIX+$573f (HUDFONT_STAGE) and the live buffer ends at
// $69ff, so $7600 is under neither.
.const WALLTILE     = MATRIX + $6600        // $7600-$7dff, 16 x 128 B
.const WALLTILE_LEN = 16 * 128
.errorif WALLTILE + WALLTILE_LEN > MATRIX + 28160, "wall tiles run past MATRIX"

// The block §12's viewport cut opened: $6a00-$75ff, 3072 B between the live
// chunky buffer and the wall tiles. It is the only contiguous code-capable
// RAM the machine has left (IMPLEMENTATION_PLAN.md §14a.7), which is the whole
// reason the cut was taken, and §12 plus §12a spend all of it.
//
// **Code here is in the PRG image and runs from where it loads** -- no
// .pseudopc relocation, unlike BOOTCODE/LINECODE/MUSCODE. That is not a
// stylistic choice: the PRG already spans $0801-$cffd, so these bytes cost the
// image nothing, and this block is above both the live buffer and everything
// mapLoad stages (which ends at HUDFONT_STAGE, $673f). The one thing it is not
// is *diffed*: probe.py allows all of $1000-$7dff as MATRIX, so `make check`
// would not notice a stray write landing on this code. WALLTILE has always had
// the same exposure.
.const SPRFREE      = MATRIX + VIEWROWS*160 // $6a00, first byte past the view
.const SPRFREE_END  = WALLTILE              // $7600
.errorif SPRFREE >= SPRFREE_END, "the viewport cut left no room below the wall tiles"

// Per-column seed for renderFrame's colBot, 160 bytes. VIEWROWS everywhere the
// weapon does not reach, and the weapon's silhouette where it does -- so the
// world is never drawn behind the gun (IMPLEMENTATION_PLAN.md §12a). Written
// by wpnPrep once a frame, read by renderFrame's opening loop; a table rather
// than an immediate because §12's sprites want the same hook.
.const colBotSeed   = SPRFREE               // 160 B, $6a00-$6a9f

// The weapon view. wpnSil is the resident silhouette (one row per column,
// fetched once at boot); wpnArtBase is the REU address of the art after it,
// which is streamed a row at a time every frame and is zero when the image
// carries no weapon block, which wpnFrame reads as "draw nothing".
.const wpnSil       = SPRFREE + 160         // 40 B,  $6aa0-$6ac7
.const wpnArtBase   = SPRFREE + 200         // 3 B,   $6ac8
.const wpnRow0      = SPRFREE + 203         // this frame's top MATRIX row
.const wpnRows      = SPRFREE + 204         // rows that fit below it
.const wpnOK        = SPRFREE + 205         // nonzero once the block has loaded
.const WPNCODE      = SPRFREE + $100        // $6b00-$6cff
.const WPNCODE_END  = SPRFREE + $300

// §12's sprites: static props (barrels, lamps, corpses -- "drawn, not animated
// and not intelligent"), 7 distinct E1M1 THINGS types, 33 instances. Resident
// art, not streamed (§14a.2's recommendation, adopted): a 33-instance level
// has only 7 *distinct* pictures, so residency is a fixed ~1 KB charge against
// SPRART's 2048 B rather than a per-frame REU cost that scales with what is on
// screen. wad2reu.py's WPN_* comment applies here too: every constant below
// with a matching name in that file must move with its Python twin.
//
// wpnFrame moved out to WPNBLIT (below, the 277 B behind BODYCODE) to free
// room in WPNCODE for sprite code -- SPRCODE2 is that freed tail. wpnBoot and
// wpnPrep together measure well under the 128 B WPNCODE keeps for them; the
// rest is sprite code, split the same bin-packed way tex.asm's eleven pieces
// are, because SPRCODE2 and SPRCODE are what the machine has, not what a
// single contiguous routine would want.
.const WPNPREP_END  = WPNCODE + $50         // $6b50: wpnBoot(27B)+wpnPrep(46B)
                                            // measure 73 B; $50=80 leaves 7 B
                                            // margin, handing the rest to
                                            // SPRCODE2 below (Opus-advised,
                                            // §12 sizing pass)
.const SPRCODE2     = WPNPREP_END           // $6b50-$6cff, 432 B
.errorif SPRCODE2 >= WPNCODE_END, "wpnBoot/wpnPrep budget overruns WPNCODE"

.const SPRART       = SPRFREE + $300        // $6d00-$74ff, 2048 B
.const SPRART_END   = MATRIX + $6500        // = MOVECODE
.errorif WPNCODE_END > SPRART, "the weapon code overruns the sprite art"
.errorif SPRART_END > SPRFREE_END, "the sprite art runs past the free block"

// ---- Block 11, THINGS: resident, docs/reu-format.md §4.10 ----
//
// MAXSSEC = 237, E1M1's own subsector count (mapinfo carries the real count
// too; this is a compile-time buffer bound, not read at runtime). Things are
// emitted by wad2reu.py sorted by subsector, so sprSsecFirst is a pure prefix
// index: subsector i's things are thingType[sprSsecFirst[i] .. sprSsecFirst[i+1]).
.const MAXSSEC       = 237
.const MAXTHINGS     = 36                   // 33 in-scope E1M1 things + slack
.const NUM_SPRTYPES  = 7

.const SPRDATA       = SPRART                       // $6d00
.const sprSsecFirst  = SPRDATA                       // MAXSSEC+1 bytes
.const thingXlo      = sprSsecFirst + MAXSSEC + 1
.const thingXhi      = thingXlo + MAXTHINGS
.const thingYlo      = thingXhi + MAXTHINGS
.const thingYhi      = thingYlo + MAXTHINGS
.const thingType     = thingYhi + MAXTHINGS         // index into the type table
// No thingZ: every §12 prop stands on its own subsector's floor, which
// sprPick already has in zDzF (secFront runs before it, bsp.asm) -- storing a
// z here would just be that same value, baked stale, for 72 bytes.
// "Typ" prefix throughout, not "spr": the zero-page draw scratch below (spr*)
// is a different namespace and one pair (sprH/sprW) would otherwise collide.
.const sprTypArtLo   = thingType + MAXTHINGS        // type table, SoA, 7 each
.const sprTypArtHi   = sprTypArtLo + NUM_SPRTYPES
.const sprTypW       = sprTypArtHi + NUM_SPRTYPES   // art box width, columns
.const sprTypH       = sprTypW + NUM_SPRTYPES       // art box height, rows
// No precomputed 8.8 u/v-step-per-world-ry coefficients: sprDraw computes
// uStep/vStep at draw time from sprTypHW/sprTypWH instead (two extra divides
// a frame per visible thing, accepted for the simpler, less bug-prone code
// over shaving a worst-case ~0.24 ms -- IMPLEMENTATION_PLAN.md §12 notes).
.const sprTypHW      = sprTypH + NUM_SPRTYPES       // world half-width
.const sprTypWH      = sprTypHW + NUM_SPRTYPES      // world height
.const SPRDATA_END   = sprTypWH + NUM_SPRTYPES
.const THINGS_LEN    = SPRDATA_END - SPRDATA        // fixed: every field above
                                                    // is a compile-time bound,
                                                    // not sized to the WAD's
                                                    // actual thing count -- so
                                                    // thingsLoad (mapload.asm)
                                                    // can length-check it like
                                                    // texLoad does WALLTILE_LEN
.errorif SPRDATA_END - SPRDATA > 588, "block 11 (THINGS) overruns its budget"

// ---- Runtime: the visible-thing list, rebuilt every frame in renderSsec's
// wake (bsp.asm), sorted back-to-front, then walked once by sprFrame. ----
//
// 6, not 10: §12.6's stress pass (E1M1's busiest sightline, sector 72) never
// saw more than sprVisN = 6, so four of the original ten slots were margin
// nobody had exercised -- this is that peak exactly, with no headroom left
// above it. The 32 bytes those four slots cost across the eight SoA arrays
// below are what the 1351 mouse's turn code (mouseTurn, src/render/
// sprite.asm) is spending -- SPRCODE3 is the only code-capable gap left in
// the machine (§14a.7). mouseTurn's glitch guard (added after MAXVIS=7 still
// overflowed by 8 B) is what used the last slot of margin; if a busier
// sightline than sector 72 ever needs a 7th visible thing, something else in
// SPRCODE3 has to shrink first, or a MAXVIS=7 pass has to come back and take
// its 8 B from somewhere other than mouseTurn.
.const MAXVIS        = 6
.const sprVisRXlo    = SPRDATA_END
.const sprVisRXhi    = sprVisRXlo + MAXVIS
.const sprVisRYlo    = sprVisRXhi + MAXVIS
.const sprVisRYhi    = sprVisRYlo + MAXVIS
.const sprVisIdx     = sprVisRYhi + MAXVIS          // thing index, 0..MAXTHINGS-1
.const sprVisDZlo    = sprVisIdx + MAXVIS           // eye-relative floor Z, captured
.const sprVisDZhi    = sprVisDZlo + MAXVIS          // from zDzF at pick time (secFront
                                                     // runs per-subsector; sprDraw runs
                                                     // after the whole BSP walk is done)
.const sprVisPerm    = sprVisDZhi + MAXVIS          // sort permutation
.const sprVisN       = sprVisPerm + MAXVIS          // 1 B: entries used this frame
.const SPRVIS_END    = sprVisN + 1

// A third sprite-code slot: the unclaimed gap between SPRVIS_END and SPRIMG
// (page-aligned at SPRART+$300). block 11's fields are all compile-time
// bounds (comment above), so this shrinks if MAXSSEC/MAXTHINGS/MAXVIS ever
// do -- the errorif below (after SPRIMG is defined) is load-bearing, not
// decorative (Opus-advised, §12 sizing pass).
.const SPRCODE3      = SPRVIS_END

// ---- Block 12, SPRIMG: resident, docs/reu-format.md §4.11 ----
//
// Column-major, one byte per pixel, %rrrriiii with the type's ramp baked in at
// build time, $00 = transparent (SPR_CLEAR, same convention as WPN_CLEAR).
// Byte-per-pixel and not 4-bit packed, unlike WPNART: the blit is a straight
// `lda (src),y / beq skip / sta (dst),y` with no nibble unpack, which the
// pixel count here (a scaled blit, not a 1:1 one like the gun) needs more than
// it needs the extra ~500 B back. Page-aligned so a type's ArtLo/ArtHi can
// point straight at a column without a per-type base-plus-offset add.
.const SPRIMG        = SPRART + $300                // $7000, page-aligned
.const SPRIMG_CAP    = $400                          // 1024 B
.errorif SPRCODE3 >= SPRIMG, "the visible list overruns the sprite code hole"

.const SPR_CLEAR     = 0                    // intensity 0 = transparent
.const SPR_NEAR      = 160                  // world units; nearer is not culled
                                            // further but a frame at SPR_NEAR is
                                            // the priced worst case (§12.4)
.const SPR_BIAS      = 1                    // subtracted from a sprite's own
                                            // quantised depth before the wall
                                            // compare -- ties favour the sprite

// ---- Sprite code, in two pieces the way tex.asm's are ----
.const SPRCODE       = SPRIMG + SPRIMG_CAP  // $7400-$74ff, 256 B
.errorif SPRCODE + 256 != SPRART_END, "SPRCODE sizing does not tile SPRART"

// wpnFrame, moved out of WPNCODE to make room for SPRCODE2 above. 277 B behind
// BODYCODE ($7e00-$7eea, src/input.asm's §11d) and the end of MATRIX -- the
// .errorif against BODYCODE lives with BODYCODE's own definition, below.
.const WPNBLIT       = $7eeb

// The weapon's geometry. Every one of these is also a constant in
// tools/wad2reu.py under the same name, and the pair must move together --
// the .reu block is WPN_SIL_BYTES + WPN_ART_BYTES long and weaponLoad rejects
// any other length with MERR_SIZE, so a mismatch fails at boot rather than
// drawing rubbish. See that file's own header for why 40 columns and not 96.
.const WPN_W         = 40                   // columns, 10 cells of 4
.const WPN_H         = 56                   // rows, 7 cell-rows of 8
.const WPN_COL0      = 60                   // leftmost column, (160-40)/2
.const WPN_ROW0      = VIEWROWS - WPN_H     // 88, unbobbed top MATRIX row
.const WPN_ROW_BYTES = WPN_W / 2            // 20, two pixels per byte
.const WPN_SIL_BYTES = WPN_W                // 40
.const WPN_ART_BYTES = WPN_H * WPN_ROW_BYTES
.const WPN_BYTES     = WPN_SIL_BYTES + WPN_ART_BYTES
.const WPN_RAMP      = 14                   // chunky2mc.asm's "gun" ramp
.const WPN_CLEAR     = 0                    // intensity 0 = transparent
.errorif WPN_COL0 + WPN_W > 160, "the weapon runs off the right of the view"
.errorif [WPN_COL0 & 3] != 0 || [WPN_W & 3] != 0, "the weapon must be cell-aligned in x"
.errorif [WPN_ROW0 & 7] != 0 || [WPN_H & 7] != 0, "the weapon must be cell-aligned in y"

// The substepped move (moveSteps, src/input.asm), in the 256 bytes between
// what the HUD stages at boot and what the wall tiles hold for good.
//
// This is *runtime* code inside MATRIX, which nothing else here is, and the
// two things that makes it depend on both hold with a margin:
//
//   - the renderer stops at $73ff (the 160-row viewport, §14a.1), so no span
//     ever reaches this page;
//   - boot staging stops at $673f (HUDFONT_STAGE + HUD_FONT_BYTES), well below
//     this page, so the loader does not overwrite it between the PRG landing
//     and the first frame.
//
// It is in the PRG image like ordinary code -- the image already spans this
// address (BOOTCODE6 ends at $6049) -- so unlike LINECODE and MUSCODE there is
// no relocator and no `make check` entry.
//
// It exists at all because the main segment has one byte free (main.asm's
// .errorif against SPHCODE) and below MATRIX the largest unclaimed run is
// five bytes. §11d's substepping is ~110 bytes.
.const MOVECODE     = MATRIX + $6500        // $7500-$75ff, 256 B
.const MOVECODE_END = WALLTILE

// The radius test (segBody, segPush -- src/input.asm), in the 512 bytes
// between the end of MATRIX and the video matrix.
//
// MATRIX is 28160 B because that is 176 rows of 160, and the wall tiles end
// exactly on its last byte; $7e00-$7fff is what the map has always had left
// over there. Nothing reads or writes it: the renderer's row bases stop at
// $73ff (math.asm's rowCellLo/Hi), the VIC is looking at bank 2 ($8000-$bfff)
// and cannot see this page at all, and boot staging never comes near it.
// `make check`'s live-RAM diff is what keeps that honest.
.const BODYCODE     = $7e00
.const BODYCODE_END = SCREEN0
.errorif WPNBLIT + 277 > BODYCODE_END, "WPNBLIT overruns the end of MATRIX"

.const CONVERTER_CODE = $9900

// Free RAM at the tail of the TABLES segment: 448 B, $9740-$98FF. 352 of them
// came from deleting the dead scanline-major rowLo/rowHi pair (the rasterizer
// uses the cell-major rowCell tables in math.asm); the rest was always slack.
// Unclaimed — the first candidate for the E1M1 resident blocks. main.asm's
// .errorif keeps the converter tables from growing back into it.
.const TABLES_FREE     = $9740
.const TABLES_FREE_END = $98ff
.const MATHCODE       = $9b60      // follows converter code
.const MATHTAB        = $c400
// $ca28 and not $ca30: the math tables end at $ca27 and the eight bytes to the
// next round address were slack. doWall's near-plane fail-safe needed two of
// them (walls.asm, !reject) and the block was already flush against TX_COL.
.const WALLSCODE      = $ca28

// per-column clip windows (page aligned). colTop/colBot each own a full
// dedicated page: with spanFill's zSX bounds check in place a stray write
// can no longer land here, but keeping the pages private removes the
// aliasing hazard entirely instead of relying solely on that check.
.const colTop  = $0200              // first open row
.const colBot  = $0300              // first closed row below

// Frame-time statistics, in colTop's unused tail: the renderer touches columns
// 0-159 only, so $02a0-$02af is free RAM that is *outside* the PRG image, which
// is what this needs -- runtime writes inside the image show up in
// tools/vicedbg/probe.py's live-RAM diff as unexplained differences, which is
// the trade instrument.asm's counters accept and this does not have to.
//
// Why the engine has to measure this itself: the host can divide frameCnt by
// wall-clock seconds and get an average frame time, but `flip` quantises that
// to a multiple of 19.95 ms, so the average says how many frames missed a
// deadline and nothing about by how much. Compute time is the number that
// decides whether more optimisation is worth anything, and only the machine
// can see it (IMPLEMENTATION_PLAN.md §16).
//
// Units are Timer B ticks, 1.015 ms each -- see FPS_CAP_TICKS.
.const ftInt   = $02a0              // the last flip-to-flip interval
.const ftComp  = $02a2              // the last frame's compute, flip -> framePace
.const ftCMin  = $02a4              // compute, min over the run
.const ftCMax  = $02a6              // compute, max over the run
.const ftHist  = $02a8              // 4 x 16-bit: frames that cost 1, 2, 3, 4+
                                    // raster frames. $02a8-$02af

// The wall texture working set is in zero page -- see the $c4 block below.
// It was going to live here, in colTop's tail, and moving it out is what
// widened this page's free tail to the 80 bytes texVSet is assembled into.

// BSP descent stack, in the free RAM below MATRIX -- the address the portal
// stack used to occupy. One 16-bit entry (a raw child word, subsector bit and
// all) per node on the path from the root down to the leaf being rendered, so
// the depth needed is the tree's depth, not its node count: E1M1's 236 nodes
// nest about 20 deep. Overflowing drops a far subtree, which costs pixels and
// nothing else, so the push is guarded rather than asserted.
.const bspStkLo  = $0f00            // BSPSTKMAX entries
.const bspStkHi  = $0f20
.const BSPSTKMAX = 32

//------------------------------------------------------------
// map residency — where build/assets.reu lands in the machine.
//
// The layout, the block ids and the packed record formats are frozen in
// docs/reu-format.md; tools/wad2reu.py writes the other half of that contract.
// The image carries each resident block's load address as well, and mapload.asm
// checks the two agree, so a stale assets.reu is caught at boot rather than
// rendering as garbage.
//
// Everything resident lives under the I/O space, which is 4 KB of RAM nothing
// else claims. That keeps the whole $0BC6-$0DFF free block available for the
// BSP stack, and it is why the capacities below are 240/96 rather than E1M1's
// exact 236/85: the two blocks then end at $DEFF, one page short of the REU
// registers at $DF00.
//------------------------------------------------------------
.const MAXNODES = 240               // capacity of the resident node arrays
.const MAXSEC   = 96                // capacity of the resident sector arrays

.const NODETAB  = $d000             // 12 SoA arrays of MAXNODES bytes
.const ndPxLo     = NODETAB +  0*MAXNODES
.const ndPxHi     = NODETAB +  1*MAXNODES
.const ndPyLo     = NODETAB +  2*MAXNODES
.const ndPyHi     = NODETAB +  3*MAXNODES
.const ndDxLo     = NODETAB +  4*MAXNODES
.const ndDxHi     = NODETAB +  5*MAXNODES
.const ndDyLo     = NODETAB +  6*MAXNODES
.const ndDyHi     = NODETAB +  7*MAXNODES
.const ndRightLo  = NODETAB +  8*MAXNODES
.const ndRightHi  = NODETAB +  9*MAXNODES
.const ndLeftLo   = NODETAB + 10*MAXNODES
.const ndLeftHi   = NODETAB + 11*MAXNODES
.const NODETAB_END = NODETAB + 12*MAXNODES      // $db40

.const SECTAB   = $dc00             // 6 SoA arrays of MAXSEC bytes
.const mapSecFloorLo = SECTAB + 0*MAXSEC
.const mapSecFloorHi = SECTAB + 1*MAXSEC
.const mapSecCeilLo  = SECTAB + 2*MAXSEC
.const mapSecCeilHi  = SECTAB + 3*MAXSEC
.const mapSecFByte   = SECTAB + 4*MAXSEC
.const mapSecCByte   = SECTAB + 5*MAXSEC
.const SECTAB_END = SECTAB + 6*MAXSEC           // $de40

.errorif SECTAB < NODETAB_END, "node table overruns the sector table"
.errorif SECTAB_END > $df00, "resident map tables overrun the REU registers"

//------------------------------------------------------------
// Doors and moving sectors (IMPLEMENTATION_PLAN.md §11) — tables *and* code,
// in the RAM under the I/O space.
//
// This is the largest free RAM in the machine and M2 had not touched it:
// $DB40-$DBFF (192 B, the tail of NODETAB's page), $DE40-$DEFF (192 B, after
// SECTAB) and $DF00-$DFFF (256 B, under the REU's own registers). 640 bytes,
// against the ~90 bytes of low RAM that tex.asm left in ten fragments.
//
// Putting *code* there is new and it is not a stunt: every routine in this
// phase reads sector heights, which are at $DC00 and only exist with
// $01 = BANK_RAM, so the whole feature had to run in that banking state
// anyway. What it costs is the trampoline (lineTramp, in low RAM) and an
// `sei` around it -- with I/O banked out the music IRQ would write its SID
// registers into RAM, so the window is closed rather than merely survived.
// The window is a few hundred cycles a frame; the CIA latch keeps running
// underneath it, so the tick is delayed, never lost (src/music.asm).
//
// The line tables are loaded, not assembled: block 7 of the image, split
// into these two homes by lineLoad at boot (docs/reu-format.md §4.8). They
// are streamed rather than resident because a block descriptor carries only
// a load *page* and neither hole starts on one.
// A record carries no geometry: activation is by sector, not by a line
// crossing (IMPLEMENTATION_PLAN.md §11.2a). `ldSec` is the sector that moves,
// `ldTrig` the sector whose entry -- or whose presence in front of the eye --
// fires it. For a door those are the same sector, which is what the use scan
// matches against a seg's back sector; for a walkover they differ, and the
// line emits one record per side so it fires from either direction.
.const MAXLINES = 16                // must match wad2reu.py MAXLINES

.const LINESPEC = $db40             // 5 SoA arrays of MAXLINES
.const ldKind   = LINESPEC + 0*MAXLINES
.const ldSec    = LINESPEC + 1*MAXLINES
.const ldTrig   = LINESPEC + 2*MAXLINES
.const ldTgtLo  = LINESPEC + 3*MAXLINES
.const ldTgtHi  = LINESPEC + 4*MAXLINES
.const LINESPEC_END = LINESPEC + 5*MAXLINES     // $db90
.const LINEDEFSZ = 5*MAXLINES       // block 7's length, checked at load

// Line kinds and flags, from wad2reu.py's LK_*/LF_*.
.const LK_NONE  = 0
.const LK_DOOR  = 1                 // use: ceiling up, wait, back down
.const LK_LIFT  = 2                 // walkover: floor down, wait, back up
.const LK_FLOOR = 3                 // walkover: floor down, once, no return
.const LK_EXIT  = 4                 // use: nothing yet -- M3's level change
.const LK_MASK  = %00001111
.const LF_WALK  = %00010000         // crossing fires it, not the use key
.const LF_REPEAT = %00100000        // may fire again once it has finished

// The thinker list: eight moving sectors, which is more than E1M1 ever has
// active at once. SoA, one array per field, indexed by slot.
.const MAXTHINK = 8
.const THINK    = LINESPEC_END      // $db90
.const thKind   = THINK + 0*MAXTHINK
.const thSec    = THINK + 1*MAXTHINK
.const thTgtLo  = THINK + 2*MAXTHINK    // where it is going
.const thTgtHi  = THINK + 3*MAXTHINK
.const thHomeLo = THINK + 4*MAXTHINK    // the height it started at
.const thHomeHi = THINK + 5*MAXTHINK
.const thState  = THINK + 6*MAXTHINK    // TH_* below; 0 = slot free
.const thWait   = THINK + 7*MAXTHINK    // frames left in TH_WAIT
.const THINK_END = THINK + 8*MAXTHINK   // $dbd0

.const TH_FREE  = 0
.const TH_GOING = 1                 // moving towards the target
.const TH_WAIT  = 2                 // holding open / down
.const TH_BACK  = 3                 // returning home

// Movement per *frame*, which is 59.85 ms, not Doom's 28.6 ms tic. Doom's
// door is 2 units/tic and its lift 4, so 1.5x the frame period and a further
// 2x the tic-to-frame ratio put them at 4 and 8. The waits are Doom's own
// (VDOORWAIT 150 tics, PLATWAIT 105) converted to frames at 16.71 fps.
.const DOOR_SPEED = 4
.const LIFT_SPEED = 8
.const FLOOR_SPEED = 2
.const DOOR_WAIT = 71               // 150 tics = 4.3 s
.const LIFT_WAIT = 50               // 105 tics = 3.0 s

// Code, in what the tables leave of the three holes. The split is by run
// order rather than by size: LINECODE is the per-frame thinker, LINECODE2 the
// activation paths, LINECODE3 the room the phase has left to grow into.
.const LINECODE  = THINK_END        // $dbd0-$dbff, 48 B
.const LINECODE_END  = $dc00
.const LINECODE2 = $de40            // $de40-$deff, 192 B, after SECTAB
.const LINECODE2_END = $df00
.const LINECODE3 = $df00            // $df00-$dfff, 256 B, under the REU regs
.const LINECODE3_END = $e000

// MAPINFO's page alignment is load-bearing: a block descriptor carries only
// the high byte of its load address (docs/reu-format.md §2). What used to be
// the free tail of this page is now SPHCODE3 and SSECHDR.
.const MAPINFO  = $0e00             // 32 B, resident block 0

// The 64-byte image header, staged inside MATRIX rather than below it.
// mapLoad walks its block descriptors and is the only code that ever reads it;
// it runs before the first frame, so MATRIX is 28 KB of scratch at that point.
// $5000 is clear of $1000, where the same routine stages each resident block
// (the largest is NODES at 2880 B). Moving it out of $0e20 freed the 64 bytes
// the bounding-sphere test now occupies -- see SPHCODE3.
.const MAPHDR   = MATRIX + $4000

// Boot-only code, on the same argument as MAPHDR one line up: mapLoad runs
// once, before the first frame, and MATRIX is scratch until spanFill writes
// the first one -- so the loader can live in the buffer it is filling. It sat
// in the main segment below $0e00 until the frame-time work needed that space
// for code that runs 150 times a frame, which is the better use of the only
// RAM the engine has left. Clear of both the staging area (MATRIX..+2880, the
// largest resident block) and MAPHDR.
.const BOOTCODE = MATRIX + $4100

// One subsector's segs, DMA'd per visit. In TABLES_FREE rather than in the
// $0e00 page: everything below MAPINFO is code headroom, and the sphere
// compares have taken the last of it -- see main.asm's .errorif.
.const SEGBUF   = TABLES_FREE       // 128 B, $9740-$97bf
.const SEGBUFSZ = 128
.errorif SEGBUF + SEGBUFSZ > TABLES_FREE_END, "SEGBUF overruns TABLES_FREE"

// The eight-byte slot header that precedes those segs, read by its own short
// DMA. Separate from SEGBUF because the second transfer's length depends on
// what the first one says -- docs/reu-format.md §5.
//
//   +0 segCount   +1 sectorId   +2 sphere cx   +4 sphere cy   +6 sphere radius
//
// The sphere is why the header grew from two bytes to eight: with it in the
// first transfer, a subsector that is outside the view can be rejected before
// the second transfer fetches a single seg.
.const SSECHDR  = $0e60             // 8 B, $0e60-$0e67
.const SSECHDRSZ = 8
.const sphCX    = SSECHDR + 2
.const sphCY    = SSECHDR + 4
.const sphR     = SSECHDR + 6

// A node's sphere is DMA'd into the *same* six bytes. Nothing needs both at
// once: the node test runs in bspLoop, before the descent reaches a leaf, and
// renderSsec re-fetches the slot header every time it draws one.
.const NODESPH  = sphCX
.const NODESPHSZ = 6                // cx, cy, r -- the record's 2 pad bytes
                                    // exist only to make the stride a shift

// Collision helpers, out of line from the main segment. $0e70-$0eee, 127 B:
// the tail of the page belongs to the jump now (JUMPCODE, below).
.const COLLCODE = $0e70

// Jumping (src/input.asm), in three fragments, because thirty-odd contiguous
// bytes no longer exist below MATRIX:
//
//   JUMPCODE   $0eef-$0eff  17 B  playerFrame: the mainLoop hook and the
//                                 take-off test. Freed by moving the texture
//                                 clip parameter out to TX_CLIP's new home in
//                                 the wall-shading block's slack.
//   JUMPCODE2  $ffe4-$fff9  22 B  jumpStep: one frame of the arc, in what is
//                                 left of MUSCODE's block above the music IRQ
//                                 handler and below the CPU vectors. Not in
//                                 the PRG image: copied up by lineBoot.
//   JUMPTAB    $0e68-$0e6f   8 B  the arc itself, JUMPFRAMES entries and an
//                                 $ff. SSECHDR's tail hole.
//   JUMPBOOT   $5c00         18 B jumpStep's .pseudopc image, boot-only.
//
// JUMPCODE2 was $0f40 first, on the reading that the gap between the BSP stack
// and BFACECODE was free. It is not: $0f40-$0f50 is frameCnt, reuScratch and
// the map checksums (below), so boot overwrote the routine and the jump
// silently did nothing. $ffe4 costs the copy but is genuinely unowned, and is
// RAM in both banking states, so jumpStep needs no `sei` and no $01.
//
// playerFrame is exactly 17 bytes and full; folding the two take-off tests
// into one `ora camJT` is what pays for the `jmp` the far block now needs.
.const JUMPCODE  = $0eef
.const JUMPCODE_END = $0f00
.const JUMPCODE2 = $ffe4            // above musCodeEnd
.const JUMPCODE2_END = $fffa        // the NMI vector
.const JUMPTAB   = $0e68
.const JUMPTAB_END = $0e70          // COLLCODE
.const JUMPBOOT  = MATRIX + $4c00   // $5c00, after BOOTCODE5's $5900-$5b12

// The HUD (IMPLEMENTATION_PLAN.md §13, docs/reu-format.md §4.9). Boot-only,
// like everything above: hudBoot paints the status bar exactly once and is
// never called again. Plenty of MATRIX is still unclaimed above JUMPBOOT's
// slack ($5c40) and below where boot code stops ($7dff) -- this phase spends
// none of the scarce low-RAM code holes every other M2 phase fought over.
.const BOOTCODE6 = MATRIX + $4c40   // $5c40

// The two REU blocks (8, 9), staged into plain MATRIX the same way every
// other loader does -- lineLoad included -- and consumed immediately by
// hudBoot, which runs once mapLoad (and its descriptor-walk callouts to
// hudBgLoad/hudFontLoad) has returned. Must match wad2reu.py's HUD_* exactly.
//
// A cell is 10 raw bytes -- 8 bitmap bytes (one C64 multicolor cell, 4x8
// px), 1 screen-RAM byte and 1 colour-RAM byte -- straight VIC multicolor
// bitmap format, not the ramp/intensity chunky format the 3D renderer's
// dither chain uses. wad2reu.py cuts these directly out of a hand-painted
// Koala-format image (assets/hud.kla), so hudBlitCell below is a plain copy,
// no dithering: what the artist painted in a real C64 multicolor editor is
// exactly what lands on screen.
.const HUD_CELL_BYTES = 10          // 8 bitmap bytes + 1 screen + 1 colour
.const HUD_BG_CELLS_W = 40
.const HUD_BG_CELLS_H = 4
.const HUD_BG_BYTES = HUD_BG_CELLS_W * HUD_BG_CELLS_H * HUD_CELL_BYTES  // 1600
.const HUD_FONT_GLYPHS = 10
.const HUD_FONT_CELLS_W = 2
.const HUD_FONT_CELLS_H = 2
.const HUD_FONT_GLYPH_BYTES = HUD_FONT_CELLS_W*HUD_FONT_CELLS_H*HUD_CELL_BYTES // 128
.const HUD_FONT_BYTES = HUD_FONT_GLYPHS * HUD_FONT_GLYPH_BYTES          // 1280

// Not at MATRIX+0, where every other staged block goes, and that is the whole
// point: mapLoad walks the descriptors in image order, LINEDEFS (block 7) is
// emitted *after* the two HUD blocks (8, 9), and lineLoad stages through
// MATRIX+0 -- so the bar's first cells came out as raw linedef records. The
// bug was invisible in the screenshot and obvious the moment the staged bytes
// were diffed against wad2reu.py's own build_hudbg() output at a hudBoot
// checkpoint. Staging above the boot code instead ($6100-$673f, inside the
// $6100-$7dff MATRIX tail nothing else claims) makes the two independent of
// descriptor order, which is what the ordering assumption should never have
// been.
.const HUDBG_STAGE   = MATRIX + $5100            // $6100, 1200 B
.const HUDFONT_STAGE = HUDBG_STAGE + HUD_BG_BYTES // $65b0, 400 B, ends $673f
.errorif HUDFONT_STAGE + HUD_FONT_BYTES > MATRIX + $6e00, "HUD staging runs past MATRIX's boot-time tail"

// The three values the bar reads once at boot. COLBUF's tail past what flip
// copies back is indeed dead (IMPLEMENTATION_PLAN.md §8.3) -- but it is not
// unclaimed: $0770-$07ff is TX_SEED, and tex.asm's 137 bytes of relocated
// vSeed/texSetup/wallSpan reach $07f8. The first version of this put the
// three bytes at $07e8 and texBoot, which runs *after* bootMain writes them,
// copied wallSpan straight over the top -- the bar then drew AMMO 180 from
// two opcodes. These are the genuine tail, and TX_SEED_END below is pulled
// down to $07fd so tex.asm's own .errorif fails the build by name if that
// block ever grows into them.
.const hudHealth = $07fd
.const hudArmor  = $07fe
.const hudAmmo   = $07ff
// Field layout, measured straight out of assets/hud.kla rather than assumed:
// decoding the Koala file and scanning for uniform-gray cells shows the
// blank space is rows 1-2 of the bar (row 3 already carries the baked-in
// "AMMO"/"HEALTH"/"ARMS"/"ARMOR" label text, so a glyph at row 2-3 -- the
// original guess -- clipped straight through it). A glyph is
// HUD_FONT_CELLS_W x _H = 2x2 cells, so it spans two of the bar's four
// cell-rows -- rows 1-2, leaving row 0 as a plain band above the numbers,
// the way Doom's own STBAR has undecorated space above its digits.
//
// Horizontally, AMMO's and HEALTH's blank boxes are only 4 cells wide in
// the art -- room for 2 digits, not 3 -- so they're drawn with
// hudDrawField2 (clamped to 0-99) instead of hudDrawField's fixed 3-digit
// unroll; the earlier 3-digit-clamped-to-99 attempt still painted a
// permanent leading "0" glyph, which ate a whole extra cell each and, on
// hardware, landed on top of AMMO's left border and HEALTH's baked-in "%"
// icon rather than beside them. ARMOR's blank box is the full 6 cells
// (cols 23-28), so it keeps the 3-digit field, unclamped. Column below is
// each field's leftmost cell (0-39); positions past AMMO were confirmed
// against a real render, not just the decoded art. AMMO left, HEALTH
// centre, ARMOR right -- Doom's own left-to-right order, minus the
// face/keys this bar has no room for.
.const HUD_GLYPH_ROW  = 1            // top cell-row a glyph is blitted at
.const HUD_DIGITS     = 3            // digits in ARMOR's field, zero-padded
.const HUD_AMMO_COL   = 1            // 2 digits, clamped to 0-99
.const HUD_HEALTH_COL = 6            // 2 digits, clamped to 0-99
.const HUD_ARMOR_COL  = 23           // 3 digits, exact fit, no clamp needed

// segFacing, the world-space backface test, in the free RAM between the BSP
// stack and MATRIX. $0f51-$0fc3.
.const BFACECODE = $0f51

// The bounding-sphere visibility test, in two pieces: the transform and the
// compares together, and the per-node REU fetch separately, because that one
// has to sit where the code that jumps into it can reach it. Both are guarded
// by an .errorif against what follows, so growing one past its block fails the
// build by name.
//
//   SPHCODE   $0c30-$0cff  208 B   sphereVisible + sphereTest
//   UDIV8     $0d00-$0d3f   64 B   udiv's short path (math.asm, not a sphere)
//   FTCODE    $0d40-$0dff  192 B   frame-time statistics (clock.asm, ditto)
//   SPHCODE3  $0e20-$0e5f   64 B   nodeSphere: the per-node REU fetch
//
// SPHCODE is where mapLoad used to be assembled. Moving boot-only code into
// MATRIX (BOOTCODE, above) freed 411 bytes here, which is what let sphereTest
// grow from the box test to the exact one -- before that the largest free block
// below MATRIX was sixty bytes and the test had to be shaped to fit it.
//
// All three of these blocks' tails are now spent: $0cb3-$0cf2 and $0d33-$0d3f
// are texture code and MUSREU, and $0fc4-$0fff is the music player's RAM.
// Below MATRIX the largest unclaimed run left is five bytes.
.const SPHCODE   = $0c30
.const UDIV8     = $0d00            // udiv's short path -- math.asm
.const FTCODE    = $0d40            // frame-time statistics -- clock.asm
.const SPHEND    = $0e00            // MAPINFO: what the block above must clear
.const SPHCODE3  = $0e20

// $ff40-$fff9, 186 B, is free RAM, and as of the jump it is fully spent: the
// music IRQ handler has $ff40-$ffe3 and jumpStep has the remaining 22 bytes
// (JUMPCODE2, above). BITMAP1
// ends at $ff3f and nothing follows it; code can live there at all because both
// banking states the engine uses ($34 and $35) have HIRAM = 0, so the KERNAL is
// out and it is RAM in either window (src/irqtest.asm established that). The
// six bytes above it, $fffa-$ffff, are the NMI/RESET/IRQ vectors, read from
// exactly this RAM when an interrupt is taken with HIRAM = 0.
//
// Nothing is put there *by the PRG image*, and that is a decision rather than
// an oversight. Reaching past $CFDA extends the image over $D000-$DFFF, so
// loading it writes 4 KB of filler across the I/O space -- harmless under
// VICE's RAM injection, but it depends on how the loader banks memory, and
// the U64 path is a DMA whose behaviour there nobody has tested.
//
// M2's music interrupt claims the block anyway, without the image reaching
// it: music.asm assembles the handler with `.pseudopc MUSCODE` inside the
// boot segment, and musInit copies it up before the first frame. The PRG
// still ends at $CFDA. See src/music.asm.
.const MUSCODE     = $ff40          // the IRQ handler's run address
.const MUSCODE_END = JUMPCODE2 - 1  // the jump has the tail now; $fffa-$ffff
                                    // above that are the vectors themselves

// The music player's RAM, in what was sphereVisible's block. 51 of the 60
// bytes; nothing else in the engine wants a block this small.
//
// musBuf is the DMA window, not a frame: records are variable-length (a count
// byte then that many register/value pairs), so the handler fetches a fixed
// MUSWINDOW bytes, reads the count out of byte 0, and only then knows how far
// to advance. The window has to cover the longest record in the stream, which
// musInit checks against the stream header rather than assuming.
.const MUSDATA   = $0fc4
.const MUSWINDOW = 40               // >= the header's window byte, checked at boot
.const musBuf    = MUSDATA          // MUSWINDOW B: one tick's delta record
.const musPtr    = MUSDATA + 40     // 3 B: 24-bit REU offset of the next record
.const musLoop   = MUSDATA + 43     // 3 B: where the tune repeats from
.const musEnd    = MUSDATA + 46     // 3 B: one past the last record
.const musBank   = MUSDATA + 49     // 1 B: $01 as the interrupt found it
.const musOK     = MUSDATA + 50     // 1 B: 1 = a stream was found and started
.const musErr    = MUSDATA + 51     // 1 B: why not, when musOK is 0
.errorif MUSDATA + 52 > $1000, "music data overruns MATRIX"

// musErr values -- why a music stream that was present was rejected. Zero with
// musOK = 0 means the image simply carries no music, which is not an error
// (src/music.asm). Unlike mapErr these do not halt the machine: silence is a
// survivable outcome and a black screen is not. tools/vicedbg/probe.py and
// tools/u64push.py --verify-map are what make a non-zero value visible.
.const MUSERR_NONE    = 0
.const MUSERR_MAGIC   = 1           // stream header is not "MU"
.const MUSERR_VERSION = 2           // wrong stream format version
.const MUSERR_WINDOW  = 3           // records are longer than MUSWINDOW

// The nine REU registers the handler has to put back. It DMAs its own record
// while the renderer is mid-transfer-setup: the renderer fills $DF02-$DF08 and
// then writes the command, and an interrupt landing between those two writes
// would otherwise return to a command that transfers the music's parameters.
// $DF00 and $DF01 are excluded deliberately -- reading the status register
// clears it.
.const MUSREU    = $0d33            // 9 B, in UDIV8's tail

// Boot-only: reads the stream header out of the REU, copies the handler to
// MUSCODE and starts the timer. Runs once, from main, so it lives in MATRIX
// like mapLoad does -- see BOOTCODE. mapLoad ends at $52a0.
.const MUSBOOT   = MATRIX + $4300   // $5300

// The third boot-only block, and the one that paid for §9.2: reuProbe, reuInit
// and clearHudRows all ran once and then sat in the main segment for the rest
// of the run. Moving them here returned ~200 bytes below $0c30, which is what
// the sliding collision test is assembled into. Same argument as BOOTCODE and
// MUSBOOT, and IMPLEMENTATION_PLAN.md §8.3's first lever: boot-only code has no
// business in the only RAM the engine cannot get more of.
.const BOOTCODE3 = MATRIX + $4500   // $5500-$56ff, after MUSBOOT ($5300-$54c5)

// CIA1 Timer A is the music tick. The KERNAL leaves it free-running as its own
// 60 Hz interrupt source and nothing in the engine reads it -- readInput uses
// $DC00/$DC01, the data ports, and clock.asm deliberately took CIA2 instead.
// The latch comes from the stream header, because the tune sets its own rate:
// DooM_Medley wants 100.2 Hz ($2663), not the 50 Hz a vertical-blank player
// would use.
.const CIA1_TALO   = $dc04
.const CIA1_TAHI   = $dc05
.const CIA1_ICR    = $dc0d
.const CIA1_CRA    = $dc0e

.const SID        = $d400
.const SID_VOLUME = $d418

// The IRQ vector, read from RAM in both banking states (HIRAM = 0 in $34 and
// $35 alike), which is the property that makes MUSCODE reachable at all. The
// NMI vector is next to it and is pointed at an `rti`: `sei` does not mask NMI
// and RESTORE is still wired to one.
.const IRQVEC     = $fffe
.const NMIVEC     = $fffa

// bsp.asm lands in two pieces. The traversal proper follows doWall in the walls segment; the node test
// and the standalone descent go in the tail of TABLES_FREE. Two pieces
// because the free RAM comes in two pieces -- neither block alone is big
// enough. Both are asserted against what follows them.
// $ce08 is where doWall ends, not a round number: the sphere test's node hook
// spent the alignment slack that used to sit between them. walls.asm's own
// .errorif is what keeps doWall from growing back into this.
.const BSPCODE  = $ce08             // after the walls segment, up to $cfff
.const BSPCODE2 = TABLES_FREE + SEGBUFSZ    // $97c0, tail of TABLES_FREE

// The doors trampoline (src/lines.asm), split across the last two holes in the
// machine that are big enough to hold a piece of it. Everything else about the
// feature runs in the RAM under I/O; these two fragments exist because the REU
// fetch and the `sei` have to happen with I/O still banked in, and the main
// segment has one spare byte.
//
// LINETRAMP is the tail of SCREEN1's matrix. The VIC reads 1000 bytes of a
// screen and this is the 24 after them, the same trick tex.asm's wall span
// plays on SCREEN0 at $83e8 -- and the reason clearHudRows stops at 120 bytes.
.const LINETRAMP = SCREEN1 + 1000   // $c3e8, 24 B to the end of the matrix
// LINESEGS is between the texture strip unpack and the BSP walk. 19 B.
.const LINESEGS  = $cdf5

// seg record field offsets within SEGBUF, indexed by the seg's byte offset in
// X. docs/reu-format.md §5.1 froze this layout; a seg is 10 bytes.
.const SEGSZ    = 10
.const sgX0     = SEGBUF + 0
.const sgY0     = SEGBUF + 2
.const sgX1     = SEGBUF + 4
.const sgY1     = SEGBUF + 6
.const sgBack   = SEGBUF + 8
// %rrrrtttt: the surface's ramp in the high nibble, its texture family in the
// low one. The low nibble was reserved and zero through M1, which is why
// Stage A texturing is a format version bump and not a wider seg record -- see
// docs/reu-format.md §5.1 and IMPLEMENTATION_PLAN.md §10.2. doWall must mask
// it off before it ors the depth intensity in.
.const sgRamp   = SEGBUF + 9

// MAPINFO field offsets — docs/reu-format.md §4.1
.const miNumNodes   = MAPINFO + 0
.const miNumSsec    = MAPINFO + 2
.const miNumSec     = MAPINFO + 4
.const miSsecShift  = MAPINFO + 5
.const miSsecBase   = MAPINFO + 6   // 24-bit REU offset
.const miRoot       = MAPINFO + 9
.const miSpawnX     = MAPINFO + 11
.const miSpawnY     = MAPINFO + 13
.const miSpawnA     = MAPINFO + 15
.const miSpawnSsec  = MAPINFO + 16
.const miSpawnSec   = MAPINFO + 18
.const miNumSegs    = MAPINFO + 19
.const miMapId      = MAPINFO + 21
.const miSphBase    = MAPINFO + 22  // 24-bit REU offset of block 4, NODESPH
// The music stream, block 5. Zero means the image carries no music, which is
// not an error: `make assets` without a tune produces one, and the engine then
// renders in silence rather than refusing to boot (src/music.asm).
.const miMusBase    = MAPINFO + 25  // 24-bit REU offset of block 5, MUSIC
// The wall texture tiles, block 6 (docs/reu-format.md §4.7). Zero means the
// image carries none, which is not an error either: the engine then draws
// walls flat, exactly as M1 did.
.const miTexBase    = MAPINFO + 28  // 24-bit REU offset of block 6, WALLTEX

// image header field offsets — docs/reu-format.md §2
// 2 added the bounding spheres: the eight-byte subsector slot header and
// block 4. A version-1 image loads none of it, so mapload.asm rejects it
// rather than reading zeroes as spheres of radius nothing and culling the
// entire map. 3 added the music stream (block 5) and miMusBase above; it
// must move in lockstep with wad2reu.py's VERSION, because mapload.asm
// halts the machine on any other number. 4 added the wall texture tiles
// (block 6, miTexBase) and the texture family in sgRamp's low nibble.
// 5 added the special lines (block 7): doors, lifts and walkover triggers,
// with their tags and target heights resolved by wad2reu.py rather than
// searched for here -- the engine has neither a tag array nor sector
// adjacency (IMPLEMENTATION_PLAN.md §11.2a).
// 6 took the wall tiles from 8x8 to 16x16 (block 6, 512 -> 2048 B).
// 7 added the weapon view (block 10, §12a). It is the first block the engine
// keeps the *address* of rather than the contents: weaponBoot records the
// descriptor's REU offset in wpnReuBase and streams the art every frame.
.const MAPFMT_VERSION = 7
.const hdrMagic     = MAPHDR + 0    // "D64U"
.const hdrVersion   = MAPHDR + 4
.const hdrBlocks    = MAPHDR + 5
.const hdrDescs     = MAPHDR + 8    // blockCount x 8 bytes
.const HDRSIZE      = 128           // 15 descriptors; it was 64 and held 7,
                                    // which version 5's eighth block outgrew

// block descriptor field offsets, relative to a descriptor base
.const bdId     = 0
.const bdFlags  = 1                 // bit 0 = resident
.const bdReuOfs = 2                 // 3 bytes: lo, hi, bank
.const bdLen    = 5                 // 2 bytes
.const bdLoadHi = 7                 // high byte of the C64 load address

// mapErr values -- why the map image was rejected at boot. Zero means it was
// not. main.asm puts the value in the border and stops, so these double as the
// only diagnostic a bare machine can give.
.const MERR_NONE    = 0
.const MERR_NOREU   = 1             // reuProbe found nothing
.const MERR_MAGIC   = 2             // header is not "D64U"
.const MERR_VERSION = 3             // wrong format version
.const MERR_BLOCKS  = 4             // impossible block count
.const MERR_ID      = 5             // resident block with an unknown id
.const MERR_ADDR    = 6             // load address disagrees with defs.asm
.const MERR_SIZE    = 7             // block longer than the space reserved
.const MERR_COUNTS  = 8             // MAPINFO exceeds MAXNODES / MAXSEC
.const MERR_SPAWN   = 9             // the engine's own spawn descent found a
                                    // different subsector than wad2reu.py did

//------------------------------------------------------------
// $01 banking. $d000-$dfff is RAM only when the low three bits are %100.
// Both states keep RAM at $a000 and $e000, where BITMAP0/BITMAP1 live, so
// switching never changes what a bitmap write does. See docs/reu-format.md
// §6.1 -- and note this is only safe because interrupts are masked for the
// whole run: main.asm opens with `sei` and never clears it.
//------------------------------------------------------------
.const BANK_IO  = $35               // I/O at $d000  -- the default state
.const BANK_RAM = $34               // RAM at $d000  -- node/sector reads

//------------------------------------------------------------
// engine constants
//------------------------------------------------------------
.const NEAR    = 16
.const HFOCAL  = 80
.const VFOCAL  = 160
.const EYE     = 41                 // eye height above sector floor
// Both are per *frame*, not per second, so they are tied to FPS_CAP_TICKS
// below: M2's frame is 1.5x longer than M1's (three raster frames, not two),
// and these were 14 and 3 at 25 fps. Rescaling them is not optional -- the
// same key held for the same second must move the player the same distance,
// or the game feels wrong in a way no test catches.
//
// 14 x 1.5 = 21 exactly. 3 x 1.5 = 4.5 does not exist in an 8-bit angle
// space, so turning is 4 units/frame: 67 deg/s where M1 turned at 75. The
// fractional accumulator that would give the exact rate costs a zero-page
// byte and six cycles a frame, and is the thing to reach for if 67 turns
// out to feel sluggish.
.const MOVE_SPEED = 21              // world units per frame (16.7 fps)
.const TURN_SPEED = 4               // angle units (of 256) per frame
.const MAXSTEP = 24                 // tallest step the player can climb
.const MINHEAD = 56                 // headroom needed to fit through an opening
// The player is a disc, not a point. Two things use the radius: segNear's
// bounding box (it always did), and the padded cross product that keeps the
// body itself out of a wall (segBody, src/input.asm).
//
// It is 24 and not Doom's 16 because the renderer's near plane is NEAR = 16:
// a seg closer than that to the eye is dropped from the frame, and dropping it
// is what lets the room behind a thin wall show through when the player stands
// against it. Keeping the body 24 units away means no wall of the subsector
// the player is standing in can ever get inside the near plane, so the case
// the renderer cannot draw is a case the player cannot reach.
//
// The padded test is conservative on a diagonal seg by up to R*(sqrt(2)-1),
// i.e. 6.6 units at 45 degrees -- it blocks early, never late. E1M1's tightest
// legitimate gap is a 64-unit door opening, which leaves 16 units of lane at
// R = 24 with the diagonal allowance not applying (door jambs are axis
// aligned), so nothing that was passable stops being passable.
.const PLRAD   = 24
.errorif PLRAD != 24, "segBody multiplies by 24 with two shifts and an add"

// How many times checkMove may project the remaining motion onto a blocking
// seg and try again before it gives up and undoes the move. Three is what an
// inside corner needs: one attempt to find the first wall, one to find the
// second after sliding along the first, and one to commit what is left.
.const SLIDETRY = 3

// How many pieces a frame's motion is broken into before it is tested. The
// collision test is a *point* test against the segs of one subsector, so the
// distance a step may cover unchecked is the distance to the far side of the
// subsector it starts in -- cross a thin one whole and the seg that should
// have stopped the player was never in SEGBUF at all.
//
// E1M1's doors are the case that made this necessary: sector 76's track is
// 16 units deep and sector 75 in front of it is another 16, against a 21-unit
// step. Walking south into that door from subsector 216 crossed 216's own
// (passable) seg, jumped clean over subsector 217 and landed *inside* the
// closed door, and the door's seg was never tested because it belongs to a
// subsector the player was never in. Four parts put the longest substep at
// 7.4 units (21/4 straight, 29.7/4 on the diagonal), comfortably under the
// 16-unit floor of E1M1's geometry.
//
// The cost is four checkMoves a frame instead of one, on frames where the
// player is moving: ~22k cycles at 1 MHz where the frame's compute is ~3.1M,
// and four ~80-byte seg DMAs instead of one, which is ~0.24 ms of the REU's
// flat 1 byte/us on hardware (§5 risk 1). Both are noise; the point test that
// silently misses a wall is not.
.const MOVESUBS = 4                 // must be a power of two: the split is a
                                    // shift and the remainder is an `and`
.const MOVESHIFT = 2                // log2(MOVESUBS)
.errorif MOVESUBS != 1 << MOVESHIFT, "MOVESUBS and MOVESHIFT disagree"

// Jumping (SPACE, the same key that opens a door -- see IN_USE below).
//
// The arc is a *table*, not a velocity and a gravity: it costs one indexed
// load a frame against an add, a subtract and a sign test, and the machine
// had seventeen free bytes for the code and eight for the table, in two
// different holes. It also makes the peak exact, which matters -- the eye may
// not rise through a ceiling, and nothing here tests for one. EYE + JUMPPEAK
// = 69 world units, which clears E1M1's lowest room and its door openings
// (72) by three.
//
// Seven frames at 16.7 fps is 0.42 s in the air. The table is read from
// index 1 (jumpTab-1,x in jumpStep), so there is no filler byte, and $ff
// ends the arc rather than a length -- one compare either way, and a
// terminator survives being retuned by hand.
.const JUMPPEAK = 28                // the highest entry below; see the sum above
.const JUMPFRAMES = 7               // table entries before the $ff

// The walk bob (src/input.asm), Doom's own up-and-down while moving.
//
// Doom bobs the eye by +-8 units around the standing height on a 20-tic
// period; here it is 0..BOBPEAK on an eight-frame one, which is 0.48 s at
// 16.71 fps against Doom's 0.57 s. Upward only because camJZ is unsigned and
// setEyeZ's first add is what carries into the floor height -- a negative
// camJZ would need a sign-extended 16-bit add there, and that block ends
// against $d000 with nothing to spare.
//
// The shape is a triangle computed from frameCnt rather than a table read:
// eight table bytes plus the load cost 17, the arithmetic costs 12, and 23 is
// exactly what the hole this went into holds (BOBCODE, below). A triangle and
// a sine are the same picture at four samples up and four down.
//
// The phase is frameCnt, not a counter of frames spent walking, which is a
// byte of zero page and two instructions this had no room for. What that
// costs is a bob that does not restart from zero when you start walking: it
// picks the wave up wherever it is, and at 0.48 s nobody can see the
// difference.
.const BOBPEAK  = 6                 // eye units at the top of the wave
.const BOBCODE  = $83e8             // 24 B, the gap behind SCREEN0's matrix
.const BOBCODE_END = $8400          // TABLES: the converter's own tables

//------------------------------------------------------------
// Ultimate 64 / C64 Ultimate turbo control
//
//   $D031  bit 0-3  CPU speed index
//          bit 7    badline timing, 0 = enabled (C64-compatible)
//
// Live only when the machine's "Turbo Control" setting is
// "C64U Turbo Registers" or "TurboEnable Bit" (tools/u64config.py sets
// the former). On a stock C64 -- and in VICE -- $D031 is an unconnected
// VIC mirror ($31 mod $40 = 49 > the last real register at $2e), so the
// writes read back as $ff and do nothing. Safe everywhere.
//
// Speed index 15 is 64 MHz on the C64 Ultimate and U64 Elite-II, 48 MHz
// on the original U64. Badlines are left ENABLED: the VIC has bus
// priority regardless, and disabling them buys cycles at the cost of
// C64-compatible timing we may still want for the raster-synced flip.
//------------------------------------------------------------
.const TURBOREG   = $d031
.const TURBO_1MHZ = $00             // speed index 0, badlines enabled
.const TURBO_MAX  = $0f             // speed index 15, badlines enabled

//------------------------------------------------------------
// REU (1750-style RAM expansion) controller. See src/reu.asm for
// what each register does and how a transfer is issued.
//------------------------------------------------------------
.const REU_STATUS  = $df00
.const REU_COMMAND = $df01
.const REU_C64ADDR = $df02          // + $df03
.const REU_REUADDR = $df04          // + $df05
.const REU_BANK    = $df06
.const REU_LENGTH  = $df07          // + $df08, 0 means 65536
.const REU_IRQMASK = $df09
.const REU_ADDRCTL = $df0a

// Command bytes: execute now (bit 7) with the $FF00 trigger
// disabled (bit 4), so the transfer runs on the store itself.
.const REU_FETCH   = $91            // REU -> C64
.const REU_STASH   = $90            // C64 -> REU
.const REU_COMPARE = $93            // compare, result in the status register

// Where reuProbe round-trips its signature. It must not be REU address 0:
// that is the map image's header, and the probe runs before the load, so a
// scratch write there destroys the magic the loader is about to check --
// which is exactly what happened the first time this was wired up, and it
// reported "bad magic" rather than "you overwrote it".
//
// Bank 0, $f000: the top of the first 64 KB, past any image wad2reu.py will
// produce (it asserts the used region stays below this) and present on every
// REU down to the smallest 1700 at 128 KB.
//
// It deliberately does NOT use the bank register. Bank 1 was tried first and
// the C64 Ultimate wrote to REU address $000000 anyway -- the stash lands at
// offset 0 with $df06 = 1, which VICE does not do. Whatever the Ultimate's
// $df06 semantics are, nothing here needs them: 64 KB of REU is reachable with
// the two address bytes alone, and the map image is 34 KB.
.const REU_PROBE_ADDR = $f000
.const REU_PROBE_BANK = 0

//------------------------------------------------------------
// zInput bits. Keyboard and joystick merge with a single `ora`, so the low
// four bits must keep matching joystick 2's up/down/left/right -- and IN_USE
// is bit 4 for the same reason, which is where the fire button reads.
//
// Bit 4 is also SPACE's own bit in keyboard row 7, and bit 6 is Q's, so that
// row needs no branches at all: mask the two bits out of the inverted read and
// `ora` them straight in. The bit assignment is doing work, in other words --
// M2's use key made the row cheaper than it was with one key on it.
//------------------------------------------------------------
.const IN_FWD    = %00000001        // W        / joy up
.const IN_BACK   = %00000010        // S        / joy down
.const IN_LEFT   = %00000100        // A        / joy left    -- turn left
.const IN_RIGHT  = %00001000        // D        / joy right   -- turn right
.const IN_USE    = %00010000        // SPACE    / joy fire     -- open a door,
                                    //                           and jump
.const IN_SLEFT  = %01000000        // Q                      -- strafe left
.const IN_SRIGHT = %10000000        // E                      -- strafe right
.const IN_ROW7   = IN_SLEFT | IN_USE
.const IN_MOVE   = IN_FWD | IN_BACK | IN_SLEFT | IN_SRIGHT

//------------------------------------------------------------
// zero page — math ($02-$13)
//------------------------------------------------------------
.const zA     = $02   // 16-bit operand A
.const zB     = $04   // 16-bit operand B
.const zP     = $06   // 32-bit product $06-$09
.const zD     = $0a   // 24-bit dividend $0a-$0c (quotient out in $0a-$0b)
.const zV     = $0d   // 16-bit divisor
.const zSign  = $0f
.const zT     = $10   // temps $10-$12 (mul8 internals, clipT result)

//------------------------------------------------------------
// zero page — renderer ($13-$3f, $80-$8f)
//------------------------------------------------------------
.const zLineI  = $13
.const zTx     = $14
.const zTy     = $16
.const zRX0    = $18
.const zRY0    = $1a
.const zRX1    = $1c
.const zRY1    = $1e
.const zSXW0   = $20
.const zSXW1   = $22
.const zC0     = $24
.const zC1     = $25
.const zDzC    = $26
.const zDzF    = $28
// line endpoint rows; layout is load-bearing: line i -> y0 at zTop0+i*4
.const zTop0   = $2a
.const zTop1   = $2c
.const zBot0   = $2e
.const zBot1   = $30
.const zBTop0  = $32
.const zBTop1  = $34
.const zBBot0  = $36
.const zBBot1  = $38
// Line 4 is the texture's u, in world units along the seg's dominant axis.
// It is a "line" only in lineSetup's sense -- a quantity that is linear in
// screen x and therefore wants the same divide-once-then-accumulate treatment
// as the four row lines. Giving it index 4 is what makes the whole of texU
// disappear: lineSetup already computes ((v1-v0) << 8)/dx and seeds the
// accumulator at column c0, which is exactly the u setup, and clampAcc never
// looks at line 4. It is also why zWallByte and its three neighbours moved to
// $b0 -- $3a-$3d is where zTop0 + 4*4 lands, and the layout is load-bearing.
.const zU0     = $3a
.const zU1     = $3c
.const zSecId  = $3e
.const zWIdx2  = $3f        // seg's byte offset in SEGBUF, live inside doWall
// The node index sideOf is working on. Shares zWIdx2 deliberately: one is live
// only inside doWall, the other only inside the BSP descent, and the two never
// nest. sideOf's 32-bit partial product borrows zTop0..zTop0+3 on the same
// argument -- those are doWall's line endpoints.
.const zNodeI  = $3f

.const zRXt    = $80
.const zRYt    = $82
.const zDX     = $84
.const zCeilByte  = $86
.const zFloorByte = $87
.const zWT     = $88
.const zWB     = $89
.const zTW     = $8a
.const zBW     = $8b
.const zBT     = $8c
.const zBB     = $8d
.const zNum    = $8e        // 16 bit: $8e-$8f -- see zInput

//------------------------------------------------------------
// zero page — frame pacing and the bounding-sphere test ($90-$95)
//
// $90 upwards was untouched: the engine allocated $02-$8f and never calls the
// KERNAL, so everything above it has been free RAM since boot.
//------------------------------------------------------------
// zInput was $8f until the walk bob's test caught what that address really
// is: the high byte of zNum, which checkMove writes twice per seg per attempt
// (src/input.asm), and the near-plane clip once per clipped seg. So walking
// rewrote the input byte with a cross product's high byte, every frame,
// *before*
// playerFrame and lineFrame read it -- IN_USE landing in it at random is why
// walking around fired jumps and opened doors nobody had asked for.
//
// $90-$91 was msLast, the pacer's old reference, and nothing has read it
// since the pacing moved to msFrame (clock.asm). zInput takes the first byte
// -- it is one byte -- and $91 is free. Anything that reads the input on the
// host reads this constant (tools/vicedbg), so the move costs nothing there.
.const zInput  = $90
.const msNow   = $92        // scratch for a torn-read-safe timer read
.const msFrame = $96        // ... at the last completed flip (see ftInt below)

// The bounding sphere's radius, world units, live across the transform.
.const zRad    = $94

//------------------------------------------------------------
// zero page — the sliding collision test ($98-$a3)
//
// Above everything else for the same reason msLast was: $02-$8f is the
// engine's allocation and $90 upwards has been untouched since boot. These
// could have shared the movement scratch at $68-$7b, and deliberately do not:
// slideVec runs *between* two runs of the seg loop, so anything it borrowed
// from the renderer's accumulators would have to be proved dead across both.
//------------------------------------------------------------
.const zSlTX   = $98        // the blocking seg's direction, x1-x0 / y1-y0
.const zSlTY   = $9a
.const zSlL    = $9c        // |t|, approximated (see slideVec)
.const zSlUX   = $9e        // t normalised, 8.8 fixed point: 256 = 1.0
.const zSlUY   = $a0
.const zSlDot  = $a2        // 256 * (motion . t-hat)
.const zSlTry  = $a4        // attempts left in the two-boundary loop
.const zSlAx   = $a5        // 0 = x, 2 = y: which axis slideVec is on. In
                            // memory rather than in X because mul8 and udiv
                            // both want X for themselves.

//------------------------------------------------------------
// zero page — the line steps and the four renderer bytes they displaced
// ($a6-$b3), and the wall texture state ($b4-$c1).
//
// Nothing above $a5 was allocated before M2's texturing: the engine's own
// block is $02-$8f and $90 upwards has been untouched since boot, which is
// what makes a five-line lineSetup affordable at all. The music interrupt
// touches no zero page (src/music.asm), so there is no handler to agree with.
//------------------------------------------------------------
.const stepTop = $a6
.const stepBot = $a8
.const stepBT  = $aa
.const stepBB  = $ac
.const stepU   = $ae        // line 4: world units of u per screen column, 8.8

.const zWallByte = $b0      // moved out of $3a-$3d to make room for zU0/zU1
.const zBack   = $b1
.const zWIdx   = $b2
.const zWCnt   = $b3

// Wall texture state, live from texSetup to the end of the seg's column loop.
.const zTexOn  = $b4        // 0 = draw this seg flat, as M1 did
.const zTexRamp = $b5       // the surface's ramp, already in the high nibble
.const zTexBias = $b6       // depth intensity - 8, signed: the texel's bias
.const zCurU   = $b7        // the u column texStrip currently holds, or $ff
.const zVStep  = $b8        // texels of v per screen row, 8.8, negative
.const zVAcc   = $ba        // v inside a span, 8.8, integer part masked to 0-7
.const zVTop   = $bc        // v at the front ceiling: the anchor every span in
                            // the seg measures from, exact in every column
.const zClipT  = $be        // near-plane clip: t, and which endpoint moved.
.const zClipW  = $bf        // 0 = neither, $01 = endpoint 0, $80 = endpoint 1
.const zTexAx  = $c0        // 0 = x, 2 = y: the endpoint texUEnds is correcting.
                            // In memory rather than in X for the same reason
                            // zSlAx is -- mul8 wants X for itself.

// The jump's whole state, in the two bytes between the texture block and
// TEXBUF. camJT is the arc's cursor and the "in the air" flag both: zero is
// standing on the floor, and the take-off test is `bne` on it.
.const camJZ   = $c2        // eye height above the sector floor, 0 on foot
.const camJT   = $c3        // index into jumpTab, 1-based; 0 = not jumping

// The wall texture working set, $c4-$d3. In zero page and not in colTop's
// tail, which is where it was first put, for two reasons: `lda texStrip,x` in
// spanTex's inner loop is 3 cycles here against 4 there, over every wall pixel
// on the screen; and moving it out of $02b0 is what left an 80-byte hole big
// enough to assemble texVSet into. The renderer allocates $02-$8f and nothing
// above $a5 was ever claimed, so this is the last of the free zero page rather
// than a byte taken from anything.
//
// texStrip is one u column of the family's tile, unpacked to a byte per texel
// with the depth bias applied and the ramp already or'd in -- so the per-pixel
// cost inside spanTex is one indexed load and nothing else. Sixteen bytes, not
// the whole 256-byte tile, because u is monotonic across a seg: the column
// loop unpacks the column it needs when u changes and never comes back to it.
//
// $d4-$e3 was free zero page -- the last of it in the machine. It was TEXBUF,
// the 32-byte tile Stage A re-DMA'd per seg; the tiles are resident at WALLTILE
// now and nothing is copied per seg at all. §11d's substepping takes seven of
// those sixteen bytes (below); $db-$e3 is what is left.
.const texStrip = $c4               // 16 B, one u column, finished chunky bytes

//------------------------------------------------------------
// zero page — the substepped move ($d4-$da), src/input.asm
//
// The frame's displacement is split into MOVESUBS equal parts, each tested by
// its own checkMove, because collision only ever looks at the segs of the
// subsector the player starts the step in: a step longer than a sector is
// thick walks through it without the seg between them ever being read. E1M1's
// door tracks are 16 units deep against a 21-unit step, which is exactly that
// (IMPLEMENTATION_PLAN.md §11d).
//
// zSubX/zSubY is the quarter step, floor(d/4). zRemX/zRemY is d - 4*floor(d/4),
// i.e. d & 3, one unit of which is handed to each of the first substeps -- so
// the four parts sum to the frame's motion *exactly*, in both directions.
// Truncating instead would make walking west up to 20% faster than walking
// east, which is the kind of asymmetry no screenshot shows and every player
// feels.
.const zSubX   = $d4        // one substep's x, floor(dx/MOVESUBS)
.const zSubY   = $d6
.const zRemX   = $d8        // units of dx the quartering lost, 0-3
.const zRemY   = $d9
.const zSubN   = $da        // substeps left this frame

//------------------------------------------------------------
// zero page — the player's radius ($db-$e1), src/input.asm
//
// The cross product checkMove computes per seg used to be thrown away except
// for its sign, because a point is either inside a subsector or it is not.
// With a radius there are two questions and the whole 32-bit value answers
// both: `cross < 0` is still "the point is inside", and `cross + PLRAD*(|dx| +
// |dy|) < 0` is "and so is every corner of the player's box" -- the cross
// product is linear in the test point, so the most-outside corner is the exact
// value plus that one term. See segBody (src/input.asm).
//
// $e2-$e3 is what is left of zero page in the machine, and §12 (below) takes
// one of the two remaining bytes.
.const zCrs    = $db        // 32-bit: the seg's cross product, whole
.const zPad    = $df        // 24-bit: PLRAD * (|dx| + |dy|)

// The 1351 mouse's previous POTX sample (mouseTurn, src/render/sprite.asm) --
// $e3 is the very last free byte of zero page in the machine; nothing else
// was left after §12's zSegQ took $e2. One byte is all mouseTurn needs: the
// delta is an 8-bit wraparound subtract against last frame's raw reading, and
// everything else it touches is dead renderer scratch at the point in the
// frame mouseTurn runs.
.const zMousePX = $e3
// Turn sensitivity: the raw POTX delta, arithmetic-shifted right this many
// bits before it is added to camA. A feel constant, same deferred-judgment
// shape as TURN_SPEED (§8.1) -- picked, not derived, and easy to retune by
// changing the shift count in mouseTurn itself (each step of the `cmp #$80 /
// ror` pair costs 3 B, cheaper than a parameterised loop at this size).
// 3, not 2: playtesting found /4 too twitchy for the 1351's native
// resolution -- /8 reads as a deliberate turn instead of a flick.
.const MOUSE_SHIFT = 3

// zero page — §12's one permanent byte, the last claimed in the machine.
// zSegQ is the current seg's quantised depth (segShade, src/render/sprite.asm)
// and must survive across doWall's whole column loop, so unlike everything
// else §12 touches it cannot be post-renderFrame scratch. $e3 is what is left.
.const zSegQ   = $e2

//------------------------------------------------------------
// zero page — doors and moving sectors ($ec-$f0), src/lines.asm
//
// The last of the free zero page, and the only zero page this phase takes:
// the tables and the thinkers are all under I/O, where the code is.
//------------------------------------------------------------
.const zLnI    = $ec        // index into the line table
.const zLnSec  = $ed        // the sector a scan is matching, then activating
.const zLnKind = $ee        // that line's kind, LK_* with the flags stripped
.const zLnUse  = $ef        // use key: 0 until released, so a held key opens
                            // a door once rather than every frame
.const camSecOld = $f0      // camSec at the end of the last frame; a walkover
                            // fires on the change, not on standing in it
.const zLnFlag = $f1        // LF_WALK, or 0 for the use-activated lines
.const zLnCnt  = $f2        // segs left in the use scan
                            // $f3 is free -- lnUse's seg cursor is checkMove's
                            // zWIdx, because segFacing reloads X from it
.const zTmpH   = $f4        // the height a thinker is moving, 16-bit
.const zTmpD   = $f6        // and its distance left to the target
                            // $f8 is free -- it was lineFrame's "run the use
                            // scan this frame" flag until the edge test moved
                            // to lineTick's side of the bank switch
.const zLnHPtr = $f9        // the SECTAB array a thinker is moving: floors, or
                            // ceilings 2*MAXSEC further on. One pointer instead
                            // of a floor/ceiling branch in each of four places,
                            // and the hi byte of a height is the same pointer
                            // at y + MAXSEC because a sector id is under 96.


//------------------------------------------------------------
// zero page — converter ($40-$4a)
//------------------------------------------------------------
.const zTmp    = $40        // $40-$47: 8 packed bytes of current cell
.const matPage = $48
.const pageCnt = $49
.const backBuf = $4a

//------------------------------------------------------------
// zero page — BSP traversal ($4b-$4f)
//------------------------------------------------------------
.const zChild  = $4b        // current child word: bit 15 = subsector
.const zFar    = $4d        // the child pushed for later
.const zSegCnt = $4f        // segs in the subsector now in SEGBUF

//------------------------------------------------------------
// zero page — camera/player ($50-$5e)
//------------------------------------------------------------
.const camX    = $50
.const camY    = $52
.const camZ    = $54
.const camA    = $56
.const camSec  = $57
.const camSin  = $58
.const camCos  = $5a
.const stackN  = $5c        // BSP stack depth
.const camSsec = $5d        // the subsector the player is standing in
// Columns whose window is still open. The frame is finished the moment this
// reaches zero, which is what replaces the portal walker's inherited [xL,xR]
// windows as the traversal's termination condition -- without it the walk
// would visit all 236 nodes every frame.
.const openCols = $5f

//------------------------------------------------------------
// zero page — span fill ($60-$67), line accumulators ($68-$7b)
//------------------------------------------------------------
.const zSX    = $60
.const zSY0   = $61
.const zSY1   = $62
.const zSCol  = $63
.const zSPtr  = $64
.const zSCnt  = $66

// 24-bit accumulators (frac, int lo, int hi) + 16-bit steps.
// clampAcc indexes accTop+0/3/6/9; lineSetup uses accTop+i*3, stepTop+i*2.
// Five lines, not four: line 4 is the texture u (see zU0). That is why the
// steps no longer follow the accumulators -- accTop..accU now runs $68-$76,
// over the two bytes stepTop used to occupy.
.const accTop  = $68
.const accBot  = $6b
.const accBT   = $6e
.const accBB   = $71
.const accU    = $74

// Back sector heights, already relative to the eye. Filled by secBack from the
// table under the I/O space, so that doWall and the collision test read them
// from zero page instead of banking on every access.
.const zBackF  = $7c
.const zBackC  = $7e

// movement scratch (renderer accs are free while moving)
.const oldX    = $68
.const oldY    = $6a
.const zMvDX   = $6c        // this frame's total displacement, 16-bit signed
.const zMvDY   = $6e
.const zCosT   = $70        // MOVE_SPEED * cos >> 14  (the forward basis, scaled)
.const zSinT   = $72        // MOVE_SPEED * sin >> 14

// boot-time map loader scratch. Same reuse argument as the movement scratch
// above, taken further: mapLoad runs once, before the first frame, so every
// renderer accumulator is dead. Nothing here may be touched after boot.
.const zMLSrc  = $68        // copy source pointer
.const zMLDst  = $6a        // copy destination pointer
.const zMLLen  = $6c        // bytes remaining
.const zMLDesc = $6e        // pointer to the current block descriptor
.const zMLCnt  = $70        // descriptors left to walk
.const zMLSum  = $72        // 16-bit sum of the block being copied
.const zMLId   = $74        // block id x 2, i.e. its offset into mapSum

// boot-time HUD blit scratch (IMPLEMENTATION_PLAN.md §13). Same reuse
// argument again, one step later than mapLoad's own: hudBoot runs after
// mapLoad and lineInit have both finished and before cli, so their scratch
// is dead too.
.const zHudSrc   = $68      // source cell pointer (HUDBG_STAGE/HUDFONT_STAGE)
.const zHudN     = $6a      // destination cell index, 0-999
.const zHudPtr   = $6c      // scratch dest pointer, recomputed per store
.const zHudOff8  = $6e      // scratch: zHudN * 8, the bitmap byte offset
.const zHudVal   = $70      // hudDrawField's remaining value
.const zHudCol   = $71      // hudDrawDigit's leftmost cell column
.const zHudDigit = $72      // the digit (0-9) hudDrawDigit is blitting
.const zHudGlyphBase = $73  // stable per-digit source base, 2 B ($73-$74)
.const zHudCnt   = $75      // hudBoot's background-cell counter -- NOT X:
                            // hudBlitCell clobbers X for its scrTab/colTab
                            // sample lookup, so a caller's loop counter may
                            // not live there across a jsr to it

// sprite draw scratch (IMPLEMENTATION_PLAN.md §12), src/render/sprite.asm.
// Same reuse argument as weapon.asm's own zA/zB/zD/zT (which sprFrame's setup
// math -- transformPoint, projSX, projRow, umul16, udiv -- also uses): the
// sprite pass runs after renderFrame and before wpnFrame/convert, so every
// renderer accumulator and every $80-$8f byte is dead. mapLoad/hudBoot already
// alias $68-$76 at a different point in the frame; this is the same block,
// reused a third time, plus $80-$8a which nothing else claims after render.
.const sprQ      = $68      // this sprite's quantised depth, minus SPR_BIAS
.const sprC0     = $69      // clipped column range
.const sprC1     = $6a
.const sprR0     = $6b      // clipped top row
.const sprRows   = $6c      // rows to draw, clipped
.const sprH      = $6d      // this type's art height (src column stride)
.const sprUAcc   = $6e      // 8.8 fixed point, integer part = art column
.const sprUStep  = $70
.const sprVAcc   = $72      // 8.8 fixed point, integer part = art row
.const sprVStep  = $74
.const sprN      = $76      // visible things this frame
.const sprSrc    = $80      // SPRIMG column pointer
.const sprDst    = $82      // MATRIX destination pointer
.const sprI      = $84      // cursor into the sorted visible list
.const sprIdx    = $85      // current thing's index into the THINGS arrays
.const sprX      = $86      // current screen column
.const sprType   = $87      // current thing's type, 0..NUM_SPRTYPES-1
.const sprSortI  = $88      // insertion sort scratch
.const sprSortJ  = $89
.const sprSortT  = $8a

// sprPick's own scratch: it runs *inside* renderFrame (bsp.asm's renderSsec,
// once per subsector), while sprFrame/sprDraw only run after renderFrame has
// returned -- so this is a fourth reuse of the same two bytes, not a third.
// Nothing sprPick stores here needs to survive past its own rts.
.const sprPickI   = sprQ    // $68 -- cursor into thingXlo/Xhi/Ylo/Yhi/Type,
                            // this subsector's [sprSsecFirst[ssec], ...end)
.const sprPickEnd = sprC0   // $69 -- end of that range, exclusive

// The player spawn is no longer a constant: it comes from MAPINFO, which
// wad2reu.py fills from the map's THINGS type 1 (docs/reu-format.md §4.1, §7).

.const WALLS2         = $9d88      // walls helper routines after math code

//------------------------------------------------------------
// Wall texturing (src/render/tex.asm), in ELEVEN pieces.
//
// 653 bytes of code, and the largest hole in the machine is 192. That is the
// whole story of this block: every routine in tex.asm is entered by jsr and
// returns, so it can be assembled anywhere, and each one is put in the
// smallest hole it fits. Nothing here is a design; it is a bin-packing.
//
// Three of the eleven are BELOW $0801 and therefore outside the PRG image,
// which cannot load them. They are assembled with .pseudopc inside a boot
// block and copied down before the first frame, exactly as the music IRQ
// handler is copied up to MUSCODE. They are marked (boot) below.
//
//   TX_UENDS  $bf40-$bfff  192  182  texUEnds, texMulT, spanTex
//   TX_SEED   $0770-$07fc  141  137  vSeed, texSetup, wallSpan  (boot)
//             ($07fd-$07ff is hudHealth/hudArmor/hudAmmo -- see §13 above)
//   TX_FETCH  $03a0-$03ff   96   81  texFetch                   (boot)
//   TX_VSET   $02b0-$02ff   80   69  texVSet                    (boot)
//   TX_SHADE  $0cb3-$0cf2   64   64  wallShade
//   TX_UADV   $cfdd-$cfff   35   33  uAdvance
//   TX_PIX    $9fe1-$9fff   31   26  texPix
//   TX_COL    $cdda-$ce07   46   27  texCol
//   TX_UPD    $0de8-$0dff   24   22  texUpd
//   TX_CLIP   $0cf3-$0cff   13   12  texClip0/texClip1
//
// Three of those moved, and every move is a pure address change -- each block
// here is entered by jsr or jmp. Two went for the jump (JUMPCODE, above):
//
//   TX_CLIP left $0eef for TX_SHADE's own slack, which handed the tail of the
//   $0e00 page to playerFrame. It is exact now: 12 bytes in 13.
//   TX_UADV moved up two bytes into the four it was leaving unused below
//   $d000, which is what setEyeZ spent on adding camJZ to the eye.
//
// and the third went for the walk bob: TX_WSPAN was $83e8-$83ff, 13 bytes of
// wallSpan in 24, and it is the last hole in the machine wide enough for
// bobStep. wallSpan moved into TX_SEED's tail -- 137 bytes in 144 now -- and
// $83e8 is BOBCODE (below).
//
// Two more need saying out loud:
//
// $bf40 is the gap between BITMAP0's last byte ($bf3f -- a bitmap is 8000
// bytes, not 8192) and SCREEN1. It is RAM in both banking states the engine
// uses and the VIC never fetches it, and it was simply unclaimed.
//
// $83e8 is the same gap at SCREEN0 -- the video matrix is 1000 bytes and ends
// at $83e7 -- and it is BOBCODE now rather than a texture block. The VIC does
// read $83f8-$83ff as sprite pointers even with every sprite disabled, but it
// only reads them, and the engine has no sprites, so what those eight bytes
// contain is nobody's business. The same 24 bytes behind SCREEN1 at $c3e8 are
// LINETRAMP (above); the pair is spent.
//
// texCol is the odd one out: it is in doWall's own tail, which only exists
// because wallShade moved out to TX_SHADE. The 28-byte hole at $98e4 would
// have fit it better and is where it was first put -- but that is where
// instrument.asm's nine counters live, and they are only *assembled* in an
// INSTRUMENT build, so the collision does not fail the build. It silently
// breaks `make stats` instead, by pointing the host at code.
//
// Each block's .errorif in tex.asm names what it would overflow into, so
// growing one past its hole fails the build by name rather than by symptom.
//------------------------------------------------------------
.const TX_UENDS  = $bf40
.const TX_SEED   = $0770
.const TX_FETCH  = $03a0
.const TX_VSET   = $02b0
.const TX_SHADE  = $0cb3
.const TX_UADV   = $cfdd
.const TX_PIX    = $9fe1
.const TX_COL    = $cdda
.const TX_UPD    = $0de8
.const TX_CLIP   = $0cf3

.const TX_UENDS_END = $c000
.const TX_SEED_END  = $07fd         // not $0800: hudHealth/Armor/Ammo (§13)
.const TX_FETCH_END = $0400
.const TX_VSET_END  = $0300
.const TX_SHADE_END = TX_CLIP       // the clip parameter has the slack now
.const TX_UADV_END  = $d000
.const TX_PIX_END   = $a000
.const TX_COL_END   = $ce08
.const TX_UPD_END   = $0e00
.const TX_CLIP_END  = $0d00         // UDIV8

// The fourth boot-only block: the .pseudopc images of TX_SEED, TX_FETCH and
// TX_VSET, plus the three copy loops that put them where they run. Same
// argument as BOOTCODE/MUSBOOT/BOOTCODE3 -- MATRIX is 28 KB of scratch until
// the first frame. ~320 B, after BOOTCODE3's $5500-$564a.
.const BOOTCODE4 = MATRIX + $4700   // $5700

// The fifth, and the same argument again: the .pseudopc images of the three
// blocks that run under I/O (LINECODE*, src/lines.asm) and the three copy
// loops that put them there. Those blocks cannot be in the PRG image at all --
// reaching past $cffb would extend it over $d000-$dfff and make loading it a
// 4 KB write across the I/O space, which is exactly the thing the note above
// MUSCODE refuses to do. ~530 B, after BOOTCODE4's $5700-$5839.
.const BOOTCODE5 = MATRIX + $4900   // $5900

// The millisecond clock and the frame pacer, in the gap between the walls
// helpers and BITMAP0. 114 B, $9f8e-$9fff.
.const CLKCODE        = $9f96

// Free-running 16-bit frame counter, incremented once per completed flip.
// Nothing in the engine reads it; it exists so that a host can DMA-read it
// twice over a known wall-clock interval and get a real frame rate out of
// hardware (tools/u64push.py --fps). Fixed address by contract with that tool.
.const frameCnt       = $0f40

// REU scratch and status. Deliberately *outside* the PRG image: reuProbe
// writes a signature here, and anything it wrote inside the image would show
// up in tools/vicedbg/probe.py's live-RAM diff as an unexplained difference.
.const reuScratch     = $0f42      // 4 bytes, round-tripped by reuProbe
.const reuOK          = $0f46      // 1 = an REU answered at boot
.const mapOK          = $0f47      // 1 = assets.reu loaded and verified
.const mapErr         = $0f48      // why not, when mapOK is 0 (see mapload.asm)

// 16-bit sum of each resident block's bytes, indexed by block id x 2, written
// by mapload.asm as it copies. This is the only way a host can check that the
// blocks under the I/O space arrived: machine:readmem on the Ultimate DMAs the
// bus as the engine has it banked, so $d000 reads back the registers, not the
// node table. The engine reads that RAM itself, so it can add it up.
.const mapSum         = $0f49      // 4 blocks x 2 bytes, $0f49-$0f50

//------------------------------------------------------------
// CIA2 as a millisecond clock — see src/clock.asm.
//
// Timer A free-runs at 1000 phi2 cycles, Timer B counts A's underflows, so
// $DD06/$DD07 is a 16-bit millisecond counter running *down* from $ffff and
// wrapping every 65.5 s. It is the only wall clock the engine has: the raster
// only says "somewhere in this 20 ms frame", and the CPU clock is 1 MHz in
// VICE and 64 MHz on the Ultimate.
//
// Two things depend on it. `framePace` uses it to hold the frame rate at
// FPS_CAP_TICKS, and a host can read $DD06/$DD07 over the monitor for *emulated*
// milliseconds, which is what makes a frame-time measurement possible under
// warp (tools/vicedbg/stats.py).
//------------------------------------------------------------
.const CIA2_TALO   = $dd04
.const CIA2_TAHI   = $dd05
.const CIA2_TBLO   = $dd06
.const CIA2_TBHI   = $dd07
.const CIA2_ICR    = $dd0d
.const CIA2_CRA    = $dd0e
.const CIA2_CRB    = $dd0f

.const MS_TICKS    = 1000          // phi2 cycles per Timer A underflow

// Frame pacing. Without a cap the engine runs at whatever 50/n the frame
// happens to cost, and everything that moves is per-frame, so a simple view
// at 50 fps moves the player twice as fast as a complex one. The cap makes
// every faster rate unreachable and pins the common case at one number.
//
// THE UNIT IS A TIMER B TICK, NOT A MILLISECOND. PAL phi2 is 985248 Hz, not
// 1 MHz, so a Timer A latch of 1000 underflows every 1.015 ms. Hardware
// confirms it: `make u64-fps` measured 19706 CIA ticks against 20044 host
// milliseconds, a ratio of 0.983 where PAL predicts 0.985.
//
// **M2 runs at three raster frames, not two** (IMPLEMENTATION_PLAN.md §8.1).
// M1 shipped 25.05 fps with ~2 ms of headroom; textures, doors and sprites
// need ~15-20 ms that do not exist there, and 16.7 fps locked is preferable
// to 25 fps that judders. The same arithmetic that made 39 the maximum at
// two frames makes 58 the maximum at three:
//
// The wait is measured from the *last flip* (msFrame), not from the pacer's
// own last release, so the reference resets at every raster crossing and the
// phase cannot accumulate -- see the long comment on framePace, and the
// hardware run where release-to-release pacing put 16 of 341 frames on the
// wrong crossing. That is what makes this number uncritical rather than
// exact: any wait that lands strictly between the two-frame crossing and the
// three-frame one selects the three-frame one, every time.
//
//   two PAL frames  = 39.90 ms = 39.3 ticks   ] the wait must land
//   three PAL frames = 59.85 ms = 58.97 ticks ] strictly between these
//
// msFrame is captured mid-tick, so a cap of N releases somewhere between
// N-1 and N whole ticks later: 41..58 all work, and 49 (49.7 ms) is the
// middle, with ~10 ms of slack against each crossing.
//
// MOVE_SPEED and TURN_SPEED are 1.5x their M1 values because of this line.
.const FPS_CAP_TICKS = 49

//------------------------------------------------------------
// Renderer instrumentation lives in src/instrument.asm, not here.
//
// defs.asm is imported by three PRGs -- the engine, reuload.asm and
// reubench.asm -- and the last two have no renderer and no clock.asm. The
// Count macro's body names `cntBump`, and KickAssembler resolves the symbols
// inside a macro body whether or not the macro is ever invoked and whether or
// not the `.if` guarding them is false. So a macro here that references engine
// code fails the standalone builds at parse time, pointing into a macro they
// do not use. Nothing in this file may name a symbol only one PRG defines.
//------------------------------------------------------------

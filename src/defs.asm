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
.const WALLSCODE      = $ca30

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
.const MAPFMT_VERSION = 5
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
.const PLRAD   = 16                 // player radius, Doom's own value

// How many times checkMove may project the remaining motion onto a blocking
// seg and try again before it gives up and undoes the move. Three is what an
// inside corner needs: one attempt to find the first wall, one to find the
// second after sliding along the first, and one to commit what is left.
.const SLIDETRY = 3

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
.const zNum    = $8e
.const zInput  = $8f

//------------------------------------------------------------
// zero page — frame pacing and the bounding-sphere test ($90-$95)
//
// $90 upwards was untouched: the engine allocated $02-$8f and never calls the
// KERNAL, so everything above it has been free RAM since boot.
//------------------------------------------------------------
.const msLast  = $90        // free: was the pacer's reference until the
                            // pacing moved to msFrame (see clock.asm)
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

// The wall texture working set, $c4-$eb. In zero page and not in colTop's
// tail, which is where it was first put, for two reasons: `lda texStrip,x` in
// spanTex's inner loop is 3 cycles here against 4 there, over every wall pixel
// on the screen; and moving it out of $02b0 is what left an 80-byte hole big
// enough to assemble texVSet into. The renderer allocates $02-$8f and nothing
// above $a5 was ever claimed, so this is the last of the free zero page rather
// than a byte taken from anything.
//
// TEXBUF is one family's 32-byte tile, DMA'd per seg (docs/reu-format.md §4.7).
// texStrip is one u column of it, unpacked to a byte per texel with the depth
// bias applied and the ramp already or'd in -- so the per-pixel cost inside
// spanTex is one indexed load and nothing else. Eight bytes, not the whole
// 64-byte tile, because u is monotonic across a seg: the column loop unpacks
// the column it needs when u changes and never comes back to it.
.const TEXBUF   = $c4               // 32 B, nibble-packed, column-major
.const texStrip = $e4               // 8 B, one u column, finished chunky bytes

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
//   TX_SEED   $0770-$07ff  144  124  vSeed, texSetup            (boot)
//   TX_FETCH  $03a0-$03ff   96   81  texFetch                   (boot)
//   TX_VSET   $02b0-$02ff   80   69  texVSet                    (boot)
//   TX_SHADE  $0cb3-$0cf2   64   64  wallShade
//   TX_UADV   $cfdd-$cfff   35   33  uAdvance
//   TX_PIX    $9fe1-$9fff   31   26  texPix
//   TX_COL    $cdda-$ce07   46   27  texCol
//   TX_UPD    $0de8-$0dff   24   22  texUpd
//   TX_WSPAN  $83e8-$83ff   24   13  wallSpan
//   TX_CLIP   $0cf3-$0cff   13   12  texClip0/texClip1
//
// Two of those moved for the jump (JUMPCODE, above), and both moves are
// pure address changes -- every block here is entered by jsr:
//
//   TX_CLIP left $0eef for TX_SHADE's own slack, which handed the tail of the
//   $0e00 page to playerFrame. It is exact now: 12 bytes in 13.
//   TX_UADV moved up two bytes into the four it was leaving unused below
//   $d000, which is what setEyeZ spent on adding camJZ to the eye.
//
// Two more need saying out loud:
//
// $bf40 is the gap between BITMAP0's last byte ($bf3f -- a bitmap is 8000
// bytes, not 8192) and SCREEN1. It is RAM in both banking states the engine
// uses and the VIC never fetches it, and it was simply unclaimed.
//
// $83e8 is the same gap at SCREEN0: the video matrix is 1000 bytes and ends
// at $83e7. The VIC does read $83f8-$83ff as sprite pointers even with every
// sprite disabled -- but it only reads them, and the engine has no sprites, so
// what those eight bytes contain is nobody's business. The same 24 bytes exist
// at $c3e8 behind SCREEN1 and are still free.
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
.const TX_WSPAN  = $83e8
.const TX_CLIP   = $0cf3

.const TX_UENDS_END = $c000
.const TX_SEED_END  = $0800
.const TX_FETCH_END = $0400
.const TX_VSET_END  = $0300
.const TX_SHADE_END = TX_CLIP       // the clip parameter has the slack now
.const TX_UADV_END  = $d000
.const TX_PIX_END   = $a000
.const TX_COL_END   = $ce08
.const TX_UPD_END   = $0e00
.const TX_WSPAN_END = $8400
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

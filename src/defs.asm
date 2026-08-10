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

// Collision helpers, out of line from the main segment. $0e70-$0eff, 144 B.
.const COLLCODE = $0e70

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
// Three blocks are free and are now the largest unclaimed RAM below MATRIX:
// $0cb3-$0cff, $0d33-$0d3f (SPHCODE's and UDIV8's own tails) and
// $0fc4-$0fff (60 B, where sphereVisible used to live).
.const SPHCODE   = $0c30
.const UDIV8     = $0d00            // udiv's short path -- math.asm
.const FTCODE    = $0d40            // frame-time statistics -- clock.asm
.const SPHEND    = $0e00            // MAPINFO: what the block above must clear
.const SPHCODE3  = $0e20

// $ff40-$fff9, 186 B, is free RAM and deliberately still unclaimed. BITMAP1
// ends at $ff3f and nothing follows it; code can live there at all because both
// banking states the engine uses ($34 and $35) have HIRAM = 0, so the KERNAL is
// out and it is RAM in either window (src/irqtest.asm established that). The
// six bytes above it, $fffa-$ffff, are the NMI/RESET/IRQ vectors, read from
// exactly this RAM when an interrupt is taken with HIRAM = 0.
//
// Nothing is put there, and that is a decision rather than an oversight.
// Reaching past $CFDA extends the PRG image over $D000-$DFFF, so loading it
// writes 4 KB of filler across the I/O space -- harmless under VICE's RAM
// injection, but it depends on how the loader banks memory, and the U64 path
// is a DMA whose behaviour there nobody has tested. udiv's short path was
// assembled here first and moved back down once mapLoad's relocation freed
// low RAM; the measurement was identical either way. This block is M2's, for
// the audio interrupt that has to reach $fffe.

// bsp.asm lands in two pieces. The traversal proper follows doWall in the walls segment; the node test
// and the standalone descent go in the tail of TABLES_FREE. Two pieces
// because the free RAM comes in two pieces -- neither block alone is big
// enough. Both are asserted against what follows them.
// $ce08 is where doWall ends, not a round number: the sphere test's node hook
// spent the alignment slack that used to sit between them. walls.asm's own
// .errorif is what keeps doWall from growing back into this.
.const BSPCODE  = $ce08             // after the walls segment, up to $cfff
.const BSPCODE2 = TABLES_FREE + SEGBUFSZ    // $97c0, tail of TABLES_FREE

// seg record field offsets within SEGBUF, indexed by the seg's byte offset in
// X. docs/reu-format.md §5.1 froze this layout; a seg is 10 bytes.
.const SEGSZ    = 10
.const sgX0     = SEGBUF + 0
.const sgY0     = SEGBUF + 2
.const sgX1     = SEGBUF + 4
.const sgY1     = SEGBUF + 6
.const sgBack   = SEGBUF + 8
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

// image header field offsets — docs/reu-format.md §2
// 2 added the bounding spheres: the eight-byte subsector slot header and
// block 4. A version-1 image loads none of it, so mapload.asm rejects it
// rather than reading zeroes as spheres of radius nothing and culling the
// entire map.
.const MAPFMT_VERSION = 2
.const hdrMagic     = MAPHDR + 0    // "D64U"
.const hdrVersion   = MAPHDR + 4
.const hdrBlocks    = MAPHDR + 5
.const hdrDescs     = MAPHDR + 8    // blockCount x 8 bytes
.const HDRSIZE      = 64

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
.const MOVE_SPEED = 14              // world units per frame
.const TURN_SPEED = 3               // angle units (of 256) per frame
.const MAXSTEP = 24                 // tallest step the player can climb
.const MINHEAD = 56                 // headroom needed to fit through an opening
.const PLRAD   = 16                 // player radius, Doom's own value

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
// zInput bits. Keyboard and joystick merge with a single `ora`, so the
// low four bits must keep matching joystick 2's up/down/left/right.
//------------------------------------------------------------
.const IN_FWD    = %00000001        // W        / joy up
.const IN_BACK   = %00000010        // S        / joy down
.const IN_LEFT   = %00000100        // A        / joy left    -- turn left
.const IN_RIGHT  = %00001000        // D        / joy right   -- turn right
.const IN_SLEFT  = %00010000        // Q                      -- strafe left
.const IN_SRIGHT = %00100000        // E                      -- strafe right
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
.const zWallByte = $3a
.const zBack   = $3b
.const zWIdx   = $3c
.const zWCnt   = $3d
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
.const msLast  = $90        // CIA2 Timer B at the last completed frame
.const msNow   = $92        // scratch for a torn-read-safe timer read
.const msFrame = $96        // ... at the last completed flip (see ftInt below)

// The bounding sphere's radius, world units, live across the transform.
.const zRad    = $94


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
.const accTop  = $68
.const accBot  = $6b
.const accBT   = $6e
.const accBB   = $71
.const stepTop = $74
.const stepBot = $76
.const stepBT  = $78
.const stepBB  = $7a

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

.const WALLS2         = $9d80      // walls helper routines after math code

// The millisecond clock and the frame pacer, in the gap between the walls
// helpers and BITMAP0. 114 B, $9f8e-$9fff.
.const CLKCODE        = $9f8e

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
// at 50 fps moves the player twice as fast as a complex one at 25 fps. The
// cap makes 50 fps unreachable and pins the common case at 25.
//
// THE UNIT IS A TIMER B TICK, NOT A MILLISECOND. PAL phi2 is 985248 Hz, not
// 1 MHz, so a Timer A latch of 1000 underflows every 1.015 ms. Hardware
// confirms it: `make u64-fps` measured 9871 CIA ticks against 10049 host
// milliseconds, a ratio of 0.982 where PAL predicts 0.985.
//
// That is what fixes this number at 39 and makes 39 the *maximum*:
//
//   39 ticks = 39.58 ms   <  two PAL frames (39.90 ms)   -- lands on the
//   40 ticks = 40.60 ms   >  two PAL frames              second crossing
//
// The wait hands over to flip's raster sync, which then lands on the next
// line-251 crossing. At 40 every frame would miss that crossing and cost a
// third raster frame -- 16.7 fps instead of 25. The 39.58 ms figure is already
// the worst case: msLast is captured mid-tick, so the counter reaches 39
// somewhere between 38 and 39 whole ticks after it, never later.
.const FPS_CAP_TICKS = 39

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

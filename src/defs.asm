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

// Portal traversal stack + per-frame scratch, in the free RAM below MATRIX.
// Parked at $0f00 rather than immediately after the code: main code had grown
// to within three bytes of the old $0b20 base. main.asm asserts the gap.
.const pStkSec = $0f00              // 12 entries
.const pStkXL  = $0f10
.const pStkXR  = $0f20
.const PSTKMAX = 12

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

// $0e00-$0e5f. MAPINFO's page alignment is load-bearing: a block descriptor
// carries only the high byte of its load address (docs/reu-format.md §2).
// $0e60-$0eff is free.
.const MAPINFO  = $0e00             // 32 B, resident block 0
.const MAPHDR   = $0e20             // 64 B, the image header, kept after boot
                                    // so a rejected image can be read back

// One subsector's segs, DMA'd per visit. In TABLES_FREE rather than in the
// $0e00 page because the main segment now ends at $0dc6 and everything below
// MAPINFO is code headroom -- see main.asm's .errorif.
.const SEGBUF   = TABLES_FREE       // 128 B, $9740-$97bf
.const SEGBUFSZ = 128
.errorif SEGBUF + SEGBUFSZ > TABLES_FREE_END, "SEGBUF overruns TABLES_FREE"

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

// image header field offsets — docs/reu-format.md §2
.const MAPFMT_VERSION = 1
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
.const zWIdx2  = $3f

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
// zero page — converter ($40-$4a)
//------------------------------------------------------------
.const zTmp    = $40        // $40-$47: 8 packed bytes of current cell
.const matPage = $48
.const pageCnt = $49
.const backBuf = $4a

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
.const stackN  = $5c
.const zXL     = $5d
.const zXR     = $5e

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

//------------------------------------------------------------
// player spawn (test map)
//------------------------------------------------------------
.const START_X = 512
.const START_Y = 512
.const START_A = 0                  // facing east, toward the portal
.const START_SEC = 0

.const WALLS2         = $9d80      // walls helper routines after math code
.const visitedSec     = $0f30      // per-frame sector visited flags (16 for testmap)

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

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

// portal traversal stack (free space below MATRIX, see main.asm map)
.const pStkSec = $0b20              // 12 entries
.const pStkXL  = $0b30
.const pStkXR  = $0b40
.const PSTKMAX = 12

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

//------------------------------------------------------------
// player spawn (test map)
//------------------------------------------------------------
.const START_X = 512
.const START_Y = 512
.const START_A = 0                  // facing east, toward the portal
.const START_SEC = 0

.const WALLS2         = $9d80      // walls helper routines after math code
.const visitedSec     = $0b50      // per-frame sector visited flags (16 for testmap)

//============================================================
//  testmap.asm — hand-built convex-sector map (SoA layout)
//
//  Winding: clockwise in standard math axes (x east, y north),
//  i.e. sector interior is on the RIGHT of each directed wall.
//
//  Layout: big room A -> low corridor B -> tall room C.
//============================================================

// sector: floor, ceil, floorByte, ceilByte
.var mSec = List()
.eval mSec.add(List().add(   0, 256, $45, $02))     // A: moss floor, dark stone ceiling
.eval mSec.add(List().add(  24, 152, $13, $12))     // B: wood corridor, lower+narrower
.eval mSec.add(List().add( -32, 320, $23, $52))     // C: flesh floor, violet ceiling

// wall: x0,y0, x1,y1, back(-1 = solid), ramp<<4
.var mWall = List()
// --- sector A (walls 0-5)
.eval mWall.add(List().add(   0,   0,    0,1024, -1, $00))
.eval mWall.add(List().add(   0,1024, 1024,1024, -1, $00))
.eval mWall.add(List().add(1024,1024, 1024, 640, -1, $60))
.eval mWall.add(List().add(1024, 640, 1024, 384,  1, $60))  // portal -> B
.eval mWall.add(List().add(1024, 384, 1024,   0, -1, $60))
.eval mWall.add(List().add(1024,   0,    0,   0, -1, $00))
// --- sector B (walls 6-9)
.eval mWall.add(List().add(1024, 384, 1024, 640,  0, $10))  // portal -> A
.eval mWall.add(List().add(1024, 640, 1536, 640, -1, $10))
.eval mWall.add(List().add(1536, 640, 1536, 384,  2, $10))  // portal -> C
.eval mWall.add(List().add(1536, 384, 1024, 384, -1, $10))
// --- sector C (walls 10-16)
.eval mWall.add(List().add(1536, 128, 1536, 384, -1, $20))
.eval mWall.add(List().add(1536, 384, 1536, 640,  1, $20))  // portal -> B
.eval mWall.add(List().add(1536, 640, 1536, 896, -1, $20))
.eval mWall.add(List().add(1536, 896, 2304, 896, -1, $50))
.eval mWall.add(List().add(2304, 896, 2304, 128, -1, $20))
.eval mWall.add(List().add(2304, 128, 1536, 128, -1, $50))

.const NUMSEC   = 3
.const NUMWALLS = 16

.function backByte(b) {
    .if (b < 0) .return $ff
    .return b
}

// sector SoA
secFloorLo: .fill NUMSEC, <mSec.get(i).get(0)
secFloorHi: .fill NUMSEC, >mSec.get(i).get(0)
secCeilLo:  .fill NUMSEC, <mSec.get(i).get(1)
secCeilHi:  .fill NUMSEC, >mSec.get(i).get(1)
secFByte:   .fill NUMSEC, mSec.get(i).get(2)
secCByte:   .fill NUMSEC, mSec.get(i).get(3)
secWFirst:  .byte 0, 6, 10
secWCount:  .byte 6, 4, 6

// wall SoA
wX0Lo: .fill NUMWALLS, <mWall.get(i).get(0)
wX0Hi: .fill NUMWALLS, >mWall.get(i).get(0)
wY0Lo: .fill NUMWALLS, <mWall.get(i).get(1)
wY0Hi: .fill NUMWALLS, >mWall.get(i).get(1)
wX1Lo: .fill NUMWALLS, <mWall.get(i).get(2)
wX1Hi: .fill NUMWALLS, >mWall.get(i).get(2)
wY1Lo: .fill NUMWALLS, <mWall.get(i).get(3)
wY1Hi: .fill NUMWALLS, >mWall.get(i).get(3)
wBack: .fill NUMWALLS, backByte(mWall.get(i).get(4))
wRamp: .fill NUMWALLS, mWall.get(i).get(5)

// player start

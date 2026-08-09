# Hypothesis B — map/sector data bug

**Prediction**: if this hypothesis is correct, some sector's
`secCeilLo/Hi` ≤ `secFloorLo/Hi` (inverted geometry), or some wall's
`wBack` points at a nonsensical sector, which would make a back-sector
projection degenerate by construction (independent of any code bug).

**Method**: read `src/testmap.asm` directly (source of truth before
assembly — no emulator needed) and tabulate every sector and wall.

## Sectors (`mSec`: floor, ceil, floorByte, ceilByte)

| id | floor | ceil | height | floorByte | ceilByte |
|----|------:|-----:|-------:|-----------|----------|
| A (0) | 0 | 256 | 256 | $45 | $02 |
| B (1) | 24 | 152 | 128 | $13 | $12 |
| C (2) | -32 | 320 | 352 | $23 | $52 |

All three have `ceil > floor` by a healthy margin (128-352 units) — no
inversion, no degenerate/zero-height sector. `secCeilLo/Hi`/`secFloorLo/Hi`
values are plain, non-sentinel-looking numbers (not 0, not $ff-pattern,
don't alias another sector's id). **This part of hypothesis B is refuted.**

## Walls (`mWall`: x0,y0,x1,y1, back, ramp)

0-indexed, matching the wall index used throughout `walls.asm` /
`IMPLEMENTATION_PLAN.md` ("wall 8" etc.):

| idx | sector | x0,y0 | x1,y1 | wBack | note |
|----:|--------|-------|-------|------:|------|
| 0 | A | (0,0) | (0,1024) | -1 (solid, $ff) | west wall |
| 1 | A | (0,1024) | (1024,1024) | -1 | north wall |
| 2 | A | (1024,1024) | (1024,640) | -1 | east wall, upper segment |
| 3 | A | (1024,640) | (1024,384) | **1** (→B) | east wall, portal segment |
| 4 | A | (1024,384) | (1024,0) | -1 | east wall, lower segment |
| 5 | A | (1024,0) | (0,0) | -1 | south wall |
| 6 | B | (1024,384) | (1024,640) | **0** (→A) | portal back to A |
| 7 | B | (1024,640) | (1536,640) | -1 | solid |
| 8 | B | (1536,640) | (1536,384) | **2** (→C) | portal to C |
| 9 | B | (1536,384) | (1024,384) | -1 | solid |
| 10 | C | (1536,128) | (1536,384) | -1 | solid |
| 11 | C | (1536,384) | (1536,640) | **1** (→B) | portal back to B |
| 12 | C | (1536,640) | (1536,896) | -1 | solid |
| 13 | C | (1536,896) | (2304,896) | -1 | solid |
| 14 | C | (2304,896) | (2304,128) | -1 | solid |
| 15 | C | (2304,128) | (1536,128) | -1 | solid |

`secWFirst = {0, 6, 10}`, `secWCount = {6, 4, 6}` — matches the 0/6/10
boundaries above exactly. Every `wBack` either is `-1` (→ `$ff`, solid) or
points at a real, adjacent sector whose shared edge matches (A↔B via
walls 3/6, B↔C via walls 8/11) — geometrically consistent, no dangling or
self-referencing portal. **Fully refuted: no map-data defect.**

## Verdict

**Refuted.** Sector heights are sane and non-degenerate; every `wBack` is
geometrically consistent with its neighbor. The bug is in the renderer,
not the map data.

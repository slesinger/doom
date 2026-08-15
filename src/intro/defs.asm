//============================================================
//  defs.asm — intro-only constants.
//
//  Deliberately not shared with src/defs.asm: the intro is a separate
//  program with its own memory map (no MATRIX, no BSP, no map data), and
//  importing the engine's several hundred constants here would suggest a
//  coupling that does not exist. Only the handful this program actually
//  uses are duplicated.
//============================================================

.const BANK_IO    = $35             // I/O at $d000 -- see src/defs.asm
.const TURBOREG   = $d031
.const TURBO_1MHZ = $00             // speed index 0, badlines enabled
.const TURBO_MAX  = $0f             // speed index 15, badlines enabled

// The REU DMA controller's own registers ($DF00-$DF0A), duplicated from
// src/reu.asm/src/defs.asm rather than imported -- see the header above.
// Needed only for the chain-in tail (intro.asm), which fetches the
// GAMECODE payload out of the merged image and jumps into it; nothing
// else in this program touches the REU (the title music is Ultimate
// Audio, ultaudio.asm, a different piece of hardware entirely).
.const REU_STATUS  = $df00
.const REU_COMMAND = $df01
.const REU_C64ADDR = $df02          // + $df03
.const REU_REUADDR = $df04          // + $df05
.const REU_BANK    = $df06
.const REU_LENGTH  = $df07          // + $df08, 0 means 65536
.const REU_ADDRCTL = $df0a          // bit7 fix C64 addr, bit6 fix REU addr
.const REU_FETCH   = $91            // REU -> C64

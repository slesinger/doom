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

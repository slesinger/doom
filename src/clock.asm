//============================================================
//  clock.asm — a millisecond clock, and the frame-rate cap
//
//  The engine had no wall clock. `flip` waits for raster line 251, which
//  pins the frame rate to 50/n and says nothing about how long the frame
//  actually took; the CPU clock is 1 MHz in VICE and 64 MHz on the
//  Ultimate, so cycle counting does not travel either.
//
//  CIA2 supplies one for the price of six stores. Timer A free-runs on
//  phi2 with a 1000-cycle period; Timer B counts A's underflows. CIA phi2
//  is 1 MHz on both machines regardless of the CPU's turbo setting -- the
//  same property that makes CIA timing usable for I/O at all -- so
//  $DD06/$DD07 is a millisecond counter, running *down* from $ffff and
//  wrapping every 65.5 seconds.
//
//  CIA1 was not used because readInput owns it, and its Timer A is left
//  running by the KERNAL as the 60 Hz IRQ source. CIA2 is free: nothing
//  here touches $DD00, which selects the VIC bank in `flip`.
//
//  Interrupts: the engine runs under `sei` from main.asm's first
//  instruction, but `sei` does not mask an NMI, and CIA2 is the NMI
//  source on a C64. msInit therefore clears every CIA2 interrupt mask
//  bit before starting the timers -- without it a timer underflow could
//  vector through $FFFA into whatever the KERNAL left there.
//============================================================

.pc = CLKCODE "clock + frame pacing"

//------------------------------------------------------------
// msInit — start the cascade. Called once, from main.
//------------------------------------------------------------
msInit:
        lda #$7f                    // no CIA2 interrupt source may raise NMI
        sta CIA2_ICR
        lda #<MS_TICKS
        sta CIA2_TALO
        lda #>MS_TICKS
        sta CIA2_TAHI
        lda #$ff                    // Timer B counts the full 16 bits before
        sta CIA2_TBLO               // wrapping: 65.5 s of millisecond ticks
        sta CIA2_TBHI
        lda #%00010001              // A: force load, start, continuous, phi2
        sta CIA2_CRA
        lda #%01010001              // B: force load, start, continuous,
        sta CIA2_CRB                //    counting A's underflows
        jsr msRead                  // seed the pacer's reference point
        lda msNow
        sta msLast
        lda msNow+1
        sta msLast+1
        rts

//------------------------------------------------------------
// msRead — Timer B into msNow, without a torn read.
//
// The two halves are latched separately, so a read that straddles a tick
// can pair a stale high byte with a fresh low one. Reading the high byte
// again and retrying on a change costs eight cycles and removes the case;
// at one tick per millisecond it retries roughly never, but the failure
// it prevents is a 256 ms jump in the pacer.
//------------------------------------------------------------
msRead:
!:      lda CIA2_TBHI
        sta msNow+1
        lda CIA2_TBLO
        sta msNow
        lda CIA2_TBHI
        cmp msNow+1
        bne !-
        rts

//------------------------------------------------------------
// framePace — spin until FPS_CAP_TICKS Timer B ticks have passed since the
// previous call. A tick is 1.015 ms on PAL, not 1 ms -- see defs.asm.
//
// Called from mainLoop immediately before `flip`, so the wait happens
// *before* the raster sync rather than instead of it: this routine decides
// which raster frame the flip may land on, and `flip` still lands it on
// line 251.
//
// Why cap at all. Everything that moves is per-frame -- MOVE_SPEED is
// world units per frame, not per second -- so an uncapped engine walks
// twice as fast through a simple view (50 fps) as through a complex one
// (25 fps). Capping is the cheap half of the fix; making motion
// proportional to elapsed milliseconds is the real one, and now that
// there is a clock it is possible (IMPLEMENTATION_PLAN.md §13).
//
// The timer counts down, so elapsed = (msLast - now) mod 65536. A frame
// slower than 65.5 s would alias, which is not a case worth code.
//------------------------------------------------------------
framePace:
!wait:  jsr msRead
        lda msLast                  // elapsed = msLast - msNow
        sec
        sbc msNow
        tax
        lda msLast+1
        sbc msNow+1
        bne !done+                  // >= 256 ms: long past the cap
        cpx #FPS_CAP_TICKS
        bcc !wait-
!done:  lda msNow                   // the new reference is *now*, not
        sta msLast                  // msLast+cap: a frame that overran its
        lda msNow+1                 // budget must not bank the overrun and
        sta msLast+1                // sprint the next one
        rts

.errorif * > BITMAP0, "clock code overflows into BITMAP0"

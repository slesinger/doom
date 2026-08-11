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
        rts                         // the pacer's reference is msFrame,
                                    // which ftInit seeds a few lines later

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
// **The reference point is the last flip, not the last release**, and that
// is the whole of what makes the pacing stable. Pacing release-to-release
// pins the interval at FPS_CAP_TICKS, which is a whole number of 1.015 ms
// ticks and therefore never a whole number of 19.95 ms raster frames: the
// phase walks by the difference every frame until it crosses a raster line,
// and one frame in every (raster period / drift) lands one crossing early.
// Measured on hardware at 58 ticks: 58.87 ms against a 59.85 ms grid drifts
// 0.98 ms a frame, and 16 of 341 frames came back at 25 fps inside an
// otherwise perfect run. M1 had the same drift and could not show it --
// 37.6 ms of compute made a 39.90 ms frame physically impossible, so the
// beat was floored away rather than absent.
//
// Measuring from msFrame instead resets the reference at every raster
// crossing, so the phase cannot accumulate. It also makes the cap's exact
// value uncritical: `flip` does the quantising, and any wait that lands
// strictly between two crossings picks the same one every time. Hence 49
// ticks -- the middle of the window, ~10 ms of slack on either side --
// rather than the largest value that fits.
//
// The timer counts down, so elapsed = (msFrame - now) mod 65536. A frame
// slower than 65.5 s would alias, which is not a case worth code.
//------------------------------------------------------------
framePace:
        jsr frameStat               // what the frame cost before any waiting
!wait:  jsr msRead
        lda msFrame                 // elapsed = msFrame - msNow
        sec
        sbc msNow
        tax
        lda msFrame+1
        sbc msNow+1
        bne !done+                  // >= 256 ms: long past the cap
        cpx #FPS_CAP_TICKS
        bcc !wait-
!done:  rts                         // no reference to update: frameMark
                                    // re-seeds msFrame at the flip itself,
                                    // so an overrun cannot be banked

.errorif * > BITMAP0, "clock code overflows into BITMAP0"

//============================================================
//  Frame-time statistics — what the average frame rate cannot say
//
//  `make u64-fps` measures 44.0 ms/frame on hardware. That number is an
//  average of quantised ones: `flip` syncs to raster line 251, so every
//  frame costs a whole multiple of 19.95 ms whatever the work took, and
//  44.0 decomposes as 39.90 x 79% + 59.85 x 21%. It says one frame in five
//  misses the 25 fps deadline. It cannot say by how much, and that is the
//  only number that decides whether more optimisation is worth anything:
//  compute a millisecond over the line and compute ten milliseconds over
//  it read exactly the same from outside.
//
//  So the engine times itself. Two reference points per frame -- one at the
//  flip, one when the renderer hands over to the pacer -- give the interval
//  (which raster frame it landed on) and the compute (what the work cost).
//  min and max over a run bound the frame-to-frame variation, which is the
//  open question: a static camera doing deterministic work should land on
//  the *same* raster frame every time, and it demonstrably does not.
//
//  Cost is three msReads and about sixty cycles a frame -- under a
//  microsecond at 64 MHz, i.e. a thousandth of what it measures. That is
//  why this is not behind INSTRUMENT: a measurement you have to make a
//  special build for is a measurement you make once.
//============================================================

.pc = FTCODE "frame-time statistics"

//------------------------------------------------------------
// ftInit — zero the accumulators and seed the reference point. From main,
// after msInit.
//------------------------------------------------------------
ftInit:
        lda #0
        ldx #15
!:      sta ftInt,x                 // ftInt .. ftHist+7
        dex
        bpl !-
        lda #$ff                    // min starts at +infinity
        sta ftCMin
        sta ftCMin+1
        jsr msRead
        lda msNow
        sta msFrame
        lda msNow+1
        sta msFrame+1
        rts

//------------------------------------------------------------
// frameStat — elapsed since the flip, i.e. this frame's compute. Called
// from framePace's first line, before it waits: after the wait every frame
// reads the same and the number is worthless.
//
// Timer B counts down, so elapsed = msFrame - msNow.
//------------------------------------------------------------
frameStat:
        jsr msRead
        lda msFrame
        sec
        sbc msNow
        sta ftComp
        lda msFrame+1
        sbc msNow+1
        sta ftComp+1
        lda ftComp                  // ftComp < ftCMin ?
        cmp ftCMin
        lda ftComp+1
        sbc ftCMin+1
        bcs !max+
        lda ftComp
        sta ftCMin
        lda ftComp+1
        sta ftCMin+1
!max:   lda ftCMax                  // ftCMax < ftComp ?
        cmp ftComp
        lda ftCMax+1
        sbc ftComp+1
        bcs !done+
        lda ftComp
        sta ftCMax
        lda ftComp+1
        sta ftCMax+1
!done:  rts

//------------------------------------------------------------
// frameMark — close the frame. From mainLoop, immediately after flip, so
// the reference point is the raster crossing itself and not the moment the
// pacer released the frame towards it.
//
// The interval is bucketed by how many raster frames it spans. A tick is
// 1.015 ms, so one raster frame is 19.65 ticks, two are 39.3 and three are
// 59.0; the thresholds sit in the gaps, where nothing legitimate lands.
//
// The buckets do not move with FPS_CAP_TICKS -- they count raster frames,
// which is a property of the VIC. What moves is which bucket means "on
// time": two in M1, three in M2 (TARGET_FRAMES in tools/u64push.py).
//------------------------------------------------------------
frameMark:
        jsr msRead
        lda msFrame                 // interval = msFrame - msNow
        sec
        sbc msNow
        sta ftInt
        lda msFrame+1
        sbc msNow+1
        sta ftInt+1
        lda msNow                   // this flip is the next frame's zero
        sta msFrame
        lda msNow+1
        sta msFrame+1
        ldx #6                      // 4+ raster frames, or over 256 ticks
        lda ftInt+1
        bne !bump+
        lda ftInt
        cmp #30                     // < 30: one raster frame, 50 fps
        bcc !one+
        cmp #50                     // < 50: two, i.e. the 25 fps deadline
        bcc !two+
        cmp #69                     // < 69: three
        bcs !bump+
        ldx #4
        bne !bump+                  // always: X = 4
!one:   ldx #0
        beq !bump+                  // always: X = 0
!two:   ldx #2
!bump:  inc ftHist,x
        bne !done+
        inc ftHist+1,x
!done:  rts

.errorif * > SPHEND, "the frame-time statistics overflow into MAPINFO"

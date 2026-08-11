//============================================================
//  reuload.asm — host-driven REU image uploader
//
//  A standalone PRG whose only job is to move bytes the host has
//  DMA'd into C64 RAM out into REU RAM, because the C64 Ultimate's
//  own "REU Preload" setting does not deliver them.
//
//  WHY THIS EXISTS
//
//  IMPLEMENTATION_PLAN.md Phase 1.2 established that the .reu file
//  reaches the Ultimate over FTP and that REU Preload Image /
//  Offset / Preload all arm and read back as armed. What it could
//  not check -- because nothing on the C64 side read $df00 yet --
//  was whether the bytes actually land in REU RAM. With
//  mapload.asm in place they can be checked, and on firmware
//  1.1.0 / core 1.49 they do not:
//
//    * the file is present and the right size (FTP SIZE says so)
//    * all three preload settings read back correct
//    * REU offset 0 still holds whatever was last written to it
//      by a running program, across any number of resets
//
//  Tried and did not help: re-running with the setting already
//  armed, saving the config to flash and resetting, toggling
//  "RAM Expansion Unit" off and on, toggling "REU Preload" off and
//  on, and matching REU Size to the image size (128 KB) in case
//  preload demands an exact fit the way VICE's -reuimage does.
//
//  So the delivery path does not depend on that feature any more.
//  The host writes a chunk into C64 RAM with machine:writemem --
//  which is a DMA and needs no cooperation from the running
//  program -- then writes an 8-byte mailbox, and this stub issues
//  the REU stash. VICE keeps using -reuimage, which does work
//  (see the Makefile).
//
//  THE MAILBOX
//
//  Laid out so the trigger byte is written LAST. The host writes
//  all eight bytes in one writemem, and a DMA fills ascending
//  addresses, so a trigger at the end cannot be seen before the
//  parameters it describes.
//
//    $0340  c64 address lo/hi     source in C64 RAM
//    $0342  reu address lo/hi     destination in REU RAM
//    $0344  reu bank
//    $0345  length lo/hi          0 means 65536, per the REU
//    $0347  go: 1 = stash, 2 = fetch, $ff = finish; cleared
//           back to 0 when the transfer is done
//
//  $ff is FINISH, not "chunk done": rlDone below never performs
//  another transfer. It does keep clearing the trigger byte, so a
//  host that sends it too early is answered normally and its later
//  commands vanish -- which is not a hang but a wrong readback, and
//  cost a day on 2026-08-11 (docs/reu-format.md §9.3).
//
//  The host polls the trigger byte back to 0 to know the transfer
//  completed. `fetch` exists so an upload can be read back and
//  compared without trusting the writing path to verify itself.
//============================================================

#import "defs.asm"

.const MBOX     = $0340
.const mbC64    = MBOX + 0
.const mbReu    = MBOX + 2
.const mbBank   = MBOX + 4
.const mbLen    = MBOX + 5
.const mbGo     = MBOX + 7

.const GO_STASH = 1
.const GO_FETCH = 2
.const GO_DONE  = $ff

// Left for the host to read: 1 once the stub is up and polling, so
// a "nothing happened" can be told from "the PRG never started".
.const RLREADY  = $0348

.pc = $0801 "basic"
:BasicUpstart2(rlMain)

.pc = $0810 "reuload"
rlMain:
        sei
        lda #0
        sta mbGo                    // ignore whatever was in RAM at reset
        jsr reuInit
        lda #1
        sta RLREADY

rlLoop:
        lda mbGo
        beq rlLoop
        cmp #GO_DONE
        beq rlDone

        pha                         // keep the command; 1 = stash, 2 = fetch
        lda mbC64
        sta REU_C64ADDR
        lda mbC64+1
        sta REU_C64ADDR+1
        lda mbReu
        sta REU_REUADDR
        lda mbReu+1
        sta REU_REUADDR+1
        lda mbBank
        sta REU_BANK
        lda mbLen
        sta REU_LENGTH
        lda mbLen+1
        sta REU_LENGTH+1
        pla

        cmp #GO_FETCH
        beq !fetch+
        lda #REU_STASH
        jmp !fire+
!fetch: lda #REU_FETCH
!fire:  sta REU_COMMAND

        lda #0
        sta mbGo                    // the host polls this back to zero
        jmp rlLoop

rlDone:
        lda #0
        sta mbGo
        inc $d020                   // visible sign of life; harmless
        jmp rlDone

#import "reu.asm"

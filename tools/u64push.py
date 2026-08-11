#!/usr/bin/env python3
"""Push build/doom.prg to a C64 Ultimate / Ultimate 64 and run it.

    python3 tools/u64push.py 192.168.1.65 build/doom.prg
    python3 tools/u64push.py 192.168.1.65 build/doom.prg --fps 10
    python3 tools/u64push.py 192.168.1.65 build/doom.prg --reu build/assets.reu

The PRG goes over the REST API, which resets the machine, DMAs the image
into RAM and starts it -- no disk image, no drive emulation.

REU images take one of two other routes, selected by --reu-mode:

  stash (default)  DMA the image into C64 RAM in 16 KB chunks and have
                   src/reuload.asm stash each one into the REU, reading
                   every chunk back with a matching fetch.
  preload          upload the image over FTP to the path the machine's
                   *REU Preload Image* setting names. The Ultimate loads
                   it into REU RAM on a reset -- but **not** on any reset
                   this tool can ask for: neither machine:reset nor the
                   reset inside run_prg triggers it (measured, by
                   poisoning REU RAM and reading it back). Only a reset
                   from the machine's own menu or a power cycle does. So
                   this mode uploads the file and tells you to do that;
                   it cannot finish the job on its own.

--verify-reu reads the whole used region of REU RAM back through the
same stub and diffs it against the local image. That is the check that
covers the *streamed* blocks; --verify-map only covers the three
resident ones, and an image whose first 16 KB arrived and whose tail did
not passes --verify-map while rendering garbage.

--fps reads the engine's frame counter (frameCnt, see src/defs.asm) twice

over a wall-clock interval and reports the real frame rate. It is a DMA
read over the network, so it does not perturb the running engine beyond
the few stolen cycles of the DMA itself.

It then reports what the engine timed about itself: compute per frame and
which raster frame each one landed on. The frame rate alone cannot separate
"the renderer is 1 ms over the deadline" from "10 ms over" -- `flip`
quantises both to the same 59.85 ms -- and those two want opposite work.
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time

from u64 import Ultimate, U64Error, add_host_args

# Must match `.const frameCnt` in src/defs.asm.
FRAMECNT_ADDR = 0x0F40
CIA2_TBLO = 0xDD06            # `.const CIA2_TBLO` in src/defs.asm

# The engine's own frame timer -- `.const ftInt` in src/defs.asm, 16 bytes:
# ftInt, ftComp, ftCMin, ftCMax, then four 16-bit histogram buckets.
FT_ADDR = 0x02A0

# PAL's frame period. The VIC's raster is the only absolutely-known frequency
# on the machine -- it does not care what the CPU or the turbo are doing -- so
# it is what calibrates everything else here.
PAL_FRAME_MS = 19.9504

# One Timer B tick is a Timer A period, i.e. 1000 phi2 cycles at PAL's
# 985248 Hz. Not a millisecond -- see FPS_CAP_TICKS in src/defs.asm.
TICK_MS = 1000.0 * 1000.0 / 985248.0

REU_CATEGORY = "C64 and Cartridge Settings"


# --- host-driven REU upload (src/reuload.asm) -------------------------------
#
# The Ultimate's own REU Preload does not deliver the image on firmware 1.1.0 /
# core 1.49: the file uploads, all three settings arm and read back correct,
# and REU RAM still holds whatever a running program last wrote there. See the
# comment block at the top of src/reuload.asm for everything that was tried.
#
# So the bytes go the other way: machine:writemem DMAs a chunk into C64 RAM,
# and a small resident stub issues the REU stash. Every chunk is read back with
# a matching REU fetch and compared, because this is precisely the leg of the
# path that turned out not to be trustworthy.

RELOAD_PRG = "build/reuload.prg"
MBOX = 0x0340                    # must match src/reuload.asm
RLREADY = 0x0348
RELOAD_BUF = 0x1000              # C64 staging buffer; free while the stub runs
# Tried doubling this to 32768 to cut the intro's ~470-chunk upload in half;
# on real hardware the *second* chunk then came back with all 32768 bytes
# wrong, reproducibly, while 16384 has never done that across thousands of
# chunks. Something in the Ultimate's own path -- HTTP body handling, the
# REU DMA, or the fetch-back read -- has a boundary here that is not
# documented anywhere this project has found it, so this stays at the size
# that is known to work rather than the size that would be faster.
RELOAD_CHUNK = 16384

GO_STASH, GO_FETCH, GO_DONE = 1, 2, 0xFF

# NOTE (2026-08-11): most of what the machinery below was built for was one
# bug, not the machine -- _stash_chunk sent GO_DONE after *every* chunk, and
# GO_DONE terminates the stub (see finish_stub). Every upload past one chunk
# therefore failed at chunk 2, in-place retries could not help, and a stub
# restart "recovered" exactly one more chunk, which is what made a
# deterministic failure look intermittent. What remains below is the residue:
# the HTTP-level 404s are real and were seen independently, so the retry path
# stays, but its failure rate should now be nothing like what these comments
# describe.
#
# The intro's music REU (build/intro.reu, ~7.6 MB used) pushes several
# hundred chunks through this loop, each several HTTP round trips, and two
# distinct failures have been seen: an occasional "HTTP 404 Could not read
# data from attachment" from the Ultimate's own web server on a writemem or
# a mailbox poll, and -- confirmed by hand, more than once, with identical
# code and identical data on both sides of it -- a chunk whose fetch-and-
# verify comes back completely wrong (every byte) for no HTTP-visible
# reason. Both are genuinely intermittent, not triggered by anything about
# the chunk itself: the same stash+fetch of the same bytes at the same REU
# offset, run again from a fresh reset, has been clean every time it was
# retried that way.
#
# What does NOT clear it is retrying the identical mbox command against
# the *same* running stub -- 8 in-place retries, 3 s apart, recovered a
# stuck chunk zero times across several attempts. Only a fresh run_prg
# did, reliably. So a chunk gets a short in-place retry first (cheap, and
# occasionally enough for the HTTP-level failure), and only escalates to
# restarting the stub if that is exhausted.
#
# Restarting is not free, though: run_prg does real work on the Ultimate
# per call, and ~10 of them inside a minute (no restraint, tried once)
# left it answering every run_prg with "Cannot open file" -- some internal
# resource it opens per call, exhausted -- which a plain machine:reset did
# not clear either; recovering needed a power cycle. RESTART_COOLDOWN and
# STUB_RESTARTS both exist to keep this from happening again: restarts are
# spaced out and capped well under where that was seen.
CHUNK_RETRIES = 3
CHUNK_RETRY_DELAY = 2.0
STUB_RESTARTS = 6
RESTART_COOLDOWN = 8.0


def image_used_bytes(img: bytes) -> int:
    """How much of a padded .reu image actually carries data.

    Two image shapes reach here: the engine's own D64U block format
    (wad2reu.py), whose header says exactly how much is used, and a plain
    padded blob (tools/mp3topcm.py's PCM for the intro), which carries no
    header at all. The second is told apart by the missing magic and
    measured by trimming its trailing zero padding instead -- silence in
    8-bit *unsigned* PCM sits at $80, not $00, so trailing zero bytes can
    only be the pad mp3topcm.py itself appended, never audio content.
    """
    if img[:4] != b"D64U":
        return len(img.rstrip(b"\x00")) or 1
    end = 64
    for i in range(img[5]):
        _bid, _flags, o0, o1, o2, length, _hi = struct.unpack_from(
            "<BBBBBHB", img, 8 + i * 8)
        end = max(end, (o0 | o1 << 8 | o2 << 16) + length)
    return end


def _mbox(u: Ultimate, c64: int, reu: int, length: int, go: int) -> None:
    """Fire one transfer and wait for the stub to acknowledge it.

    The trigger byte is last in the mailbox and the whole thing goes in one
    writemem, so the stub cannot see `go` before the parameters it describes.
    """
    u.writemem(MBOX, struct.pack("<HHBHB", c64, reu & 0xFFFF, reu >> 16,
                                 length & 0xFFFF, go))
    for _ in range(200):
        if u.readmem(MBOX + 7, 1)[0] == 0:
            return
        time.sleep(0.02)
    raise U64Error("REU loader did not acknowledge a transfer")


RELOAD_SETTLE = 3.0               # see start_stub


def start_stub(u: Ultimate) -> None:
    """(Re)start src/reuload.asm and wait until it is ready for commands."""
    if not os.path.isfile(RELOAD_PRG):
        raise U64Error(f"{RELOAD_PRG} is missing -- run `make {RELOAD_PRG}`")
    with open(RELOAD_PRG, "rb") as fh:
        u.run_prg(fh.read())

    for _ in range(100):
        if u.readmem(RLREADY, 1)[0] == 1:
            break
        time.sleep(0.1)
    else:
        raise U64Error("REU loader did not start")

    # RLREADY going to 1 says the stub is polling its mailbox; it does not
    # say the Ultimate is done with its own post-reset housekeeping. That
    # housekeeping is exactly what WARMUP_SECONDS in measure_fps sits out
    # before trusting the frame counter -- and the same thing this waits
    # out here, for the same reason: it narrows how often the first couple
    # of chunks after a reset misbehave, it does not eliminate it.
    time.sleep(RELOAD_SETTLE)


def upload_reu(u: Ultimate, image: str) -> None:
    with open(image, "rb") as fh:
        img = fh.read()
    used = image_used_bytes(img)
    total_chunks = (used + RELOAD_CHUNK - 1) // RELOAD_CHUNK
    print(f"uploading {used} of {len(img)} bytes into REU RAM "
          f"({total_chunks} chunks)")

    start_stub(u)
    restarts = 0
    ofs = 0
    while ofs < used:
        chunk = img[ofs:ofs + RELOAD_CHUNK]
        try:
            _stash_with_retries(u, ofs, chunk)
        except U64Error as exc:
            restarts += 1
            if restarts > STUB_RESTARTS:
                raise U64Error(f"${ofs:06X}: still failing after "
                               f"{STUB_RESTARTS} stub restarts: {exc}")
            print(f"  ${ofs:06X} +{len(chunk):<6} failed ({exc}) -- "
                  f"restarting the loader stub "
                  f"({restarts}/{STUB_RESTARTS}) and pausing "
                  f"{RESTART_COOLDOWN:.0f}s first")
            time.sleep(RESTART_COOLDOWN)
            start_stub(u)
            continue                # retry this same chunk on the fresh stub
        print(f"  ${ofs:06X} +{len(chunk):<6} stashed and verified")
        ofs += RELOAD_CHUNK
    finish_stub(u)


def _stash_with_retries(u: Ultimate, ofs: int, chunk: bytes) -> None:
    for attempt in range(1, CHUNK_RETRIES + 1):
        try:
            _stash_chunk(u, ofs, chunk)
            return
        except U64Error as exc:
            if attempt == CHUNK_RETRIES:
                raise
            print(f"  ${ofs:06X} +{len(chunk):<6} attempt {attempt} "
                  f"failed ({exc}) -- retrying")
            time.sleep(CHUNK_RETRY_DELAY)


def _stash_chunk(u: Ultimate, ofs: int, chunk: bytes) -> None:
    """One chunk's worth of the loop body in upload_reu -- factored out so
    a transient failure partway through can retry the whole thing instead
    of leaving REU RAM at that offset in a state nothing checks again."""
    u.writemem(RELOAD_BUF, chunk)
    _mbox(u, RELOAD_BUF, ofs, len(chunk), GO_STASH)

    # read it straight back out of the REU, through the same DMA engine
    u.writemem(RELOAD_BUF, b"\0" * len(chunk))
    _mbox(u, RELOAD_BUF, ofs, len(chunk), GO_FETCH)
    back = u.readmem(RELOAD_BUF, len(chunk))
    if back != chunk:
        n = sum(1 for a, b in zip(back, chunk) if a != b)
        raise U64Error(f"REU verify failed at offset {ofs}: "
                       f"{n} of {len(chunk)} bytes differ")


def finish_stub(u: Ultimate) -> None:
    """Tell the stub to stop polling. Once, after the last chunk.

    GO_DONE is not "chunk complete" -- it is *terminate*: rlDone in
    src/reuload.asm is an infinite loop that performs no more transfers.
    It does keep clearing the trigger byte, so every later command is
    acknowledged instantly and silently ignored, and the host sees not a
    hang but a verify failure -- the fetch never ran, so the readback is
    the zeros the host itself staged.

    This lived inside _stash_chunk from the retry refactor until
    2026-08-11, which made every upload past one chunk fail at chunk 2,
    always, with a byte count equal to the non-zero bytes of that chunk.
    It is also the whole of the "intermittent" corruption the retry and
    stub-restart machinery above was built for: retrying in place could
    not work (the stub was dead), and restarting it "recovered" exactly
    one further chunk, which is what made it look transient.
    """
    u.writemem(MBOX, struct.pack("<HHBHB", 0, 0, 0, 0, GO_DONE))


def verify_reu(u: Ultimate, image: str) -> int:
    """Diff the whole used region of REU RAM against the local image.

    verify_map covers the three resident blocks, which all live in the
    first 4 KB of the image; the streamed blocks -- SSECDATA and NODESPH,
    which is most of it and all of the per-frame geometry -- were covered
    by nothing until this existed. An image whose head arrived and whose
    tail did not therefore passed every check the tool had while
    rendering visibly wrong walls, which is exactly what happened on
    2026-08-11.

    Uses the same stub as the uploader, so it resets the machine: call it
    before run_prg, not after.
    """
    with open(image, "rb") as fh:
        img = fh.read()
    used = image_used_bytes(img)
    print(f"reu: reading back {used} bytes and diffing against {image}")

    start_stub(u)
    rc = 0
    for ofs in range(0, used, RELOAD_CHUNK):
        n = min(RELOAD_CHUNK, used - ofs)
        u.writemem(RELOAD_BUF, b"\0" * n)
        _mbox(u, RELOAD_BUF, ofs, n, GO_FETCH)
        got = u.readmem(RELOAD_BUF, n)
        want = img[ofs:ofs + n]
        if got == want:
            print(f"reu:   ${ofs:06X} +{n:<6} matches")
            continue
        bad = [i for i in range(n) if got[i] != want[i]]
        print(f"reu:   *** ${ofs:06X} +{n}: {len(bad)} bytes differ, first at "
              f"${ofs + bad[0]:06X} (want {want[bad[0]]:02X}, "
              f"got {got[bad[0]]:02X}) ***")
        rc = 1
    finish_stub(u)
    if rc == 0:
        print("reu: image delivered intact, streamed blocks included")
    return rc


def _reu_size_bytes(setting: str) -> int | None:
    """'512 KB' / '16 MB' -> bytes. None if the string is not one of those."""
    parts = str(setting).split()
    if len(parts) != 2 or not parts[0].isdigit():
        return None
    unit = {"KB": 1024, "MB": 1024 * 1024}.get(parts[1].upper())
    return int(parts[0]) * unit if unit else None


MENU_HINT = ("arm it once from the Ultimate's own menu -- C64 and Cartridge "
             "Settings -> REU Preload Image / REU Preload Offset (0 KB) / "
             "REU Preload (Enabled). Setting these over the REST API is "
             "accepted and does nothing (docs/reu-format.md §9.2). Or run "
             "with --reu-mode stash.")


def push_reu(u: Ultimate, image: str, remote: str) -> None:
    """Deliver the image the way the Ultimate's own preload does it.

    The file is replaced over FTP; the machine loads it into REU RAM at
    the next reset, and run_prg resets. Nothing is *set* here -- see
    MENU_HINT for why -- only read back and checked, because a preload
    that is not armed fails exactly like a preload that is: the REU
    answers every transfer with whatever its RAM already held.
    """
    size = os.path.getsize(image)
    cfg = u.get_category(REU_CATEGORY)

    enabled = str(cfg.get("REU Preload", "")).strip()
    armed = str(cfg.get("REU Preload Image", "")).strip()
    offset = str(cfg.get("REU Preload Offset", "")).strip()
    if enabled != "Enabled":
        raise U64Error(f"REU Preload is '{enabled or 'unset'}' on the "
                       f"machine, not 'Enabled' -- {MENU_HINT}")
    if armed.lower().lstrip("/") != remote.lower().lstrip("/"):
        raise U64Error(f"REU Preload Image is '{armed}', not '{remote}' -- "
                       f"point it at {remote} or pass --reu-remote {armed}. "
                       f"{MENU_HINT}")
    if offset not in ("0 KB", "0"):
        raise U64Error(f"REU Preload Offset is '{offset}', not '0 KB' -- the "
                       f"image would land at the wrong REU address. "
                       f"{MENU_HINT}")

    # The image is padded to REU_IMAGE_SIZE; a machine whose REU is smaller
    # than that cannot hold it, and the tail is exactly where the music
    # stream lives. Compare rather than assume -- this is the setting that
    # will bite when the tune lands.
    reu_size = _reu_size_bytes(cfg.get("REU Size", ""))
    if reu_size is not None and reu_size < size:
        raise U64Error(f"the machine's REU Size is {cfg.get('REU Size')} but "
                       f"the image is {size} bytes -- raise REU Size in the "
                       f"same menu")

    print(f"uploading {image} ({size} bytes) -> {remote}")
    sent = u.ftp_put(image, remote)
    if sent != size:
        raise U64Error(f"short upload: sent {sent} of {size} bytes")
    print(f"REU preload armed: {armed} at {offset} "
          f"(REU {cfg.get('REU Size')}, {cfg.get('RAM Expansion Unit')})")
    print("*** now reset the machine from its own menu, or power-cycle it: "
          "neither machine:reset nor run_prg's reset triggers preload, so "
          "REU RAM still holds whatever was in it. Nothing here can tell "
          "the difference -- run with --verify-reu afterwards. ***")


# Must match src/defs.asm. mapErr values come from src/mapload.asm.
MAPOK_ADDR = 0x0F47
MAPERR_ADDR = 0x0F48
MAPSUM_ADDR = 0x0F49          # 4 x 16-bit, indexed by block id
MERR = {0: "none", 1: "no REU", 2: "bad magic", 3: "wrong version",
        4: "bad block count", 5: "unknown block id", 6: "load address mismatch",
        7: "block too long", 8: "MAPINFO counts out of range"}


def verify_map(u: Ultimate, image: str) -> int:
    """Check on real hardware that the REU image reached the machine.

    Phase 1 established that the .reu file reaches the Ultimate over FTP and
    that the REU Preload setting arms. What it could not show is that the bytes
    land in REU RAM, because nothing on the C64 side read $DF00 yet. This does:
    it reads back the resident blocks the engine DMA'd out of the REU and
    compares them against the local image, byte for byte.

    Blocks 1 and 2 live under the I/O space at $D000/$DC00, and machine:readmem
    DMAs the bus as the engine has it banked -- so a read there returns the I/O
    registers, not the node table. Those blocks are checked through the 16-bit
    sum mapload.asm computes while it copies them (mapSum, src/defs.asm), which
    is the only view of that RAM anything outside the engine can get.
    """
    ok = u.readmem(MAPOK_ADDR, 1)[0]
    err = u.readmem(MAPERR_ADDR, 1)[0]
    if ok != 1:
        print(f"map: *** NOT LOADED *** mapErr={err} ({MERR.get(err, '?')})")
        return 1
    print("map: engine reports mapOK=1 (header magic and version verified)")

    with open(image, "rb") as fh:
        img = fh.read()
    if img[0:4] != b"D64U":
        print(f"map: local {image} has bad magic {img[0:4]!r}")
        return 1

    rc = 0
    for i in range(img[5]):
        bid, flags, o0, o1, o2, length, loadhi = struct.unpack_from(
            "<BBBBBHB", img, 8 + i * 8)
        if not flags & 1:
            continue
        want = img[(o0 | o1 << 8 | o2 << 16):][:length]
        addr = loadhi << 8
        sm = u.readmem(MAPSUM_ADDR + bid * 2, 2)
        engine_sum = sm[0] | sm[1] << 8
        want_sum = sum(want) & 0xFFFF
        if engine_sum != want_sum:
            print(f"map: *** block {bid} ${addr:04X} +{length}: engine sum "
                  f"${engine_sum:04X}, image says ${want_sum:04X} ***")
            rc = 1
            continue
        under_io = 0xD000 <= addr <= 0xDFFF
        got = b"" if under_io else u.readmem(addr, length)
        if under_io:
            print(f"map: block {bid} ${addr:04X} +{length} verified by "
                  f"checksum ${engine_sum:04X} (under I/O, not host-readable)")
        elif got == want:
            print(f"map: block {bid} ${addr:04X} +{length} verified byte-exact "
                  f"and by checksum ${engine_sum:04X}")
        else:
            n = sum(1 for a, b in zip(got, want) if a != b)
            print(f"map: *** block {bid} ${addr:04X} +{length}: {n} of "
                  f"{length} bytes differ ***")
            rc = 1
    return rc


def read_framecnt(u: Ultimate) -> int:
    raw = u.readmem(FRAMECNT_ADDR, 2)
    if len(raw) < 2:
        raise U64Error(f"readmem returned {len(raw)} bytes, expected 2")
    return raw[0] | (raw[1] << 8)


def read_ms(u: Ultimate) -> int:
    """CIA2 Timer B, the engine's millisecond clock (src/clock.asm).

    Counts *down* from $FFFF and wraps every 65.5 s. `$01` is $35 for the
    whole run, so the Ultimate's DMA read of $DD06 sees the CIA register and
    not the RAM under it. Read as one two-byte burst: the low byte ticks every
    millisecond, so two separate reads could straddle a carry.
    """
    raw = u.readmem(CIA2_TBLO, 2)
    if len(raw) < 2:
        raise U64Error(f"readmem returned {len(raw)} bytes, expected 2")
    return raw[0] | (raw[1] << 8)


# Frames are dropped for the first seconds after a run_prg -- the Ultimate is
# still finishing its own post-reset housekeeping and stealing bus cycles.
# Measured: a 0-5 s window reads 37.8 fps, every 5 s window after that reads
# exactly 50.00. Timing across the transient silently under-reports, so it is
# discarded rather than averaged in.
#
# The engine's own timer has since put a number on it (IMPLEMENTATION_PLAN.md
# §16): the first *two* frames cost 2.30 s each, 58x the frames that follow.
# One of them inside a 20 s window is enough to read 22.7 fps for an engine
# that is running at 25.0, which is exactly what happened once. 3 s of warmup
# cleared it about as often as not, because the wait is for frameCnt to move
# and frameCnt does not move until the first of those two frames has finished.
WARMUP_SECONDS = 20.0


def wait_for_engine(u: Ultimate, deadline: float = 20.0) -> None:
    """Block until frameCnt is advancing, then let the machine settle.

    run_prg resets the machine, and the C64 spends a couple of seconds in
    the BASIC ROM boot before the autostart hands over.
    """
    end = time.monotonic() + deadline
    prev = None
    while time.monotonic() < end:
        try:
            now = read_framecnt(u)
        except U64Error:
            now = None
        if now is not None and prev is not None and now != prev:
            time.sleep(WARMUP_SECONDS)
            return
        prev = now
        time.sleep(0.25)
    raise U64Error(f"frame counter never advanced within {deadline:.0f} s")


def measure_fps(u: Ultimate, seconds: float) -> None:
    wait_for_engine(u)
    report_boot_transient(u)
    reset_frame_stats(u)
    t0 = time.monotonic()
    c0, m0 = read_framecnt(u), read_ms(u)
    time.sleep(seconds)
    c1, m1 = read_framecnt(u), read_ms(u)
    t1 = time.monotonic()

    frames = (c1 - c0) & 0xFFFF          # 16-bit counter, wraps
    elapsed = t1 - t0
    if frames == 0:
        print(f"fps: counter did not advance in {elapsed:.1f} s "
              f"(frameCnt = {c0}) -- the engine is not running, or is "
              f"wedged", file=sys.stderr)
        return
    fps = frames / elapsed
    print(f"fps: {frames} frames in {elapsed:.2f} s = {fps:.2f} fps "
          f"({1000.0 / fps:.1f} ms/frame)")
    check_cia_timebase(m0, m1, elapsed)
    report_frame_stats(u)


# The accumulators run from boot, and the first second after run_prg is not
# representative: the Ultimate is still finishing its own post-reset
# housekeeping and stealing bus cycles (see WARMUP_SECONDS). Clearing them at
# the top of the window keeps that transient out of ftCMax, which is otherwise
# the one number it would dominate.
FT_CLEAR = bytes([0, 0, 0, 0, 0xFF, 0xFF, 0, 0]) + bytes(8)


def report_boot_transient(u: Ultimate) -> None:
    """Say what the warmup just sat out, before clearing it away.

    The accumulators run from the first rendered frame, so reading them at
    the top of the window is a free measurement of the post-reset transient
    -- the thing that made a 25.0 fps engine read 22.7 once.
    """
    try:
        raw = u.readmem(FT_ADDR, 16)
    except U64Error:
        return
    if len(raw) < 16:
        return
    slow = raw[14] | raw[15] << 8            # the 4+ raster frames bucket
    cmax = raw[6] | raw[7] << 8
    if slow:
        print(f"boot: {slow} frame(s) before the window cost up to "
              f"{cmax * TICK_MS / 1000.0:.2f} s each -- the Ultimate's "
              f"post-reset bus stealing, now sat out")


def reset_frame_stats(u: Ultimate) -> None:
    try:
        u.writemem(FT_ADDR, FT_CLEAR)
    except U64Error as e:
        print(f"frame: could not clear the accumulators ({e}) -- min/max "
              f"below include everything since boot", file=sys.stderr)


def report_frame_stats(u: Ultimate) -> None:
    """Print what the engine timed about itself.

    The frame rate above is an average of quantised frames: `flip` syncs to
    raster line 251, so a frame costs a whole number of 19.95 ms periods
    whatever the work took. That average says how many frames missed the
    25 fps deadline; it cannot say by how much, and only the machine can.
    See IMPLEMENTATION_PLAN.md §16.
    """
    raw = u.readmem(FT_ADDR, 16)
    if len(raw) < 16:
        print(f"frame: readmem returned {len(raw)} bytes, expected 16",
              file=sys.stderr)
        return
    val = [raw[i] | raw[i + 1] << 8 for i in range(0, 16, 2)]
    _, comp, cmin, cmax, *hist = val
    if cmin > cmax:                      # cleared, and no frame since
        print("frame: no compute samples -- the engine has not completed a "
              "frame since the accumulators were cleared", file=sys.stderr)
        return

    deadline = 2 * PAL_FRAME_MS
    print(f"frame: compute {comp * TICK_MS:.1f} ms last, "
          f"{cmin * TICK_MS:.1f} min, {cmax * TICK_MS:.1f} max "
          f"(deadline {deadline:.2f} ms)")
    total = sum(hist) or 1
    parts = " ".join(f"{n}x{h}" if n < 4 else f"4+x{h}"
                     for n, h in enumerate(hist, start=1))
    print(f"frame: raster frames {parts} -- "
          f"{100.0 * hist[1] / total:.0f}% made the 25 fps deadline")

    # A frame spanning four or more raster frames is not the renderer being
    # slow; nothing it does varies by a factor of four. It is the post-reset
    # transient bleeding into the window, and it drags the average far enough
    # to look like a general slowdown -- see WARMUP_SECONDS.
    if hist[3]:
        print(f"frame: *** {hist[3]} frame(s) in the window spanned 4+ raster "
              f"frames, worst {cmax * TICK_MS:.0f} ms. That is the Ultimate's "
              f"post-reset housekeeping, not the engine: raise WARMUP_SECONDS "
              f"and measure again before believing the fps line above ***")
        return

    if cmax * TICK_MS <= deadline:
        print("frame: ok -- every frame's compute fits in two raster frames, "
              "so any miss is pacing, not the renderer")
    elif cmin * TICK_MS > deadline:
        print(f"frame: *** every frame overruns by at least "
              f"{cmin * TICK_MS - deadline:.1f} ms -- the renderer is the "
              f"whole story, and 25 fps needs that much off it ***")
    else:
        print(f"frame: *** compute straddles the deadline: "
              f"{deadline - cmin * TICK_MS:.1f} ms under it at best, "
              f"{cmax * TICK_MS - deadline:.1f} ms over it at worst -- "
              f"the spread is what costs the frames, not the average ***")


def check_cia_timebase(m0: int, m1: int, elapsed: float) -> None:
    """Calibrate CIA2 Timer B against the host clock and against PAL.

    `framePace` caps the frame rate on the assumption that CIA phi2 stays at
    1 MHz whatever the turbo is doing -- if it does not, FPS_CAP_TICKS is wrong by
    the turbo ratio and every simple view runs at the wrong speed. `reubench`
    already showed the CIA *rate* is turbo-invariant (it reported the same DMA
    tick counts at 1 MHz and 64 MHz), but that calibration leaned on the REU's
    assumed 1 byte/us. This one leans on nothing: it compares emulated
    milliseconds against the host's own wall clock.

    The counter wraps every 65.5 s, so anything past one wrap is reported as
    unusable rather than guessed at -- and a badly wrong timebase shows up as
    exactly that, which is the informative failure.
    """
    ticks = (m0 - m1) & 0xFFFF           # Timer B counts down
    ratio = ticks / (elapsed * 1000.0)
    print(f"cia: {ticks} CIA ms in {elapsed * 1000.0:.0f} host ms "
          f"= {ratio:.3f} x")
    if elapsed > 60.0:
        print("cia: sample is longer than the counter's 65.5 s wrap -- "
              "rerun with a shorter --fps window")
    elif 0.95 <= ratio <= 1.05:
        print("cia: ok -- Timer B is a real millisecond clock under turbo, "
              "so FPS_CAP_TICKS means what it says")
    else:
        print(f"cia: *** off by {ratio:.3f}x -- FPS_CAP_TICKS in src/defs.asm is "
              f"wrong by that factor ***")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("prg", help="the .prg to run")
    ap.add_argument("--reu", metavar="IMG",
                    help="REU image to deliver before running; ignored if "
                         "the file does not exist")
    ap.add_argument("--reu-mode", choices=("preload", "stash"),
                    default="stash",
                    help="how to deliver it: DMA it in chunk by chunk through "
                         "src/reuload.asm, or FTP it to the machine's preload "
                         "image -- which then needs a menu reset or a power "
                         "cycle by hand (default: %(default)s)")
    ap.add_argument("--reu-remote", default="/Usb0/doom.reu",
                    help="path on the Ultimate to upload the REU image to; "
                         "must be what REU Preload Image already names "
                         "(default: %(default)s)")
    ap.add_argument("--fps", type=float, metavar="SECONDS", nargs="?",
                    const=10.0,
                    help="after starting, measure the frame rate over this "
                         "many seconds (default 10)")
    ap.add_argument("--verify-reu", action="store_true",
                    help="before running, read the whole used region of REU "
                         "RAM back and diff it against the image (covers the "
                         "streamed blocks, which --verify-map does not)")
    ap.add_argument("--verify-map", action="store_true",
                    help="after starting, read back the resident map blocks "
                         "and compare them against the local REU image")
    ap.add_argument("--no-run", action="store_true",
                    help="upload the REU image and set configuration, but "
                         "do not start the PRG")
    args = ap.parse_args(argv)

    if not os.path.isfile(args.prg):
        print(f"error: no such file: {args.prg}", file=sys.stderr)
        return 2

    u = Ultimate(args.host, args.password, timeout=60)

    try:
        info = u.info()
        print(f"{info.get('product', '?')} at {args.host} "
              f"(firmware {info.get('firmware_version', '?')})")

        if args.reu:
            if os.path.isfile(args.reu):
                if args.reu_mode == "preload":
                    push_reu(u, args.reu, args.reu_remote)
                else:
                    upload_reu(u, args.reu)
            else:
                print(f"note: {args.reu} does not exist yet -- "
                      f"running without an REU image")

        rc = 0
        if args.verify_reu:
            if not args.reu or not os.path.isfile(args.reu):
                print("--verify-reu needs --reu <image>", file=sys.stderr)
                return 2
            rc = verify_reu(u, args.reu)

        if args.no_run:
            return rc

        with open(args.prg, "rb") as fh:
            data = fh.read()
        print(f"running {args.prg} ({len(data)} bytes)")
        u.run_prg(data)

        if args.verify_map:
            if not args.reu or not os.path.isfile(args.reu):
                print("--verify-map needs --reu <image>", file=sys.stderr)
                return 2
            wait_for_engine(u)
            rc = verify_map(u, args.reu)

        if args.fps:
            measure_fps(u, args.fps)
        return rc
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())

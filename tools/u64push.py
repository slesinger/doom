#!/usr/bin/env python3
"""Push build/doom.prg to a C64 Ultimate / Ultimate 64 and run it.

    python3 tools/u64push.py 192.168.1.65 build/doom.prg
    python3 tools/u64push.py 192.168.1.65 build/doom.prg --fps 10
    python3 tools/u64push.py 192.168.1.65 build/doom.prg --reu build/assets.reu

The PRG goes over the REST API, which resets the machine, DMAs the image
into RAM and starts it -- no disk image, no drive emulation.

REU images take the other route. The REST API has no "attach REU"
command, so the image is uploaded over the Ultimate's FTP service and
the machine's *REU Preload* setting is pointed at it; the Ultimate then
loads it into REU RAM on the next reset, which run_prg performs anyway.
That is the answer to the open question in IMPLEMENTATION_PLAN.md
Phase 1.2.

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
RELOAD_CHUNK = 16384

GO_STASH, GO_FETCH, GO_DONE = 1, 2, 0xFF


def image_used_bytes(img: bytes) -> int:
    """How much of a padded .reu image actually carries data."""
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


def upload_reu(u: Ultimate, image: str) -> None:
    with open(image, "rb") as fh:
        img = fh.read()
    used = image_used_bytes(img)

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

    print(f"uploading {used} of {len(img)} bytes into REU RAM "
          f"({(used + RELOAD_CHUNK - 1) // RELOAD_CHUNK} chunks)")
    for ofs in range(0, used, RELOAD_CHUNK):
        chunk = img[ofs:ofs + RELOAD_CHUNK]
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
        print(f"  ${ofs:06X} +{len(chunk):<6} stashed and verified")

    u.writemem(MBOX, struct.pack("<HHBHB", 0, 0, 0, 0, GO_DONE))


def push_reu(u: Ultimate, image: str, remote: str) -> None:
    size = os.path.getsize(image)
    print(f"uploading {image} ({size} bytes) -> {remote}")
    sent = u.ftp_put(image, remote)
    if sent != size:
        raise U64Error(f"short upload: sent {sent} of {size} bytes")
    for item, value in (("REU Preload Image", remote),
                        ("REU Preload Offset", "0 KB"),
                        ("REU Preload", "Enabled")):
        u.set_item(REU_CATEGORY, item, value)
    after = u.get_category(REU_CATEGORY)
    if str(after.get("REU Preload", "")).strip() != "Enabled":
        raise U64Error("REU Preload did not enable")
    print(f"REU preload armed: {after.get('REU Preload Image')} "
          f"(REU {after.get('REU Size')}, {after.get('RAM Expansion Unit')})")


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
WARMUP_SECONDS = 6.0


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
                    help="REU image to upload and arm as the preload image; "
                         "ignored if the file does not exist")
    ap.add_argument("--reu-remote", default="/Usb0/doom.reu",
                    help="path on the Ultimate to upload the REU image to "
                         "(default: %(default)s)")
    ap.add_argument("--fps", type=float, metavar="SECONDS", nargs="?",
                    const=10.0,
                    help="after starting, measure the frame rate over this "
                         "many seconds (default 10)")
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
                upload_reu(u, args.reu)
            else:
                print(f"note: {args.reu} does not exist yet -- "
                      f"running without an REU image")

        if args.no_run:
            return 0

        with open(args.prg, "rb") as fh:
            data = fh.read()
        print(f"running {args.prg} ({len(data)} bytes)")
        u.run_prg(data)

        rc = 0
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

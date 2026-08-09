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


# Frames are dropped for the first second or so after a run_prg -- the
# Ultimate is still finishing its own post-reset housekeeping and stealing
# bus cycles. Measured: a 0-5 s window reads 37.8 fps, every 5 s window
# after that reads exactly 50.00. Timing across the transient silently
# under-reports, so it is discarded rather than averaged in.
WARMUP_SECONDS = 3.0


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
    t0 = time.monotonic()
    c0 = read_framecnt(u)
    time.sleep(seconds)
    c1 = read_framecnt(u)
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

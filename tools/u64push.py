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
import sys
import time

from u64 import Ultimate, U64Error, add_host_args

# Must match `.const frameCnt` in src/defs.asm.
FRAMECNT_ADDR = 0x0F40

REU_CATEGORY = "C64 and Cartridge Settings"


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
                push_reu(u, args.reu, args.reu_remote)
            else:
                print(f"note: {args.reu} does not exist yet -- "
                      f"running without an REU image")

        if args.no_run:
            return 0

        with open(args.prg, "rb") as fh:
            data = fh.read()
        print(f"running {args.prg} ({len(data)} bytes)")
        u.run_prg(data)

        if args.fps:
            measure_fps(u, args.fps)
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    return 0


if __name__ == "__main__":
    sys.exit(main())

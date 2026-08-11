#!/usr/bin/env python3
"""Enable the Ultimate Audio sampler and unmute it in the output mixer.

Two settings the intro's music depends on, neither touched by
tools/u64config.py (that one is the engine's turbo profile; this is the
intro's own hardware, and the two programs are pushed independently -- see
the Makefile). Confirmed against a live machine (firmware 1.1.0, core 1.49)
via GET /v1/configs/<category> -- the "Ultimate Audio, Register API" PDF's
§2.1 names ("Ultimate Audio" under "C64 and Cartridge Settings", an "Audio
settings" category with "Left/Right Channel Output") describe an older
firmware's menu wording and do not exist on this one:

    C64 and Cartridge Settings -> Map Ultimate Audio $DF20-DFFF   Enabled
    Audio Mixer                -> Vol Sampler L / Vol Sampler R   not OFF

Without the first, $DF20-$DFFF is not mapped into the I/O space at all and
every write src/intro/ultaudio.asm's uaLoad makes goes nowhere -- silently,
same as the REU registers with "RAM Expansion Unit" off (src/reu.asm).
Without the second, the two channels are muted in the mixer that feeds the
DIN jack and HDMI. Only "OFF" is treated as a fault, not forced to a
specific dB string: a live machine reported "0 dB" where the API's own GET
had echoed back "0 dB" with a leading space earlier in the same session
(cosmetic, and not reproducible by writing that string back -- the readback
never matched what was just set), so this settles for "audible" rather than
chasing an exact round-trip on a value that was never wrong. "Speaker
Mixer" (the piezo speaker some boards carry) is left alone -- a separate,
optional output this program has no opinion about.

    python3 tools/introconfig.py 192.168.1.65            # apply + verify
    python3 tools/introconfig.py 192.168.1.65 --show     # report only
"""
from __future__ import annotations

import argparse
import sys

from u64 import Ultimate, U64Error, add_host_args

CART_CATEGORY = "C64 and Cartridge Settings"
CART_ITEM = "Map Ultimate Audio $DF20-DFFF"
CART_WANT = "Enabled"

MIXER_CATEGORY = "Audio Mixer"
MIXER_ITEMS = ("Vol Sampler L", "Vol Sampler R")
MUTED = "OFF"


def apply_cart(u: Ultimate, show: bool) -> int:
    """0 = already correct, 1 = differs/changed, 2 = fatal."""
    current = u.get_category(CART_CATEGORY)
    if CART_ITEM not in current:
        print(f"error: this machine has no {CART_ITEM!r} under "
              f"{CART_CATEGORY!r} -- is 'Ultimate Audio' available on "
              f"this firmware?", file=sys.stderr)
        return 2
    have = str(current[CART_ITEM]).strip()
    if have == CART_WANT:
        print(f"  ok      {CART_CATEGORY}: {CART_ITEM}: {have}")
        return 0
    if show:
        print(f"  DIFFERS {CART_CATEGORY}: {CART_ITEM}: {have} "
              f"(want {CART_WANT})")
        return 1
    u.set_item(CART_CATEGORY, CART_ITEM, CART_WANT)
    after = str(u.get_category(CART_CATEGORY).get(CART_ITEM, "")).strip()
    if after != CART_WANT:
        print(f"error: {CART_ITEM} did not stick: now {after!r}",
              file=sys.stderr)
        return 2
    print(f"  set     {CART_CATEGORY}: {CART_ITEM}: {have} -> {after}")
    return 1


def check_mixer(u: Ultimate, show: bool) -> int:
    """Only "OFF" is a fault -- see the module docstring."""
    current = u.get_category(MIXER_CATEGORY)
    missing = [k for k in MIXER_ITEMS if k not in current]
    if missing:
        print(f"error: this machine has no {missing} under "
              f"{MIXER_CATEGORY!r}", file=sys.stderr)
        return 2
    muted = [k for k in MIXER_ITEMS if str(current[k]).strip() == MUTED]
    if not muted:
        for k in MIXER_ITEMS:
            print(f"  ok      {MIXER_CATEGORY}: {k}: "
                  f"{str(current[k]).strip()}")
        return 0
    if show:
        for k in muted:
            print(f"  DIFFERS {MIXER_CATEGORY}: {k}: {MUTED} (muted)")
        return 1
    for k in muted:
        u.set_item(MIXER_CATEGORY, k, "0 dB")
        print(f"  set     {MIXER_CATEGORY}: {k}: {MUTED} -> 0 dB")
    return 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    add_host_args(ap)
    ap.add_argument("--show", action="store_true",
                    help="report the current settings, change nothing")
    args = ap.parse_args(argv)

    u = Ultimate(args.host, args.password)
    try:
        cart = apply_cart(u, args.show)
        mixer = check_mixer(u, args.show)
    except U64Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    if cart == 2 or mixer == 2:
        return 2
    if args.show:
        return 1 if (cart or mixer) else 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
